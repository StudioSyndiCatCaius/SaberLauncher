package saber

// BIOS installer: a drive with a "bios" folder at its root gets an "Install BIOS" card on
// Home. Playing it opens a menu of the consoles whose BIOS files were found there; picking
// one copies its files to where the libretro cores look (APP/libretro/system/...).
// Saber ships no BIOS: these are the user's own dumps, matched by file name (any case,
// any subfolder of "bios").

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

Bios_Known :: struct {
	name:     string,         // canonical file name, as the cores expect it
	platform: Retro_Platform,
	dest:     string,         // folder under APP/libretro/system ("" = system itself)
}

// File names the cores in RETRO_CORES load (swanstation / mednafen, flycast, mGBA / gambatte /
// SameBoy, melonDS, RPCS3, Genesis Plus GX, Mesen, Snes9x, mednafen PCE). PS2 BIOSes have no fixed
// name: see bios_is_ps2.
BIOS_KNOWN := [?]Bios_Known {
	{"scph5500.bin", .PS1, ""}, {"scph5501.bin", .PS1, ""}, {"scph5502.bin", .PS1, ""},
	{"scph1000.bin", .PS1, ""}, {"scph1001.bin", .PS1, ""}, {"scph3000.bin", .PS1, ""},
	{"scph3500.bin", .PS1, ""}, {"scph7000.bin", .PS1, ""}, {"scph7001.bin", .PS1, ""},
	{"scph7003.bin", .PS1, ""}, {"scph7502.bin", .PS1, ""}, {"scph101.bin", .PS1, ""},
	{"psxonpsp660.bin", .PS1, ""}, {"ps1_rom.bin", .PS1, ""},
	{"dc_boot.bin", .DC, "dc"}, {"dc_flash.bin", .DC, "dc"},
	{"gba_bios.bin", .GBA, ""},
	{"gb_bios.bin", .GB, ""}, {"dmg_boot.bin", .GB, ""}, {"sgb_bios.bin", .GB, ""}, {"sgb_boot.bin", .GB, ""},
	{"gbc_bios.bin", .GBC, ""}, {"cgb_boot.bin", .GBC, ""},
	{"bios7.bin", .NDS, ""}, {"bios9.bin", .NDS, ""}, {"firmware.bin", .NDS, ""},
	{"dsi_bios7.bin", .NDS, ""}, {"dsi_bios9.bin", .NDS, ""}, {"dsi_firmware.bin", .NDS, ""}, {"dsi_nand.bin", .NDS, ""},
	{"bios_MD.bin", .MD, ""}, {"bios_CD_U.bin", .MD, ""}, {"bios_CD_E.bin", .MD, ""}, {"bios_CD_J.bin", .MD, ""},
	{"bios_U.sms", .SMS, ""}, {"bios_E.sms", .SMS, ""}, {"bios_J.sms", .SMS, ""},
	{"bios.gg", .GG, ""},
	{"disksys.rom", .NES, ""},
	{"BS-X.bin", .SNES, ""}, {"STBIOS.bin", .SNES, ""},
	{"syscard3.pce", .PCE, ""}, {"syscard2.pce", .PCE, ""}, {"syscard1.pce", .PCE, ""}, {"gexpress.pce", .PCE, ""},
}

PS2_BIOS_SIZE :: 4 * 1024 * 1024
BIOS_MAX_DEPTH :: 3

Bios_File :: struct {
	src:       string,
	name:      string, // installed as
	platform:  Retro_Platform,
	dest:      string, // full destination path
	size:      i64,
	installed: bool,   // an identical file is already there
}

// A PS2-family BIOS dump (retail consoles and PS2-based arcade boards like Namco System
// 246/256): 4 MiB holding the ROMDIR "RESET" entry pcsx2 itself checks for. Any name: pcsx2
// lists every valid image in system/pcsx2/bios.
PS2_ROMDIR_SCAN :: 512 * 1024

bios_is_ps2 :: proc(path, name: string, size: i64) -> bool {
	if size != PS2_BIOS_SIZE do return false
	ext := strings.to_lower(filepath.ext(name), context.temp_allocator)
	if ext != ".bin" && ext != ".rom0" && ext != ".rom" && ext != "" do return false
	f, err := os.open(path)
	if err != nil do return false
	defer os.close(f)
	buf := make([]u8, PS2_ROMDIR_SCAN, context.temp_allocator)
	n, _ := os.read(f, buf)
	return strings.contains(string(buf[:max(n, 0)]), "RESET\x00\x00\x00\x00\x00")
}

// A PS3 system update (.pup, "SCEUF" header), whatever it's called.
bios_is_ps3 :: proc(path, name: string) -> bool {
	if !strings.equal_fold(filepath.ext(name), ".pup") do return false
	f, err := os.open(path)
	if err != nil do return false
	defer os.close(f)
	head: [5]byte
	n, _ := os.read(f, head[:])
	return n == 5 && string(head[:]) == "SCEUF"
}

// The "bios" folder at a drive's root, any case ("" = none).
bios_folder :: proc(root: string) -> string {
	fis, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil do return ""
	for fi in fis {
		if fi.type == .Directory && strings.equal_fold(fi.name, "bios") do return strings.clone(fi.fullpath)
	}
	return ""
}

// Every BIOS file under `dir` (temp-allocated), sorted by console then name.
bios_find :: proc(dir: string) -> [dynamic]Bios_File {
	out := make([dynamic]Bios_File, context.temp_allocator)
	bios_walk(&out, dir, 0)
	slice.sort_by(out[:], proc(a, b: Bios_File) -> bool {
		if a.platform != b.platform do return a.platform < b.platform
		return a.name < b.name
	})
	return out
}

bios_walk :: proc(out: ^[dynamic]Bios_File, dir: string, depth: int) {
	fis, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for fi in fis {
		if fi.type == .Directory {
			if depth < BIOS_MAX_DEPTH do bios_walk(out, fi.fullpath, depth + 1)
			continue
		}
		if fi.type != .Regular || fi.size <= 0 do continue
		f := Bios_File{src = fi.fullpath, size = fi.size}
		for k in BIOS_KNOWN {
			if strings.equal_fold(fi.name, k.name) {
				f.name, f.platform = k.name, k.platform
				f.dest = retro_dir("system", k.dest, k.name) if k.dest != "" else retro_dir("system", k.name)
				break
			}
		}
		if f.platform == .None && bios_is_ps2(fi.fullpath, fi.name, fi.size) {
			f.name, f.platform = fi.name, .PS2
			f.dest = retro_dir("system", "pcsx2", "bios", fi.name)
		}
		if f.platform == .None && bios_is_ps3(fi.fullpath, fi.name) {
			// any name (PS3UPDAT493.PUP...): RPCS3 installs system/rpcs3/firmware/PS3UPDAT.PUP on first start
			f.name, f.platform = "PS3UPDAT.PUP", .PS3
			f.dest = retro_dir("system", "rpcs3", "firmware", "PS3UPDAT.PUP")
		}
		if f.platform == .None do continue
		// the same file twice (say bios/ and bios/ps1/): keep the first
		dup := false
		for o in out do if o.dest == f.dest do dup = true
		if dup do continue
		f.dest = strings.clone(f.dest, context.temp_allocator)
		append(out, f)
		if f.platform == .PS2 do bios_ps2_companions(out, fis, fi.name)
	}
}

// pcsx2 reads a BIOS's NVRAM / MECHACON / ROM1-2 / EROM dumps from beside it, by the same stem.
PS2_COMPANION_EXTS := [?]string{".nvm", ".mec", ".rom1", ".rom2", ".erom"}

bios_ps2_companions :: proc(out: ^[dynamic]Bios_File, fis: []os.File_Info, bin: string) {
	stem := filepath.stem(bin)
	for fi in fis {
		if fi.type != .Regular || !strings.equal_fold(filepath.stem(fi.name), stem) do continue
		ext := strings.to_lower(filepath.ext(fi.name), context.temp_allocator)
		if !slice.contains(PS2_COMPANION_EXTS[:], ext) do continue
		append(out, Bios_File{src = fi.fullpath, name = fi.name, platform = .PS2, size = fi.size,
			dest = strings.clone(retro_dir("system", "pcsx2", "bios", fi.name), context.temp_allocator)})
	}
}

// Full compare is only done for small files on the main thread; big ones (PS3 firmware)
// match by size there and are verified byte for byte by the install worker.
BIOS_QUICK_LIMIT :: 16 * 1024 * 1024

bios_same :: proc(a, b: string, quick := false) -> bool {
	fa, ea := os.open(a)
	if ea != nil do return false
	defer os.close(fa)
	fb, eb := os.open(b)
	if eb != nil do return false
	defer os.close(fb)
	sa, _ := os.file_size(fa)
	sb, _ := os.file_size(fb)
	if sa != sb do return false
	if quick && sa > BIOS_QUICK_LIMIT do return true
	// streamed: the PS3 firmware (PS3UPDAT.PUP) is ~200 MB
	CHUNK :: 1024 * 1024
	ba := make([]byte, CHUNK, context.temp_allocator)
	bb := make([]byte, CHUNK, context.temp_allocator)
	for off: i64 = 0; off < sa; off += CHUNK {
		na, _ := os.read_at(fa, ba, off)
		nb, _ := os.read_at(fb, bb, off)
		if na <= 0 || na != nb || string(ba[:na]) != string(bb[:nb]) do return false
	}
	return true
}

// Drive scan (worker thread): the "Install BIOS" card for a drive whose bios folder holds any.
bios_game :: proc(root, label: string) -> (Game, bool) {
	dir := bios_folder(root)
	if dir == "" do return {}, false
	if len(bios_find(dir)) == 0 {
		delete(dir)
		return {}, false
	}
	g: Game
	g.root = dir
	g.bios_dir = dir
	g.title = strings.clone("Install BIOS")
	g.drive_label = strings.clone(label)
	g.from_drive = true
	return g, true
}

// ---------------------------------------------------------------------------
// Menu (opened by playing the card)

Bios_Group :: struct {
	platform: Retro_Platform,
	files:    int,
	missing:  int,
}

Bios_Menu :: struct {
	open:      bool,
	t:         f32,
	sel:       int,
	scroll:    int, // first row shown
	root_buf:  [512]u8,
	root:      string, // the card's Game.root, looked up again like game_menu
	label_buf: [128]u8,
	label:     string,
	files:     [dynamic]Bios_File, // heap: cloned when opened
	groups:    [dynamic]Bios_Group,
	note_buf:  [160]u8,
	note:      string, // last result, shown as the subtitle
}

bios_menu: Bios_Menu

bios_menu_open :: proc(g: ^Game) {
	bios_menu.root = fmt.bprint(bios_menu.root_buf[:], g.root)
	bios_menu.label = fmt.bprint(bios_menu.label_buf[:], g.drive_label)
	bios_menu.note = ""
	bios_menu.sel = 0
	bios_menu.scroll = 0
	bios_menu_refresh()
	if len(bios_menu.files) == 0 {
		set_status("No BIOS files found on %s anymore", g.drive_label)
		sfx_back()
		return
	}
	bios_menu.open = true
	sfx_click()
}

bios_menu_refresh :: proc() {
	for f in bios_menu.files {
		delete(f.src)
		delete(f.dest)
	}
	clear(&bios_menu.files)
	clear(&bios_menu.groups)
	for f in bios_find(bios_menu.root) {
		c := f
		c.src = strings.clone(f.src)
		c.name = filepath.base(c.src) if f.platform == .PS2 else f.name
		c.dest = strings.clone(f.dest)
		c.installed = bios_same(f.src, f.dest, quick = true)
		append(&bios_menu.files, c)
		if n := len(bios_menu.groups); n == 0 || bios_menu.groups[n - 1].platform != c.platform {
			append(&bios_menu.groups, Bios_Group{platform = c.platform})
		}
		grp := &bios_menu.groups[len(bios_menu.groups) - 1]
		grp.files += 1
		if !c.installed do grp.missing += 1
	}
}

// Rows: [Install All], one per console, Close
bios_menu_has_all :: proc() -> bool {
	return len(bios_menu.groups) > 1
}

bios_menu_rows :: proc() -> int {
	return (bios_menu_has_all() ? 1 : 0) + len(bios_menu.groups) + 1
}

Bios_Row_Kind :: enum {
	All,
	Group,
	Close,
}

bios_menu_row :: proc(row: int) -> (Bios_Row_Kind, int) {
	i := row
	if bios_menu_has_all() {
		if i == 0 do return .All, -1
		i -= 1
	}
	if i < len(bios_menu.groups) do return .Group, i
	return .Close, -1
}

bios_menu_sub :: proc() -> string {
	if bios_job_running() {
		text, _ := bios_job_progress()
		return text
	}
	if bios_menu.note != "" do return bios_menu.note
	return fmt.tprintf("Your own dumps from %s  ·  copied into APP\\libretro\\system", bios_menu.label)
}

// Install job: copies run on a worker thread (the PS3 firmware is ~200 MB), each file
// written as <dest>.part, verified, then renamed. The menu polls it every frame.
Bios_Copy :: struct {
	src, dest: string,
	failed:    bool, // set by the worker, logged on the main thread
}

Bios_Job :: struct {
	thread:   ^thread.Thread,
	platform: Retro_Platform,
	copies:   [dynamic]Bios_Copy,
	total:    i64,
	copied:   i64,  // atomic
	current:  int,  // atomic: index of the file being copied
	cancel:   bool, // atomic
	finished: bool, // atomic
	done:     int,
	failed:   int,
}

bios_job: Bios_Job

bios_job_running :: proc() -> bool {
	return bios_job.thread != nil
}

// Copies every missing file of `platform` (.None = every console).
bios_install :: proc(platform: Retro_Platform) {
	if bios_job_running() do return
	bios_job = {platform = platform}
	for f in bios_menu.files {
		if (platform != .None && f.platform != platform) || f.installed do continue
		append(&bios_job.copies, Bios_Copy{src = strings.clone(f.src), dest = strings.clone(f.dest)})
		bios_job.total += f.size
	}
	if len(bios_job.copies) == 0 {
		delete(bios_job.copies)
		bios_install_report(platform, 0, 0)
		return
	}
	sfx_click()
	bios_job.thread = thread.create_and_start(bios_job_run)
}

bios_job_run :: proc() {
	buf := make([]byte, 1024 * 1024)
	defer delete(buf)
	for &c, i in bios_job.copies {
		if sync.atomic_load(&bios_job.cancel) do break
		sync.atomic_store(&bios_job.current, i)
		if bios_copy_file(c.src, c.dest, buf) {
			bios_job.done += 1
		} else {
			bios_job.failed += 1
			c.failed = !sync.atomic_load(&bios_job.cancel)
		}
		free_all(context.temp_allocator)
	}
	sync.atomic_store(&bios_job.finished, true)
}

bios_copy_file :: proc(src, dest: string, buf: []byte) -> bool {
	os.make_directory_all(filepath.dir(dest))
	part := fmt.tprintf("%s.part", dest)
	ok := false
	{
		in_f, e1 := os.open(src)
		if e1 != nil do return false
		defer os.close(in_f)
		out_f, e2 := os.open(part, {.Write, .Create, .Trunc})
		if e2 != nil do return false
		defer os.close(out_f)
		for {
			if sync.atomic_load(&bios_job.cancel) do break
			n, _ := os.read(in_f, buf)
			if n <= 0 {
				ok = true
				break
			}
			if w, e := os.write(out_f, buf[:n]); e != nil || w != n do break
			sync.atomic_add(&bios_job.copied, i64(n))
		}
	}
	if ok do ok = bios_same(src, part)
	if ok {
		os.remove(dest)
		ok = os.rename(part, dest) == nil
	}
	if !ok do os.remove(part)
	return ok
}

// Main thread, every frame: finishes a completed job.
bios_job_poll :: proc() {
	if !bios_job_running() || !sync.atomic_load(&bios_job.finished) do return
	thread.join(bios_job.thread)
	thread.destroy(bios_job.thread)
	cancelled := sync.atomic_load(&bios_job.cancel)
	platform, done, failed := bios_job.platform, bios_job.done, bios_job.failed
	for c in bios_job.copies {
		if c.failed do plugin_logf("BIOS: couldn't copy %s to %s", c.src, c.dest)
		delete(c.src)
		delete(c.dest)
	}
	delete(bios_job.copies)
	bios_job = {}
	if cancelled {
		bios_menu.note = fmt.bprintf(bios_menu.note_buf[:], "BIOS install stopped")
		set_status("%s", bios_menu.note)
	} else {
		bios_install_report(platform, done, failed)
	}
	if bios_menu.open || bios_menu_card_present() do bios_menu_refresh()
}

// The progress line shown as the menu subtitle while copying.
bios_job_progress :: proc() -> (text: string, frac: f32) {
	i := clamp(sync.atomic_load(&bios_job.current), 0, len(bios_job.copies) - 1)
	frac = f32(f64(sync.atomic_load(&bios_job.copied)) / f64(max(bios_job.total, 1)))
	return fmt.tprintf("Copying %s  ·  %d%%  (%d/%d)", filepath.base(bios_job.copies[i].dest), int(frac * 100), i + 1, len(bios_job.copies)), frac
}

bios_install_report :: proc(platform: Retro_Platform, done, failed: int) {
	what := platform == .None ? "BIOS" : fmt.tprintf("%s BIOS", RETRO_PLATFORM_NAME[platform])
	switch {
	case failed > 0:
		bios_menu.note = fmt.bprintf(bios_menu.note_buf[:], "Couldn't copy %d %s file(s)  ·  is APP writable?", failed, what)
		sfx_back()
	case done == 0:
		bios_menu.note = fmt.bprintf(bios_menu.note_buf[:], "%s already installed", what)
		sfx_click()
	case:
		bios_menu.note = fmt.bprintf(bios_menu.note_buf[:], "Installed %d %s file%s", done, what, done == 1 ? "" : "s")
		sfx_click()
	}
	set_status("%s", bios_menu.note)
}

// Stops a running copy (drive pulled, Saber quitting) and waits for the worker.
bios_job_cancel :: proc() {
	if !bios_job_running() do return
	sync.atomic_store(&bios_job.cancel, true)
	for !sync.atomic_load(&bios_job.finished) do sleep_ms(5)
	bios_job_poll()
}

bios_menu_choose :: proc(row: int) {
	if bios_job_running() {
		kind, _ := bios_menu_row(row)
		if kind == .Close do bios_menu_close()
		return
	}
	switch kind, gi := bios_menu_row(row); kind {
	case .All:
		bios_install(.None)
	case .Group:
		bios_install(bios_menu.groups[gi].platform)
	case .Close:
		bios_menu_close()
	}
}

bios_menu_close :: proc() {
	bios_menu.open = false
	sfx_back()
}

bios_menu_card_present :: proc() -> bool {
	for g in app.drive_games do if g.bios_dir != "" && g.root == bios_menu.root do return true
	return false
}

bios_menu_input :: proc() {
	if !bios_menu_card_present() {
		bios_job_cancel()
		bios_menu.open = false // the drive was pulled
		return
	}
	n := bios_menu_rows()
	bios_menu.sel = clamp(bios_menu.sel, 0, n - 1)
	if input.up || input.down {
		bios_menu.sel = (bios_menu.sel + (input.up ? n - 1 : 1)) % n
		sfx_click()
	}
	if input.cancel || input.action || input.power {
		bios_menu_close()
		return
	}
	if input.confirm do bios_menu_choose(bios_menu.sel)
}

draw_bios_menu :: proc(w, h: f32) {
	bios_menu.t = smooth_to(bios_menu.t, bios_menu.open ? 1 : 0, 16)
	if bios_menu.t < 0.02 && !bios_menu.open do return
	if bios_menu.open && !bios_menu_card_present() do bios_menu.open = false
	t := bios_menu.t
	interactive := bios_menu.open

	ROW_H :: 64
	GAP :: 8
	HEAD :: 112
	rl.DrawRectangle(0, 0, i32(w), i32(h), with_alpha(COL_SHADE, u8(150 * t)))
	rows := bios_menu_rows()
	pw := min(f32(940), w - 48)
	ph := min(h - 48, HEAD + f32(rows) * (ROW_H + GAP) + 24)
	ph = max(ph, min(h - 48, 420))
	s := 0.94 + 0.06 * t
	r := rl.Rectangle{(w - pw * s) * 0.5, (h - ph * s) * 0.5, pw * s, ph * s}
	draw_panel(r, false, with_alpha(COL_PANEL_SOLID, u8(244 * t)))
	if t < 0.5 do return

	// header: chip badge, title, source, overall tally
	total, missing := 0, 0
	for grp in bios_menu.groups {
		total += grp.files
		missing += grp.missing
	}
	draw_bios_tile(BIOS_STYLE[.None], {r.x + 26, r.y + 24, 60, 60})
	draw_t_fit("Install BIOS", r.x + 102, r.y + 26, r.width - 360, 28, COL_TEXT, true)
	draw_t_fit(bios_menu_sub(), r.x + 102, r.y + 64, r.width - 360, 15, bios_menu.note != "" || bios_job_running() ? COL_ACCENT : COL_MUTED, true)
	{
		right := r.x + r.width - 30
		label := missing == 0 ? "All installed" : fmt.tprintf("%d of %d installed", total - missing, total)
		lw := measure_t(label, 17)
		draw_t_right(label, right, r.y + 42, 17, missing == 0 ? BIOS_OK : COL_MUTED)
		if bios_job_running() {
			_, frac := bios_job_progress()
			draw_bios_progress({right - 180, r.y + 70, 180, 5}, frac)
		} else if missing == 0 {
			draw_bios_check(right - lw - 18, r.y + 52, 11)
		} else {
			draw_bios_progress({right - 180, r.y + 70, 180, 5}, f32(total - missing) / f32(max(total, 1)))
		}
	}
	rl.DrawRectangle(i32(r.x + 24), i32(r.y + HEAD - 14), i32(r.width - 48), 1, COL_FAINT)

	// list (left) + details of the focused row (right, when there's room)
	wide := r.width >= 720
	list := rl.Rectangle{r.x + 24, r.y + HEAD, wide ? r.width * 0.5 - 24 : r.width - 48, r.height - HEAD - 22}
	visible := max(1, int((list.height + GAP) / (ROW_H + GAP)))
	bios_menu.sel = clamp(bios_menu.sel, 0, rows - 1)
	if bios_menu.sel < bios_menu.scroll do bios_menu.scroll = bios_menu.sel
	if bios_menu.sel >= bios_menu.scroll + visible do bios_menu.scroll = bios_menu.sel - visible + 1
	bios_menu.scroll = clamp(bios_menu.scroll, 0, max(rows - visible, 0))

	clicked := -1
	for i in bios_menu.scroll ..< min(rows, bios_menu.scroll + visible) {
		br := rl.Rectangle{list.x, list.y + f32(i - bios_menu.scroll) * (ROW_H + GAP), list.width - (rows > visible ? 12 : 0), ROW_H}
		hovered := interactive && mouse_over(br, true)
		if hovered {
			hover_enter(fmt.tprintf("bios-%d", i))
			bios_menu.sel = i
			if rl.IsMouseButtonPressed(.LEFT) do clicked = i
		}
		draw_bios_row(i, br, i == bios_menu.sel)
	}
	if rows > visible {
		track := rl.Rectangle{list.x + list.width - 5, list.y, 5, f32(visible) * (ROW_H + GAP) - GAP}
		rl.DrawRectangleRounded(track, 1, 4, COL_FAINT)
		th := track.height * f32(visible) / f32(rows)
		ty := track.y + (track.height - th) * f32(bios_menu.scroll) / f32(rows - visible)
		rl.DrawRectangleRounded({track.x, ty, track.width, th}, 1, 4, with_alpha(COL_ACCENT, 200))
	}
	if wide {
		d := rl.Rectangle{list.x + list.width + 16, list.y, r.x + r.width - 24 - (list.x + list.width + 16), list.height}
		draw_bios_details(d)
	}
	if clicked >= 0 do bios_menu_choose(clicked)
}

// ---------------------------------------------------------------------------
// Menu pieces

BIOS_OK :: rl.Color{72, 196, 120, 255}

Bios_Icon :: enum {
	Chip,
	Disc,
	Handheld,      // upright, screen over the buttons
	Wide_Handheld, // landscape, buttons either side of the screen
	Dual_Screen,
	Cartridge,
}

Bios_Style :: struct {
	icon:  Bios_Icon,
	color: rl.Color,
	tag:   string,
}

// Saber's own simple device drawings in a colour per console, not the consoles' logos:
// nothing here copies a trademark, so it ships with Saber.
BIOS_STYLE := [Retro_Platform]Bios_Style {
	.None  = {.Chip, {90, 180, 255, 255}, ""},
	.PS1   = {.Disc, {156, 168, 194, 255}, "PS1"},
	.PS2   = {.Disc, {72, 112, 224, 255}, "PS2"},
	.PSP   = {.Wide_Handheld, {136, 146, 170, 255}, "PSP"},
	.DC    = {.Disc, {242, 136, 52, 255}, "DC"},
	.GB    = {.Handheld, {150, 178, 72, 255}, "GB"},
	.GBC   = {.Handheld, {170, 96, 216, 255}, "GBC"},
	.GBA   = {.Wide_Handheld, {104, 96, 216, 255}, "GBA"},
	.NES   = {.Cartridge, {216, 68, 62, 255}, "NES"},
	.SNES  = {.Cartridge, {152, 132, 216, 255}, "SNES"},
	.N64   = {.Cartridge, {52, 170, 102, 255}, "N64"},
	.MD    = {.Cartridge, {228, 82, 72, 255}, "MD"},
	.SMS   = {.Cartridge, {72, 132, 228, 255}, "SMS"},
	.GG    = {.Wide_Handheld, {82, 178, 228, 255}, "GG"},
	.NDS   = {.Dual_Screen, {178, 188, 206, 255}, "NDS"},
	.PCE   = {.Cartridge, {238, 152, 62, 255}, "PCE"},
	.A2600 = {.Cartridge, {208, 148, 78, 255}, "2600"},
	.GC    = {.Disc, {122, 100, 202, 255}, "GC"},
	.WII   = {.Disc, {188, 208, 228, 255}, "Wii"},
	.PS3   = {.Disc, {150, 150, 160, 255}, "PS3"},
}

// A rounded tile tinted with the console's colour, its device drawn inside.
draw_bios_tile :: proc(st: Bios_Style, r: rl.Rectangle) {
	rl.DrawRectangleRounded(r, 0.32, 8, with_alpha(st.color, 46))
	rl.DrawRectangleRoundedLinesEx(r, 0.32, 8, 1.5, with_alpha(st.color, 120))
	pad := r.width * 0.14
	draw_bios_icon(st, {r.x + pad, r.y + pad, r.width - pad * 2, r.height - pad * 2})
}

draw_bios_icon :: proc(st: Bios_Style, r: rl.Rectangle) {
	col := st.color
	ink := rl.Color{18, 22, 34, 235}
	cx, cy := r.x + r.width * 0.5, r.y + r.height * 0.5
	s := min(r.width, r.height)
	dpad :: proc(x, y, size: f32, c: rl.Color) {
		t := size * 0.36
		rl.DrawRectangleRec({x - size * 0.5, y - t * 0.5, size, t}, c)
		rl.DrawRectangleRec({x - t * 0.5, y - size * 0.5, t, size}, c)
	}
	switch st.icon {
	case .Chip:
		body := rl.Rectangle{cx - s * 0.3, cy - s * 0.3, s * 0.6, s * 0.6}
		for i in 0 ..< 4 {
			o := body.x + body.width * (0.2 + f32(i) * 0.2) - s * 0.035
			p := body.y + body.height * (0.2 + f32(i) * 0.2) - s * 0.035
			rl.DrawRectangleRec({o, body.y - s * 0.14, s * 0.07, s * 0.14}, {226, 184, 92, 255})
			rl.DrawRectangleRec({o, body.y + body.height, s * 0.07, s * 0.14}, {226, 184, 92, 255})
			rl.DrawRectangleRec({body.x - s * 0.14, p, s * 0.14, s * 0.07}, {226, 184, 92, 255})
			rl.DrawRectangleRec({body.x + body.width, p, s * 0.14, s * 0.07}, {226, 184, 92, 255})
		}
		rl.DrawRectangleRounded(body, 0.18, 6, {40, 46, 60, 255})
		die := rl.Rectangle{body.x + body.width * 0.25, body.y + body.height * 0.25, body.width * 0.5, body.height * 0.5}
		rl.DrawRectangleRoundedLinesEx(die, 0.2, 6, max(1, s * 0.03), col)
	case .Disc:
		rad := s * 0.46
		rl.DrawCircleV({cx, cy}, rad, col)
		rl.DrawCircleSector({cx, cy}, rad * 0.96, 200, 250, 12, {255, 255, 255, 90})
		rl.DrawCircleSector({cx, cy}, rad * 0.96, 20, 60, 12, {255, 255, 255, 50})
		rl.DrawRing({cx, cy}, rad * 0.3, rad * 0.38, 0, 360, 32, {0, 0, 0, 60})
		rl.DrawCircleV({cx, cy}, rad * 0.17, ink)
	case .Handheld:
		b := rl.Rectangle{cx - s * 0.3, cy - s * 0.46, s * 0.6, s * 0.92}
		rl.DrawRectangleRounded(b, 0.22, 6, col)
		rl.DrawRectangleRounded({b.x + b.width * 0.13, b.y + b.height * 0.09, b.width * 0.74, b.height * 0.4}, 0.14, 4, ink)
		dpad(b.x + b.width * 0.3, b.y + b.height * 0.7, b.width * 0.26, ink)
		rl.DrawCircleV({b.x + b.width * 0.66, b.y + b.height * 0.73}, b.width * 0.075, ink)
		rl.DrawCircleV({b.x + b.width * 0.8, b.y + b.height * 0.66}, b.width * 0.075, ink)
	case .Wide_Handheld:
		b := rl.Rectangle{cx - s * 0.5, cy - s * 0.27, s, s * 0.54}
		rl.DrawRectangleRounded(b, 0.5, 8, col)
		rl.DrawRectangleRounded({b.x + b.width * 0.29, b.y + b.height * 0.16, b.width * 0.42, b.height * 0.68}, 0.12, 4, ink)
		dpad(b.x + b.width * 0.15, b.y + b.height * 0.5, b.height * 0.36, ink)
		rl.DrawCircleV({b.x + b.width * 0.82, b.y + b.height * 0.6}, b.height * 0.08, ink)
		rl.DrawCircleV({b.x + b.width * 0.9, b.y + b.height * 0.42}, b.height * 0.08, ink)
	case .Dual_Screen:
		top := rl.Rectangle{cx - s * 0.36, cy - s * 0.47, s * 0.72, s * 0.44}
		bot := rl.Rectangle{top.x, cy + s * 0.03, top.width, top.height}
		for b in ([2]rl.Rectangle{top, bot}) {
			rl.DrawRectangleRounded(b, 0.2, 6, col)
			rl.DrawRectangleRounded({b.x + b.width * 0.2, b.y + b.height * 0.15, b.width * 0.6, b.height * 0.7}, 0.1, 4, ink)
		}
		rl.DrawRectangleRec({top.x + top.width * 0.1, cy - s * 0.03, top.width * 0.8, s * 0.06}, with_alpha(col, 160))
	case .Cartridge:
		b := rl.Rectangle{cx - s * 0.36, cy - s * 0.46, s * 0.72, s * 0.92}
		rl.DrawRectangleRounded(b, 0.12, 4, col)
		rl.DrawRectangleRec({b.x + b.width * 0.3, b.y, b.width * 0.4, b.height * 0.06}, {0, 0, 0, 70}) // grip
		lab := rl.Rectangle{b.x + b.width * 0.12, b.y + b.height * 0.14, b.width * 0.76, b.height * 0.5}
		rl.DrawRectangleRounded(lab, 0.12, 4, {245, 245, 250, 230})
		if st.tag != "" {
			size := min(lab.height * 0.5, lab.width / max(f32(len(st.tag)), 1) * 1.5)
			draw_t_center(st.tag, lab.x + lab.width * 0.5, lab.y + (lab.height - size) * 0.5, size, ink)
		}
		for k in 0 ..< 3 {
			y := b.y + b.height * (0.74 + f32(k) * 0.07)
			rl.DrawRectangleRec({b.x + b.width * 0.18, y, b.width * 0.64, max(1, s * 0.025)}, {0, 0, 0, 70})
		}
	}
}

draw_bios_check :: proc(cx, cy, rad: f32) {
	rl.DrawCircleV({cx, cy}, rad, BIOS_OK)
	lw := max(2, rad * 0.24)
	a := rl.Vector2{cx - rad * 0.46, cy + rad * 0.02}
	b := rl.Vector2{cx - rad * 0.12, cy + rad * 0.36}
	c := rl.Vector2{cx + rad * 0.48, cy - rad * 0.34}
	rl.DrawLineEx(a, b, lw, rl.WHITE)
	rl.DrawLineEx(b, c, lw, rl.WHITE)
	rl.DrawCircleV(b, lw * 0.5, rl.WHITE)
}

// Not there yet: a downward arrow into a tray, in the accent colour.
draw_bios_pending :: proc(cx, cy, rad: f32, col: rl.Color) {
	rl.DrawRing({cx, cy}, rad - max(1.5, rad * 0.14), rad, 0, 360, 32, col)
	lw := max(1.5, rad * 0.18)
	rl.DrawLineEx({cx, cy - rad * 0.5}, {cx, cy + rad * 0.3}, lw, col)
	rl.DrawLineEx({cx - rad * 0.36, cy}, {cx, cy + rad * 0.38}, lw, col)
	rl.DrawLineEx({cx + rad * 0.36, cy}, {cx, cy + rad * 0.38}, lw, col)
}

draw_bios_progress :: proc(r: rl.Rectangle, frac: f32) {
	rl.DrawRectangleRounded(r, 1, 4, COL_FAINT)
	if frac > 0 do rl.DrawRectangleRounded({r.x, r.y, r.width * clamp(frac, 0, 1), r.height}, 1, 4, frac >= 1 ? BIOS_OK : COL_ACCENT)
}

// Right-aligned state: a green check once everything's in, else how much is new.
draw_bios_state :: proc(right, cy: f32, files, missing: int, hot: bool) {
	if missing == 0 {
		draw_t_right("Installed", right - 30, cy - 9, 16, BIOS_OK)
		draw_bios_check(right - 12, cy, 11)
		return
	}
	label := missing == files ? (hot ? "Install" : fmt.tprintf("%d new", missing)) : fmt.tprintf("%d new", missing)
	col := hot ? COL_ACCENT : COL_MUTED
	draw_t_right(label, right - 30, cy - 9, 16, col)
	draw_bios_pending(right - 12, cy, 11, col)
}

draw_bios_row :: proc(row: int, br: rl.Rectangle, hot: bool) {
	kind, gi := bios_menu_row(row)
	if hot {
		draw_glass(br, 18, mix_color(COL_PANEL_HI, COL_ACCENT, 0.25), 0.85, COL_ACCENT, 0.7, refract = 2)
	} else {
		draw_glass(br, 18, COL_PANEL_SOLID, 0.72, refract = 2)
	}
	cy := br.y + br.height * 0.5
	tile := rl.Rectangle{br.x + 10, br.y + 8, br.height - 16, br.height - 16}
	tx := tile.x + tile.width + 14
	right := br.x + br.width - 16
	switch kind {
	case .Close:
		draw_t_center("Close", br.x + br.width * 0.5, cy - 10, 20, hot ? COL_TEXT : COL_MUTED)
	case .All:
		files, missing := 0, 0
		for grp in bios_menu.groups {
			files += grp.files
			missing += grp.missing
		}
		draw_bios_tile(BIOS_STYLE[.None], tile)
		draw_t_fit("Install everything", tx, br.y + 12, right - tx - 120, 19, COL_TEXT, hot)
		draw_t(fmt.tprintf("%d consoles  ·  %d files", len(bios_menu.groups), files), tx, br.y + 36, 14, COL_MUTED)
		draw_bios_state(right, cy, files, missing, hot)
	case .Group:
		grp := bios_menu.groups[gi]
		draw_bios_tile(BIOS_STYLE[grp.platform], tile)
		draw_t_fit(RETRO_PLATFORM_NAME[grp.platform], tx, br.y + 12, right - tx - 120, 19, COL_TEXT, hot)
		draw_t(grp.files == 1 ? "1 file" : fmt.tprintf("%d files", grp.files), tx, br.y + 36, 14, COL_MUTED)
		draw_bios_state(right, cy, grp.files, grp.missing, hot)
	}
}

bios_size_label :: proc(n: i64) -> string {
	if n >= 1024 * 1024 do return fmt.tprintf("%.1f MB", f64(n) / (1024 * 1024))
	if n >= 1024 do return fmt.tprintf("%d KB", n / 1024)
	return fmt.tprintf("%d B", n)
}

// "APP\libretro\system\..." for a destination path.
bios_dest_label :: proc(dest: string) -> string {
	dir, _ := filepath.split(dest) // no allocation: this runs every frame
	dir = strings.trim_right(dir, "\\/")
	if i := strings.index(dir, "libretro"); i >= 0 do return fmt.tprintf("APP\\%s", dir[i:])
	return dir
}

draw_bios_details :: proc(d: rl.Rectangle) {
	draw_glass(d, 18, COL_PANEL_SOLID, 0.6, refract = 2)
	kind, gi := bios_menu_row(bios_menu.sel)
	x, y := d.x + 20, d.y + 18
	inner := d.width - 40
	bottom := d.y + d.height - 16
	LINE :: 30
	switch kind {
	case .Close:
		draw_bios_tile(BIOS_STYLE[.None], {x, y, 64, 64})
		draw_t("Bring your own firmware", x + 80, y + 10, 20, COL_TEXT)
		draw_t_fit("Saber ships no BIOS files", x + 80, y + 38, inner - 80, 14, COL_MUTED, false)
		lines := [?]string {
			"These are dumps from your own consoles,",
			"matched by file name on the drive.",
			"Nothing is copied until you pick a row.",
		}
		for l, i in lines do draw_t_fit(l, x, y + 96 + f32(i) * 24, inner, 15, COL_MUTED, false)
	case .All:
		draw_t("Everything on this drive", x, y, 20, COL_TEXT)
		y += 40
		for grp, i in bios_menu.groups {
			if y + LINE + 4 > bottom {
				draw_t(fmt.tprintf("+ %d more", len(bios_menu.groups) - i), x, y + 4, 14, COL_MUTED)
				break
			}
			draw_bios_tile(BIOS_STYLE[grp.platform], {x, y, 30, 30})
			draw_t_fit(RETRO_PLATFORM_NAME[grp.platform], x + 42, y + 6, inner - 150, 16, COL_TEXT, false)
			done := grp.files - grp.missing
			draw_t_right(fmt.tprintf("%d/%d", done, grp.files), x + inner - 28, y + 7, 15, grp.missing == 0 ? BIOS_OK : COL_MUTED)
			if grp.missing == 0 do draw_bios_check(x + inner - 10, y + 15, 9)
			else do draw_bios_pending(x + inner - 10, y + 15, 9, COL_MUTED)
			y += LINE + 6
		}
	case .Group:
		grp := bios_menu.groups[gi]
		st := BIOS_STYLE[grp.platform]
		draw_bios_tile(st, {x, y, 64, 64})
		draw_t_fit(RETRO_PLATFORM_NAME[grp.platform], x + 80, y + 6, inner - 80, 22, COL_TEXT, true)
		dest := ""
		for f in bios_menu.files do if f.platform == grp.platform {
			dest = bios_dest_label(f.dest)
			break
		}
		draw_t_fit(dest, x + 80, y + 38, inner - 80, 14, COL_MUTED, true)
		draw_bios_progress({x, y + 80, inner, 5}, f32(grp.files - grp.missing) / f32(max(grp.files, 1)))
		y += 100
		shown := 0
		for f in bios_menu.files {
			if f.platform != grp.platform do continue
			if y + LINE > bottom {
				draw_t(fmt.tprintf("+ %d more", grp.files - shown), x, y + 4, 14, COL_MUTED)
				break
			}
			if f.installed do draw_bios_check(x + 9, y + 11, 9)
			else do draw_bios_pending(x + 9, y + 11, 9, COL_MUTED)
			sz := bios_size_label(f.size)
			draw_t_fit(f.name, x + 28, y + 2, inner - 28 - measure_t(sz, 14) - 12, 16, f.installed ? COL_TEXT : COL_MUTED, false)
			draw_t_right(sz, x + inner, y + 3, 14, COL_MUTED)
			y += LINE
			shown += 1
		}
	}
}

// ---------------------------------------------------------------------------
// Box art: a made-up "system software" case, drawn once into a texture

BIOS_ART_W :: 600
BIOS_ART_H :: 840

bios_art: rl.Texture2D
bios_art_ok: bool

// Main thread, outside BeginDrawing (render textures can't nest inside the frame's own).
bios_art_ensure :: proc() {
	if bios_art_ok do return
	W, H :: f32(BIOS_ART_W), f32(BIOS_ART_H)
	rt := rl.LoadRenderTexture(BIOS_ART_W, BIOS_ART_H)
	if rt.id == 0 do return
	defer rl.UnloadRenderTexture(rt)

	ink := rl.Color{232, 238, 250, 255}
	dim := rl.Color{150, 164, 196, 255}
	gold := rl.Color{226, 184, 92, 255}
	glow := rl.Color{90, 180, 255, 255}

	rl.BeginTextureMode(rt)
	rl.ClearBackground({8, 12, 26, 255})
	rl.DrawRectangleGradientV(0, 0, BIOS_ART_W, BIOS_ART_H, {20, 34, 72, 255}, {6, 8, 18, 255})

	// circuit traces fanning out from the chip
	cx, cy: f32 = W * 0.5, 400
	traces := [?][4]f32{
		{-1, -1, 0.9, 0.3}, {1, -1, 0.7, 0.5}, {-1, 1, 0.6, 0.8}, {1, 1, 0.85, 0.2},
		{-1, 0, 0.95, 0.6}, {1, 0, 0.9, 0.4}, {0, -1, 0.5, 0.7}, {0, 1, 0.6, 0.3},
	}
	for t, i in traces {
		for k in 0 ..< 3 {
			off := (f32(k) - 1) * 26
			sx := cx + t[0] * 150 + (t[0] == 0 ? off : 0)
			sy := cy + t[1] * 150 + (t[1] == 0 ? off : 0)
			// out, then bend at 45° toward the edge
			mx := sx + t[0] * 60 * t[2] + (t[0] == 0 ? off * 0.5 : 0)
			my := sy + t[1] * 60 * t[2] + (t[1] == 0 ? off * 0.5 : 0)
			ex := mx + (t[0] != 0 ? t[0] : (i % 2 == 0 ? -1 : 1)) * 220 * t[3]
			ey := my + (t[1] != 0 ? t[1] : (k % 2 == 0 ? -1 : 1)) * 220 * t[3]
			ey = clamp(ey, 130, 560)
			my = clamp(my, 130, 560)
			col := with_alpha(glow, 60)
			rl.DrawLineEx({sx, sy}, {mx, my}, 3, col)
			rl.DrawLineEx({mx, my}, {ex, ey}, 3, col)
			rl.DrawCircleV({ex, ey}, 6, with_alpha(glow, 90))
			rl.DrawCircleV({ex, ey}, 2.5, with_alpha(ink, 200))
		}
	}

	// glow behind the chip
	for r := f32(260); r > 120; r -= 14 do rl.DrawCircleV({cx, cy}, r, with_alpha(glow, 7))

	// the chip: gold pins on four sides, a dark package and a polished die
	chip := rl.Rectangle{cx - 130, cy - 130, 260, 260}
	for i in 0 ..< 9 {
		px := chip.x + 26 + f32(i) * 26
		py := chip.y + 26 + f32(i) * 26
		rl.DrawRectangleRounded({px - 6, chip.y - 22, 12, 26}, 0.4, 4, gold)
		rl.DrawRectangleRounded({px - 6, chip.y + chip.height - 4, 12, 26}, 0.4, 4, gold)
		rl.DrawRectangleRounded({chip.x - 22, py - 6, 26, 12}, 0.4, 4, gold)
		rl.DrawRectangleRounded({chip.x + chip.width - 4, py - 6, 26, 12}, 0.4, 4, gold)
	}
	rl.DrawRectangleRounded({chip.x, chip.y + 8, chip.width, chip.height}, 0.08, 8, {0, 0, 0, 120})
	rl.DrawRectangleRounded(chip, 0.08, 8, {34, 38, 48, 255})
	rl.DrawRectangleRoundedLinesEx(chip, 0.08, 8, 2, {80, 88, 108, 255})
	rl.DrawCircleV({chip.x + 26, chip.y + 26}, 8, {22, 24, 32, 255}) // pin-1 dot
	die := rl.Rectangle{chip.x + 50, chip.y + 50, chip.width - 100, chip.height - 100}
	rl.DrawRectangleGradientV(i32(die.x), i32(die.y), i32(die.width), i32(die.height), {58, 66, 86, 255}, {30, 34, 46, 255})
	rl.DrawRectangleLinesEx(die, 2, with_alpha(glow, 140))
	draw_t_center("SB-1000", cx, cy - 22, 34, ink)
	draw_t_center("FIRMWARE", cx, cy + 22, 18, dim)

	// top banner, like a console case's system strip
	rl.DrawRectangle(0, 0, BIOS_ART_W, 96, {4, 6, 14, 235})
	rl.DrawRectangle(0, 96, BIOS_ART_W, 5, glow)
	draw_t("SABER", 34, 26, 40, ink)
	draw_t_right("SYSTEM SOFTWARE", W - 34, 38, 22, dim)

	// title block
	draw_t_center("BIOS", cx, 600, 84, ink)
	draw_t_center("INSTALLER", cx, 688, 40, gold)
	rl.DrawRectangle(i32(cx - 120), 744, 240, 3, with_alpha(glow, 160))
	draw_t_center("Bring your own firmware", cx, 764, 22, dim)

	// spine edge highlight
	rl.DrawRectangleGradientH(0, 0, 18, BIOS_ART_H, {255, 255, 255, 30}, {255, 255, 255, 0})
	rl.EndTextureMode()

	img := rl.LoadImageFromTexture(rt.texture)
	rl.ImageFlipVertical(&img) // render textures come out upside down
	bios_art, bios_art_ok = texture_from_image(img)
	rl.UnloadImage(img)
}

bios_art_unload :: proc() {
	if bios_art_ok do rl.UnloadTexture(bios_art)
	bios_art_ok = false
}
