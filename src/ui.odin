package saber

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

HEADER_H :: 84
FOOTER_H :: 56
PAD :: 40
RADIUS :: 12
TITLE_STRIP :: 40

// ---------------------------------------------------------------------------
// Primitives

roundness :: proc(r: rl.Rectangle, px: f32) -> f32 {
	m := min(r.width, r.height)
	return m <= 0 ? 0 : min(1, px * 2 / m)
}

draw_panel :: proc(r: rl.Rectangle, hi: bool, fill := rl.Color{}) {
	fill := fill.a == 0 ? COL_PANEL : fill
	rr := roundness(r, RADIUS)
	rl.DrawRectangleRounded({r.x, r.y + 4, r.width, r.height}, rr, 8, COL_SHADOW)
	rl.DrawRectangleRounded(r, rr, 8, hi ? COL_PANEL_HI : fill)
	rl.DrawRectangleRoundedLinesEx(r, rr, 8, 1, hi ? COL_ACCENT_SOFT : COL_FAINT)
}

draw_focus_ring :: proc(r: rl.Rectangle) {
	a := u8(170 + 60 * math.sin(f32(rl.GetTime()) * 3.2))
	g := rl.Rectangle{r.x - 3, r.y - 3, r.width + 6, r.height + 6}
	rl.DrawRectangleRoundedLinesEx(g, roundness(g, RADIUS + 3), 8, 2.5, rl.Color{COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, a})
}

// Scissor stack that follows the swipe offset and survives nesting (marquees inside cards).
clip_stack: [8]rl.Rectangle
clip_n: int
draw_dx: f32

push_clip :: proc(r: rl.Rectangle) {
	c := rl.Rectangle{r.x + draw_dx, r.y, r.width, r.height}
	if clip_n > 0 {
		p := clip_stack[clip_n - 1]
		x0 := max(c.x, p.x)
		y0 := max(c.y, p.y)
		x1 := min(c.x + c.width, p.x + p.width)
		y1 := min(c.y + c.height, p.y + p.height)
		c = {x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
	}
	clip_stack[clip_n] = c
	clip_n += 1
	rl.BeginScissorMode(i32(c.x), i32(c.y), i32(c.width), i32(c.height))
}

pop_clip :: proc() {
	clip_n -= 1
	if clip_n > 0 {
		c := clip_stack[clip_n - 1]
		rl.BeginScissorMode(i32(c.x), i32(c.y), i32(c.width), i32(c.height))
	} else {
		rl.EndScissorMode()
	}
}

mouse_over :: proc(r: rl.Rectangle, modal := false) -> bool {
	if input.using_pad || (!modal && input_locked()) {
		return false
	}
	return rl.CheckCollisionPointRec(rl.GetMousePosition(), r)
}

ui_button :: proc(id: string, r: rl.Rectangle, label: string, focused := false, modal := false) -> bool {
	hovered := mouse_over(r, modal)
	if hovered {
		hover_enter(id)
	}
	hot := hovered || focused
	rr := roundness(r, RADIUS)
	if hot {
		rl.DrawRectangleRounded(r, rr, 8, rl.Color{COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 46})
		rl.DrawRectangleRoundedLinesEx(r, rr, 8, 2, COL_ACCENT)
	} else {
		rl.DrawRectangleRounded(r, rr, 8, with_alpha(COL_TINT, 12))
		rl.DrawRectangleRoundedLinesEx(r, rr, 8, 1, COL_FAINT)
	}
	draw_t_center(label, r.x + r.width * 0.5, r.y + (r.height - 20) * 0.5, 20, hot ? COL_TEXT : COL_MUTED)
	if hovered && rl.IsMouseButtonPressed(.LEFT) {
		sfx_click()
		return true
	}
	return false
}

draw_texture_cover :: proc(tex: rl.Texture2D, dest: rl.Rectangle, tint := rl.WHITE) {
	tw := f32(tex.width)
	th := f32(tex.height)
	if tw <= 0 || th <= 0 || dest.width <= 0 || dest.height <= 0 {
		return
	}
	// crop the source instead of scissoring the destination
	s := max(dest.width / tw, dest.height / th)
	sw := dest.width / s
	sh := dest.height / s
	rl.DrawTexturePro(tex, {(tw - sw) * 0.5, (th - sh) * 0.5, sw, sh}, dest, {}, 0, tint)
}

// Whole image inside `dest`, centred, aspect kept: no cropping, no stretching.
// Covers from different consoles (PS1 jewel case vs PS2 DVD case vs 3D renders)
// all keep their real shape; the leftover space shows the card behind them.
draw_texture_contain :: proc(tex: rl.Texture2D, dest: rl.Rectangle, tint := rl.WHITE) -> rl.Rectangle {
	tw := f32(tex.width)
	th := f32(tex.height)
	if tw <= 0 || th <= 0 || dest.width <= 0 || dest.height <= 0 {
		return {}
	}
	s := min(dest.width / tw, dest.height / th)
	w, h := tw * s, th * s
	r := rl.Rectangle{dest.x + (dest.width - w) * 0.5, dest.y + (dest.height - h) * 0.5, w, h}
	rl.DrawTexturePro(tex, {0, 0, tw, th}, r, {}, 0, tint)
	return r
}

draw_texture_fit :: proc(tex: rl.Texture2D, x, y, max_w, max_h: f32) -> f32 {
	tw := f32(tex.width)
	th := f32(tex.height)
	if tw <= 0 || th <= 0 {
		return 0
	}
	s := min(max_w / tw, max_h / th)
	rl.DrawTexturePro(tex, {0, 0, tw, th}, {x, y, tw * s, th * s}, {}, 0, rl.WHITE)
	return th * s
}

draw_triangle_dir :: proc(cx, cy, size: f32, dir: Nav_Dir, col: rl.Color) {
	s := size * 0.5
	switch dir {
	case .Left:
		rl.DrawTriangle({cx + s * 0.6, cy - s}, {cx - s * 0.6, cy}, {cx + s * 0.6, cy + s}, col)
	case .Right:
		rl.DrawTriangle({cx - s * 0.6, cy - s}, {cx - s * 0.6, cy + s}, {cx + s * 0.6, cy}, col)
	case .Down:
		rl.DrawTriangle({cx - s, cy - s * 0.5}, {cx, cy + s * 0.5}, {cx + s, cy - s * 0.5}, col)
	case .Up, .None:
		rl.DrawTriangle({cx - s, cy + s * 0.5}, {cx + s, cy + s * 0.5}, {cx, cy - s * 0.5}, col)
	}
}

// ---------------------------------------------------------------------------
// Controller glyphs + hint bar

Hint :: struct {
	button: string,
	label:  string,
}

glyph_color :: proc(b: string) -> rl.Color {
	switch b {
	case "A": return {104, 200, 120, 255}
	case "B": return {232, 100, 100, 255}
	case "X": return {96, 150, 240, 255}
	case "Y": return {232, 192, 76, 255}
	}
	return {255, 255, 255, 40}
}

// Draws a pad glyph; returns its width.
draw_glyph :: proc(b: string, x, cy: f32) -> f32 {
	if len(b) == 1 {
		r: f32 = 12
		rl.DrawCircleV({x + r, cy}, r, glyph_color(b))
		draw_t_center(b, x + r, cy - 8, 16, rl.Color{16, 18, 24, 255})
		return r * 2
	}
	tw := measure_t(b, 12)
	pill := rl.Rectangle{x, cy - 11, tw + 16, 22}
	rl.DrawRectangleRounded(pill, 1, 8, with_alpha(COL_TINT, 34))
	draw_t(b, x + 8, cy - 6, 12, COL_TEXT)
	return pill.width
}

hint_width :: proc(h: Hint) -> f32 {
	gw := len(h.button) == 1 ? f32(24) : measure_t(h.button, 12) + 16
	return gw + 8 + measure_t(h.label, 16)
}

draw_hints :: proc(w, h: f32, hints: []Hint) {
	cy := h - FOOTER_H * 0.5
	x := w - PAD
	for i := len(hints) - 1; i >= 0; i -= 1 {
		hint := hints[i]
		x -= hint_width(hint)
		gw := draw_glyph(hint.button, x, cy)
		draw_t(hint.label, x + gw + 8, cy - 9, 16, COL_MUTED)
		x -= 28
	}
}

// ---------------------------------------------------------------------------
// Header / footer

TAB_LABELS := [Screen]string {
	.Main     = "HOME",
	.Library  = "GAMES",
	.Movies   = "MOVIES",
	.Apps     = "APPS",
	.Plugins  = "PLUGINS",
	.Settings = "SETTINGS",
}

draw_header :: proc(w: f32) {
	rl.DrawRectangleGradientV(0, 0, i32(w), HEADER_H, with_alpha(COL_SHADE, 235), with_alpha(COL_SHADE, 190))
	rl.DrawRectangle(0, HEADER_H - 1, i32(w), 1, COL_FAINT)

	rl.DrawRectangleRounded({PAD, 28, 4, 28}, 1, 4, COL_ACCENT)
	draw_t("SABER", PAD + 16, 24, 32, COL_TEXT)

	size: f32 = 17
	gap: f32 = 36
	total: f32 = 0
	for label in TAB_LABELS {
		total += measure_t(label, size)
	}
	total += gap * f32(SCREEN_COUNT - 1)
	x := (w - total) * 0.5
	ty: f32 = 33
	draw_glyph("LB", x - 64, ty + 9)
	for label, s in TAB_LABELS {
		tw := measure_t(label, size)
		r := rl.Rectangle{x - 10, 16, tw + 20, HEADER_H - 24}
		active := s == app.screen
		hovered := mouse_over(r)
		if active {
			app.tab_x = app.tab_w == 0 ? x : smooth_to(app.tab_x, x, 16)
			app.tab_w = app.tab_w == 0 ? tw : smooth_to(app.tab_w, tw, 16)
		}
		draw_t(label, x, ty, size, active || hovered ? COL_TEXT : COL_MUTED)
		if hovered {
			hover_enter(label)
			if rl.IsMouseButtonPressed(.LEFT) {
				go_screen(s)
			}
		}
		x += tw + gap
	}
	draw_glyph("RB", x - gap + 28, ty + 9)
	rl.DrawRectangleRounded({app.tab_x, HEADER_H - 4, app.tab_w, 3}, 1, 4, COL_ACCENT)

	draw_t_right(clock_label(), w - PAD, 26, 26, COL_TEXT)
}

clock_label :: proc() -> string {
	h, m, _ := time.clock_from_time(time.now())
	return fmt.tprintf("%02d:%02d", h, m)
}

draw_footer :: proc(w, h: f32) {
	y := h - FOOTER_H
	rl.DrawRectangleGradientV(0, i32(y), i32(w), FOOTER_H, with_alpha(COL_SHADE, 170), with_alpha(COL_SHADE, 235))
	rl.DrawRectangle(0, i32(y), i32(w), 1, COL_FAINT)

	age := rl.GetTime() - app.status_at
	if app.status != "" && age < STATUS_SECONDS {
		a := u8(255 * clamp(f32(STATUS_SECONDS - age), 0, 1))
		draw_t(app.status, PAD, y + 19, 17, rl.Color{COL_TEXT.r, COL_TEXT.g, COL_TEXT.b, a})
	} else {
		draw_t(app.scan_message, PAD, y + 19, 16, COL_MUTED)
	}

	switch {
	case plugin_dialog_open():
		// the dialog draws its own hints
	case app.power_open:
		draw_hints(w, h, []Hint{{"A", "Select"}, {"B", "Back"}})
	case app.dropdown_open:
		draw_hints(w, h, []Hint{{"A", "Choose"}, {"B", "Close"}})
	case app.screen == .Plugins:
		if app.plugin_focus == 1 {
			on_setting := len(plugins) > 0 && app.plugin_action >= len(plugins[clamp(app.plugin_sel, 0, len(plugins) - 1)].actions)
			draw_hints(w, h, []Hint{{"A", on_setting ? "Change" : "Run"}, {"B", "Plugins"}, {"LB / RB", "Menus"}})
		} else {
			draw_hints(w, h, []Hint{{"A", "Actions"}, {"B", "Home"}, {"LB / RB", "Menus"}})
		}
	case app.screen == .Settings:
		draw_hints(w, h, []Hint{{"A", "Select"}, {"B", "Home"}, {"LB / RB", "Menus"}, {"SELECT", "Power"}})
	case app.screen == .Main:
		draw_hints(w, h, []Hint{{"A", "Play"}, {"Y", "Rescan"}, {"LB / RB", "Menus"}, {"SELECT", "Power"}})
	case:
		draw_hints(w, h, []Hint{{"A", app.screen == .Apps ? "Open" : "Play"}, {"B", "Home"}, {"Y", "Rescan"}, {"LB / RB", "Menus"}})
	}
}

draw_heading :: proc(text: string, count: int, y: f32) {
	draw_t(text, PAD, y, 15, COL_ACCENT)
	if count >= 0 {
		draw_t(fmt.tprintf("%d", count), PAD + measure_t(text, 15) + 12, y, 15, COL_MUTED)
	}
}

// ---------------------------------------------------------------------------
// Cards

Card :: struct {
	tex:         rl.Texture2D,
	has_tex:     bool,
	title:       string,
	placeholder: string,
	contain:     bool, // show the whole image (covers, icons) instead of filling and cropping
	badge:       string, // small bubble in the art's top-right corner
}

card_for :: proc(s: Screen, i: int) -> Card {
	#partial switch s {
	case .Main:
		g := &app.drive_games[i]
		return {g.box, g.has_box, g.title, "NO ART", true, g.mod_name != "" ? fmt.tprintf("Modded : %s", g.mod_name) : ""}
	case .Library:
		g := &app.library_games[i]
		return {g.box, g.has_box, g.title, "NO ART", true, ""}
	case .Movies:
		m := &app.movies[i]
		return {m.thumb, m.has_thumb, m.title, "VIDEO", false, ""}
	case .Apps:
		a := &app.shell_apps[i]
		return {a.icon, a.has_icon, a.title, "APP", true, ""}
	}
	return {}
}

draw_card :: proc(c: Card, r: rl.Rectangle, hi: bool, title_size: f32 = 17) {
	box := r
	if hi {
		box.y -= 6
	}
	draw_panel(box, hi)
	art := rl.Rectangle{box.x + 8, box.y + 8, box.width - 16, box.height - 16 - TITLE_STRIP}
	if hi {
		splash_focus_art = art
	}
	if c.has_tex && c.contain {
		rl.DrawRectangleRounded(art, roundness(art, RADIUS - 4), 6, with_alpha(COL_SHADE, 70))
		draw_texture_contain(c.tex, art)
	} else if c.has_tex {
		draw_texture_cover(c.tex, art)
	} else {
		rl.DrawRectangleRounded(art, roundness(art, RADIUS - 4), 6, with_alpha(COL_TINT, 8))
		draw_t_center(c.placeholder, art.x + art.width * 0.5, art.y + art.height * 0.5 - 8, 15, COL_MUTED)
	}
	if c.badge != "" {
		size: f32 = 12
		tw := min(measure_t(c.badge, size), art.width - 28)
		pill := rl.Rectangle{art.x + art.width - tw - 22, art.y + 6, tw + 16, 22}
		rl.DrawRectangleRounded(pill, 1, 8, with_alpha(COL_ACCENT, 230))
		draw_t_fit(c.badge, pill.x + 8, pill.y + 5, tw, size, rl.Color{16, 18, 24, 255}, false)
	}
	draw_t_fit(c.title, box.x + 14, box.y + box.height - TITLE_STRIP + 8, box.width - 28, title_size, hi ? COL_TEXT : COL_MUTED, hi)
	if hi {
		draw_focus_ring(box)
	}
}

card_mouse :: proc(s: Screen, i: int, r: rl.Rectangle) {
	if !mouse_over(r) {
		return
	}
	hover_enter(fmt.tprintf("card-%d-%d", int(s), i))
	if rl.IsMouseButtonPressed(.LEFT) {
		sel := grid_selection(s)
		if sel^ == i {
			activate_item(s, i)
		} else {
			sel^ = i
			sfx_click()
		}
	}
}

// ---------------------------------------------------------------------------
// Home: carousel of games on inserted drives

draw_main :: proc(w, h: f32) {
	top := f32(HEADER_H + 28)
	draw_heading("INSERTED", len(app.drive_games), top)
	bottom := h - FOOTER_H - 24

	if len(app.drive_games) == 0 {
		pw := min(w - PAD * 2, 760)
		r := rl.Rectangle{(w - pw) * 0.5, (top + bottom) * 0.5 - 110, pw, 220}
		draw_panel(r, false)
		bob := 3 * math.sin(f32(rl.GetTime()) * 1.4)
		draw_t_center("Insert a disc or drive", w * 0.5, r.y + 66 + bob, 30, COL_TEXT)
		draw_t_center("Saber looks for a _Saber folder at the drive root or one folder down.", w * 0.5, r.y + 118, 17, COL_MUTED)
		draw_t_center("Your library lives under GAMES.", w * 0.5, r.y + 146, 17, COL_MUTED)
		return
	}

	info_h: f32 = 130
	area_top := top + 40
	area_h := bottom - area_top - info_h
	card_h := area_h
	card_w := (card_h - TITLE_STRIP) / 1.4
	gap: f32 = 40
	step := card_w * 0.82 + gap
	sel := clamp(app.selected_drive, 0, len(app.drive_games) - 1)
	target := w * 0.5 - f32(sel) * step
	if !app.carousel_ready {
		app.carousel_x = target
		app.carousel_ready = true
	}
	app.carousel_x = smooth_to(app.carousel_x, target, 12)

	// draw far cards first so the focused one sits on top
	order := make([]int, len(app.drive_games), context.temp_allocator)
	for i in 0 ..< len(order) {
		order[i] = i
	}
	dist :: proc(i: int, sel: int) -> int { return abs(i - sel) }
	for i in 0 ..< len(order) {
		for j in i + 1 ..< len(order) {
			if dist(order[j], sel) > dist(order[i], sel) {
				order[i], order[j] = order[j], order[i]
			}
		}
	}
	for i in order {
		cx := app.carousel_x + f32(i) * step
		k := clamp(abs(cx - w * 0.5) / step, 0, 1)
		scale := 1 - 0.18 * k
		cw := card_w * scale
		ch := card_h * scale
		r := rl.Rectangle{cx - cw * 0.5, area_top + (card_h - ch) * 0.5, cw, ch}
		if r.x > w || r.x + r.width < 0 {
			continue
		}
		card_mouse(.Main, i, r)
		draw_card(card_for(.Main, i), r, i == sel, 18)
		if k > 0.02 {
			rl.DrawRectangleRounded(r, roundness(r, RADIUS), 8, with_alpha(COL_SHADE, u8(110 * k)))
		}
	}

	g := &app.drive_games[sel]
	iy := area_top + card_h + 24
	draw_t_center(g.title, w * 0.5, iy, 30, COL_TEXT)
	meta := fmt.tprintf("%s  ·  played %s", g.drive_label, format_playtime(g.playtime_seconds))
	if g.tags != "" {
		meta = fmt.tprintf("%s  ·  %s", g.tags, meta)
	}
	draw_t_center(meta, w * 0.5, iy + 42, 16, COL_MUTED)
	if len(g.info) > 0 {
		parts := make([dynamic]string, context.temp_allocator)
		for line in g.info {
			if line.label == "Serial" || line.label == "System" || line.label == "Released" do continue
			append(&parts, line.value)
		}
		draw_t_center(strings.join(parts[:], "  ·  ", context.temp_allocator), w * 0.5, iy + 68, 16, COL_MUTED)
	}
}

// ---------------------------------------------------------------------------
// Grid pages (games / movies / apps)

Grid_Layout :: struct {
	cols:   int,
	aspect: f32, // art height / width
}

grid_layout :: proc(s: Screen) -> Grid_Layout {
	#partial switch s {
	case .Movies:
		return {3, 0.5625}
	case .Apps:
		return {4, 1}
	}
	return {4, 1.4}
}

draw_library :: proc(w, h: f32) {
	draw_grid_page(.Library, "GAMES", "No games yet. Add a folder with a _Saber subfolder to APP/games.", w, h)
}

draw_movies :: proc(w, h: f32) {
	draw_grid_page(.Movies, "MOVIES", "No movies yet. Drop .mp4 / .mkv / .avi files into APP/movies.", w, h)
}

draw_apps :: proc(w, h: f32) {
	draw_grid_page(.Apps, "APPS", "No apps yet. Add a .toml (name, exe, exe_args) to APP/apps.", w, h)
}

draw_grid_page :: proc(s: Screen, heading, empty: string, w, h: f32) {
	top := f32(HEADER_H + 28)
	n := grid_count(s)
	draw_heading(heading, n, top)
	grid_top := top + 36
	bottom := h - FOOTER_H - 20
	left_w := math.round(w * 0.6)
	area := rl.Rectangle{PAD, grid_top, left_w - PAD - 16, bottom - grid_top}

	detail := rl.Rectangle{left_w + 8, grid_top, w - left_w - 8 - PAD, area.height}
	if n == 0 {
		draw_t(empty, PAD, grid_top + 8, 18, COL_MUTED)
		draw_panel(detail, false)
		return
	}

	lay := grid_layout(s)
	gap: f32 = 18
	cell_w := (area.width - gap * f32(lay.cols - 1)) / f32(lay.cols)
	cell_h := cell_w * lay.aspect + TITLE_STRIP + 16
	row_h := cell_h + gap
	sel := clamp(grid_selection(s)^, 0, n - 1)

	// keep the focused row in view
	row_y := f32(sel / lay.cols) * row_h
	target := app.scroll[s]
	if row_y < target {
		target = row_y
	}
	if row_y + cell_h + 10 > target + area.height {
		target = row_y + cell_h + 10 - area.height
	}
	app.scroll[s] = smooth_to(app.scroll[s], max(target, 0), 14)

	// room above the first row for the lifted focus card and its ring
	push_clip({0, area.y - 12, left_w, area.height + 12})
	for i in 0 ..< n {
		r := rl.Rectangle{
			area.x + f32(i % lay.cols) * (cell_w + gap),
			area.y + f32(i / lay.cols) * row_h - app.scroll[s],
			cell_w,
			cell_h,
		}
		if r.y + r.height < area.y - 12 || r.y > area.y + area.height {
			continue
		}
		card_mouse(s, i, r)
		draw_card(card_for(s, i), r, i == sel)
	}
	pop_clip()

	draw_detail(s, sel, detail)
}

// Right-hand info panel.
draw_detail :: proc(s: Screen, i: int, r: rl.Rectangle) {
	draw_panel(r, false, with_alpha(COL_PANEL_SOLID, 214))
	x := r.x + 28
	y := r.y + 28
	iw := r.width - 56
	action := "PLAY"

	kv :: proc(label, value: string, x: f32, y: ^f32, w: f32) {
		if value == "" {
			return
		}
		draw_t(label, x, y^, 15, COL_MUTED)
		draw_t_fit(value, x + 110, y^ - 1, w - 110, 17, COL_TEXT, false)
		y^ += 30
	}

	#partial switch s {
	case .Library:
		g := &app.library_games[i]
		if g.has_logo {
			y += draw_texture_fit(g.logo, x, y, iw, 96) + 20
		}
		draw_t_fit(g.title, x, y, iw, 30, COL_TEXT, true)
		y += 42
		if g.tags != "" {
			draw_t_fit(g.tags, x, y, iw, 16, COL_ACCENT, false)
			y += 34
		}
		kv("Played", format_playtime(g.playtime_seconds), x, &y, iw)
		kv("Last", g.date_last, x, &y, iw)
		kv("First", g.date_first, x, &y, iw)
		kv("Source", g.from_drive ? g.drive_label : "Library", x, &y, iw)
		for line in g.info do kv(line.label, line.value, x, &y, iw)
	case .Movies:
		m := &app.movies[i]
		if m.has_thumb {
			y += draw_texture_fit(m.thumb, x, y, iw, min(iw * 0.5625, r.height * 0.4)) + 20
		}
		draw_t_fit(m.title, x, y, iw, 30, COL_TEXT, true)
		y += 46
		kv("File", filepath.base(m.path), x, &y, iw)
		if movie_player_label != "" {
			kv("Player", movie_player_label, x, &y, iw)
		} else {
			draw_t("No player found — install VLC", x, y, 16, COL_WARN)
		}
	case .Apps:
		a := &app.shell_apps[i]
		action = "OPEN"
		if a.has_icon {
			y += draw_texture_fit(a.icon, x, y, iw, 110) + 20
		}
		draw_t_fit(a.title, x, y, iw, 30, COL_TEXT, true)
		y += 46
		if strings.trim_space(a.exe) == "" {
			draw_t("No exe set in the .toml", x, y, 16, COL_WARN)
		} else {
			kv("Program", filepath.base(a.exe), x, &y, iw)
			kv("Args", strings.trim_space(a.args), x, &y, iw)
		}
	}

	btn := rl.Rectangle{x, r.y + r.height - 28 - 52, min(iw, 240), 52}
	if ui_button(fmt.tprintf("detail-%d", int(s)), btn, "", true) {
		activate_item(s, i)
	}
	gw := draw_glyph("A", btn.x + 18, btn.y + btn.height * 0.5)
	draw_t(action, btn.x + 18 + gw + 12, btn.y + 16, 20, COL_TEXT)
}

// ---------------------------------------------------------------------------
// Settings

SETTINGS_LABELS := [Settings_Row]string {
	.Ui_Theme    = "UI theme",
	.Wallpaper   = "Wallpaper",
	.Music       = "Theme music",
	.Volume      = "Music volume",
	.Font        = "Font",
	.Online_Mode = "Online Mode",
	.Emulation   = "Emulation",
	.Launch_Mode = "Launch mode",
	.Updates     = "Check for updates",
	.Desktop     = "Desktop",
}

SETTINGS_HELP := [Settings_Row]string {
	.Ui_Theme    = "Menu colors inspired by classic consoles.",
	.Wallpaper   = "Images from APP/assets/bkg.",
	.Music       = "Tracks from APP/assets/bgm.",
	.Volume      = "Background music level.",
	.Font        = "Bundled fonts from APP/assets/fonts, then Windows fonts.",
	.Online_Mode = "Lets plugins use the internet (e.g. cover downloads). Turning it off stops all online activity at once.",
	.Emulation   = "Video, audio, controls and emulator cores for console games.",
	.Launch_Mode = "",
	.Updates    = "Downloads the latest release with SaberUpdater, then restarts Saber. Needs Online Mode.",
	.Desktop     = "Starts Explorer without closing Saber.",
}

ROW_H :: 62
ROW_GAP :: 8

draw_settings :: proc(w, h: f32) {
	top := f32(HEADER_H + 28)
	draw_heading("SETTINGS", -1, top)
	pw := min(w - PAD * 2, 880)
	x := (w - pw) * 0.5
	y := top + 36

	launch_row: rl.Rectangle
	for row in Settings_Row {
		i := int(row)
		r := rl.Rectangle{x, y + f32(i) * (ROW_H + ROW_GAP), pw, ROW_H}
		focused := app.settings_focus == i
		if !app.dropdown_open && mouse_over(r) && app.settings_focus != i {
			app.settings_focus = i
			hover_enter(fmt.tprintf("set-%d", i))
		}
		draw_panel(r, focused)
		if focused {
			rl.DrawRectangleRounded({r.x + 8, r.y + 16, 3, r.height - 32}, 1, 4, COL_ACCENT)
		}
		draw_t(SETTINGS_LABELS[row], r.x + 26, r.y + (ROW_H - 20) * 0.5, 20, focused ? COL_TEXT : COL_MUTED)

		val := rl.Rectangle{r.x + r.width * 0.4, r.y + 10, r.width * 0.6 - 16, ROW_H - 20}
		switch row {
		case .Ui_Theme:
			if d := draw_stepper(val, app.settings.ui_theme, index_of_ui_theme(app.settings.ui_theme), len(UI_THEMES), focused); d != 0 {
				cycle_ui_theme(d)
			}
		case .Wallpaper:
			idx := index_of_name(theme.bkg_files[:], app.settings.bkg)
			if d := draw_stepper(val, app.settings.bkg != "" ? app.settings.bkg : "None", idx, len(theme.bkg_files), focused); d != 0 {
				cycle_bkg(d)
			}
		case .Music:
			idx := index_of_name(theme.bgm_files[:], app.settings.bgm)
			if d := draw_stepper(val, app.settings.bgm != "" ? filepath.stem(app.settings.bgm) : "None", idx, len(theme.bgm_files), focused); d != 0 {
				cycle_bgm(d)
			}
		case .Font:
			if d := draw_stepper(val, ui_font_name, max(index_of_font(app.settings.font), 0), len(font_choices), focused); d != 0 {
				cycle_font(d)
			}
		case .Volume:
			draw_volume_slider(val, focused)
		case .Online_Mode:
			if d := draw_stepper(val, app.settings.online_mode ? "On" : "Off", app.settings.online_mode ? 1 : 0, 2, focused); d != 0 {
				set_online_mode(!app.settings.online_mode)
			}
		case .Emulation:
			draw_t_right("Open settings", val.x + val.width - 40, val.y + 11, 18, focused ? COL_TEXT : COL_MUTED)
			draw_glyph("A", val.x + val.width - 26, val.y + val.height * 0.5)
			if mouse_over(r) && rl.IsMouseButtonPressed(.LEFT) {
				emu_open(false)
			}
		case .Launch_Mode:
			launch_row = r
			draw_select_box(val, LAUNCH_MODE_NAMES[app.settings.launch_mode], focused)
			if !app.dropdown_open && mouse_over(val) && rl.IsMouseButtonPressed(.LEFT) {
				open_dropdown()
			}
		case .Updates:
			draw_t_right(UPDATE_STATUS[update_get_state()], val.x + val.width - 40, val.y + 11, 18, focused ? COL_TEXT : COL_MUTED)
			draw_glyph("A", val.x + val.width - 26, val.y + val.height * 0.5)
			if mouse_over(r) && rl.IsMouseButtonPressed(.LEFT) {
				update_check_start()
				sfx_click()
			}
		case .Desktop:
			draw_t_right("Open Explorer", val.x + val.width - 40, val.y + 11, 18, focused ? COL_TEXT : COL_MUTED)
			draw_glyph("A", val.x + val.width - 26, val.y + val.height * 0.5)
			if mouse_over(r) && rl.IsMouseButtonPressed(.LEFT) {
				open_desktop()
				set_status("Started Explorer")
				sfx_click()
			}
		}
	}

	help := SETTINGS_HELP[Settings_Row(app.settings_focus)]
	if Settings_Row(app.settings_focus) == .Launch_Mode {
		help = LAUNCH_MODE_HELP[app.settings.launch_mode]
	}
	if !app.dropdown_open {
		draw_t(help, x + 4, y + f32(SETTINGS_ROWS) * (ROW_H + ROW_GAP) + 8, 16, COL_MUTED)
	}

	draw_dropdown(launch_row)
}

// "< value  2/5 >" control; returns -1 / +1 when an arrow is clicked.
draw_stepper :: proc(r: rl.Rectangle, value: string, idx, count: int, focused: bool) -> int {
	col := focused ? COL_TEXT : COL_MUTED
	arrow := focused ? COL_ACCENT : COL_MUTED
	left := rl.Rectangle{r.x, r.y, 36, r.height}
	right := rl.Rectangle{r.x + r.width - 36, r.y, 36, r.height}
	draw_triangle_dir(left.x + 18, r.y + r.height * 0.5, 14, .Left, arrow)
	draw_triangle_dir(right.x + 18, r.y + r.height * 0.5, 14, .Right, arrow)
	counter := count > 0 ? fmt.tprintf("%d/%d", idx + 1, count) : ""
	cw := measure_t(counter, 14)
	draw_t_fit(value, left.x + 44, r.y + 11, r.width - 88 - cw - 16, 18, col, focused)
	draw_t(counter, right.x - cw - 8, r.y + 13, 14, COL_MUTED)
	if count <= 1 {
		return 0
	}
	if mouse_over(left) && rl.IsMouseButtonPressed(.LEFT) {
		return -1
	}
	if mouse_over(right) && rl.IsMouseButtonPressed(.LEFT) {
		return 1
	}
	return 0
}

draw_volume_slider :: proc(r: rl.Rectangle, focused: bool) {
	track := rl.Rectangle{r.x + 12, r.y + r.height * 0.5 - 3, r.width - 90, 6}
	hit := rl.Rectangle{track.x - 8, r.y, track.width + 16, r.height}
	if mouse_over(hit) && rl.IsMouseButtonPressed(.LEFT) {
		app.slider_drag = true
	}
	if app.slider_drag {
		if rl.IsMouseButtonDown(.LEFT) {
			v := clamp((rl.GetMousePosition().x - draw_dx - track.x) / track.width, 0, 1)
			app.settings.volume = v
			if theme.has_music {
				rl.SetMusicVolume(theme.music, v)
			}
		} else {
			app.slider_drag = false
			set_volume(app.settings.volume) // save once on release
		}
	}
	v := app.settings.volume
	rl.DrawRectangleRounded(track, 1, 6, with_alpha(COL_TINT, 30))
	rl.DrawRectangleRounded({track.x, track.y, track.width * v, track.height}, 1, 6, focused ? COL_ACCENT : COL_MUTED)
	rl.DrawCircleV({track.x + track.width * v, track.y + 3}, focused ? 10 : 8, COL_TEXT)
	draw_t_right(fmt.tprintf("%d%%", int(v * 100 + 0.5)), r.x + r.width - 8, r.y + 11, 18, focused ? COL_TEXT : COL_MUTED)
}

draw_select_box :: proc(r: rl.Rectangle, value: string, focused: bool) {
	rr := roundness(r, 8)
	rl.DrawRectangleRounded(r, rr, 6, with_alpha(COL_TINT, focused ? 20 : 10))
	rl.DrawRectangleRoundedLinesEx(r, rr, 6, 1, focused ? COL_ACCENT_SOFT : COL_FAINT)
	draw_t(value, r.x + 16, r.y + 11, 18, focused ? COL_TEXT : COL_MUTED)
	draw_triangle_dir(r.x + r.width - 22, r.y + r.height * 0.5 + 2, 14, .Down, focused ? COL_ACCENT : COL_MUTED)
}

DROP_ITEM_H :: 58

draw_dropdown :: proc(row: rl.Rectangle) {
	target: f32 = app.dropdown_open ? 1 : 0
	app.dropdown_t = smooth_to(app.dropdown_t, target, 18)
	if !app.dropdown_open && app.dropdown_t < 0.02 {
		return
	}
	n := len(Launch_Mode)
	box := rl.Rectangle{row.x + row.width * 0.4, row.y + 4, row.width * 0.6 - 6, f32(n) * DROP_ITEM_H + 12}
	box.height *= 0.85 + 0.15 * app.dropdown_t
	a := app.dropdown_t
	rr := roundness(box, RADIUS)
	rl.DrawRectangleRounded({box.x, box.y + 8, box.width, box.height}, rr, 8, rl.Color{0, 0, 0, u8(120 * a)})
	rl.DrawRectangleRounded(box, rr, 8, with_alpha(COL_PANEL_SOLID, u8(250 * a)))
	rl.DrawRectangleRoundedLinesEx(box, rr, 8, 1, rl.Color{COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, u8(90 * a)})
	if a < 0.6 {
		return
	}

	clicked_inside := false
	for mode in Launch_Mode {
		i := int(mode)
		it := rl.Rectangle{box.x + 6, box.y + 6 + f32(i) * DROP_ITEM_H, box.width - 12, DROP_ITEM_H}
		if app.dropdown_open && mouse_over(it) {
			if app.dropdown_sel != i {
				app.dropdown_sel = i
				hover_enter(fmt.tprintf("mode-%d", i))
			}
			if rl.IsMouseButtonPressed(.LEFT) {
				clicked_inside = true
				choose_launch_mode(mode)
			}
		}
		if i == app.dropdown_sel {
			rl.DrawRectangleRounded(it, roundness(it, 8), 6, rl.Color{COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 40})
		}
		current := mode == app.settings.launch_mode
		if current {
			rl.DrawCircleV({it.x + 16, it.y + 20}, 4, COL_ACCENT)
		}
		draw_t(LAUNCH_MODE_NAMES[mode], it.x + 30, it.y + 9, 18, i == app.dropdown_sel ? COL_TEXT : COL_MUTED)
		draw_t_fit(LAUNCH_MODE_HELP[mode], it.x + 30, it.y + 33, it.width - 40, 13, COL_MUTED, false)
	}
	if app.dropdown_open && !clicked_inside && !input.using_pad && rl.IsMouseButtonPressed(.LEFT) && !rl.CheckCollisionPointRec(rl.GetMousePosition(), box) {
		app.dropdown_open = false
		sfx_back()
	}
}

// ---------------------------------------------------------------------------
// Modal menus: close/power dialog and the in-game overlay

// Returns the index of a clicked option, or -1.
draw_modal_menu :: proc(title, sub: string, labels: []string, sel: int, t: f32, w, h: f32, interactive: bool) -> int {
	rl.DrawRectangle(0, 0, i32(w), i32(h), with_alpha(COL_SHADE, u8(150 * t)))
	bh: f32 = 54
	gap: f32 = 10
	pw: f32 = 460
	ph := 104 + f32(len(labels)) * (bh + gap) + 14
	s := 0.94 + 0.06 * t
	r := rl.Rectangle{(w - pw * s) * 0.5, (h - ph * s) * 0.5, pw * s, ph * s}
	draw_panel(r, false, with_alpha(COL_PANEL_SOLID, u8(244 * t)))
	if t < 0.5 {
		return -1
	}
	draw_t_fit(title, r.x + 28, r.y + 26, r.width - 56, 26, COL_TEXT, true)
	draw_t(sub, r.x + 28, r.y + 62, 15, COL_MUTED)
	clicked := -1
	for label, i in labels {
		br := rl.Rectangle{r.x + 24, r.y + 104 + f32(i) * (bh + gap), r.width - 48, bh}
		if interactive {
			if ui_button(fmt.tprintf("modal-%d", i), br, label, i == sel, true) {
				clicked = i
			}
		} else {
			ui_button("", br, label, false, true)
		}
	}
	return clicked
}

draw_power_dialog :: proc(w, h: f32) {
	app.power_t = smooth_to(app.power_t, app.power_open ? 1 : 0, 16)
	if app.power_t < 0.02 && !app.power_open {
		return
	}
	title := "Power"
	sub := app.in_shell ? "Saber is this account's shell" : app.settings.launch_mode == .Standalone ? "Quit Saber?" : "Quit Saber or power off the PC"
	if app.power_confirm != .Cancel {
		title = fmt.tprintf("%s?", POWER_LABELS[app.power_confirm])
		sub = "Unsaved progress in running games will be lost"
	}
	if clicked := draw_modal_menu(title, sub, power_labels(), app.power_sel, app.power_t, w, h, app.power_open); clicked >= 0 {
		app.power_sel = clicked
		apply_power_choice()
	}
}
