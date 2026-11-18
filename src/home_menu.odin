package saber

// Home's options menu (Start / Backspace / right-click on empty space): settings for the drive
// screen as a whole, as opposed to a card's actions menu (X).

import "core:fmt"
import rl "vendor:raylib"

HOME_PER_ROW_MAX :: 8
HOME_PER_ROW_MIN :: 2 // 1 per row would just be a tall list of huge cards
// slider notches: 2, 3 ... 8, Unlimited
HOME_PER_ROW_STOPS :: HOME_PER_ROW_MAX - HOME_PER_ROW_MIN + 2

Home_Menu_Row :: enum {
	Per_Row,
	Rescan,
	Close,
}

Home_Menu :: struct {
	open: bool,
	t:    f32,
	sel:  int,
	drag: bool, // dragging the games-per-row slider
}

home_menu: Home_Menu

home_menu_open :: proc() {
	if input_locked() do return
	home_menu.open = true
	home_menu.sel = 0
	home_menu.drag = false
	sfx_click()
}

home_per_row_label :: proc() -> string {
	n := app.settings.home_per_row
	return n == 0 ? "Unlimited" : fmt.tprintf("%d", n)
}

home_per_row_stop :: proc() -> int {
	n := app.settings.home_per_row
	return n == 0 ? HOME_PER_ROW_STOPS - 1 : clamp(n, HOME_PER_ROW_MIN, HOME_PER_ROW_MAX) - HOME_PER_ROW_MIN
}

home_per_row_set_stop :: proc(stop: int) {
	stop := clamp(stop, 0, HOME_PER_ROW_STOPS - 1)
	if stop == home_per_row_stop() do return
	app.settings.home_per_row = stop == HOME_PER_ROW_STOPS - 1 ? 0 : HOME_PER_ROW_MIN + stop
	app.scroll[.Main] = 0
	save_settings()
	sfx_click()
}

home_menu_choose :: proc(row: Home_Menu_Row) {
	switch row {
	case .Per_Row: // A steps right, wrapping back to 2 after Unlimited
		s := home_per_row_stop() + 1
		home_per_row_set_stop(s >= HOME_PER_ROW_STOPS ? 0 : s)
	case .Rescan:
		home_menu.open = false
		rescan_all(drives_async = true)
		set_status("Rescanned drives, library, movies and apps")
		sfx_click()
	case .Close:
		home_menu.open = false
		sfx_back()
	}
}

home_menu_input :: proc() {
	rows := len(Home_Menu_Row)
	home_menu.sel = clamp(home_menu.sel, 0, rows - 1)
	nav_list(&home_menu.sel, rows)
	row := Home_Menu_Row(home_menu.sel)
	if row == .Per_Row && (input.left || input.right) {
		home_per_row_set_stop(home_per_row_stop() + (input.right ? 1 : -1))
		return
	}
	if input.cancel || input.menu || input.power {
		home_menu.open = false
		sfx_back()
		return
	}
	if input.confirm do home_menu_choose(row)
}

draw_home_menu :: proc(w, h: f32) {
	if !modal_fade(&home_menu.t, home_menu.open) do return
	bh: f32 = 54
	gap: f32 = 10
	slider_h: f32 = 96
	rows := len(Home_Menu_Row)
	r := modal_panel({0, 0, w, h}, 520, 104 + slider_h + gap + f32(rows - 1) * (bh + gap) + 14, home_menu.t)
	if home_menu.t < 0.5 do return
	draw_t("Home Options", r.x + 28, r.y + 26, 26, COL_TEXT)
	draw_t("Settings for this screen", r.x + 28, r.y + 62, 15, COL_MUTED)

	// games-per-row slider panel
	sr := rl.Rectangle{r.x + 24, r.y + 104, r.width - 48, slider_h}
	focused := home_menu.sel == int(Home_Menu_Row.Per_Row)
	draw_glass(sr, 16, focused ? COL_PANEL_HI : COL_PANEL, 0.2, COL_ACCENT, focused ? 0.35 : 0, refract = 6)
	draw_t("Max Games per Row", sr.x + 18, sr.y + 14, 18, focused ? COL_TEXT : COL_MUTED)
	draw_t_right(home_per_row_label(), sr.x + sr.width - 18, sr.y + 14, 18, focused ? COL_ACCENT : COL_MUTED)

	track := rl.Rectangle{sr.x + 30, sr.y + 64, sr.width - 60, 6}
	stops := HOME_PER_ROW_STOPS
	step := track.width / f32(stops - 1)
	hit := rl.Rectangle{track.x - 16, track.y - 22, track.width + 32, 44}
	if home_menu.open && mouse_over(hit, true) && rl.IsMouseButtonPressed(.LEFT) {
		home_menu.drag = true
		home_menu.sel = int(Home_Menu_Row.Per_Row)
	}
	if home_menu.drag {
		if rl.IsMouseButtonDown(.LEFT) {
			x := rl.GetMousePosition().x - draw_dx - track.x
			home_per_row_set_stop(int(x / step + 0.5))
		} else {
			home_menu.drag = false
		}
	}
	cur := home_per_row_stop()
	rl.DrawRectangleRounded(track, 1, 6, with_alpha(COL_SHADE, 90))
	rl.DrawRectangleRounded({track.x, track.y, step * f32(cur), track.height}, 1, 6, focused ? COL_ACCENT : COL_MUTED)
	for i in 0 ..< stops {
		x := track.x + step * f32(i)
		rl.DrawCircleV({x, track.y + 3}, 3, i <= cur ? COL_TEXT : COL_FAINT)
		lbl := i == stops - 1 ? "All" : fmt.tprintf("%d", HOME_PER_ROW_MIN + i)
		draw_t_center(lbl, x, track.y + 12, 12, i == cur ? COL_TEXT : COL_MUTED)
	}
	kr: f32 = focused ? 13 : 11
	kx := track.x + step * f32(cur)
	knob := rl.Rectangle{kx - kr * 1.4, track.y + 3 - kr, kr * 2.8, kr * 2}
	draw_soft_shadow(knob, kr, 0.6)
	draw_glass(knob, kr, rl.WHITE, ui_theme_light ? 0.5 : 0.28, COL_ACCENT, focused ? 0.5 : 0, refract = 6)

	// the plain rows
	y := sr.y + slider_h + gap
	for row in Home_Menu_Row {
		if row == .Per_Row do continue
		label := row == .Rescan ? "Rescan Drives" : "Close"
		br := rl.Rectangle{r.x + 24, y, r.width - 48, bh}
		if home_menu.open {
			if ui_button(fmt.tprintf("home-menu-%d", int(row)), br, label, int(row) == home_menu.sel, true) {
				home_menu.sel = int(row)
				home_menu_choose(row)
			}
		} else {
			ui_button("", br, label, false, true)
		}
		y += bh + gap
	}
}
