package flasher

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import win "core:sys/windows"
import rl "vendor:raylib"

// Disc dumper: rips a PS1/PS2 disc straight into the flash destination and adds SimpRetro
// (+ core + BIOS) so the result is a ready-to-play Saber game.
//
//   PS2 (DVD or CD): 2048-byte sectors -> <Name>.iso      (core: pcsx2)
//   PS1 (CD):        raw 2352-byte sectors, all tracks -> <Name>.bin + .cue   (core: swanstation)
//   Multi-disc:      "<Name> (Disc N)" per disc + <Name>.m3u; the job waits for each disc swap.
//
// The Dump tab only *selects* a disc and fills in the wizard; the dump itself runs as steps
// of the normal flash job, so it gets the same progress overlay, Cancel, and targets.

foreign import kernel32_dump "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32_dump {
	DeviceIoControl :: proc(h: win.HANDLE, code: u32, in_buf: rawptr, in_size: u32, out_buf: rawptr, out_size: u32, returned: ^u32, overlapped: rawptr) -> win.BOOL ---
	SetFilePointerEx :: proc(h: win.HANDLE, dist: i64, new_pos: ^i64, method: u32) -> win.BOOL ---
	VirtualAlloc :: proc(addr: rawptr, size: uint, alloc_type: u32, protect: u32) -> rawptr ---
	VirtualFree :: proc(addr: rawptr, size: uint, free_type: u32) -> win.BOOL ---
}

DRIVE_CDROM :: 5
IOCTL_STORAGE_CHECK_VERIFY2 :: 0x002D0800
IOCTL_CDROM_READ_TOC :: 0x00024000
IOCTL_CDROM_RAW_READ :: 0x0002403E
FSCTL_ALLOW_EXTENDED_DASD_IO :: 0x00090083
FILE_FLAG_NO_BUFFERING :: 0x20000000
MEM_COMMIT_RESERVE :: 0x3000
MEM_RELEASE :: 0x8000
PAGE_READWRITE :: 0x04
TRACK_MODE_XA_FORM2 :: 1 // full 2352-byte data sectors
TRACK_MODE_CDDA :: 2

RAW_SECTOR :: 2352
ISO_SECTOR :: 2048
PS2_BIOS_SIZE :: 4 * 1024 * 1024

Platform :: enum {
	Unknown,
	PS1,
	PS2,
}

PLATFORM_NAME := [Platform]string{.Unknown = "Data disc", .PS1 = "PlayStation", .PS2 = "PlayStation 2"}
PLATFORM_TAG := [Platform]string{.Unknown = "", .PS1 = "ps1", .PS2 = "ps2"}
PLATFORM_CORE := [Platform]string{.Unknown = "", .PS1 = "swanstation_libretro.dll", .PS2 = "pcsx2_libretro.dll"}

Disc_Info :: struct {
	letter:   u8,
	present:  bool,
	label:    [64]u8, // fixed buffers: copied into the job thread by value
	label_n:  int,
	serial:   [32]u8,
	serial_n: int,
	platform: Platform,
	bytes:    i64, // image size (ISO9660 volume / TOC lead-out)
}

disc_label :: proc(d: ^Disc_Info) -> string { return string(d.label[:d.label_n]) }
disc_serial :: proc(d: ^Disc_Info) -> string { return string(d.serial[:d.serial_n]) }

set_buf :: proc(buf: []u8, n: ^int, s: string) {
	n^ = min(len(s), len(buf))
	copy(buf[:n^], s[:n^])
}

// ---------------------------------------------------------------- probing

optical_letters :: proc() -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	mask := GetLogicalDrives()
	for i in 0 ..< 26 {
		if mask & (u32(1) << u32(i)) == 0 do continue
		root := [4]u16{u16('A' + i), ':', '\\', 0}
		if GetDriveTypeW(wp(root[:])) == DRIVE_CDROM do append(&out, u8('A' + i))
	}
	return out[:]
}

open_volume :: proc(letter: u8, no_buffering := false) -> win.HANDLE {
	path := fmt.tprintf(`\\.\%c:`, letter)
	flags: u32 = no_buffering ? FILE_FLAG_NO_BUFFERING : 0
	return win.CreateFileW(win.utf8_to_wstring(path), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, flags, nil)
}

// "cdrom0:\SLUS_204.69;1" -> "SLUS-20469"
serial_from_boot :: proc(v: string) -> string {
	s := v
	if i := strings.last_index_any(s, "\\:"); i >= 0 do s = s[i + 1:]
	if i := strings.index_byte(s, ';'); i >= 0 do s = s[:i]
	s, _ = strings.replace_all(strings.trim_space(s), "_", "-", context.temp_allocator)
	s, _ = strings.replace_all(s, ".", "", context.temp_allocator)
	return strings.to_upper(s, context.temp_allocator)
}

probe_disc :: proc(letter: u8) -> Disc_Info {
	d := Disc_Info{letter = letter}
	root := [4]u16{u16(letter), ':', '\\', 0}
	name: [64]u16
	if !GetVolumeInformationW(wp(root[:]), win.LPWSTR(raw_data(name[:])), 64, nil, nil, nil, nil, 0) do return d
	d.present = true
	set_buf(d.label[:], &d.label_n, w2s(name[:]))

	if data, err := os.read_entire_file(fmt.tprintf("%c:\\SYSTEM.CNF", letter), context.temp_allocator); err == nil {
		for line in strings.split_lines(string(data), context.temp_allocator) {
			k, _, v := strings.partition(line, "=")
			k = strings.trim_space(k)
			if k == "BOOT2" {
				d.platform = .PS2
				set_buf(d.serial[:], &d.serial_n, serial_from_boot(v))
			} else if k == "BOOT" && d.platform == .Unknown {
				d.platform = .PS1
				set_buf(d.serial[:], &d.serial_n, serial_from_boot(v))
			}
		}
	}
	if d.platform == .PS1 {
		if toc, ok := read_toc(letter); ok do d.bytes = i64(toc.leadout) * RAW_SECTOR
	} else {
		d.bytes = iso_volume_bytes(letter)
	}
	return d
}

// ISO9660 primary volume descriptor (sector 16): "volume space size" at byte 80, little-endian.
iso_volume_bytes :: proc(letter: u8) -> i64 {
	h := open_volume(letter)
	if h == win.INVALID_HANDLE_VALUE do return 0
	defer win.CloseHandle(h)
	buf: [ISO_SECTOR]u8
	got: u32
	if !SetFilePointerEx(h, 16 * ISO_SECTOR, nil, 0) || !win.ReadFile(h, &buf[0], ISO_SECTOR, &got, nil) || got != ISO_SECTOR do return 0
	if string(buf[1:6]) != "CD001" do return 0
	blocks := u32(buf[80]) | u32(buf[81]) << 8 | u32(buf[82]) << 16 | u32(buf[83]) << 24
	return i64(blocks) * ISO_SECTOR
}

Track :: struct {
	number: int,
	audio:  bool,
	lba:    int,
}

Toc :: struct {
	tracks:  [99]Track,
	count:   int,
	leadout: int, // first LBA after the last track
}

read_toc :: proc(letter: u8) -> (toc: Toc, ok: bool) {
	h := open_volume(letter)
	if h == win.INVALID_HANDLE_VALUE do return
	defer win.CloseHandle(h)
	raw: [4 + 100 * 8]u8
	got: u32
	if !DeviceIoControl(h, IOCTL_CDROM_READ_TOC, nil, 0, &raw[0], len(raw), &got, nil) do return
	first, last := int(raw[2]), int(raw[3])
	n := last - first + 1
	if n <= 0 || n > 99 do return
	for i in 0 ..= n { // n tracks + lead-out (0xAA)
		e := raw[4 + i * 8:]
		lba := (int(e[5]) * 60 + int(e[6])) * 75 + int(e[7]) - 150
		if i == n {
			toc.leadout = lba
		} else {
			toc.tracks[i] = Track{number = int(e[2]), audio = (e[1] & 0x4) == 0, lba = lba}
		}
	}
	toc.count = n
	return toc, toc.leadout > 0
}

// ---------------------------------------------------------------- reading

Dump_Speed :: struct {
	start:      time.Tick,
	done, base: i64,
}

dump_report :: proc(sp: ^Dump_Speed, done, total: i64, disc_label: string) {
	sp.done = done
	secs := time.duration_seconds(time.tick_since(sp.start))
	rate := secs > 0.5 ? f64(done) / secs : 0
	eta := ""
	if rate > 0 && total > done {
		left := int(f64(total - done) / rate)
		eta = fmt.tprintf(" · %d:%02d left", left / 60, left % 60)
	}
	step_progress(f32(f64(done) / f64(max(total, 1))), fmt.tprintf("%s%s / %s · %.1f MB/s%s", disc_label, fmt_size(u64(done)), fmt_size(u64(total)), rate / (1024 * 1024), eta))
}

// Copies a 2048-byte-sector disc to `out` as a plain ISO.
dump_iso :: proc(letter: u8, total: i64, out: string, label: string) -> string {
	if total <= 0 do return "Couldn't read the disc size (not an ISO9660 disc?)"
	h := open_volume(letter, no_buffering = true)
	if h == win.INVALID_HANDLE_VALUE do return fmt.tprintf("Couldn't open drive %c: (error %d)", letter, win.GetLastError())
	defer win.CloseHandle(h)
	ret: u32
	DeviceIoControl(h, FSCTL_ALLOW_EXTENDED_DASD_IO, nil, 0, nil, 0, &ret, nil) // read past the filesystem's idea of the end

	f := win.CreateFileW(win.utf8_to_wstring(out), win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if f == win.INVALID_HANDLE_VALUE do return fmt.tprintf("Couldn't create %s", out)
	defer win.CloseHandle(f)

	CHUNK :: 2 * 1024 * 1024
	buf := cast([^]u8)VirtualAlloc(nil, CHUNK, MEM_COMMIT_RESERVE, PAGE_READWRITE) // page-aligned for unbuffered reads
	if buf == nil do return "Out of memory"
	defer VirtualFree(buf, 0, MEM_RELEASE)

	sp := Dump_Speed{start = time.tick_now()}
	pos: i64
	for pos < total {
		if cancelled() do return CANCELLED_MSG
		want := u32(min(i64(CHUNK), total - pos))
		got: u32
		ok := false
		for attempt in 0 ..< 4 {
			if SetFilePointerEx(h, pos, nil, 0) && win.ReadFile(h, buf, want, &got, nil) && got == want {
				ok = true
				break
			}
			if attempt == 1 do step_progress(f32(f64(pos) / f64(total)), fmt.tprintf("Retrying sector %d…", pos / ISO_SECTOR))
			time.sleep(300 * time.Millisecond)
		}
		if !ok {
			// narrow it down sector by sector so the error says where the damage is
			for s := pos; s < pos + i64(want); s += ISO_SECTOR {
				if !SetFilePointerEx(h, s, nil, 0) || !win.ReadFile(h, buf, ISO_SECTOR, &got, nil) || got != ISO_SECTOR {
					return fmt.tprintf("Read error at sector %d (%s in) — clean the disc and try again", s / ISO_SECTOR, fmt_size(u64(s)))
				}
			}
			return fmt.tprintf("Read error around %s — clean the disc and try again", fmt_size(u64(pos)))
		}
		written: u32
		if !win.WriteFile(f, buf, want, &written, nil) || written != want do return "Disk write failed (drive full?)"
		pos += i64(want)
		dump_report(&sp, pos, total, label)
	}
	return ""
}

RAW_READ_INFO :: struct #packed {
	disk_offset:  i64,
	sector_count: u32,
	track_mode:   u32,
}

// Copies every track of a CD as raw 2352-byte sectors into one .bin and writes a matching .cue.
dump_bin_cue :: proc(letter: u8, bin_path, cue_path: string, label: string) -> string {
	toc, ok := read_toc(letter)
	if !ok do return "Couldn't read the disc's table of contents"
	h := open_volume(letter)
	if h == win.INVALID_HANDLE_VALUE do return fmt.tprintf("Couldn't open drive %c: (error %d)", letter, win.GetLastError())
	defer win.CloseHandle(h)

	f := win.CreateFileW(win.utf8_to_wstring(bin_path), win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if f == win.INVALID_HANDLE_VALUE do return fmt.tprintf("Couldn't create %s", bin_path)
	defer win.CloseHandle(f)

	PER :: 16 // sectors per IOCTL (drives cap raw reads around 64 KB)
	buf := cast([^]u8)VirtualAlloc(nil, PER * RAW_SECTOR, MEM_COMMIT_RESERVE, PAGE_READWRITE)
	if buf == nil do return "Out of memory"
	defer VirtualFree(buf, 0, MEM_RELEASE)

	total := i64(toc.leadout) * RAW_SECTOR
	sp := Dump_Speed{start = time.tick_now()}
	for ti in 0 ..< toc.count {
		t := toc.tracks[ti]
		end := ti + 1 < toc.count ? toc.tracks[ti + 1].lba : toc.leadout
		mode: u32 = t.audio ? TRACK_MODE_CDDA : TRACK_MODE_XA_FORM2
		for lba := t.lba; lba < end; {
			if cancelled() do return CANCELLED_MSG
			n := min(PER, end - lba)
			info := RAW_READ_INFO{disk_offset = i64(lba) * ISO_SECTOR, sector_count = u32(n), track_mode = mode}
			got: u32
			ok := false
			for attempt in 0 ..< 4 {
				if DeviceIoControl(h, IOCTL_CDROM_RAW_READ, &info, size_of(info), buf, u32(n * RAW_SECTOR), &got, nil) && got == u32(n * RAW_SECTOR) {
					ok = true
					break
				}
				time.sleep(300 * time.Millisecond)
			}
			if !ok do return fmt.tprintf("Read error at sector %d (track %d) — clean the disc and try again", lba, t.number)
			written: u32
			if !win.WriteFile(f, buf, got, &written, nil) || written != got do return "Disk write failed (drive full?)"
			lba += n
			dump_report(&sp, i64(lba) * RAW_SECTOR, total, label)
		}
	}

	// cue sheet: one file, INDEX 01 at each track's start (MM:SS:FF relative to the file)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "FILE \"%s\" BINARY\r\n", bin_path[strings.last_index_byte(bin_path, '\\') + 1:])
	for ti in 0 ..< toc.count {
		t := toc.tracks[ti]
		fmt.sbprintf(&sb, "  TRACK %02d %s\r\n", t.number, t.audio ? "AUDIO" : "MODE2/2352")
		m, s, fr := t.lba / (75 * 60), (t.lba / 75) % 60, t.lba % 75
		fmt.sbprintf(&sb, "    INDEX 01 %02d:%02d:%02d\r\n", m, s, fr)
	}
	if os.write_entire_file(cue_path, transmute([]u8)strings.to_string(sb)) != nil do return "Couldn't write the .cue file"
	return ""
}

// ---------------------------------------------------------------- dump job steps (worker thread)

disc_file_base :: proc(name: string, disc, discs: int) -> string {
	n := sanitize_name(name)
	return discs > 1 ? fmt.tprintf("%s (Disc %d)", n, disc) : n
}

// Waits until a different disc of the same platform is in the drive.
wait_for_disc :: proc(letter: u8, n: int, prev_serial, prev_label: string) -> (Disc_Info, string) {
	step_begin(fmt.tprintf("Insert disc %d", n))
	for {
		if cancelled() do return {}, CANCELLED_MSG
		d := probe_disc(letter)
		if !d.present {
			step_progress(-1, fmt.tprintf("Waiting for disc %d in %c:…", n, letter))
		} else if disc_serial(&d) == prev_serial && disc_label(&d) == prev_label {
			step_progress(-1, fmt.tprintf("Still disc %d in the drive — swap to disc %d", n - 1, n))
		} else {
			step_end(.Done, disc_serial(&d))
			return d, ""
		}
		time.sleep(1 * time.Second)
		free_all(context.temp_allocator)
	}
}

run_dump :: proc() -> string {
	d := job.dump
	discs := max(job.dump_discs, 1)
	images := make([dynamic]string, context.temp_allocator)
	prev_serial, prev_label := "", ""
	for i in 1 ..= discs {
		if i > 1 {
			nd, err := wait_for_disc(d.letter, i, prev_serial, prev_label)
			if err != "" do return err
			d = nd
		} else {
			fresh := probe_disc(d.letter) // the disc may have changed since it was picked
			if !fresh.present do return fmt.tprintf("No disc in %c:", d.letter)
			d = fresh
		}
		prev_serial = strings.clone(disc_serial(&d), context.temp_allocator)
		prev_label = strings.clone(disc_label(&d), context.temp_allocator)

		base := disc_file_base(job.name, i, discs)
		label := discs > 1 ? fmt.tprintf("Disc %d · ", i) : ""
		step_begin(fmt.tprintf("Dumping %s%s", discs > 1 ? fmt.tprintf("disc %d · ", i) : "", PLATFORM_NAME[d.platform]))
		err: string
		if d.platform == .PS1 {
			cue := fmt.tprintf("%s\\%s.cue", job.dest, base)
			err = dump_bin_cue(d.letter, fmt.tprintf("%s\\%s.bin", job.dest, base), cue, label)
			append(&images, fmt.tprintf("%s.cue", base))
		} else {
			err = dump_iso(d.letter, d.bytes, fmt.tprintf("%s\\%s.iso", job.dest, base), label)
			append(&images, fmt.tprintf("%s.iso", base))
		}
		if err != "" do return err
		step_end(.Done, fmt_size(u64(d.bytes)))
	}
	if discs > 1 {
		m3u := strings.join(images[:], "\r\n", context.temp_allocator)
		_ = os.write_entire_file(fmt.tprintf("%s\\%s.m3u", job.dest, sanitize_name(job.name)), transmute([]u8)m3u)
	}
	return add_emulator(d.platform)
}

// SimpRetro.exe + the platform's core + BIOS into the game folder.
add_emulator :: proc(p: Platform) -> string {
	step_begin("Adding SimpRetro")
	simp := job.simpretro
	if simp == "" || !os.exists(fmt.tprintf("%s\\SimpRetro.exe", simp)) do return "SimpRetro folder isn't set or has no SimpRetro.exe (Settings)"
	copy_one :: proc(src, dst: string) -> bool {
		return bool(win.CopyFileW(win.utf8_to_wstring(src), win.utf8_to_wstring(dst), false))
	}
	if !copy_one(fmt.tprintf("%s\\SimpRetro.exe", simp), fmt.tprintf("%s\\SimpRetro.exe", job.dest)) do return "Couldn't copy SimpRetro.exe"
	core, ok := find_core(simp, PLATFORM_CORE[p])
	if !ok do return fmt.tprintf("Core %s not found in %s\\cores", PLATFORM_CORE[p], simp)
	if !copy_one(core, fmt.tprintf("%s\\%s", job.dest, PLATFORM_CORE[p])) do return "Couldn't copy the emulator core"

	bios := find_bios(job.bios, p)
	if len(bios) == 0 {
		step_end(.Done, p == .PS2 ? "No PS2 BIOS — add one to bios\\pcsx2\\bios" : "No PS1 BIOS — add one to bios\\")
		job_log(p == .PS2 ? "No PS2 BIOS found: the game won't boot until a BIOS is put in bios\\pcsx2\\bios" : "No PS1 BIOS found: put scph1001.bin (or similar) in bios\\")
		return ""
	}
	dir := p == .PS2 ? fmt.tprintf("%s\\bios\\pcsx2\\bios", job.dest) : fmt.tprintf("%s\\bios", job.dest)
	make_dirs(dir)
	for b in bios do copy_one(b, fmt.tprintf("%s\\%s", dir, b[strings.last_index_byte(b, '\\') + 1:]))
	step_end(.Done, fmt.tprintf("%s + %d BIOS file%s", PLATFORM_CORE[p], len(bios), len(bios) == 1 ? "" : "s"))
	return ""
}

find_core :: proc(simp, core: string) -> (string, bool) {
	for p in ([]string{fmt.tprintf("%s\\cores\\%s", simp, core), fmt.tprintf("%s\\%s", simp, core)}) {
		if os.exists(p) do return p, true
	}
	return "", false
}

// PS1 BIOSes are 512 KB (scph*.bin), PS2 BIOSes 4 MB. Searches the folder and one level down.
find_bios :: proc(dir: string, p: Platform) -> []string {
	Ctx :: struct {
		p:   Platform,
		out: [dynamic]string,
	}
	ctx := Ctx{p = p, out = make([dynamic]string, context.temp_allocator)}
	if dir == "" || !os.is_dir(dir) do return nil
	walk_dir(dir, proc(path: string, is_dir: bool, user: rawptr) -> bool {
		x := (^Ctx)(user)
		if is_dir do return true
		lower := strings.to_lower(path, context.temp_allocator)
		if !strings.has_suffix(lower, ".bin") do return false
		size := file_size(path)
		base := lower[strings.last_index_byte(lower, '\\') + 1:]
		if x.p == .PS2 && size == PS2_BIOS_SIZE do append(&x.out, strings.clone(path, context.temp_allocator))
		if x.p == .PS1 && size == 512 * 1024 && strings.has_prefix(base, "scph") do append(&x.out, strings.clone(path, context.temp_allocator))
		return false
	}, &ctx)
	return ctx.out[:]
}

detect_simpretro :: proc() -> (string, bool) {
	for s in sources {
		if is_url(s) do continue
		p := fmt.tprintf("%s\\shared\\SimpRetro", s)
		if os.exists(fmt.tprintf("%s\\SimpRetro.exe", p)) do return p, true
	}
	return "", false
}

// ---------------------------------------------------------------- Dump tab

dump_drives: [dynamic]Disc_Info
dump_sel := -1
dump_discs := 1
dump_active: bool // wizard is in "dump this disc" mode
dump_disc: Disc_Info

refresh_dump_drives :: proc() {
	clear(&dump_drives)
	for l in optical_letters() do append(&dump_drives, probe_disc(l))
	if dump_sel >= len(dump_drives) do dump_sel = -1
	if dump_sel < 0 {
		for &d, i in dump_drives do if d.present && d.platform != .Unknown { dump_sel = i; break }
	}
}

use_disc :: proc(d: Disc_Info) {
	dump_disc = d
	dump_active = true
	delete(preconfig_dir)
	preconfig_dir = ""
	dd := d
	if field_str(&fields[F_NAME]) == "" {
		label := disc_label(&dd)
		field_set(&fields[F_NAME], label != "" ? label : disc_serial(&dd))
	}
	field_set(&fields[F_TAGS], PLATFORM_TAG[d.platform])
	field_set(&fields[F_EXE], "SimpRetro.exe")
	field_set(&fields[F_ARGS], "")
	field_set(&fields[F_SOURCE], "")
	if field_str(&fields[F_BOX]) == "" {
		if c := fetch_cover(d.platform, disc_serial(&dd)); c != "" do field_set(&fields[F_BOX], c)
	}
	page = .Game
	set_status(fmt.tprintf("Disc %s ready — name the game, add box art, then flash. It's dumped during the flash.", disc_serial(&dd)), COL_OK)
}

dump_drives_loaded: bool

draw_dump_page :: proc() {
	if !dump_drives_loaded {
		refresh_dump_drives()
		dump_drives_loaded = true
	}
	page_header("Dump disc", "Rip a PlayStation / PlayStation 2 disc into a ready-to-play Saber game (runs in SimpRetro).")
	x, w := content_x(), content_w()
	running := sync.atomic_load(&job.running)
	if button({x + w - 120, 40, 120, 38}, "Refresh", .Secondary, IC_REFRESH, running) do refresh_dump_drives()

	y: f32 = 116
	if len(dump_drives) == 0 {
		empty := rl.Rectangle{x, y, w, 150}
		card(empty)
		draw_icon(IC_DISC, empty.x + empty.width / 2, empty.y + 46, 30, COL_FAINT)
		t := "No disc drive found"
		draw_text(t, empty.x + (empty.width - text_w(t, 17, true)) / 2, empty.y + 76, 17, COL_TEXT, true)
		return
	}

	cw: f32 = 340
	ch: f32 = 108
	cols := max(1, int((w + 16) / (cw + 16)))
	cw = (w - f32(cols - 1) * 16) / f32(cols)
	for &d, i in dump_drives {
		r := rl.Rectangle{x + f32(i % cols) * (cw + 16), y + f32(i / cols) * (ch + 16), cw, ch}
		disc_card(r, &d, i, running)
	}
	y += f32((len(dump_drives) + cols - 1) / cols) * (ch + 16) + 8

	if dump_sel < 0 || dump_sel >= len(dump_drives) do return
	d := &dump_drives[dump_sel]
	if !d.present || d.platform == .Unknown {
		draw_text(d.present ? "This doesn't look like a PlayStation or PlayStation 2 disc." : "Insert a disc and press Refresh.", x, y + 10, 15, COL_MUTED)
		return
	}

	// what will be created
	r := rl.Rectangle{x, y, w, H - FOOTER_H - 20 - y}
	card(r)
	ix, iw := r.x + 28, r.width - 56
	cy := r.y + 24
	draw_text("WHAT YOU'LL GET", ix, cy, 12, COL_FAINT, true)
	cy += 26

	simp := field_str(&fields[F_SIMPRETRO])
	_, has_core := find_core(simp, PLATFORM_CORE[d.platform])
	has_simp := simp != "" && os.exists(fmt.tprintf("%s\\SimpRetro.exe", simp))
	bios := find_bios(field_str(&fields[F_BIOS]), d.platform)
	img := d.platform == .PS1 ? "Disc image (.bin + .cue, raw)" : "Disc image (.iso)"
	check_row(ix, cy, iw, img, fmt_size(u64(d.bytes)), true); cy += 30
	check_row(ix, cy, iw, "SimpRetro.exe", has_simp ? simp : "Set the SimpRetro folder in Settings", has_simp); cy += 30
	check_row(ix, cy, iw, PLATFORM_CORE[d.platform], has_core ? "found" : "missing from SimpRetro\\cores", has_core); cy += 30
	bios_msg := len(bios) > 0 ? fmt.tprintf("%d file%s from %s", len(bios), len(bios) == 1 ? "" : "s", field_str(&fields[F_BIOS])) : (d.platform == .PS2 ? "No PS2 BIOS (4 MB .bin) — set a BIOS folder in Settings; the game won't boot without one" : "No PS1 BIOS (scph*.bin) — set a BIOS folder in Settings")
	check_row(ix, cy, iw, "BIOS", bios_msg, len(bios) > 0, warn_only = true); cy += 40

	// disc count
	draw_text("DISCS", ix, cy + 12, 12, COL_FAINT, true)
	if button({ix + 90, cy, 40, 40}, "-", .Secondary, 0, dump_discs <= 1 || running) do dump_discs -= 1
	n := fmt.tprint(dump_discs)
	draw_text(n, ix + 150 - text_w(n, 18, true) / 2, cy + 9, 18, COL_TEXT, true)
	if button({ix + 170, cy, 40, 40}, "+", .Secondary, 0, dump_discs >= 9 || running) do dump_discs += 1
	draw_text(dump_discs > 1 ? "You'll be asked to swap discs during the flash; an .m3u is made for disc switching." : "Multi-disc game? Set how many discs it has.", ix + 230, cy + 12, 13, COL_MUTED)

	if button({r.x + r.width - 28 - 230, r.y + r.height - 70, 230, 46}, "Use this disc", .Primary, IC_NEXT, running || !has_simp || !has_core) {
		use_disc(d^)
	}
}

check_row :: proc(x, y, w: f32, title, detail: string, ok: bool, warn_only := false) {
	col := ok ? COL_OK : (warn_only ? COL_WARN : COL_DANGER)
	rl.DrawCircleV({x + 10, y + 10}, 10, alpha(col, 40))
	draw_icon(ok ? IC_CHECK : IC_WARN, x + 10, y + 10, 11, col)
	draw_text(title, x + 32, y + 1, 15, COL_TEXT, true)
	tw := text_w(title, 15, true)
	draw_text_fit(detail, x + 32 + tw + 14, y + 2, 13, ok ? COL_MUTED : col, w - 46 - tw)
}

disc_card :: proc(r: rl.Rectangle, d: ^Disc_Info, i: int, locked: bool) {
	sel := dump_sel == i
	h := !locked && hovered(r)
	if h do cursor = .POINTING_HAND
	if h && rl.IsMouseButtonPressed(.LEFT) do dump_sel = i
	a := anim(rect_id(r, 11), sel)
	rounded(r, 12, mix(h ? COL_CARD_HI : COL_CARD, rl.Color{22, 40, 60, 255}, a))
	rounded_line(r, 12, 1 + a, mix(COL_BORDER, COL_ACCENT, a))
	rounded({r.x + 16, r.y + 18, 44, 44}, 10, alpha(COL_ACCENT, u8(24 + a * 30)))
	draw_icon(IC_DISC, r.x + 38, r.y + 40, 22, COL_ACCENT)

	if !d.present {
		draw_text(fmt.tprintf("%c:  No disc", d.letter), r.x + 74, r.y + 18, 16, COL_MUTED, true)
		return
	}
	label := disc_label(d)
	title := d.platform != .Unknown ? fmt.tprintf("%c:  %s", d.letter, disc_serial(d)) : fmt.tprintf("%c:  %s", d.letter, label == "" ? "Disc" : label)
	draw_text_fit(title, r.x + 74, r.y + 16, 16, COL_TEXT, r.width - 90, true)
	draw_text(fmt.tprintf("%s%s", fmt_size(u64(d.bytes)), label != "" && d.platform != .Unknown ? fmt.tprintf(" · %s", label) : ""), r.x + 74, r.y + 40, 13, COL_MUTED)
	pill(r.x + 74, r.y + 66, PLATFORM_NAME[d.platform], d.platform == .Unknown ? COL_MUTED : COL_ACCENT)
}

// Settings card: emulator locations for disc dumps.
draw_emulator_settings :: proc(y: f32) {
	x, w := content_x(), content_w()
	r := rl.Rectangle{x, y, w, 300}
	card(r)
	rounded({r.x + 28, r.y + 26, 44, 44}, 10, alpha(COL_ACCENT, 36))
	draw_icon(IC_DISC, r.x + 50, r.y + 48, 22, COL_ACCENT)
	draw_text("SimpRetro & BIOS", r.x + 88, r.y + 26, 18, COL_TEXT, true)
	draw_text("Used by Dump disc: the emulator and cores, and your console BIOS files (dumped from your own console).", r.x + 88, r.y + 52, 14, COL_MUTED)

	ix, iw := r.x + 28, r.width - 56
	field_label(ix, r.y + 96, "SIMPRETRO FOLDER", "Holds SimpRetro.exe and cores\\", iw)
	if path_input(&fields[F_SIMPRETRO], {ix, r.y + 120, iw - 130, 44}, "Not set") {
		if p, ok := pick_folder("SimpRetro folder"); ok do field_set(&fields[F_SIMPRETRO], p)
	}
	if button({ix + iw - 120, r.y + 120, 120, 44}, "Detect", .Secondary, IC_SEARCH) {
		if p, ok := detect_simpretro(); ok {
			field_set(&fields[F_SIMPRETRO], p)
		} else {
			set_status("SimpRetro wasn't found in your config sources' shared\\ folders.", COL_WARN)
		}
	}
	field_label(ix, r.y + 184, "BIOS FOLDER", "PS1: scph*.bin · PS2: 4 MB .bin", iw)
	if path_input(&fields[F_BIOS], {ix, r.y + 208, iw, 44}, "Not set") {
		if p, ok := pick_folder("BIOS folder"); ok do field_set(&fields[F_BIOS], p)
	}
	b := field_str(&fields[F_BIOS])
	px := ix
	px += pill(px, r.y + 264, fmt.tprintf("%d PS1 BIOS", len(find_bios(b, .PS1))), len(find_bios(b, .PS1)) > 0 ? COL_OK : COL_MUTED) + 8
	pill(px, r.y + 264, fmt.tprintf("%d PS2 BIOS", len(find_bios(b, .PS2))), len(find_bios(b, .PS2)) > 0 ? COL_OK : COL_MUTED)
}

// ---------------------------------------------------------------- per-platform dumper scripts (dumpers/*.lua, embedded)

DUMPER_SCRIPTS := [Platform]string {
	.Unknown = "",
	.PS1     = #load("dumpers/ps1.lua", string),
	.PS2     = #load("dumpers/ps2.lua", string),
}

// `covers_source` from the platform's dumper script. Entries are either a GitHub repo
// (https://github.com/<user>/<repo>, laid out as covers/default/<SERIAL>.jpg) or a URL
// containing {serial}.
cover_sources :: proc(p: Platform) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	src := DUMPER_SCRIPTS[p]
	if src == "" do return out[:]
	L := luaL_newstate()
	if L == nil do return out[:]
	defer lua_close(L)
	if luaL_loadbufferx(L, raw_data(src), len(src), "dumper", nil) != LUA_OK || lua_pcall(L, 0, 1, 0) != LUA_OK do return out[:]
	if lua_type(L, -1) != LUA_TTABLE do return out[:]
	lua_getfield(L, -1, "covers_source")
	if lua_type(L, -1) == LUA_TTABLE {
		for i: i64 = 1; ; i += 1 {
			if lua_rawgeti(L, -1, i) != LUA_TSTRING {
				lua_pop(L, 1)
				break
			}
			append(&out, strings.clone(lua_string(L, -1), context.temp_allocator))
			lua_pop(L, 1)
		}
	}
	return out[:]
}

cover_url :: proc(source, serial: string) -> string {
	if strings.contains(source, "{serial}") {
		u, _ := strings.replace_all(source, "{serial}", serial, context.temp_allocator)
		return u
	}
	repo := strings.trim_right(strings.trim_prefix(source, "https://github.com/"), "/")
	return fmt.tprintf("https://raw.githubusercontent.com/%s/main/covers/default/%s.jpg", repo, serial)
}

// Small synchronous GET to a file (covers are ~50–200 KB). UI thread only, no job steps.
http_get_file :: proc(url, path: string) -> bool {
	if !load_wininet() do return false
	hnet := InternetOpenW(win.L("SaberFlasher/1.0"), 0, nil, nil, 0)
	if hnet == nil do return false
	defer InternetCloseHandle(hnet)
	h := InternetOpenUrlW(hnet, win.utf8_to_wstring(url), nil, 0, INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_UI, 0)
	if h == nil do return false
	defer InternetCloseHandle(h)
	status: u32
	sz := u32(size_of(status))
	HttpQueryInfoW(h, HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER, &status, &sz, nil)
	if status != 200 do return false
	data := make([dynamic]u8, context.temp_allocator)
	buf: [16 * 1024]u8
	for {
		got: u32
		if !InternetReadFile(h, &buf[0], len(buf), &got) do return false
		if got == 0 do break
		append(&data, ..buf[:got])
	}
	if len(data) < 1024 do return false
	return os.write_entire_file(path, data[:]) == nil
}

// Downloads the cover for a disc into %TEMP%\SaberFlasher\covers; "" if none was found.
fetch_cover :: proc(p: Platform, serial: string) -> string {
	if serial == "" do return ""
	tmp: [260]u16
	n := win.GetTempPathW(len(tmp), cstring16(raw_data(tmp[:])))
	dir := fmt.tprintf("%s\\SaberFlasher\\covers", strings.trim_right(w2s(tmp[:n]), "\\"))
	make_dirs(dir)
	path := fmt.tprintf("%s\\%s.jpg", dir, serial)
	if os.exists(path) && file_size(path) > 1024 do return path
	for s in cover_sources(p) {
		if http_get_file(cover_url(s, serial), path) do return path
	}
	return ""
}
