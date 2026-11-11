package saber

// File explorer: a controller-friendly browser for an inserted drive, opened from a drive
// card's actions menu ("Browse Files"). A opens folders / previews files, B goes up a level
// (closes at the drive root), Y adds a picture to Saber's backgrounds (bkg) or a sound to its
// music (bgm). Pictures open in a full-screen viewer (Left / Right flip through the folder),
// sounds play in place of the menu music until stopped.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

EFileType :: enum {
	Directory,
	File_Sound,
	File_Video,
	File_Image,
	File_Rom,
	File_Other,
}

Explorer_Entry :: struct {
	name: string, // heap
	type: EFileType,
	size: i64,
	thumb: Thumb_State,
	tex:   rl.Texture2D, // .Ready
}

Thumb_State :: enum u8 {
	None,
	Queued,
	Ready,
	Failed,
}

File_Explorer :: struct {
	open:      bool,
	t:         f32,
	letter:    u8, // the drive being browsed; closes when it goes away
	root:      string, // heap, "F:\"
	dir:       string, // heap, current folder
	label_buf: [128]u8,
	label:     string,
	entries:   [dynamic]Explorer_Entry,
	sel:       int,
	scroll:    int,
	err:       string, // listing failed (static text)
	follow:    bool, // keep the selection in view (pad / keys moved it)
	// sound preview
	music:     rl.Music,
	has_music: bool,
	music_idx: int,
	// picture viewer
	viewing:   bool,
	view_t:    f32,
	view_idx:  int,
	view_tex:  rl.Texture2D,
	has_tex:   bool,
}

explorer: File_Explorer

EXPLORER_SKIP :: []string{"$RECYCLE.BIN", "System Volume Information"}

explorer_type :: proc(name: string) -> EFileType {
	ext := strings.to_lower(filepath.ext(name), context.temp_allocator)
	has :: proc(list: []string, e: string) -> bool {
		for x in list do if x == e do return true
		return false
	}
	switch {
	case has(MUS_EXTS, ext):   return .File_Sound
	case has(IMG_EXTS, ext):   return .File_Image
	case has(VIDEO_EXTS, ext): return .File_Video
	case ext == ".cue" || ext == ".iso" || ext == ".chd" || ext == ".m3u":
		return .File_Rom
	}
	if _, ok := rom_platform(ext); ok do return .File_Rom
	return .File_Other
}

// ---------------------------------------------------------------------------
// Open / close / navigation

explorer_open :: proc(g: ^Game) {
	if g.drive_letter < 'A' || g.drive_letter > 'Z' do return
	explorer_free()
	explorer.letter = g.drive_letter
	explorer.root = fmt.aprintf("%c:\\", g.drive_letter)
	explorer.label = fmt.bprint(explorer.label_buf[:], g.drive_label != "" ? g.drive_label : fmt.tprintf("Drive %c", g.drive_letter))
	explorer_cd(explorer.root, "")
	explorer.open = true
	sfx_click()
}

explorer_close :: proc() {
	explorer_stop_sound()
	explorer_view_close()
	explorer.open = false
	sfx_back()
}

explorer_free :: proc() {
	explorer_stop_sound()
	explorer_unload_tex()
	explorer.viewing = false
	thumbs_reset()
	for e in explorer.entries do delete(e.name)
	clear(&explorer.entries)
	delete(explorer.root)
	delete(explorer.dir)
	explorer.root, explorer.dir = "", ""
}

explorer_shutdown :: proc() {
	explorer_free()
	thumbs_shutdown()
	delete(explorer.entries)
}

// Lists `dir`; focuses the entry named `focus` (coming back up from it).
explorer_cd :: proc(dir: string, focus: string) {
	new_dir := strings.clone(dir)
	delete(explorer.dir)
	explorer.dir = new_dir
	thumbs_reset()
	for e in explorer.entries do delete(e.name)
	clear(&explorer.entries)
	explorer.sel, explorer.scroll = 0, 0
	explorer.follow = true
	explorer.err = ""

	fis, err := os.read_all_directory_by_path(explorer.dir, context.allocator)
	if err != nil {
		explorer.err = "Couldn't read this folder"
		return
	}
	defer os.file_info_slice_delete(fis, context.allocator)
	outer: for fi in fis {
		for s in EXPLORER_SKIP do if strings.equal_fold(fi.name, s) do continue outer
		type := fi.type == .Directory ? EFileType.Directory : explorer_type(fi.name)
		append(&explorer.entries, Explorer_Entry{name = strings.clone(fi.name), type = type, size = fi.size})
	}
	slice.sort_by(explorer.entries[:], proc(a, b: Explorer_Entry) -> bool {
		da, db := a.type == .Directory, b.type == .Directory
		if da != db do return da
		return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
	})
	// first row of every subfolder: back up one level
	if !explorer_at_root() do inject_at(&explorer.entries, 0, Explorer_Entry{name = strings.clone(".."), type = .Directory})
	for e, i in explorer.entries do if e.name == focus do explorer.sel = i
}

explorer_at_root :: proc() -> bool {
	return len(explorer.dir) <= len(explorer.root)
}

explorer_up :: proc() {
	if explorer_at_root() {
		explorer_close()
		return
	}
	trimmed := strings.trim_right(explorer.dir, "\\/")
	child := strings.clone(filepath.base(trimmed), context.temp_allocator)
	up := filepath.dir(trimmed)
	defer delete(up)
	parent := up
	if len(parent) < len(explorer.root) do parent = explorer.root
	explorer_cd(parent, child)
	sfx_back()
}

explorer_path :: proc(i: int) -> string {
	return path_join({explorer.dir, explorer.entries[i].name})
}

explorer_drive_present :: proc() -> bool {
	for g in app.drive_games do if g.drive_letter == explorer.letter do return true
	return false
}

// ---------------------------------------------------------------------------
// Actions

explorer_activate :: proc(i: int) {
	if i < 0 || i >= len(explorer.entries) do return
	e := explorer.entries[i]
	switch e.type {
	case .Directory:
		if e.name == ".." {
			explorer_up()
			return
		}
		explorer_cd(explorer_path(i), "")
		sfx_click()
	case .File_Sound:
		if explorer.has_music && explorer.music_idx == i {
			explorer_stop_sound()
			sfx_back()
		} else {
			explorer_play_sound(i)
		}
	case .File_Image:
		explorer_view(i)
	case .File_Video, .File_Rom, .File_Other:
		set_status("%s  ·  nothing to preview", e.name)
		sfx_back()
	}
}

explorer_play_sound :: proc(i: int) {
	explorer_stop_sound()
	path := explorer_path(i)
	crash_note("explorer: loading sound %s", path)
	explorer.music = rl.LoadMusicStream(strings.clone_to_cstring(path, context.temp_allocator))
	if !rl.IsMusicValid(explorer.music) {
		set_status("Couldn't play %s", explorer.entries[i].name)
		sfx_back()
		return
	}
	explorer.has_music = true
	explorer.music_idx = i
	explorer.music.looping = true
	rl.SetMusicVolume(explorer.music, app.settings.volume)
	theme_pause_for_game()
	rl.PlayMusicStream(explorer.music)
}

explorer_stop_sound :: proc() {
	if !explorer.has_music do return
	crash_note("explorer: stopping sound preview")
	rl.StopMusicStream(explorer.music)
	crash_note("explorer: unloading sound preview")
	rl.UnloadMusicStream(explorer.music)
	explorer.has_music = false
	crash_note("explorer: resuming menu music")
	theme_resume_after_game()
	crash_note("explorer: sound preview stopped")
}

// Copies a picture into Saber's backgrounds or a sound into its music.
explorer_add :: proc(i: int) {
	if i < 0 || i >= len(explorer.entries) do return
	e := explorer.entries[i]
	dir, what: string
	#partial switch e.type {
	case .File_Image: dir, what = theme.bkg_dir, "background"
	case .File_Sound: dir, what = theme.bgm_dir, "music"
	case:
		sfx_back()
		return
	}
	dst := path_join({dir, e.name})
	if os.exists(dst) {
		set_status("%s is already in Saber's %s", e.name, what)
		sfx_back()
		return
	}
	os.make_directory_all(dir)
	if os.copy_file(dst, explorer_path(i)) != nil {
		os.remove(dst)
		set_status("Couldn't copy %s  ·  is APP writable?", e.name)
		sfx_back()
		return
	}
	refresh_media_lists()
	set_status("Added %s to Saber's %s  ·  choose it in Settings", e.name, what)
	sfx_click()
}

explorer_can_add :: proc(i: int) -> bool {
	return i >= 0 && i < len(explorer.entries) && (explorer.entries[i].type == .File_Image || explorer.entries[i].type == .File_Sound)
}

// ---------------------------------------------------------------------------
// Picture viewer

explorer_unload_tex :: proc() {
	if explorer.has_tex {
		rl.UnloadTexture(explorer.view_tex)
		explorer.has_tex = false
	}
}

explorer_view :: proc(i: int) {
	explorer_unload_tex()
	explorer.view_tex, explorer.has_tex = load_texture_smooth(explorer_path(i), 2560)
	explorer.view_idx = i
	explorer.sel = i
	if !explorer.viewing do explorer.view_t = 0
	explorer.viewing = true
	if !explorer.has_tex do set_status("Couldn't open %s", explorer.entries[i].name)
	sfx_click()
}

explorer_view_close :: proc() {
	explorer.viewing = false
	explorer_unload_tex()
}

// Next / previous picture in the folder.
explorer_view_step :: proc(delta: int) {
	n := len(explorer.entries)
	for k in 1 ..< n {
		j := ((explorer.view_idx + delta * k) % n + n) % n
		if explorer.entries[j].type == .File_Image {
			explorer_view(j)
			return
		}
	}
}

// ---------------------------------------------------------------------------
// Input

explorer_rows_visible: int = 8 // set by the draw pass

explorer_input :: proc() {
	if !explorer_drive_present() {
		explorer_free()
		explorer.open = false // the drive was pulled
		return
	}
	if explorer.viewing {
		switch {
		case input.left:   explorer_view_step(-1)
		case input.right:  explorer_view_step(1)
		case input.extra:  explorer_add(explorer.view_idx)
		case input.cancel, input.confirm:
			explorer_view_close()
			sfx_back()
		case input.action, input.power:
			explorer_close()
		}
		return
	}
	n := len(explorer.entries)
	if n > 0 {
		page := max(explorer_rows_visible - 1, 1)
		step := 0
		if input.up do step = -1
		if input.down do step = 1
		if input.left do step = -page
		if input.right do step = page
		if step != 0 {
			if abs(step) == 1 {
				explorer.sel = (explorer.sel + step + n) % n
			} else {
				explorer.sel = clamp(explorer.sel + step, 0, n - 1)
			}
			explorer.follow = true
			sfx_click()
		}
		if wheel := rl.GetMouseWheelMove(); wheel != 0 {
			explorer.scroll = clamp(explorer.scroll - int(wheel) * 3, 0, max(n - explorer_rows_visible, 0))
		}
	}
	switch {
	case input.cancel:
		explorer_up()
	case input.action, input.power:
		explorer_close()
	case input.confirm:
		explorer_activate(explorer.sel)
	case input.extra:
		if explorer_can_add(explorer.sel) do explorer_add(explorer.sel)
	}
}

explorer_hints :: proc(w, h: f32) {
	if explorer.viewing {
		draw_hints(w, h, []Hint{{"LEFT / RIGHT", "Pictures"}, {"Y", "Add to Backgrounds"}, {"B", "Back"}})
		return
	}
	a := "Open"
	if explorer.sel >= 0 && explorer.sel < len(explorer.entries) {
		#partial switch explorer.entries[explorer.sel].type {
		case .File_Image: a = "View"
		case .File_Sound: a = explorer.has_music && explorer.music_idx == explorer.sel ? "Stop" : "Play"
		}
	}
	hints := make([dynamic]Hint, context.temp_allocator)
	append(&hints, Hint{"A", a})
	if explorer_can_add(explorer.sel) {
		append(&hints, Hint{"Y", explorer.entries[explorer.sel].type == .File_Image ? "Add to Backgrounds" : "Add to Music"})
	}
	append(&hints, Hint{"B", explorer_at_root() ? "Close" : "Up"})
	append(&hints, Hint{"X", "Close"})
	draw_hints(w, h, hints[:])
}

// ---------------------------------------------------------------------------
// Drawing

draw_file_explorer :: proc(w, h: f32) {
	if explorer.has_music do rl.UpdateMusicStream(explorer.music)
	explorer.t = smooth_to(explorer.t, explorer.open ? 1 : 0, 16)
	if explorer.t < 0.02 && !explorer.open do return
	t := explorer.t
	interactive := explorer.open && !explorer.viewing

	thumbs_collect()
	ROW_H :: 56
	GAP :: 6
	HEAD :: 112
	// dim only the page: the header and the footer (hints, status) stay readable
	rl.DrawRectangle(0, HEADER_H, i32(w), i32(h - HEADER_H - FOOTER_H), with_alpha(COL_SHADE, u8(150 * t)))
	pw := min(f32(1000), w - 48)
	ph := min(h - HEADER_H - FOOTER_H - 32, f32(760))
	s := 0.94 + 0.06 * t
	r := rl.Rectangle{(w - pw * s) * 0.5, HEADER_H + (h - HEADER_H - FOOTER_H - ph * s) * 0.5, pw * s, ph * s}
	draw_panel(r, false, with_alpha(COL_PANEL_SOLID, u8(244 * t)))
	if t < 0.5 do return

	// header: drive icon, label, current path
	draw_usb_stick({r.x + 56, r.y + 54}, 26, 0)
	draw_t_fit(fmt.tprintf("Browse  ·  %s", explorer.label), r.x + 102, r.y + 26, r.width - 330, 28, COL_TEXT, true)
	draw_t_fit(explorer.dir, r.x + 102, r.y + 64, r.width - 330, 15, COL_MUTED, true)
	if explorer.has_music && explorer.music_idx < len(explorer.entries) {
		draw_t_right(fmt.tprintf("Playing  %s", explorer.entries[explorer.music_idx].name), r.x + r.width - 30, r.y + 42, 15, COL_ACCENT)
	}
	rl.DrawRectangle(i32(r.x + 24), i32(r.y + HEAD - 14), i32(r.width - 48), 1, COL_FAINT)

	if interactive && rl.IsMouseButtonPressed(.RIGHT) do explorer_up()
	list := rl.Rectangle{r.x + 24, r.y + HEAD, r.width - 48, r.height - HEAD - 22}
	n := len(explorer.entries)
	if explorer.err != "" || n == 0 {
		draw_t_center(explorer.err != "" ? explorer.err : "This folder is empty", r.x + r.width * 0.5, list.y + 60, 18, COL_MUTED)
		return
	}
	visible := max(1, int((list.height + GAP) / (ROW_H + GAP)))
	explorer_rows_visible = visible
	explorer.sel = clamp(explorer.sel, 0, n - 1)
	if explorer.follow {
		explorer.follow = false
		if explorer.sel < explorer.scroll do explorer.scroll = explorer.sel
		if explorer.sel >= explorer.scroll + visible do explorer.scroll = explorer.sel - visible + 1
	}
	explorer.scroll = clamp(explorer.scroll, 0, max(n - visible, 0))

	clicked := -1
	for i in explorer.scroll ..< min(n, explorer.scroll + visible) {
		e := explorer.entries[i]
		br := rl.Rectangle{list.x, list.y + f32(i - explorer.scroll) * (ROW_H + GAP), list.width - (n > visible ? 14 : 0), ROW_H}
		if interactive && mouse_over(br, true) {
			hover_enter(fmt.tprintf("explorer-%d", i))
			explorer.sel = i
			if rl.IsMouseButtonPressed(.LEFT) do clicked = i
		}
		focused := i == explorer.sel
		if focused {
			rl.DrawRectangleRounded(br, 0.3, 8, COL_ACCENT_SOFT)
			rl.DrawRectangleRoundedLinesEx(br, 0.3, 8, 2, COL_ACCENT)
		}
		playing := explorer.has_music && explorer.music_idx == i
		if e.thumb == .None && (e.type == .File_Image || e.type == .File_Video) do thumbs_request(i)
		if e.thumb == .Ready {
			draw_thumb(e.tex, {br.x + 6, br.y + 6, 50, ROW_H - 12})
		} else if e.name != ".." {
			draw_file_icon(e.type, {br.x + 31, br.y + ROW_H * 0.5}, playing)
		}
		size_w: f32 = 0
		if e.type != .Directory {
			sz := fmt_bytes(e.size)
			size_w = measure_t(sz, 15) + 20
			draw_t_right(sz, br.x + br.width - 18, br.y + 19, 15, COL_MUTED)
		}
		if e.name == ".." {
			draw_up_icon({br.x + 31, br.y + ROW_H * 0.5}, focused)
			draw_t("Up one folder", br.x + 68, br.y + 17, 19, COL_TEXT)
			continue
		}
		draw_t_fit(e.name, br.x + 68, br.y + 17, br.width - 68 - size_w - 18, 19, playing ? COL_ACCENT : COL_TEXT, focused)
	}
	if n > visible {
		track := rl.Rectangle{list.x + list.width - 5, list.y, 5, f32(visible) * (ROW_H + GAP) - GAP}
		rl.DrawRectangleRounded(track, 1, 4, COL_FAINT)
		th := track.height * f32(visible) / f32(n)
		ty := track.y + (track.height - th) * f32(explorer.scroll) / f32(n - visible)
		rl.DrawRectangleRounded({track.x, ty, track.width, th}, 1, 4, with_alpha(COL_ACCENT, 200))
	}
	if clicked >= 0 do explorer_activate(clicked)

	draw_explorer_viewer(w, h)
}

draw_explorer_viewer :: proc(w, h: f32) {
	explorer.view_t = smooth_to(explorer.view_t, explorer.viewing ? 1 : 0, 14)
	if !explorer.viewing do return
	t := explorer.view_t
	rl.DrawRectangle(0, 0, i32(w), i32(h - FOOTER_H), {0, 0, 0, u8(235 * t)})
	area := rl.Rectangle{PAD, 70, w - PAD * 2, h - 70 - FOOTER_H - 16}
	if explorer.has_tex {
		tw, th := f32(explorer.view_tex.width), f32(explorer.view_tex.height)
		sc := min(area.width / tw, area.height / th)
		dw, dh := tw * sc, th * sc
		rl.DrawTexturePro(explorer.view_tex, {0, 0, tw, th}, {area.x + (area.width - dw) * 0.5, area.y + (area.height - dh) * 0.5, dw, dh}, {}, 0, with_alpha(rl.WHITE, u8(255 * t)))
		draw_t_right(fmt.tprintf("%d × %d", explorer.view_tex.width, explorer.view_tex.height), w - PAD, 26, 16, COL_MUTED)
	} else {
		draw_t_center("Couldn't open this picture", w * 0.5, h * 0.5 - 10, 20, COL_MUTED)
	}
	if explorer.view_idx < len(explorer.entries) {
		draw_t_fit(explorer.entries[explorer.view_idx].name, PAD, 24, w * 0.6, 22, rl.WHITE, true)
	}
	if rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT) {
		explorer_view_close()
		sfx_back()
	}
}

draw_file_icon :: proc(type: EFileType, c: rl.Vector2, active: bool) {
	col := active ? COL_ACCENT : COL_MUTED
	switch type {
	case .Directory:
		fc := rl.Color{232, 192, 76, 255}
		rl.DrawRectangleRounded({c.x - 14, c.y - 11, 12, 6}, 0.5, 4, fc)
		rl.DrawRectangleRounded({c.x - 14, c.y - 8, 28, 19}, 0.2, 4, fc)
	case .File_Sound:
		rl.DrawCircleV({c.x - 5, c.y + 7}, 5, col)
		rl.DrawRectangleV({c.x - 1, c.y - 11}, {3, 18}, col)
		rl.DrawTriangle({c.x + 2, c.y - 11}, {c.x + 2, c.y - 4}, {c.x + 10, c.y - 7}, col)
	case .File_Image:
		rl.DrawRectangleRoundedLinesEx({c.x - 14, c.y - 11, 28, 22}, 0.2, 4, 2, col)
		rl.DrawTriangle({c.x - 10, c.y + 8}, {c.x + 2, c.y + 8}, {c.x - 4, c.y - 2}, col)
		rl.DrawTriangle({c.x - 1, c.y + 8}, {c.x + 10, c.y + 8}, {c.x + 5, c.y + 1}, col)
		rl.DrawCircleV({c.x + 6, c.y - 5}, 2.5, col)
	case .File_Video:
		rl.DrawRectangleRoundedLinesEx({c.x - 14, c.y - 11, 28, 22}, 0.2, 4, 2, col)
		rl.DrawTriangle({c.x - 4, c.y - 6}, {c.x - 4, c.y + 6}, {c.x + 6, c.y}, col)
	case .File_Rom:
		draw_spinning_disc(c, 13, 0)
	case .File_Other:
		rl.DrawRectangleRoundedLinesEx({c.x - 10, c.y - 13, 20, 26}, 0.15, 4, 2, col)
		for k in 0 ..< 3 do rl.DrawRectangleV({c.x - 5, c.y - 6 + f32(k) * 5}, {10, 2}, col)
	}
}

// ---------------------------------------------------------------------------
// Thumbnails: decoded on a worker thread through the Windows thumbnail cache (fast, and
// it reads JPG/WebP and video frames), uploaded to textures on the main thread.
// Only rows that get drawn are requested; changing folder bumps `gen`, so stale work is dropped.

THUMB_PX :: 112
THUMB_UPLOADS_PER_FRAME :: 6

Thumb_Job :: struct {
	gen:   int,
	idx:   int,
	path:  string, // heap
	video: bool,
}

Thumb_Done :: struct {
	gen: int,
	idx: int,
	img: rl.Image,
	ok:  bool,
}

Thumbs :: struct {
	lock:   sync.Mutex,
	sema:   sync.Sema,
	jobs:   [dynamic]Thumb_Job,
	done:   [dynamic]Thumb_Done,
	gen:    int, // under lock
	stop:   bool,
	worker: ^thread.Thread,
}

thumbs: Thumbs

thumbs_request :: proc(i: int) {
	if thumbs.worker == nil {
		thumbs.worker = thread.create_and_start_with_data(&thumbs, thumbs_worker)
	}
	explorer.entries[i].thumb = .Queued
	sync.mutex_lock(&thumbs.lock)
	append(&thumbs.jobs, Thumb_Job{gen = thumbs.gen, idx = i, path = path_join({explorer.dir, explorer.entries[i].name}), video = explorer.entries[i].type == .File_Video})
	sync.mutex_unlock(&thumbs.lock)
	sync.sema_post(&thumbs.sema)
}

// Main thread: uploads finished thumbnails.
thumbs_collect :: proc() {
	sync.mutex_lock(&thumbs.lock)
	defer sync.mutex_unlock(&thumbs.lock)
	n := 0
	for len(thumbs.done) > 0 && n < THUMB_UPLOADS_PER_FRAME {
		d := pop_front(&thumbs.done)
		if d.gen != thumbs.gen || d.idx >= len(explorer.entries) {
			if d.ok do rl.UnloadImage(d.img)
			continue
		}
		e := &explorer.entries[d.idx]
		e.thumb = .Failed
		if d.ok {
			if tex, ok := texture_from_image(d.img); ok {
				e.tex = tex
				e.thumb = .Ready
			}
			rl.UnloadImage(d.img)
			n += 1
		}
	}
}

// Drops queued work and the current folder's textures (before the entry list changes).
thumbs_reset :: proc() {
	sync.mutex_lock(&thumbs.lock)
	thumbs.gen += 1
	for j in thumbs.jobs do delete(j.path)
	clear(&thumbs.jobs)
	for d in thumbs.done do if d.ok do rl.UnloadImage(d.img)
	clear(&thumbs.done)
	sync.mutex_unlock(&thumbs.lock)
	for &e in explorer.entries {
		if e.thumb == .Ready do rl.UnloadTexture(e.tex)
		e.thumb = .None
	}
}

thumbs_shutdown :: proc() {
	if thumbs.worker == nil do return
	sync.mutex_lock(&thumbs.lock)
	thumbs.stop = true
	sync.mutex_unlock(&thumbs.lock)
	sync.sema_post(&thumbs.sema)
	thread.join(thumbs.worker)
	thread.destroy(thumbs.worker)
	thumbs.worker = nil
	thumbs_reset()
	delete(thumbs.jobs)
	delete(thumbs.done)
}

thumbs_worker :: proc(data: rawptr) {
	t := (^Thumbs)(data)
	thumbs_com_init()
	for {
		sync.sema_wait(&t.sema)
		sync.mutex_lock(&t.lock)
		if t.stop {
			sync.mutex_unlock(&t.lock)
			return
		}
		if len(t.jobs) == 0 {
			sync.mutex_unlock(&t.lock)
			continue
		}
		job := pop_front(&t.jobs)
		sync.mutex_unlock(&t.lock)

		img, ok := thumb_decode(job.path, job.video)
		delete(job.path)
		free_all(context.temp_allocator)

		sync.mutex_lock(&t.lock)
		if job.gen == t.gen {
			append(&t.done, Thumb_Done{gen = job.gen, idx = job.idx, img = img, ok = ok})
		} else if ok {
			rl.UnloadImage(img)
		}
		sync.mutex_unlock(&t.lock)
	}
}

thumb_decode :: proc(path: string, video: bool) -> (rl.Image, bool) {
	// the shell's thumbnail cache first: fast, small, and it handles every format Explorer does
	img, ok := shell_image(path, THUMB_PX, THUMB_PX, still = !video)
	if !ok && !video {
		img, ok = load_image_smooth(path, THUMB_PX)
	}
	if !ok do return {}, false
	if img.width > THUMB_PX || img.height > THUMB_PX {
		sc := f32(THUMB_PX) / f32(max(img.width, img.height))
		rl.ImageResize(&img, max(i32(f32(img.width) * sc), 1), max(i32(f32(img.height) * sc), 1))
	}
	return img, true
}

// Thumbnail cropped to fill `r`, with rounded-looking corners from a thin frame.
draw_thumb :: proc(tex: rl.Texture2D, r: rl.Rectangle) {
	tw, th := f32(tex.width), f32(tex.height)
	src := rl.Rectangle{0, 0, tw, th}
	if tw / th > r.width / r.height {
		src.width = th * r.width / r.height
		src.x = (tw - src.width) * 0.5
	} else {
		src.height = tw * r.height / r.width
		src.y = (th - src.height) * 0.5
	}
	rl.DrawTexturePro(tex, src, r, {}, 0, rl.WHITE)
	rl.DrawRectangleLinesEx(r, 1, COL_FAINT)
}

draw_up_icon :: proc(c: rl.Vector2, active: bool) {
	col := active ? COL_ACCENT : COL_MUTED
	rl.DrawTriangle({c.x, c.y - 12}, {c.x - 10, c.y - 2}, {c.x + 10, c.y - 2}, col)
	rl.DrawRectangleV({c.x - 2.5, c.y - 3}, {5, 10}, col)
	rl.DrawRectangleV({c.x - 2.5, c.y + 5}, {14, 5}, col)
}
