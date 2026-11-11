package saber

// Install to Library (a game card's X / right-click actions menu): copies a game off an
// inserted disc or drive, so it plays without the media.
//
//   PS1 disc             games_roms/ps1/<Title>/<serial>.bin + .cue   (more discs of it: + <Title>.m3u)
//   PS2 / PSP disc       games_roms/<ps2|psp>/<Title>/<serial>.iso
//   burned DC CD-R       games_roms/dc/<Title>/trackNN.bin + disc.cue
//   ROM / disc image     games_roms/<platform>/<file>   (a .cue brings the files it lists)
//   _Saber game          games/<folder>   (or games_roms/<platform>/<folder> when it has rom=)
//
// Discs get _Saber/saber.ini with platform=, serial=, rom= (+ mod= for burned discs), which
// game_from_folder turns into a libretro game sharing the physical disc's memory card.
// The copy runs on a worker thread with its own drive handle, so the live disc reader (`cd`)
// stays free for a game on another drive. Files are written as *.part and renamed once
// complete: a cancelled or failed install leaves nothing behind.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

INSTALL_PART :: ".part"
INSTALL_CHUNK :: 512 * 1024
INSTALL_CANCELLED :: "Cancelled"
INSTALL_CARD_SEC :: 5.0 // "Installed" / "Install Stopped" stays this long
INSTALL_SPARE :: 64 * 1024 * 1024 // free space kept on top of the game's size

Install_Kind :: enum {
	Disc,   // PS1 / PS2 / PSP disc -> image
	Dc,     // burned Dreamcast CD-R -> tracks
	Folder, // a _Saber game folder
	Rom,    // a ROM file or disc image
}

Install_Job :: struct {
	worker:      ^thread.Thread,
	running:     bool,
	done:        bool, // atomic: the worker finished
	cancel:      bool, // atomic
	ejected:     bool, // the disc left the drive mid-install
	kind:        Install_Kind,
	letter:      u8, // discs
	platform:    Retro_Platform,
	game_root:   string, // Game.root of the card being installed
	title:       string,
	serial:      string,
	mod_name:    string,
	src:         string, // Folder: the game folder; Rom: the file
	box:         string, // discs: art copied into _Saber
	dest:        string, // Disc / Dc / Folder: the game folder; Rom: the platform folder
	buf:         []u8,   // worker's copy buffer
	done_bytes:  i64,    // atomic
	total_bytes: i64,    // atomic
	started:     f64,
	err:         string, // set by the worker; "" = success
	// progress card
	card_t:      f32,
	ended_at:    f64,
	ended_ok:    bool,
	ended_buf:   [192]u8,
	ended_msg:   string,
}

install: Install_Job

// Temp-allocated path join (the worker joins a lot of paths).
tjoin :: proc(parts: []string) -> string {
	p, _ := filepath.join(parts, context.temp_allocator)
	return p
}

// A folder / file name from a title: no Windows-reserved characters, no trailing dots or spaces.
install_name :: proc(s: string) -> string {
	n := strings.trim_right(safe_file_name(s), ". ")
	return n != "" ? n : "Game"
}

// What installing `g` means; why != "" explains a game that can't be installed.
install_kind :: proc(g: ^Game) -> (kind: Install_Kind, ok: bool, why: string) {
	if !g.from_drive do return
	switch {
	case g.saber_dir != "":
		return .Folder, true, ""
	case g.rom_path != "":
		return .Rom, true, ""
	case g.disc_letter != 0 && g.platform == .DC:
		if g.gdrom do return .Dc, false, "Pressed Dreamcast GD-ROMs can't be read by PC drives"
		return .Dc, true, ""
	case g.disc_letter != 0 && g.platform != .None:
		return .Disc, true, ""
	}
	return
}

// Where `g` goes (temp).
install_dest :: proc(g: ^Game, kind: Install_Kind) -> string {
	switch kind {
	case .Disc, .Dc:
		name := install_name(g.title)
		// a burned (modded) disc never lands on top of the original's copy
		if g.mod_name != "" do name = fmt.tprintf("%s (%s)", name, install_name(g.mod_name))
		return tjoin({app.roms_dir, RETRO_PLATFORM_DIR[g.platform], name})
	case .Rom:
		return tjoin({app.roms_dir, RETRO_PLATFORM_DIR[g.platform]})
	case .Folder:
		base := filepath.base(strings.trim_right(g.root, "\\/"))
		if base == "" || base == "." || strings.has_suffix(base, ":") do base = g.title // a game in a drive's root
		if g.platform != .None do return tjoin({app.roms_dir, RETRO_PLATFORM_DIR[g.platform], install_name(base)})
		return tjoin({app.games_dir, install_name(base)})
	}
	return ""
}

install_disc_image :: proc(serial: string, p: Retro_Platform) -> string {
	return fmt.tprintf("%s%s", install_name(serial), p == .PS1 ? ".cue" : ".iso")
}

// `g` is already in the library.
install_exists :: proc(g: ^Game, kind: Install_Kind) -> bool {
	dest := install_dest(g, kind)
	switch kind {
	case .Disc:
		return os.exists(tjoin({dest, install_disc_image(g.disc_serial, g.platform)}))
	case .Rom:
		return os.exists(tjoin({dest, filepath.base(g.rom_path)}))
	case .Dc, .Folder:
		return os.exists(dest)
	}
	return false
}

// The disc in this game's drive is being copied: playing it now would fight over the drive.
install_busy_with :: proc(g: ^Game) -> bool {
	if !install.running || !g.from_drive do return false
	if install.kind == .Disc || install.kind == .Dc do return g.disc_letter != 0 && g.disc_letter == install.letter
	return false
}

install_is :: proc(g: ^Game) -> bool {
	return install.running && g.root == install.game_root
}

install_start :: proc(g: ^Game) -> (ok: bool, err: string) {
	if install.running do return false, fmt.tprintf("Already installing %s", install.title)
	kind, can, why := install_kind(g)
	if !can do return false, why != "" ? why : "Only games on inserted discs and drives can be installed"
	install_free()
	install.kind = kind
	install.letter = g.disc_letter
	install.platform = g.platform
	install.game_root = strings.clone(g.root)
	install.title = strings.clone(g.title)
	install.serial = strings.clone(g.disc_serial)
	install.mod_name = strings.clone(g.mod_name)
	install.src = strings.clone(kind == .Rom ? g.rom_path : g.root)
	if (kind == .Disc || kind == .Dc) && g.box_file != "" && os.exists(g.box_file) do install.box = strings.clone(g.box_file)
	install.dest = strings.clone(install_dest(g, kind))
	install.ejected = false
	install.started = rl.GetTime()
	install.ended_at = 0
	sync.atomic_store(&install.done_bytes, 0)
	sync.atomic_store(&install.total_bytes, 0)
	sync.atomic_store(&install.cancel, false)
	sync.atomic_store(&install.done, false)
	install.running = true
	install.worker = thread.create_and_start_with_data(&install, install_worker)
	return true, ""
}

install_free :: proc() {
	delete(install.game_root)
	delete(install.title)
	delete(install.serial)
	delete(install.mod_name)
	delete(install.src)
	delete(install.box)
	delete(install.dest)
	delete(install.err)
	install.game_root, install.title, install.serial, install.mod_name = "", "", "", ""
	install.src, install.box, install.dest, install.err = "", "", "", ""
}

install_cancel :: proc() {
	if install.running do sync.atomic_store(&install.cancel, true)
}

// Main loop: watches for an ejected disc and picks up a finished install.
install_update :: proc() {
	if !install.running do return
	if install.kind == .Disc || install.kind == .Dc {
		if _, present, polled := media_volume(install.letter); polled && !present && !install.ejected {
			install.ejected = true
			install_cancel()
		}
	}
	if !sync.atomic_load(&install.done) do return
	thread.join(install.worker)
	thread.destroy(install.worker)
	install.worker = nil
	install.running = false
	install.ended_at = rl.GetTime()
	install.ended_ok = install.err == ""
	switch {
	case install.ended_ok:
		lib := install.kind == .Folder && install.platform == .None ? "GAMES" : "GAMES (games_roms)"
		install.ended_msg = fmt.bprintf(install.ended_buf[:], "%s  ·  now in %s", install.title, lib)
		rescan_library()
		update_scan_message()
		sfx_click()
	case install.ejected:
		install.ended_msg = fmt.bprintf(install.ended_buf[:], "The disc was removed")
		sfx_back()
	case install.err == INSTALL_CANCELLED:
		install.ended_msg = fmt.bprintf(install.ended_buf[:], "Cancelled  ·  nothing was kept")
		sfx_back()
	case:
		install.ended_msg = fmt.bprintf(install.ended_buf[:], "%s", install.err)
		sfx_back()
	}
	set_status("%s: %s", install.ended_ok ? "Installed" : "Install stopped", install.ended_msg)
}

install_shutdown :: proc() {
	if install.worker == nil do return
	install_cancel() // the worker removes its partial files
	thread.join(install.worker)
	thread.destroy(install.worker)
	install.worker = nil
	install.running = false
}

// ---------------------------------------------------------------------------
// Worker

install_worker :: proc(data: rawptr) {
	j := (^Install_Job)(data)
	context = runtime.default_context()
	defer sync.atomic_store(&j.done, true)
	defer free_all(context.temp_allocator)
	j.buf = make([]u8, INSTALL_CHUNK)
	defer {
		delete(j.buf)
		j.buf = nil
	}
	err: string
	switch j.kind {
	case .Disc:   err = install_disc(j)
	case .Dc:     err = install_dc(j)
	case .Folder: err = install_folder(j)
	case .Rom:    err = install_rom(j)
	}
	if err == "" && sync.atomic_load(&j.cancel) do err = INSTALL_CANCELLED
	if err != "" do j.err = strings.clone(err)
}

install_cancelled :: proc(j: ^Install_Job) -> bool {
	return sync.atomic_load(&j.cancel)
}

install_add :: proc(j: ^Install_Job, n: int) {
	sync.atomic_add(&j.done_bytes, i64(n))
}

// "" = enough room in `dir` (which exists) for `need` bytes.
install_check_space :: proc(dir: string, need: i64) -> string {
	if free, ok := disk_free_bytes(dir); ok && free < need + INSTALL_SPARE {
		return fmt.tprintf("Not enough space: needs %s, %s free", fmt_bytes(need), fmt_bytes(free))
	}
	return ""
}

install_bad_sector :: proc(lba: int) -> string {
	return fmt.tprintf("Couldn't read sector %d (scratched or dirty disc?)", lba)
}

// The last two sectors of a data track before an audio track / the lead-out: many drives
// refuse them (run-out blocks), and images carry them as zeros anyway.
install_runout :: proc(toc: ^Cd_Toc, lba: int) -> bool {
	for ti in 0 ..< toc.count {
		next := ti + 1 < toc.count ? toc.tracks[ti + 1].lba : toc.leadout
		if !toc.tracks[ti].audio && lba >= next - 2 && lba < next do return true
	}
	return false
}

// PS1 / PS2 / PSP disc -> <serial>.bin + .cue (PS1) or <serial>.iso, then the game's saber.ini.
install_disc :: proc(j: ^Install_Job) -> string {
	h, opened := disc_open(j.letter)
	if !opened do return fmt.tprintf("Couldn't open the disc in %c:", j.letter)
	defer disc_close(h)

	// PS1 gets raw sectors behind a .cue; PS2 / PSP a plain .iso (the same split retro_play uses)
	raw := j.platform == .PS1
	toc: Cd_Toc
	cooked := false
	sectors: int
	if raw {
		toc_ok: bool
		if toc, toc_ok = cd_read_toc(h); !toc_ok do return "Couldn't read the disc's table of contents"
		cooked = disc_profile(h) >= 0x10 // a PS1 game on DVD media: only 2048-byte reads exist
		sectors = toc.leadout
	} else {
		pvd_ok: bool
		if sectors, pvd_ok = iso_volume_sectors(h); !pvd_ok do return "Couldn't read the disc's file system"
	}
	sector := raw ? RAW_SECTOR : ISO_SECTOR
	total := i64(sectors) * i64(sector)
	sync.atomic_store(&j.total_bytes, total)

	dir := j.dest
	new_dir := !os.exists(dir)
	if os.make_directory_all(dir) != nil do return "Couldn't create the game folder"
	success := false
	defer if !success && new_dir do os.remove_all(dir)
	if e := install_check_space(dir, total); e != "" do return e

	base := install_name(j.serial)
	image := fmt.tprintf("%s%s", base, raw ? ".bin" : ".iso")
	image_path := tjoin({dir, image})
	part := strings.concatenate({image_path, INSTALL_PART}, context.temp_allocator)
	f, ferr := os.open(part, {.Write, .Create, .Trunc})
	if ferr != nil do return "Couldn't write the disc image"
	err := raw ? install_read_raw(j, h, &toc, cooked, sectors, f) : install_read_iso(j, h, sectors, f)
	os.close(f)
	if err != "" {
		os.remove(part)
		return err
	}
	if os.rename(part, image_path) != nil {
		os.remove(part)
		return "Couldn't finish the disc image"
	}
	entry := image
	if raw {
		cue := cd_cue_text(&toc, image)
		defer delete(cue)
		entry = fmt.tprintf("%s.cue", base)
		if os.write_entire_file(tjoin({dir, entry}), cue) != nil do return "Couldn't write the .cue"
	}
	if e := install_write_disc_ini(j, dir, entry); e != "" do return e
	success = true
	return ""
}

install_read_raw :: proc(j: ^Install_Job, h: Disc_Handle, toc: ^Cd_Toc, cooked: bool, sectors: int, f: ^os.File) -> string {
	buf := j.buf[:CACHE_BLOCK * RAW_SECTOR]
	for lba := 0; lba < sectors; lba += CACHE_BLOCK {
		if install_cancelled(j) do return INSTALL_CANCELLED
		n := min(CACHE_BLOCK, sectors - lba)
		if cd_read_sectors(h, toc, cooked, lba, n, buf) >= 0 {
			// one by one: some drives only refuse the run-out sectors inside a bigger read
			for k in 0 ..< n {
				if cd_read_sectors(h, toc, cooked, lba + k, 1, buf[k * RAW_SECTOR:]) >= 0 && !install_runout(toc, lba + k) {
					return install_bad_sector(lba + k)
				}
			}
		}
		if _, e := os.write(f, buf[:n * RAW_SECTOR]); e != nil do return "Couldn't write the disc image (disk full?)"
		install_add(j, n * RAW_SECTOR)
	}
	return ""
}

install_read_iso :: proc(j: ^Install_Job, h: Disc_Handle, sectors: int, f: ^os.File) -> string {
	read :: proc(h: Disc_Handle, lba: int, buf: []u8) -> bool {
		for _ in 0 ..< 3 do if disc_read_user(h, lba, buf) do return true
		return false
	}
	run := len(j.buf) / ISO_SECTOR
	for lba := 0; lba < sectors; lba += run {
		if install_cancelled(j) do return INSTALL_CANCELLED
		n := min(run, sectors - lba)
		chunk := j.buf[:n * ISO_SECTOR]
		if !read(h, lba, chunk) {
			// find the sector that fails, so the error can name it
			for k in 0 ..< n {
				if !read(h, lba + k, chunk[k * ISO_SECTOR:][:ISO_SECTOR]) do return install_bad_sector(lba + k)
			}
		}
		if _, e := os.write(f, chunk); e != nil do return "Couldn't write the disc image (disk full?)"
		install_add(j, len(chunk))
	}
	return ""
}

// Writes (or updates, for another disc of the same game) _Saber/saber.ini in `dir`.
install_write_disc_ini :: proc(j: ^Install_Job, dir, entry: string) -> string {
	saber := tjoin({dir, "_Saber"})
	if os.make_directory_all(saber) != nil do return "Couldn't create the game's _Saber folder"
	ini_path := tjoin({saber, "saber.ini"})
	serial := j.serial
	box, rom_keep := "", ""
	if old, e := os.read_entire_file(ini_path, context.temp_allocator); e == nil {
		// the first disc installed keeps naming the game (save states are per serial)
		if v, found := ini_get(string(old), "serial"); found && v != "" do serial = v
		if v, found := ini_get(string(old), "box"); found do box = v
		// PS2 / PSP: another disc of the game doesn't take over from the first (no .m3u there)
		if v, found := ini_get(string(old), "rom"); found && v != "" && j.platform != .PS1 && os.exists(tjoin({dir, v})) do rom_keep = v
	}
	rom := rom_keep != "" ? rom_keep : entry
	if j.platform == .PS1 {
		if m3u, multi := install_write_m3u(j, dir); multi do rom = m3u
	}
	if j.box != "" {
		ext := strings.to_lower(filepath.ext(j.box), context.temp_allocator)
		name := fmt.tprintf("box%s", ext != "" ? ext : ".png")
		if os.copy_file(tjoin({saber, name}), j.box) == nil do box = name
	}
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "[game]\ntitle=%s\ntags=%s\nplatform=%s\nserial=%s\nrom=%s\n", j.title, RETRO_PLATFORM_NAME[j.platform], RETRO_PLATFORM_DIR[j.platform], serial, rom)
	if box != "" do fmt.sbprintf(&sb, "box=%s\n", box)
	if j.mod_name != "" do fmt.sbprintf(&sb, "mod=%s\n", j.mod_name)
	if os.write_entire_file(ini_path, strings.to_string(sb)) != nil do return "Couldn't write the game's saber.ini"
	return ""
}

// More than one disc of a PS1 game in `dir`: <Title>.m3u lists them, in the order they were
// installed (disc 1 first, as a rule). Returns its name.
install_write_m3u :: proc(j: ^Install_Job, dir: string) -> (name: string, multi: bool) {
	cues := make([dynamic]string, context.temp_allocator)
	if fis, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
		for fi in fis do if fi.type == .Regular && strings.equal_fold(filepath.ext(fi.name), ".cue") do append(&cues, fi.name)
	}
	if len(cues) < 2 do return "", false
	name = fmt.tprintf("%s.m3u", install_name(j.title))
	order := make([dynamic]string, context.temp_allocator)
	has :: proc(list: []string, s: string) -> bool {
		for v in list do if strings.equal_fold(v, s) do return true
		return false
	}
	if old, e := os.read_entire_file(tjoin({dir, name}), context.temp_allocator); e == nil {
		it := string(old)
		for line in strings.split_lines_iterator(&it) {
			l := strings.trim_space(line)
			if l != "" && has(cues[:], l) && !has(order[:], l) do append(&order, l)
		}
	}
	for c in cues do if !has(order[:], c) do append(&order, c)
	if os.write_entire_file(tjoin({dir, name}), strings.join(order[:], "\r\n", context.temp_allocator)) != nil do return "", false
	return name, true
}

// Burned Dreamcast CD-R -> trackNN.bin + disc.cue in the game folder.
install_dc :: proc(j: ^Install_Job) -> string {
	h, opened := disc_open(j.letter)
	if !opened do return fmt.tprintf("Couldn't open the disc in %c:", j.letter)
	defer disc_close(h)
	part := strings.concatenate({j.dest, INSTALL_PART}, context.temp_allocator)
	os.remove_all(part)
	if os.make_directory_all(part) != nil do return "Couldn't create the game folder"
	success := false
	defer if !success do os.remove_all(part)
	if toc, ok := cd_read_toc(h); ok {
		sync.atomic_store(&j.total_bytes, i64(toc.leadout) * RAW_SECTOR)
		if e := install_check_space(part, i64(toc.leadout) * RAW_SECTOR); e != "" do return e
	}
	progress :: proc(data: rawptr, done, total: int) -> bool {
		j := (^Install_Job)(data)
		sync.atomic_store(&j.total_bytes, i64(total) * RAW_SECTOR)
		sync.atomic_store(&j.done_bytes, i64(done) * RAW_SECTOR)
		return !install_cancelled(j)
	}
	cue, ok, err := dc_rip(h, part, progress, j, strict = true)
	if !ok do return err
	delete(cue)
	if e := install_write_disc_ini(j, part, "disc.cue"); e != "" do return e
	if os.exists(j.dest) && os.remove_all(j.dest) != nil do return "Couldn't replace the installed copy"
	if os.rename(part, j.dest) != nil do return "Couldn't finish the install"
	success = true
	return ""
}

// A _Saber game folder. A reinstall copies over the installed one, so saves and settings kept
// inside the game folder survive; a new install is copied to <folder>.part, then renamed.
install_folder :: proc(j: ^Install_Job) -> string {
	total := install_tree_size(j.src, true)
	sync.atomic_store(&j.total_bytes, total)
	parent := filepath.dir(j.dest)
	if os.make_directory_all(parent) != nil do return "Couldn't create the library folder"
	if e := install_check_space(parent, total); e != "" do return e
	if os.exists(j.dest) do return install_copy_tree(j, j.src, j.dest, true)
	part := strings.concatenate({j.dest, INSTALL_PART}, context.temp_allocator)
	os.remove_all(part)
	if e := install_copy_tree(j, j.src, part, true); e != "" {
		os.remove_all(part)
		return e
	}
	if os.rename(part, j.dest) != nil {
		os.remove_all(part)
		return "Couldn't finish the install"
	}
	return ""
}

// Not copied: the drive's own system folders, other _Saber games inside this one (a game in a
// drive's root sits next to the drive's other games), and the play history.
install_skip :: proc(fi: os.File_Info, top, in_saber: bool) -> bool {
	if top && (fi.name == "System Volume Information" || strings.has_prefix(fi.name, "$")) do return true
	if fi.type == .Directory && fi.name != "_Saber" && os.exists(tjoin({fi.fullpath, "_Saber", "saber.ini"})) do return true
	if in_saber && strings.equal_fold(fi.name, "records.ini") do return true
	return false
}

install_tree_size :: proc(dir: string, top: bool, in_saber := false) -> i64 {
	fis, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil do return 0
	defer os.file_info_slice_delete(fis, context.allocator)
	total: i64
	for fi in fis {
		if install_skip(fi, top, in_saber) do continue
		if fi.type == .Directory do total += install_tree_size(fi.fullpath, false, top && fi.name == "_Saber")
		else if fi.type == .Regular do total += fi.size
	}
	return total
}

install_copy_tree :: proc(j: ^Install_Job, src, dst: string, top: bool, in_saber := false) -> string {
	if os.make_directory_all(dst) != nil do return fmt.tprintf("Couldn't create %s", dst)
	fis, err := os.read_all_directory_by_path(src, context.allocator)
	if err != nil do return fmt.tprintf("Couldn't read %s", src)
	defer os.file_info_slice_delete(fis, context.allocator)
	for fi in fis {
		if install_skip(fi, top, in_saber) do continue
		out := tjoin({dst, fi.name})
		if fi.type == .Directory {
			if e := install_copy_tree(j, fi.fullpath, out, false, top && fi.name == "_Saber"); e != "" do return e
		} else if fi.type == .Regular {
			if e := install_copy_file(j, fi.fullpath, out); e != "" do return e
		}
	}
	return ""
}

// Copies one file through <dst>.part.
install_copy_file :: proc(j: ^Install_Job, src, dst: string) -> string {
	in_f, oerr := os.open(src)
	if oerr != nil do return fmt.tprintf("Couldn't read %s", filepath.base(src))
	defer os.close(in_f)
	size, _ := os.file_size(in_f)
	part := strings.concatenate({dst, INSTALL_PART}, context.temp_allocator)
	out_f, cerr := os.open(part, {.Write, .Create, .Trunc})
	if cerr != nil do return fmt.tprintf("Couldn't write %s", filepath.base(dst))
	fail :: proc(out_f: ^os.File, part, msg: string) -> string {
		os.close(out_f)
		os.remove(part)
		return msg
	}
	copied: i64
	for copied < size {
		if install_cancelled(j) do return fail(out_f, part, INSTALL_CANCELLED)
		want := int(min(i64(len(j.buf)), size - copied))
		n, rerr := os.read(in_f, j.buf[:want])
		if n <= 0 {
			if rerr != nil || n == 0 do return fail(out_f, part, fmt.tprintf("Couldn't read %s", filepath.base(src)))
		}
		if _, werr := os.write(out_f, j.buf[:n]); werr != nil do return fail(out_f, part, "Couldn't write the copy (disk full?)")
		copied += i64(n)
		install_add(j, n)
	}
	os.close(out_f)
	if os.rename(part, dst) != nil {
		os.remove(part)
		return fmt.tprintf("Couldn't replace %s (is it in use?)", filepath.base(dst))
	}
	return ""
}

// A ROM (or a .cue and the files it lists) into games_roms/<platform>/.
install_rom :: proc(j: ^Install_Job) -> string {
	src_dir := filepath.dir(j.src)
	names := make([dynamic]string, context.temp_allocator) // relative to src_dir
	append(&names, filepath.base(j.src))
	if strings.equal_fold(filepath.ext(j.src), ".cue") {
		if text, e := os.read_entire_file(j.src, context.temp_allocator); e == nil {
			for n in cue_file_names(string(text)) do if !filepath.is_abs(n) && !strings.contains(n, "..") do append(&names, n)
		}
	}
	total: i64
	for n in names {
		if fi, e := os.stat(tjoin({src_dir, n}), context.temp_allocator); e == nil do total += fi.size
		else do return fmt.tprintf("Missing %s next to the .cue", n)
	}
	sync.atomic_store(&j.total_bytes, total)
	if os.make_directory_all(j.dest) != nil do return "Couldn't create the library folder"
	if e := install_check_space(j.dest, total); e != "" do return e
	created := make([dynamic]string, context.temp_allocator)
	for n in names {
		out := tjoin({j.dest, n})
		os.make_directory_all(filepath.dir(out))
		existed := os.exists(out)
		if e := install_copy_file(j, tjoin({src_dir, n}), out); e != "" {
			for c in created do os.remove(c) // a .cue without its tracks would show as a broken game
			return e
		}
		if !existed do append(&created, out)
	}
	return ""
}

// "650 MB", "4.3 GB"
fmt_bytes :: proc(n: i64) -> string {
	switch {
	case n >= 1024 * 1024 * 1024: return fmt.tprintf("%.1f GB", f64(n) / (1024 * 1024 * 1024))
	case n >= 1024 * 1024:        return fmt.tprintf("%d MB", n / (1024 * 1024))
	case:                         return fmt.tprintf("%d KB", max(n / 1024, 0))
	}
}

// ---------------------------------------------------------------------------
// Actions menu (X / right-click on a Home or Games card)

Game_Menu_Row :: enum {
	Play,
	Install,
	Cancel_Install,
	Plugin, // a plugin's game_actions row (Game_Menu_Item.action)
	Close,
}

Game_Menu_Item :: struct {
	row:    Game_Menu_Row,
	action: int, // .Plugin: index into plugin_game_actions
}

Game_Menu :: struct {
	open:      bool,
	t:         f32,
	sel:       int,
	screen:    Screen,
	root_buf:  [512]u8,
	root:      string, // the card's Game.root: drive scans replace the list, so it is looked up again
	title_buf: [128]u8,
	title:     string,
	installed: bool, // already in the library: the row reads "Reinstall"
	armed:     bool, // "Reinstall" pressed once
	play:      bool, // Play chosen: launched by game_menu_update, outside the draw pass
}

game_menu: Game_Menu

game_menu_open :: proc(s: Screen, i: int) {
	if input_locked() || i < 0 || i >= grid_count(s) do return
	g := s == .Main ? &app.drive_games[i] : &app.library_games[i]
	game_menu.screen = s
	game_menu.root = fmt.bprint(game_menu.root_buf[:], g.root)
	game_menu.title = fmt.bprint(game_menu.title_buf[:], g.title)
	game_menu.sel = 0
	game_menu.armed = false
	kind, can, _ := install_kind(g)
	game_menu.installed = can && install_exists(g, kind)
	plugins_game_actions_collect(g)
	game_menu.open = true
	sfx_click()
}

game_menu_game :: proc() -> ^Game {
	list := game_menu.screen == .Main ? app.drive_games[:] : app.library_games[:]
	for &g in list do if g.root == game_menu.root do return &g
	return nil
}

game_menu_rows :: proc(g: ^Game) -> []Game_Menu_Item {
	rows := make([dynamic]Game_Menu_Item, context.temp_allocator)
	append(&rows, Game_Menu_Item{row = .Play})
	if install_is(g) {
		append(&rows, Game_Menu_Item{row = .Cancel_Install})
	} else if _, can, why := install_kind(g); can || why != "" {
		append(&rows, Game_Menu_Item{row = .Install})
	}
	for _, i in plugin_game_actions do append(&rows, Game_Menu_Item{row = .Plugin, action = i})
	append(&rows, Game_Menu_Item{row = .Close})
	return rows[:]
}

game_menu_label :: proc(g: ^Game, item: Game_Menu_Item) -> string {
	switch item.row {
	case .Play:
		return "Play"
	case .Install:
		if game_menu.armed do return "Press Again to Reinstall"
		return game_menu.installed ? "Reinstall" : "Install to Library"
	case .Cancel_Install:
		total := sync.atomic_load(&install.total_bytes)
		if total <= 0 do return "Cancel Install"
		return fmt.tprintf("Cancel Install (%d%%)", int(f64(sync.atomic_load(&install.done_bytes)) * 100 / f64(total)))
	case .Plugin:
		return plugin_game_actions[item.action].name
	case .Close:
		return "Close"
	}
	return ""
}

game_menu_sub :: proc(g: ^Game) -> string {
	if install_is(g) do return "Installing to your library…"
	kind, can, why := install_kind(g)
	switch {
	case !g.from_drive:
		return g.platform != .None ? fmt.tprintf("%s  ·  in your library", RETRO_PLATFORM_NAME[g.platform]) : "In your library"
	case !can && why != "":
		return why
	case game_menu.installed:
		return "Already in your library  ·  reinstall to refresh it"
	case kind == .Folder && g.platform == .None:
		return "Install copies it to GAMES"
	case:
		return fmt.tprintf("Install copies it to GAMES  ·  %s", RETRO_PLATFORM_NAME[g.platform])
	}
}

// Start of handle_app_input: a game chosen from the menu (clicks arrive while drawing, and a
// game runs its own frame loop). true = this frame's input was used.
game_menu_update :: proc() -> bool {
	if !game_menu.play do return false
	game_menu.play = false
	if g := game_menu_game(); g != nil do play_game(g)
	return true
}

game_menu_close :: proc() {
	game_menu.open = false
	sfx_back()
}

game_menu_input :: proc() {
	g := game_menu_game()
	if g == nil {
		game_menu.open = false // its drive went away
		return
	}
	rows := game_menu_rows(g)
	n := len(rows)
	game_menu.sel = clamp(game_menu.sel, 0, n - 1)
	if input.up || input.down {
		game_menu.sel = (game_menu.sel + (input.up ? n - 1 : 1)) % n
		game_menu.armed = false
		sfx_click()
	}
	if input.cancel || input.action || input.power {
		game_menu_close()
		return
	}
	if input.confirm do game_menu_choose(g, rows[game_menu.sel])
}

game_menu_choose :: proc(g: ^Game, item: Game_Menu_Item) {
	switch item.row {
	case .Play:
		game_menu.open = false
		game_menu.play = true
	case .Install:
		if install.running {
			set_status("Already installing %s  ·  one install at a time", install.title)
			sfx_back()
			return
		}
		if _, can, why := install_kind(g); !can {
			set_status("%s", why)
			sfx_back()
			return
		}
		if game_menu.installed && !game_menu.armed {
			game_menu.armed = true
			sfx_click()
			return
		}
		if ok, err := install_start(g); !ok {
			set_status("%s", err)
			sfx_back()
			return
		}
		set_status("Installing %s…", g.title)
		game_menu.open = false
		sfx_click()
	case .Cancel_Install:
		install_cancel()
		set_status("Cancelling the install of %s…", install.title)
		game_menu_close()
	case .Plugin:
		game_menu.open = false
		sfx_click()
		if msg := plugins_game_action_run(item.action); msg != "" do set_status("%s", msg)
	case .Close:
		game_menu_close()
	}
}

draw_game_menu :: proc(w, h: f32) {
	game_menu.t = smooth_to(game_menu.t, game_menu.open ? 1 : 0, 16)
	if game_menu.t < 0.02 && !game_menu.open do return
	g := game_menu_game()
	if g == nil {
		game_menu.open = false
		return
	}
	rows := game_menu_rows(g)
	labels := make([]string, len(rows), context.temp_allocator)
	for r, i in rows do labels[i] = game_menu_label(g, r)
	if clicked := draw_modal_menu(game_menu.title, game_menu_sub(g), labels, game_menu.sel, game_menu.t, w, h, game_menu.open); clicked >= 0 {
		if clicked != game_menu.sel do game_menu.armed = false
		game_menu.sel = clicked
		game_menu_choose(g, rows[clicked])
	}
}

// ---------------------------------------------------------------------------
// Progress card: bottom-right, above the drive card when both show

draw_install_card :: proc(w, h: f32) {
	now := rl.GetTime()
	show := install.running || (install.ended_at > 0 && now - install.ended_at < INSTALL_CARD_SEC)
	install.card_t = smooth_to(install.card_t, show ? 1 : 0, 14)
	t := install.card_t
	if t < 0.02 do return

	cw: f32 = 440
	ch: f32 = 104
	s := 0.92 + 0.08 * t
	y := h - FOOTER_H - 20 - ch * s - drive_scan.card_t * (92 + 12)
	r := rl.Rectangle{w - PAD - cw * s + (1 - t) * 60, y, cw * s, ch * s}
	failed := !install.running && !install.ended_ok
	draw_soft_shadow(r, RADIUS, t * 1.4)
	draw_glass(r, RADIUS, COL_PANEL_SOLID, 0.5, failed ? COL_WARN : COL_ACCENT, 0.25, t)
	if t < 0.5 do return

	icon := rl.Vector2{r.x + 52, r.y + r.height * 0.5}
	time := f32(now)
	disc := install.kind == .Disc || install.kind == .Dc
	if disc {
		draw_spinning_disc(icon, 30, install.running ? time : 0)
	} else {
		draw_usb_stick(icon, 30, install.running ? time : 0)
	}
	tx := r.x + 100
	tw := r.width - (tx - r.x) - 22
	if !install.running {
		draw_t(install.ended_ok ? "Installed" : "Install Stopped", tx, r.y + 24, 21, COL_TEXT)
		draw_t_fit(install.ended_msg, tx, r.y + 56, tw, 15, COL_MUTED, false)
		return
	}
	done := sync.atomic_load(&install.done_bytes)
	total := sync.atomic_load(&install.total_bytes)
	frac := total > 0 ? clamp(f32(f64(done) / f64(total)), 0, 1) : 0
	draw_t_fit(fmt.tprintf("Installing %s", install.title), tx, r.y + 18, tw, 19, COL_TEXT, false)
	line := "Preparing…"
	if sync.atomic_load(&install.cancel) {
		line = "Cancelling…"
	} else if total > 0 {
		line = fmt.tprintf("%d%%  ·  %s of %s", int(frac * 100), fmt_bytes(done), fmt_bytes(total))
		elapsed := now - install.started
		if speed := f64(done) / max(elapsed, 0.001); elapsed > 2 && speed > 0 && total > done {
			left := int(f64(total - done) / speed)
			line = fmt.tprintf("%s  ·  %s/s  ·  %d:%02d left", line, fmt_bytes(i64(speed)), left / 60, left % 60)
		}
	}
	draw_t_fit(line, tx, r.y + 46, tw, 14, COL_MUTED, false)
	bar := rl.Rectangle{tx, r.y + r.height - 28, tw, 8}
	rl.DrawRectangleRounded(bar, 1, 8, COL_FAINT)
	if frac > 0 do rl.DrawRectangleRounded({bar.x, bar.y, max(bar.height, bar.width * frac), bar.height}, 1, 8, COL_ACCENT)
}
