package saber

import rl "vendor:raylib"

// Settings > Visible Tabs: checkbox list of header tabs. Settings is locked on.

tabs_menu: struct {
	open: bool,
	sel:  int,
	t:    f32,
}

tabs_menu_open :: proc() {
	tabs_menu.open = true
	tabs_menu.sel = 0
	tabs_menu.t = 0
	app.settings_focus = int(Settings_Row.Visible_Tabs)
	sfx_click()
}

tabs_menu_close :: proc() {
	tabs_menu.open = false
	sfx_back()
}

tabs_menu_toggle :: proc(i: int) {
	order := SCREEN_ORDER
	if i < 0 || i >= SCREEN_COUNT do return
	sc := order[i]
	if sc == .Settings {
		set_status("Settings is always visible")
		return
	}
	app.settings.hidden_tabs ~= {sc}
	save_settings()
	sfx_click()
}

tabs_menu_input :: proc() {
	if input.cancel || input.power {
		tabs_menu_close()
		return
	}
	nav_list(&tabs_menu.sel, SCREEN_COUNT)
	if input.confirm || input.left || input.right do tabs_menu_toggle(tabs_menu.sel)
}

tabs_menu_draw :: proc(w, h: f32) {
	if !modal_fade(&tabs_menu.t, tabs_menu.open, 18) do return
	t := tabs_menu.t
	r := modal_panel({0, 0, w, h}, min(w - PAD * 2, 620), 104 + f32(SCREEN_COUNT) * (DRIVES_ROW_H + 8) + 20, t)
	if t < 0.5 do return

	draw_t("Visible Tabs", r.x + 28, r.y + 26, 26, COL_TEXT)
	draw_t("Checked tabs show in the header. Settings is always visible.", r.x + 28, r.y + 62, 15, COL_MUTED)
	clicked_inside := false
	for sc, i in SCREEN_ORDER {
		row := rl.Rectangle{r.x + 24, r.y + 104 + f32(i) * (DRIVES_ROW_H + 8), r.width - 48, DRIVES_ROW_H}
		if tabs_menu.open && mouse_over(row, true) {
			clicked_inside = true
			if list_row_mouse("vistab", i, row, &tabs_menu.sel) do tabs_menu_toggle(i)
		}
		focused := i == tabs_menu.sel
		locked := sc == .Settings
		draw_panel(row, focused)
		label := locked ? "SETTINGS  (always visible)" : TAB_LABELS[sc]
		draw_t_fit(label, row.x + 20, row.y + (DRIVES_ROW_H - 20) * 0.5, row.width - 160, 20, focused && !locked ? COL_TEXT : COL_MUTED, focused)
		draw_checkbox(row, tab_visible(sc), focused)
	}
	if tabs_menu.open && !clicked_inside && !input.using_pad && rl.IsMouseButtonPressed(.LEFT) && !rl.CheckCollisionPointRec(rl.GetMousePosition(), r) {
		tabs_menu_close()
	}
}
