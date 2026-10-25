package saber

// Physical disc access for libretro cores, without dumping first.
//
// A CD in drive F: is served to the core through the libretro VFS as
//   saber-disc://F/disc<gen>.cue   (generated from the drive's TOC)
//   saber-disc://F/disc<gen>.bin   (raw 2352-byte sectors, read live with IOCTL_CDROM_RAW_READ)
// Cores with "local-first" file access (swanstation) only hand URI paths to the
// frontend VFS, hence the scheme. `gen` bumps on every disc swap so stale handles fail cleanly.
// Every other path is passed through to the real filesystem.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:io"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import win "core:sys/windows"

IOCTL_CDROM_READ_TOC :: 0x00024000
IOCTL_CDROM_RAW_READ :: 0x0002403E
TRACK_MODE_YELLOW_MODE2 :: 0 // full 2352-byte data sectors on most drives
TRACK_MODE_XA_FORM2 :: 1 // same, for drives that reject YellowMode2
TRACK_MODE_CDDA :: 2
RAW_SECTOR :: 2352
ISO_SECTOR :: 2048
VIRTUAL_SCHEME :: "saber-disc"

Cd_Track :: struct {
	number: int,
	audio:  bool,
	lba:    int,
}

Cd_Toc :: struct {
	tracks:  [99]Cd_Track,
	count:   int,
	leadout: int, // first LBA after the last track
}

RAW_READ_INFO :: struct #packed {
	disk_offset:  i64,
	sector_count: u32,
	track_mode:   u32,
}

CACHE_BLOCK :: 16 // sectors per IOCTL (drives cap raw reads around 64 KB)
CACHE_SLOTS :: 8

Cache_Slot :: struct {
	block: int, // first LBA / CACHE_BLOCK; -1 = empty
	used:  u64,
	data:  [CACHE_BLOCK * RAW_SECTOR]u8,
}

Cd_Reader :: struct {
	lock:   sync.Mutex, // cores may read from their own CD thread
	letter: u8,
	handle: win.HANDLE,
	gen:    int,
	ok:     bool,
	cooked: bool, // a DVD/BD holding a PS1 file tree: only 2048-byte reads exist, raw sectors are synthesized
	iso:    bool, // served as a plain 2048-byte .iso (PSP, PS2 DVDs); toc.leadout = sector count
	toc:    Cd_Toc,
	cue:    string,
	cache:  [CACHE_SLOTS]Cache_Slot,
	tick:   u64,
}

cd: Cd_Reader

open_cd_volume :: proc(letter: u8) -> win.HANDLE {
	path := fmt.tprintf(`\\.\%c:`, letter)
	return win.CreateFileW(win.utf8_to_wstring(path), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, 0, nil)
}

cd_read_toc :: proc(h: win.HANDLE) -> (toc: Cd_Toc, ok: bool) {
	raw: [4 + 100 * 8]u8
	got: u32
	if !win.DeviceIoControl(h, IOCTL_CDROM_READ_TOC, nil, 0, &raw[0], len(raw), &got, nil) do return
	first, last := int(raw[2]), int(raw[3])
	n := last - first + 1
	if n <= 0 || n > 99 do return
	for i in 0 ..= n { // n tracks + lead-out (0xAA)
		e := raw[4 + i * 8:]
		lba := (int(e[5]) * 60 + int(e[6])) * 75 + int(e[7]) - 150
		if i == n {
			toc.leadout = lba
		} else {
			toc.tracks[i] = Cd_Track{number = int(e[2]), audio = (e[1] & 0x4) == 0, lba = lba}
		}
	}
	toc.count = n
	return toc, toc.leadout > 0
}

// Opens (or re-opens after a swap) the disc in `letter`. Returns the new .cue path.
cd_open :: proc(letter: u8) -> (cue_path: string, ok: bool) {
	sync.mutex_lock(&cd.lock)
	defer sync.mutex_unlock(&cd.lock)
	cd_close_locked()
	cd.letter = letter
	cd.gen += 1
	cd.handle = open_cd_volume(letter)
	if cd.handle == win.INVALID_HANDLE_VALUE do return "", false
	toc, toc_ok := cd_read_toc(cd.handle)
	if !toc_ok {
		win.CloseHandle(cd.handle)
		cd.handle = win.INVALID_HANDLE_VALUE
		return "", false
	}
	cd.toc = toc
	cd.cooked = disc_profile(cd.handle) >= 0x10
	if cd.cooked do retro_log_line("[disc] DVD/BD medium: synthesizing raw sectors from 2048-byte reads")
	for &s in cd.cache do s.block = -1

	sb := strings.builder_make()
	fmt.sbprintf(&sb, "FILE \"disc%d.bin\" BINARY\r\n", cd.gen)
	for ti in 0 ..< toc.count {
		t := toc.tracks[ti]
		fmt.sbprintf(&sb, "  TRACK %02d %s\r\n", t.number, t.audio ? "AUDIO" : "MODE2/2352")
		fmt.sbprintf(&sb, "    INDEX 01 %02d:%02d:%02d\r\n", t.lba / (75 * 60), (t.lba / 75) % 60, t.lba % 75)
	}
	cd.cue = strings.to_string(sb)
	cd.ok = true
	return cd_virtual_path(letter, cd.gen, "cue"), true
}

// Opens the disc in `letter` as a plain .iso of its 2048-byte sectors (DVD-based systems).
cd_open_iso :: proc(letter: u8) -> (iso_path: string, ok: bool) {
	sync.mutex_lock(&cd.lock)
	defer sync.mutex_unlock(&cd.lock)
	cd_close_locked()
	cd.letter = letter
	cd.gen += 1
	cd.handle = open_cd_volume(letter)
	if cd.handle == win.INVALID_HANDLE_VALUE do return "", false
	// size: the ISO9660 volume space size (primary volume descriptor, sector 16)
	pvd: [ISO_SECTOR]u8
	got: u32
	if !win.SetFilePointerEx(cd.handle, 16 * ISO_SECTOR, nil, win.FILE_BEGIN) ||
	   !win.ReadFile(cd.handle, &pvd[0], ISO_SECTOR, &got, nil) || got != ISO_SECTOR || string(pvd[1:6]) != "CD001" {
		win.CloseHandle(cd.handle)
		cd.handle = win.INVALID_HANDLE_VALUE
		return "", false
	}
	cd.toc = {}
	cd.toc.leadout = int(u32(pvd[80]) | u32(pvd[81]) << 8 | u32(pvd[82]) << 16 | u32(pvd[83]) << 24)
	cd.iso = true
	cd.cooked = false
	for &s in cd.cache do s.block = -1
	cd.ok = true
	retro_log_line("[disc] %c: as .iso, %d sectors", letter, cd.toc.leadout)
	return cd_virtual_path(letter, cd.gen, "iso"), true
}

cd_close :: proc() {
	sync.mutex_lock(&cd.lock)
	defer sync.mutex_unlock(&cd.lock)
	cd_close_locked()
}

cd_close_locked :: proc() {
	if cd.handle != nil && cd.handle != win.INVALID_HANDLE_VALUE do win.CloseHandle(cd.handle)
	cd.handle = nil
	cd.ok = false
	cd.iso = false
	delete(cd.cue)
	cd.cue = ""
}

cd_virtual_path :: proc(letter: u8, gen: int, ext: string) -> string {
	return fmt.aprintf("%s://%c/disc%d.%s", VIRTUAL_SCHEME, letter, gen, ext)
}

cd_sector_size :: proc() -> int {
	return cd.iso ? ISO_SECTOR : RAW_SECTOR
}

cd_bin_size :: proc() -> i64 {
	return i64(cd.toc.leadout) * i64(cd_sector_size())
}

cd_track_mode :: proc(lba: int) -> u32 {
	for ti := cd.toc.count - 1; ti >= 0; ti -= 1 {
		if lba >= cd.toc.tracks[ti].lba do return cd.toc.tracks[ti].audio ? TRACK_MODE_CDDA : TRACK_MODE_YELLOW_MODE2
	}
	return TRACK_MODE_YELLOW_MODE2
}

// Fills a cache slot with CACHE_BLOCK sectors, split where the track mode changes.
// Unreadable sectors (scratches) come back as zeros instead of failing the core.
cd_fill :: proc(slot: ^Cache_Slot, block: int) {
	slot.block = block
	first := block * CACHE_BLOCK
	end := min(first + CACHE_BLOCK, cd.toc.leadout)
	if cd.iso {
		n := end - first
		got: u32
		ok := win.SetFilePointerEx(cd.handle, win.LARGE_INTEGER(i64(first) * ISO_SECTOR), nil, win.FILE_BEGIN) &&
			win.ReadFile(cd.handle, &slot.data[0], u32(n * ISO_SECTOR), &got, nil) && got == u32(n * ISO_SECTOR)
		if !ok {
			retro_log_line("[disc] read of %d sectors at LBA %d failed (error %d)", n, first, win.GetLastError())
			runtime.mem_zero(&slot.data[0], n * ISO_SECTOR)
		}
		return
	}
	for lba := first; lba < end; {
		mode := cd_track_mode(lba)
		run := lba + 1
		for run < end && cd_track_mode(run) == mode do run += 1
		n := run - lba
		dst := slot.data[(lba - first) * RAW_SECTOR:]
		if cd.cooked {
			cd_fill_cooked(lba, n, dst)
			lba = run
			continue
		}
		info := RAW_READ_INFO{disk_offset = i64(lba) * ISO_SECTOR, sector_count = u32(n), track_mode = mode}
		ok := false
		for attempt in 0 ..< 4 {
			// drives disagree on which mode returns raw data sectors; alternate between both
			if mode != TRACK_MODE_CDDA do info.track_mode = attempt % 2 == 0 ? TRACK_MODE_YELLOW_MODE2 : TRACK_MODE_XA_FORM2
			got: u32
			if win.DeviceIoControl(cd.handle, IOCTL_CDROM_RAW_READ, &info, size_of(info), &dst[0], u32(n * RAW_SECTOR), &got, nil) && got == u32(n * RAW_SECTOR) {
				ok = true
				break
			}
		}
		if !ok {
			retro_log_line("[disc] raw read of %d sectors at LBA %d failed (error %d)", n, lba, win.GetLastError())
			runtime.mem_zero(&dst[0], n * RAW_SECTOR)
		}
		lba = run
	}
}

// Reads n user-data sectors and wraps each in a Mode 2 Form 1 frame (sync, MSF header, XA subheader).
// EDC/ECC are left zero; the cores don't check them.
cd_fill_cooked :: proc(lba, n: int, dst: []u8) {
	user: [CACHE_BLOCK * ISO_SECTOR]u8
	got: u32
	ok := win.SetFilePointerEx(cd.handle, win.LARGE_INTEGER(i64(lba) * ISO_SECTOR), nil, win.FILE_BEGIN) &&
		win.ReadFile(cd.handle, &user[0], u32(n * ISO_SECTOR), &got, nil) && got == u32(n * ISO_SECTOR)
	if !ok {
		retro_log_line("[disc] read of %d sectors at LBA %d failed (error %d)", n, lba, win.GetLastError())
		runtime.mem_zero(&user[0], n * ISO_SECTOR)
	}
	bcd :: proc(v: int) -> u8 {return u8(v / 10 << 4 | v % 10)}
	for i in 0 ..< n {
		s := dst[i * RAW_SECTOR:][:RAW_SECTOR]
		runtime.mem_zero(&s[0], RAW_SECTOR)
		for j in 1 ..= 10 do s[j] = 0xFF
		a := lba + i + 150
		s[12], s[13], s[14], s[15] = bcd(a / (75 * 60)), bcd(a / 75 % 60), bcd(a % 75), 2
		s[18], s[22] = 0x08, 0x08 // subheader: data, form 1
		copy(s[24:], user[i * ISO_SECTOR:][:ISO_SECTOR])
	}
}

cd_read_bin :: proc(gen: int, offset: i64, out: []u8) -> i64 {
	sync.mutex_lock(&cd.lock)
	defer sync.mutex_unlock(&cd.lock)
	if !cd.ok || gen != cd.gen do return -1
	size := cd_bin_size()
	if offset >= size do return 0
	want := min(i64(len(out)), size - offset)
	done: i64
	for done < want {
		pos := offset + done
		sector := i64(cd_sector_size())
		lba := int(pos / sector)
		block := lba / CACHE_BLOCK
		slot: ^Cache_Slot
		oldest := &cd.cache[0]
		for &s in cd.cache {
			if s.block == block {
				slot = &s
				break
			}
			if s.used < oldest.used do oldest = &s
		}
		if slot == nil {
			slot = oldest
			cd_fill(slot, block)
		}
		cd.tick += 1
		slot.used = cd.tick
		in_block := pos - i64(block) * CACHE_BLOCK * sector
		n := min(want - done, CACHE_BLOCK * sector - in_block)
		copy(out[done:done + n], slot.data[in_block:in_block + n])
		done += n
	}
	return done
}

// ---------------------------------------------------------------------------
// VFS

Vfs_Kind :: enum {
	Real,
	Cue,
	Bin,
}

Vfs_File :: struct {
	kind: Vfs_Kind,
	path: cstring,
	file: ^os.File,
	gen:  int,
	pos:  i64,
}

Vfs_Dir :: struct {
	entries: []os.File_Info,
	index:   int, // entry currently returned; -1 before the first readdir
	name:    cstring,
}

vfs_iface := Vfs_Interface {
	get_path        = vfs_get_path,
	open            = vfs_open,
	close           = vfs_close,
	size            = vfs_size,
	tell            = vfs_tell,
	seek            = vfs_seek,
	read            = vfs_read,
	write           = vfs_write,
	flush           = vfs_flush,
	remove          = vfs_remove,
	rename          = vfs_rename,
	truncate        = vfs_truncate,
	stat            = vfs_stat,
	mkdir           = vfs_mkdir,
	opendir         = vfs_opendir,
	readdir         = vfs_readdir,
	dirent_get_name = vfs_dirent_get_name,
	dirent_is_dir   = vfs_dirent_is_dir,
	closedir        = vfs_closedir,
}

// "saber-disc://F/disc3.bin" -> (.Bin, 3). Cores may join the .bin name with either slash.
vfs_classify :: proc(path: string) -> (kind: Vfs_Kind, gen: int) {
	p, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	p = strings.to_lower(p, context.temp_allocator)
	prefix := fmt.tprintf("%s://%c/disc", VIRTUAL_SCHEME, cd.letter | 0x20)
	if !strings.has_prefix(p, prefix) do return .Real, 0
	rest := p[len(prefix):]
	dot := strings.index_byte(rest, '.')
	if dot <= 0 do return .Real, 0
	for ch in rest[:dot] {
		if ch < '0' || ch > '9' do return .Real, 0
		gen = gen * 10 + int(ch - '0')
	}
	switch rest[dot + 1:] {
	case "cue": return .Cue, gen
	case "bin", "iso": return .Bin, gen // .iso: the same image, 2048-byte sectors (cd.iso)
	}
	return .Real, 0
}

vfs_get_path :: proc "c" (stream: rawptr) -> cstring {
	return (^Vfs_File)(stream).path
}

vfs_open :: proc "c" (path: cstring, mode: c.uint, hints: c.uint) -> rawptr {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	if path == nil do return nil
	p := string(path)
	kind, gen := vfs_classify(p)
	if kind != .Real do retro_log_line("[vfs] open %s", p)
	f := new(Vfs_File)
	f.kind, f.gen = kind, gen
	f.path = strings.clone_to_cstring(p)
	if kind != .Real {
		if mode & VFS_FILE_ACCESS_WRITE != 0 || !cd.ok || gen != cd.gen {
			vfs_free(f)
			return nil
		}
		return f
	}
	flags: os.File_Flags
	if mode & VFS_FILE_ACCESS_READ != 0 do flags += {.Read}
	if mode & VFS_FILE_ACCESS_WRITE != 0 {
		flags += {.Write}
		if mode & VFS_FILE_ACCESS_UPDATE_EXISTING == 0 do flags += {.Create, .Trunc}
	}
	file, err := os.open(p, flags)
	if err != nil {
		vfs_free(f)
		return nil
	}
	f.file = file
	return f
}

vfs_free :: proc(f: ^Vfs_File) {
	delete(f.path)
	free(f)
}

vfs_close :: proc "c" (stream: rawptr) -> c.int {
	context = runtime.default_context()
	f := (^Vfs_File)(stream)
	if f == nil do return -1
	if f.file != nil do os.close(f.file)
	vfs_free(f)
	return 0
}

vfs_size :: proc "c" (stream: rawptr) -> i64 {
	context = runtime.default_context()
	f := (^Vfs_File)(stream)
	switch f.kind {
	case .Cue: return i64(len(cd.cue))
	case .Bin: return cd_bin_size()
	case .Real:
		n, err := os.file_size(f.file)
		return err == nil ? n : -1
	}
	return -1
}

vfs_tell :: proc "c" (stream: rawptr) -> i64 {
	context = runtime.default_context()
	f := (^Vfs_File)(stream)
	if f.kind == .Real {
		n, err := os.seek(f.file, 0, .Current)
		return err == nil ? n : -1
	}
	return f.pos
}

// Returns 0 on success like RetroArch's VFS (fseek semantics); cores rely on that.
vfs_seek :: proc "c" (stream: rawptr, offset: i64, seek_position: c.int) -> i64 {
	context = runtime.default_context()
	f := (^Vfs_File)(stream)
	if f.kind == .Real {
		whence: io.Seek_From = seek_position == VFS_SEEK_POSITION_END ? .End : seek_position == VFS_SEEK_POSITION_CURRENT ? .Current : .Start
		_, err := os.seek(f.file, offset, whence)
		return err == nil ? 0 : -1
	}
	base: i64
	switch seek_position {
	case VFS_SEEK_POSITION_CURRENT: base = f.pos
	case VFS_SEEK_POSITION_END:     base = vfs_size(stream)
	}
	if base + offset < 0 do return -1
	f.pos = base + offset
	return 0
}

vfs_read :: proc "c" (stream: rawptr, s: rawptr, length: u64) -> i64 {
	context = runtime.default_context()
	f := (^Vfs_File)(stream)
	out := ([^]u8)(s)[:length]
	switch f.kind {
	case .Real:
		n, err := os.read(f.file, out)
		return err == nil || err == io.Error.EOF ? i64(n) : -1
	case .Cue:
		if f.pos >= i64(len(cd.cue)) do return 0
		n := copy(out, cd.cue[f.pos:])
		f.pos += i64(n)
		return i64(n)
	case .Bin:
		n := cd_read_bin(f.gen, f.pos, out)
		if n > 0 do f.pos += n
		return n
	}
	return -1
}

vfs_write :: proc "c" (stream: rawptr, s: rawptr, length: u64) -> i64 {
	context = runtime.default_context()
	f := (^Vfs_File)(stream)
	if f.kind != .Real do return -1
	n, err := os.write(f.file, ([^]u8)(s)[:length])
	return err == nil ? i64(n) : -1
}

vfs_flush :: proc "c" (stream: rawptr) -> c.int {
	context = runtime.default_context()
	f := (^Vfs_File)(stream)
	if f.kind != .Real do return 0
	return os.flush(f.file) == nil ? 0 : -1
}

vfs_truncate :: proc "c" (stream: rawptr, length: i64) -> i64 {
	context = runtime.default_context()
	f := (^Vfs_File)(stream)
	if f.kind != .Real do return -1
	return os.truncate(f.file, length) == nil ? 0 : -1
}

vfs_remove :: proc "c" (path: cstring) -> c.int {
	context = runtime.default_context()
	return os.remove(string(path)) == nil ? 0 : -1
}

vfs_rename :: proc "c" (old_path, new_path: cstring) -> c.int {
	context = runtime.default_context()
	return os.rename(string(old_path), string(new_path)) == nil ? 0 : -1
}

vfs_stat :: proc "c" (path: cstring, size: ^i32) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	if path == nil do return 0
	p := string(path)
	kind, gen := vfs_classify(p)
	if kind != .Real {
		if !cd.ok || gen != cd.gen do return 0
		if size != nil do size^ = i32(kind == .Cue ? i64(len(cd.cue)) : cd_bin_size())
		return VFS_STAT_IS_VALID
	}
	fi, err := os.stat(p, context.temp_allocator)
	if err != nil do return 0
	if size != nil do size^ = i32(fi.size)
	return VFS_STAT_IS_VALID | (fi.type == .Directory ? VFS_STAT_IS_DIRECTORY : 0)
}

vfs_mkdir :: proc "c" (dir: cstring) -> c.int {
	context = runtime.default_context()
	p := string(dir)
	if os.is_dir(p) do return -2
	return os.make_directory(p) == nil ? 0 : -1
}

vfs_opendir :: proc "c" (dir: cstring, include_hidden: bool) -> rawptr {
	context = runtime.default_context()
	entries, err := os.read_all_directory_by_path(string(dir), context.allocator)
	if err != nil do return nil
	d := new(Vfs_Dir)
	d.entries = entries
	d.index = -1
	return d
}

vfs_readdir :: proc "c" (dirstream: rawptr) -> bool {
	context = runtime.default_context()
	d := (^Vfs_Dir)(dirstream)
	d.index += 1
	delete(d.name)
	d.name = nil
	if d.index >= len(d.entries) do return false
	d.name = strings.clone_to_cstring(d.entries[d.index].name)
	return true
}

vfs_dirent_get_name :: proc "c" (dirstream: rawptr) -> cstring {
	return (^Vfs_Dir)(dirstream).name
}

vfs_dirent_is_dir :: proc "c" (dirstream: rawptr) -> bool {
	d := (^Vfs_Dir)(dirstream)
	return d.index >= 0 && d.index < len(d.entries) && d.entries[d.index].type == .Directory
}

vfs_closedir :: proc "c" (dirstream: rawptr) -> c.int {
	context = runtime.default_context()
	d := (^Vfs_Dir)(dirstream)
	delete(d.name)
	os.file_info_slice_delete(d.entries, context.allocator)
	free(d)
	return 0
}

// ---------------------------------------------------------------------------
// ISO9660 fallback: some burned PS2 DVDs carry a bogus UDF bridge (an empty DVD-Video
// VIDEO_TS) that Windows mounts instead, hiding the game's files. Reads a root-directory
// file straight from the ISO9660 filesystem of the raw volume.

iso_read_root_file :: proc(letter: u8, name: string, max_size := 64 * 1024, allocator := context.allocator) -> (data: []byte, ok: bool) {
	h := open_cd_volume(letter)
	if h == win.INVALID_HANDLE_VALUE do return
	defer win.CloseHandle(h)

	read :: proc(h: win.HANDLE, lba: u32, buf: []byte) -> bool {
		if !win.SetFilePointerEx(h, win.LARGE_INTEGER(i64(lba) * ISO_SECTOR), nil, win.FILE_BEGIN) do return false
		got: u32
		return bool(win.ReadFile(h, &buf[0], u32(len(buf)), &got, nil)) && got == u32(len(buf))
	}
	le32 :: proc(b: []byte) -> u32 {return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24}

	pvd: [ISO_SECTOR]byte
	if !read(h, 16, pvd[:]) || string(pvd[1:6]) != "CD001" do return
	root := pvd[156:]
	dir_lba, dir_len := le32(root[2:]), le32(root[10:])
	if dir_len == 0 || dir_len > 1024 * 1024 do return
	dir := make([]byte, (int(dir_len) + ISO_SECTOR - 1) / ISO_SECTOR * ISO_SECTOR, context.temp_allocator)
	if !read(h, dir_lba, dir) do return

	for i := 0; i < int(dir_len); {
		n := int(dir[i])
		if n == 0 { // records never cross a sector boundary
			i = (i / ISO_SECTOR + 1) * ISO_SECTOR
			continue
		}
		if i + 33 > len(dir) do break
		id := string(dir[i + 33:][:min(int(dir[i + 32]), len(dir) - i - 33)])
		if semi := strings.index_byte(id, ';'); semi >= 0 do id = id[:semi]
		if strings.equal_fold(id, name) {
			lba, size := le32(dir[i + 2:]), int(le32(dir[i + 10:]))
			if size > max_size do return
			buf := make([]byte, (size + ISO_SECTOR - 1) / ISO_SECTOR * ISO_SECTOR, context.temp_allocator)
			if size > 0 && !read(h, lba, buf) do return
			return slice.clone(buf[:size], allocator), true
		}
		i += n
	}
	return
}

// ---------------------------------------------------------------------------
// Burned discs: the drive's current MMC profile says what kind of medium is inserted.

IOCTL_CDROM_GET_CONFIGURATION :: 0x00024058

Get_Configuration_Input :: struct {
	feature:      u32, // 0 = profile list
	request_type: u32, // 1 = current
	reserved:     [2]rawptr,
}

// The drive's current MMC profile (0x08 CD-ROM, 0x09 CD-R, 0x10 DVD-ROM, 0x1A DVD+RW, ...); 0 = unknown.
disc_profile :: proc(h: win.HANDLE) -> u16 {
	input := Get_Configuration_Input{feature = 0, request_type = 1}
	out: [8]byte
	got: u32
	if !win.DeviceIoControl(h, IOCTL_CDROM_GET_CONFIGURATION, &input, size_of(input), &out[0], len(out), &got, nil) || got < 8 do return 0
	return u16(out[6]) << 8 | u16(out[7])
}

// true for CD-R/RW, DVD±R/RW/RAM, BD-R/RE; false for pressed (ROM) discs or when unknown.
disc_is_recordable :: proc(letter: u8) -> bool {
	h := open_cd_volume(letter)
	if h == win.INVALID_HANDLE_VALUE do return false
	defer win.CloseHandle(h)
	profile := disc_profile(h)
	switch profile {
	case 0x0000, 0x0008, 0x0010, 0x0040: return false // none, CD-ROM, DVD-ROM, BD-ROM
	}
	return profile < 0x0100
}
