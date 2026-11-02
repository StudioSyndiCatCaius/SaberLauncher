package saber

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// Settings > Ignored drives: fixed (hard) drives besides the system drive that the game scan skips.

Drive_Entry :: struct {
	letter: rune,
	label:  string,
}

drives_menu: struct {
	open:    bool,
	sel:     int,
	t:       f32,
	changed: bool,
	list:    [dynamic]Drive_Entry,
}

// Read by the drive-scan worker too; a u32 store is atomic enough for a skip flag.
drive_ignored :: proc(letter: rune) -> bool {
	if letter < 'A' || letter > 'Z' do return false
	return app.settings.ignore_drives & (1 << u32(letter - 'A')) != 0
}

// "DE" / "D, E" (temp)
drive_letters :: proc(mask: u32, sep := "") -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< u32(26) {
		if mask & (1 << i) == 0 do continue
		if strings.builder_len(b) > 0 do strings.write_string(&b, sep)
		strings.write_rune(&b, rune('A' + i))
	}
	return strings.to_string(b)
}

drives_menu_clear :: proc() {
	for d in drives_menu.list do delete(d.label)
	clear(&drives_menu.list)
}

drives_menu_open :: proc() {
	drives_menu_clear()
	mask := current_drive_mask()
	for i in 0 ..< u32(26) {
		letter := rune('A' + i)
		if mask & (1 << i) == 0 || is_system_drive(letter) || drive_type(letter) != DRIVE_FIXED do continue
		append(&drives_menu.list, Drive_Entry{letter, volume_label(letter)})
	}
	// keep ignored drives that are unplugged right now, so they can still be un-ignored
	for i in 0 ..< u32(26) {
		if app.settings.ignore_drives & (1 << i) != 0 && mask & (1 << i) == 0 {
			append(&drives_menu.list, Drive_Entry{rune('A' + i), strings.clone("(not connected)")})
		}
	}
	drives_menu.open = true
	drives_menu.sel = 0
	drives_menu.t = 0
	drives_menu.changed = false
	app.settings_focus = int(Settings_Row.Ignored_Drives)
	sfx_click()
}

drives_menu_close :: proc() {
	drives_menu.open = false
	sfx_back()
	if !drives_menu.changed do return
	save_settings()
	app.portable_mask = portable_drive_mask(app.drive_mask)
	drive_scan_start(.Drive)
	set_status("Ignored drives changed, rescanning…")
}

drives_menu_toggle :: proc(i: int) {
	if i < 0 || i >= len(drives_menu.list) do return
	app.settings.ignore_drives ~= 1 << u32(drives_menu.list[i].letter - 'A')
	drives_menu.changed = true
	sfx_click()
}

drives_menu_input :: proc() {
	if input.cancel || input.power {
		drives_menu_close()
		return
	}
	n := len(drives_menu.list)
	if n == 0 {
		if input.confirm do drives_menu_close()
		return
	}
	if input.up {
		drives_menu.sel = (drives_menu.sel - 1 + n) % n
		sfx_click()
	}
	if input.down {
		drives_menu.sel = (drives_menu.sel + 1) % n
		sfx_click()
	}
	if input.confirm || input.left || input.right {
		drives_menu_toggle(drives_menu.sel)
	}
}

DRIVES_ROW_H :: 58

drives_menu_draw :: proc(w, h: f32) {
	drives_menu.t = smooth_to(drives_menu.t, drives_menu.open ? 1 : 0, 18)
	t := drives_menu.t
	if !drives_menu.open && t < 0.02 do return

	rl.DrawRectangle(0, 0, i32(w), i32(h), with_alpha(COL_SHADE, u8(150 * t)))
	n := len(drives_menu.list)
	pw := min(w - PAD * 2, 620)
	ph := 104 + f32(max(n, 1)) * (DRIVES_ROW_H + 8) + 20
	s := 0.94 + 0.06 * t
	r := rl.Rectangle{(w - pw * s) * 0.5, (h - ph * s) * 0.5, pw * s, ph * s}
	draw_soft_shadow(r, RADIUS, t * 1.6)
	draw_panel(r, false, with_alpha(COL_PANEL_SOLID, u8(244 * t)))
	if t < 0.5 do return

	draw_t("Ignored drives", r.x + 28, r.y + 26, 26, COL_TEXT)
	draw_t("Checked drives are not scanned for games. The system drive is always skipped.", r.x + 28, r.y + 62, 15, COL_MUTED)
	if n == 0 {
		draw_t("No other hard drives found.", r.x + 28, r.y + 110, 18, COL_MUTED)
	}
	clicked_inside := false
	for d, i in drives_menu.list {
		row := rl.Rectangle{r.x + 24, r.y + 104 + f32(i) * (DRIVES_ROW_H + 8), r.width - 48, DRIVES_ROW_H}
		if drives_menu.open && mouse_over(row, true) {
			clicked_inside = true
			if drives_menu.sel != i {
				drives_menu.sel = i
				hover_enter(fmt.tprintf("igdrive-%d", i))
			}
			if rl.IsMouseButtonPressed(.LEFT) do drives_menu_toggle(i)
		}
		focused := i == drives_menu.sel
		draw_panel(row, focused)
		draw_t_fit(fmt.tprintf("%c:  %s", d.letter, d.label), row.x + 20, row.y + (DRIVES_ROW_H - 20) * 0.5, row.width - 160, 20, focused ? COL_TEXT : COL_MUTED, focused)
		draw_checkbox(row, drive_ignored(d.letter), focused)
	}
	if drives_menu.open && !clicked_inside && !input.using_pad && rl.IsMouseButtonPressed(.LEFT) && !rl.CheckCollisionPointRec(rl.GetMousePosition(), r) {
		drives_menu_close()
	}
}
