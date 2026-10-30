package saber

// Plugins page: installed plugins on the left, the selected one's info and actions on the right.

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

PLUGIN_ROW_H :: 64
PLUGIN_LIST_W :: 380
ACTION_ROW_H :: 58

handle_plugins_input :: proc() {
	n := len(plugins)
	if n == 0 do return
	app.plugin_sel = clamp(app.plugin_sel, 0, n - 1)
	p := &plugins[app.plugin_sel]
	if app.plugin_focus == 0 {
		if input.up && app.plugin_sel > 0 {
			app.plugin_sel -= 1
			app.plugin_action = 0
			sfx_click()
		}
		if input.down && app.plugin_sel < n - 1 {
			app.plugin_sel += 1
			app.plugin_action = 0
			sfx_click()
		}
		if input.right || input.confirm {
			app.plugin_focus = 1
			app.plugin_action = 0
			sfx_click()
		}
		return
	}
	// right column: the on/off switch, then actions, then settings, as one list
	items := plugin_items(p)
	on_setting := app.plugin_action == 0 || app.plugin_action > len(p.actions)
	if input.left && !on_setting {
		app.plugin_focus = 0
		sfx_back()
		return
	}
	app.plugin_action = clamp(app.plugin_action, 0, items - 1)
	if input.up && app.plugin_action > 0 {
		app.plugin_action -= 1
		sfx_click()
	}
	if input.down && app.plugin_action < items - 1 {
		app.plugin_action += 1
		sfx_click()
	}
	if app.plugin_action == 0 {
		if input.left || input.right || input.confirm {
			plugin_set_enabled(p, !p.enabled)
			sfx_click()
		}
	} else if app.plugin_action <= len(p.actions) {
		if input.confirm do run_plugin_action(p, &p.actions[app.plugin_action - 1])
	} else {
		s := &p.settings[app.plugin_action - 1 - len(p.actions)]
		if input.left do plugin_change_setting(p, s, -1)
		else if input.right || input.confirm do plugin_change_setting(p, s, 1)
	}
}

plugin_items :: proc(p: ^Plugin) -> int {
	if p.L == nil do return 1 // off: only the switch
	return 1 + len(p.actions) + len(p.settings)
}

run_plugin_action :: proc(p: ^Plugin, a: ^Plugin_Action) {
	if msg := plugin_run_action(p, a); msg != "" do set_status("%s", msg)
	if a.runnable && (!a.online || online_enabled()) {
		sfx_click()
	} else {
		sfx_back()
	}
}

// "memory_card" -> "Memory card"
pretty_key :: proc(key: string) -> string {
	s, _ := strings.replace_all(key, "_", " ", context.temp_allocator)
	if s == "" do return s
	return strings.concatenate({strings.to_upper(s[:1], context.temp_allocator), s[1:]}, context.temp_allocator)
}

draw_plugins :: proc(w, h: f32) {
	top := f32(HEADER_H + 28)
	draw_heading("PLUGINS", len(plugins), top)
	y0 := top + 36
	bottom := h - FOOTER_H - 24
	if len(plugins) == 0 {
		draw_t("No plugins. Put .lua files in APP/plugins.", PAD, y0 + 8, 18, COL_MUTED)
		return
	}
	app.plugin_sel = clamp(app.plugin_sel, 0, len(plugins) - 1)

	// list
	for &p, i in plugins {
		r := rl.Rectangle{PAD, y0 + f32(i) * (PLUGIN_ROW_H + ROW_GAP), PLUGIN_LIST_W, PLUGIN_ROW_H}
		if r.y + r.height > bottom do break
		sel := i == app.plugin_sel
		if mouse_over(r) && rl.IsMouseButtonPressed(.LEFT) {
			app.plugin_sel = i
			app.plugin_focus = 0
			app.plugin_action = 0
			sfx_click()
		}
		draw_panel(r, sel && app.plugin_focus == 0)
		if sel {
			rl.DrawRectangleRounded({r.x + 8, r.y + 16, 3, r.height - 32}, 1, 4, COL_ACCENT)
		}
		tx := r.x + 24
		if p.has_icon {
			draw_texture_fit(p.icon, r.x + 14, r.y + 10, 44, 44)
			tx = r.x + 72
		}
		draw_t_fit(p.name, tx, r.y + 11, r.width - tx + r.x - 16, 19, sel ? COL_TEXT : COL_MUTED, sel)
		sub := p.file
		if !p.enabled do sub = fmt.tprintf("%s  ·  OFF", p.file)
		if p.platform != "" do sub = fmt.tprintf("%s  ·  %s", p.file, strings.to_upper(p.platform, context.temp_allocator))
		draw_t_fit(sub, tx, r.y + 37, r.width - tx + r.x - 16, 14, COL_MUTED, false)
	}

	// detail
	p := &plugins[app.plugin_sel]
	r := rl.Rectangle{PAD + PLUGIN_LIST_W + 24, y0, w - PAD * 2 - PLUGIN_LIST_W - 24, bottom - y0}
	draw_panel(r, false, with_alpha(COL_PANEL_SOLID, 214))
	x := r.x + 28
	iw := r.width - 56
	y := r.y + 24
	tx := x
	if p.has_icon {
		draw_texture_fit(p.icon, x, y - 4, 64, 64)
		tx = x + 80
	}
	draw_t_fit(p.name, tx, y, iw - (tx - x), 28, COL_TEXT, true)
	y += 40
	byline := make([dynamic]string, context.temp_allocator)
	if p.version != "" do append(&byline, fmt.tprintf("v%s", p.version))
	if p.author != "" do append(&byline, fmt.tprintf("by %s", p.author))
	append(&byline, p.file)
	draw_t_fit(strings.join(byline[:], "  ·  ", context.temp_allocator), tx, y, iw - (tx - x), 15, COL_ACCENT, false)
	y += p.has_icon ? 40 : 28
	if p.description != "" {
		draw_t_fit(p.description, x, y, iw, 16, COL_TEXT, false)
		y += 30
	}

	kv :: proc(label, value: string, x: f32, y: ^f32, w: f32) {
		draw_t(label, x, y^, 15, COL_MUTED)
		draw_t_fit(value, x + 150, y^ - 1, w - 150, 16, COL_TEXT, false)
		y^ += 26
	}
	// on/off switch
	{
		sr := rl.Rectangle{x, y, iw, ACTION_ROW_H - 6}
		focused := app.plugin_focus == 1 && app.plugin_action == 0
		draw_panel(sr, focused)
		draw_t_fit("Enabled", sr.x + 18, sr.y + 7, iw * 0.5, 18, focused ? COL_TEXT : COL_MUTED, false)
		note := "Turning a plugin on or off needs a Saber restart."
		if p.enabled != (p.L != nil) do note = "Restart Saber to apply (Settings > Restart Saber)."
		draw_t_fit(note, sr.x + 18, sr.y + 30, iw * 0.53, 13, COL_MUTED, false)
		val := rl.Rectangle{sr.x + iw * 0.55, sr.y + 6, iw * 0.45 - 12, sr.height - 12}
		if d := draw_stepper(val, p.enabled ? "On" : "Off", p.enabled ? 1 : 0, 2, focused); d != 0 {
			app.plugin_focus = 1
			app.plugin_action = 0
			plugin_set_enabled(p, !p.enabled)
		}
		y += ACTION_ROW_H + 8
	}
	if p.L == nil {
		draw_t("This plugin is off.", x, y, 16, COL_MUTED)
		return
	}

	if p.platform != "" do kv("Platform", strings.to_upper(p.platform, context.temp_allocator), x, &y, iw)
	if p.game_count > 0 do kv("Games", fmt.tprintf("%d known serials", p.game_count), x, &y, iw)
	for line in p.system {
		if y > r.y + r.height * 0.55 do break
		kv(pretty_key(line.label), line.value, x, &y, iw)
	}

	// actions
	y += 14
	draw_t("ACTIONS", x, y, 15, COL_ACCENT)
	y += 28
	if len(p.actions) == 0 {
		draw_t("This plugin has no actions.", x, y, 16, COL_MUTED)
		y += 30
	}
	for &a, i in p.actions {
		ar := rl.Rectangle{x, y, iw, ACTION_ROW_H}
		if ar.y + ar.height > r.y + r.height - 16 do break
		focused := app.plugin_focus == 1 && app.plugin_action == i + 1
		if mouse_over(ar) && rl.IsMouseButtonPressed(.LEFT) {
			app.plugin_focus = 1
			app.plugin_action = i + 1
			run_plugin_action(p, &a)
		}
		draw_panel(ar, focused)
		draw_t_fit(a.name, ar.x + 18, ar.y + 9, iw - 140, 18, focused ? COL_TEXT : COL_MUTED, focused)
		desc := a.description
		if !a.runnable do desc = desc != "" ? fmt.tprintf("%s  (not implemented)", desc) : "Not implemented yet"
		if a.online && !online_enabled() do desc = "Needs Online Mode (Settings)"
		draw_t_fit(desc, ar.x + 18, ar.y + 33, iw - 140, 14, COL_MUTED, false)
		if focused {
			draw_t_right("Run", ar.x + ar.width - 44, ar.y + 19, 17, COL_TEXT)
			draw_glyph("A", ar.x + ar.width - 26, ar.y + ar.height * 0.5)
		}
		y += ACTION_ROW_H + ROW_GAP
	}

	// settings
	if len(p.settings) == 0 do return
	y += 14
	draw_t("SETTINGS", x, y, 15, COL_ACCENT)
	y += 28
	for &s, i in p.settings {
		sr := rl.Rectangle{x, y, iw, ACTION_ROW_H - 6}
		if sr.y + sr.height > r.y + r.height - 16 do break
		idx := 1 + len(p.actions) + i
		focused := app.plugin_focus == 1 && app.plugin_action == idx
		draw_panel(sr, focused)
		if s.description != "" {
			draw_t_fit(s.name, sr.x + 18, sr.y + 7, iw * 0.5, 18, focused ? COL_TEXT : COL_MUTED, false)
			draw_t_fit(s.description, sr.x + 18, sr.y + 30, iw * 0.53, 13, COL_MUTED, false)
		} else {
			draw_t_fit(s.name, sr.x + 18, sr.y + (sr.height - 18) * 0.5, iw * 0.5, 18, focused ? COL_TEXT : COL_MUTED, false)
		}
		val := rl.Rectangle{sr.x + iw * 0.55, sr.y + 6, iw * 0.45 - 12, sr.height - 12}
		count := s.kind == .Bool ? 2 : len(s.options)
		if d := draw_stepper(val, setting_value_label(&s), s.value, count, focused); d != 0 {
			app.plugin_focus = 1
			app.plugin_action = idx
			plugin_change_setting(p, &s, d)
		}
		y += ACTION_ROW_H
	}
}
