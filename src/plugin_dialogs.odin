package saber

// Dialogs for Lua plugins. Non-blocking: the call returns immediately, the dialog is drawn
// over Saber by the main loop, and the plugin hears back through callbacks.
//
//   Dialog_Info(text, options, on_select)
//       options:   list of button labels (default {"OK"})
//       on_select: function(index) -- 1-based button index, or nil when dismissed with B
//
//   Dialog_Process(text, progress, on_end)
//       progress:  called every frame; returns 0..1 (and optionally a new text line).
//                  Do one small step of work per call. Reaching 1.0 closes the dialog.
//       on_end:    function(cancelled) -- cancelled = true when the user pressed Cancel / B
//
// Dialogs queue up: a Dialog_Info opened from on_end shows after the process closes.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

Plugin_Dialog_Kind :: enum {
	Info,
	Process,
}

Plugin_Dialog :: struct {
	kind:      Plugin_Dialog_Kind,
	L:         ^lua_State,
	title:     string, // plugin name
	text:      string,
	options:   [dynamic]string,
	sel:       int,
	on_select: c.int, // registry refs (LUA_NOREF when absent)
	progress:  c.int,
	on_end:    c.int,
	value:     f32,
	shown:     f32, // eased bar
	t:         f32,
	opened:    bool, // first frame drawn: ignore the press that opened it
	clicked:   bool, // a button was clicked while drawing; acted on by the next input pass
}

plugin_dialogs: [dynamic]Plugin_Dialog

plugin_dialog_open :: proc() -> bool {
	return len(plugin_dialogs) > 0
}

plugin_for_state :: proc(L: ^lua_State) -> ^Plugin {
	for &p in plugins do if p.L == L do return &p
	return nil
}

dialog_ref_arg :: proc(L: ^lua_State, idx: c.int) -> c.int {
	if lua_type(L, idx) != LUA_TFUNCTION do return LUA_NOREF
	lua_pushvalue(L, idx)
	return luaL_ref(L, LUA_REGISTRYINDEX)
}

dialog_free :: proc(d: ^Plugin_Dialog) {
	for ref in ([]c.int{d.on_select, d.progress, d.on_end}) {
		if ref != LUA_NOREF do luaL_unref(d.L, LUA_REGISTRYINDEX, ref)
	}
	for o in d.options do delete(o)
	delete(d.options)
	delete(d.text)
	delete(d.title)
}

// Calls the callback `ref` with one argument pushed by `push`; logs Lua errors.
dialog_call :: proc(d: ^Plugin_Dialog, ref: c.int, push: proc(L: ^lua_State, d: ^Plugin_Dialog), nresults: c.int = 0) -> bool {
	if ref == LUA_NOREF do return false
	L := d.L
	lua_rawgeti(L, LUA_REGISTRYINDEX, i64(ref))
	push(L, d)
	if lua_pcall(L, 1, nresults, 0) != LUA_OK {
		msg := lua_string(L, -1)
		plugin_logf("%s: dialog callback: %s", d.title, msg)
		set_status("%s: %s", d.title, msg)
		lua_pop(L, 1)
		return false
	}
	return true
}

// Closes the front dialog. `index` (1-based, 0 = dismissed) goes to on_select;
// `cancelled` goes to on_end.
dialog_finish :: proc(index: int, cancelled: bool) {
	d := plugin_dialogs[0]
	ordered_remove(&plugin_dialogs, 0)
	eat_input()
	@(static) pick: int
	@(static) cancel: bool
	pick, cancel = index, cancelled
	switch d.kind {
	case .Info:
		dialog_call(&d, d.on_select, proc(L: ^lua_State, d: ^Plugin_Dialog) {
			if pick > 0 do lua_pushinteger(L, i64(pick))
			else do lua_pushnil(L)
		})
	case .Process:
		dialog_call(&d, d.on_end, proc(L: ^lua_State, d: ^Plugin_Dialog) {
			lua_pushboolean(L, cancel ? 1 : 0)
		})
	}
	dialog_free(&d)
}

// Input + progress polling for the front dialog. Called from handle_app_input.
handle_plugin_dialog_input :: proc() {
	d := &plugin_dialogs[0]
	if !d.opened do return
	switch d.kind {
	case .Info:
		n := len(d.options)
		if input.up || input.left {
			d.sel = (d.sel - 1 + n) % n
			sfx_click()
		}
		if input.down || input.right {
			d.sel = (d.sel + 1) % n
			sfx_click()
		}
		if input.confirm || d.clicked {
			if !d.clicked do sfx_click() // ui_button already clicked
			dialog_finish(d.sel + 1, false)
		} else if input.cancel || input.power {
			sfx_back()
			dialog_finish(0, false)
		}
	case .Process:
		if input.cancel || input.power || d.clicked {
			sfx_back()
			dialog_finish(0, true)
			return
		}
		poll_process(d)
	}
}

poll_process :: proc(d: ^Plugin_Dialog) {
	if d.progress == LUA_NOREF {
		dialog_finish(0, false)
		return
	}
	L := d.L
	top := lua_gettop(L)
	lua_rawgeti(L, LUA_REGISTRYINDEX, i64(d.progress))
	if lua_pcall(L, 0, 2, 0) != LUA_OK {
		msg := strings.clone(lua_string(L, -1), context.temp_allocator)
		lua_settop(L, top)
		plugin_logf("%s: progress: %s", d.title, msg)
		set_status("%s failed: %s", d.title, msg)
		dialog_finish(0, true)
		return
	}
	d.value = clamp(f32(lua_tonumberx(L, -2, nil)), 0, 1)
	if lua_type(L, -1) == LUA_TSTRING {
		delete(d.text)
		d.text = strings.clone(lua_string(L, -1))
	}
	lua_settop(L, top)
	if d.value >= 1 do dialog_finish(0, false)
}

draw_plugin_dialog :: proc(w, h: f32) {
	if len(plugin_dialogs) == 0 do return
	d := &plugin_dialogs[0]
	d.t = smooth_to(d.t, 1, 12)
	switch d.kind {
	case .Info:
		labels := make([dynamic]string, context.temp_allocator)
		for o in d.options do append(&labels, o)
		draw_info_dialog(d, labels[:], w, h)
		draw_hints(w, h, []Hint{{"A", "Select"}, {"B", "Close"}})
	case .Process:
		draw_process_dialog(d, w, h)
		draw_hints(w, h, []Hint{{"B", "Cancel"}})
	}
	d.opened = true
}

DIALOG_W :: 520
DIALOG_TEXT :: 17
DIALOG_LINE :: 24

draw_info_dialog :: proc(d: ^Plugin_Dialog, labels: []string, w, h: f32) {
	rl.DrawRectangle(0, 0, i32(w), i32(h), with_alpha(COL_SHADE, u8(150 * d.t)))
	lines := wrap_text(d.text, DIALOG_TEXT, DIALOG_W - 56)
	bh: f32 = 54
	gap: f32 = 10
	ph := 76 + f32(len(lines)) * DIALOG_LINE + 20 + f32(len(labels)) * (bh + gap) + 14
	s := 0.94 + 0.06 * d.t
	r := rl.Rectangle{(w - DIALOG_W * s) * 0.5, (h - ph * s) * 0.5, DIALOG_W * s, ph * s}
	draw_panel(r, false, with_alpha(COL_PANEL_SOLID, u8(244 * d.t)))
	if d.t < 0.5 do return
	draw_t_fit(d.title, r.x + 28, r.y + 26, r.width - 56, 22, COL_ACCENT, false)
	y := r.y + 70
	for line in lines {
		draw_t(line, r.x + 28, y, DIALOG_TEXT, COL_TEXT)
		y += DIALOG_LINE
	}
	y += 20
	for label, i in labels {
		br := rl.Rectangle{r.x + 24, y + f32(i) * (bh + gap), r.width - 48, bh}
		if ui_button(fmt.tprintf("pdlg-%d", i), br, label, i == d.sel, true) && d.opened {
			d.sel = i
			d.clicked = true
		}
	}
}

draw_process_dialog :: proc(d: ^Plugin_Dialog, w, h: f32) {
	d.shown = smooth_to(d.shown, d.value, 14)
	rl.DrawRectangle(0, 0, i32(w), i32(h), with_alpha(COL_SHADE, u8(150 * d.t)))
	pw: f32 = 560
	ph: f32 = 230
	r := rl.Rectangle{(w - pw) * 0.5, (h - ph) * 0.5, pw, ph}
	draw_panel(r, false, with_alpha(COL_PANEL_SOLID, u8(244 * d.t)))
	draw_t_fit(d.title, r.x + 28, r.y + 26, r.width - 56, 22, COL_ACCENT, false)
	draw_t_fit(d.text, r.x + 28, r.y + 66, r.width - 56 - 64, DIALOG_TEXT, COL_TEXT, false)
	draw_t_right(fmt.tprintf("%d%%", int(d.value * 100 + 0.5)), r.x + r.width - 28, r.y + 66, 17, COL_TEXT)
	bar := rl.Rectangle{r.x + 28, r.y + 104, r.width - 56, 10}
	rl.DrawRectangleRounded(bar, 1, 8, COL_FAINT)
	if d.shown > 0.001 {
		rl.DrawRectangleRounded({bar.x, bar.y, max(bar.height, bar.width * d.shown), bar.height}, 1, 8, COL_ACCENT)
	}
	if ui_button("pdlg-cancel", {r.x + 24, r.y + 146, r.width - 48, 54}, "Cancel", true, true) && d.opened {
		d.clicked = true
	}
}

// Greedy word wrap; explicit newlines are kept.
wrap_text :: proc(text: string, size, max_w: f32) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	para_it := text
	for para in strings.split_lines_iterator(&para_it) {
		line := ""
		words := para
		for word in strings.fields_iterator(&words) {
			try := line == "" ? word : fmt.tprintf("%s %s", line, word)
			if line != "" && measure_t(try, size) > max_w {
				append(&lines, line)
				line = word
			} else {
				line = try
			}
		}
		append(&lines, line)
	}
	return lines[:]
}

// ---------------------------------------------------------------------------
// Lua globals

dialog_new :: proc(L: ^lua_State, kind: Plugin_Dialog_Kind) -> Plugin_Dialog {
	d := Plugin_Dialog{kind = kind, L = L, on_select = LUA_NOREF, progress = LUA_NOREF, on_end = LUA_NOREF}
	p := plugin_for_state(L)
	d.title = strings.clone(p != nil ? p.name : "Plugin")
	d.text = strings.clone(lua_string(L, 1))
	return d
}

// Dialog_Info(text, options, on_select)
lua_dialog_info :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	d := dialog_new(L, .Info)
	if lua_type(L, 2) == LUA_TTABLE {
		n := int(lua_rawlen(L, 2))
		for i in 1 ..= n {
			lua_rawgeti(L, 2, i64(i))
			if lua_type(L, -1) == LUA_TSTRING || lua_type(L, -1) == LUA_TNUMBER {
				append(&d.options, strings.clone(lua_string(L, -1)))
			}
			lua_pop(L, 1)
		}
	}
	if len(d.options) == 0 do append(&d.options, strings.clone("OK"))
	d.on_select = dialog_ref_arg(L, 3)
	append(&plugin_dialogs, d)
	sfx_click()
	return 0
}

// Dialog_Process(text, progress, on_end)
lua_dialog_process :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	d := dialog_new(L, .Process)
	d.progress = dialog_ref_arg(L, 2)
	d.on_end = dialog_ref_arg(L, 3)
	append(&plugin_dialogs, d)
	return 0
}
