package saber

// Plugin views: a full-screen page a Lua plugin draws itself, immediate-mode style.
//
//   UI_Open(frame [, on_close])   opens the view; frame() runs once per frame and calls the UI_ widgets
//                                 below, top to bottom. B / Esc closes it (unless a search bar is typing),
//                                 then on_close() runs. Opening another view replaces the current one.
//   UI_Close()                    closes it (takes effect after the current frame).
//   Play_Rom(path [, platform])   plays a ROM file in Saber's libretro host right after this frame
//                                 (platform from the extension unless given, e.g. "nes"). Works anywhere.
//
// Widgets (only inside frame):
//   UI_Title(text [, sub])
//   UI_Text(text [, color])       color: "muted" (default) | "text" | "accent" | "warn"
//   text, changed, submitted = UI_SearchBar(id, text [, placeholder])
//       A / Enter / click starts typing: the keyboard types directly, a pad gets an on-screen keyboard
//       (A type, X delete, Y space, B done). Enter / Esc / Done stops typing (submitted = true then).
//   picked, focused = UI_Grid(id, count, opts, tile)
//       a scrolling tile grid filling the rest of the page. tile(i) is called only for the visible
//       tiles and returns { title=, sub=, image=<png/jpg path>, badge=, progress=0..1 }.
//       opts: { cols = 6, aspect = 1.0 (art height / width) }. picked = the 1-based index activated
//       this frame (A / click on the selected tile), else nil; focused = the selected index (nil if empty).
//       The selection resets to the first tile whenever count changes.
//   UI_Hints({ {"A", "Play"}, {"B", "Close"} })   footer hints for this frame.
//
// Up / Down move between widgets; images are loaded a few per frame and cached until the view closes.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

View_Grid :: struct {
	sel:    int,
	count:  int,
	scroll: f32,
	target: f32,
	follow: bool,
}

View_Image :: struct {
	tex:  rl.Texture2D,
	ok:   bool,
	used: u64, // frame it was last drawn
}

Plugin_View :: struct {
	open:      bool,
	t:         f32,
	L:         ^lua_State,
	frame:     c.int, // registry refs
	on_close:  c.int,
	name:      string, // plugin name (heap)
	close_req: bool,
	in_frame:  bool,
	inp:        Input, // this frame's input, stashed by plugin_view_input
	focus:     string, // id of the focused widget (heap)
	order:     [dynamic]string, // focusable ids drawn this frame (temp strings)
	move:      int, // -1 / +1: focus the previous / next widget after the frame
	// search bar typing
	editing:   bool,
	edit_new:  bool, // typing started this frame: skip the key that started it
	osk:       bool, // on-screen keyboard (pad)
	osk_sel:   int,
	osk_bar:   Maybe(rl.Rectangle), // search bar typing with the on-screen keyboard: drawn after the frame, on top
	// layout of the current frame
	x, y, w:   f32,
	bottom:    f32,
	hints:     [dynamic]Hint, // temp
	grids:     map[string]View_Grid,
	images:    map[string]View_Image,
	loads:     int,
	frames:    u64,
	play:      string, // Play_Rom path (heap), started by handle_app_input
	play_plat: string,
}

pview: Plugin_View

// The Game a plugin's Play_Rom builds (kept for the session's splash, records and art).
plugin_rom_game: Game

plugin_view_input :: proc() {
	pview.inp = input
	if pview.editing && !pview.osk do pview.inp = {} // the keyboard is typing: WASD, Backspace, Esc are text keys
	if pview.editing do return
	if input.cancel || input.power {
		sfx_back()
		pview.close_req = true
	}
}

plugin_view_open :: proc(L: ^lua_State, frame, on_close: c.int) {
	plugin_view_close()
	p := plugin_for_state(L)
	pview.open = true
	pview.L = L
	pview.frame = frame
	pview.on_close = on_close
	pview.name = strings.clone(p != nil ? p.name : "Plugin")
	sfx_click()
}

// Closes the view now (outside a frame): on_close runs, images are freed.
plugin_view_close :: proc() {
	if !pview.open && pview.L == nil do return
	L := pview.L
	on_close := pview.on_close
	pview.open = false
	pview.close_req = false
	pview.editing = false
	if L != nil {
		if pview.frame != LUA_NOREF do luaL_unref(L, LUA_REGISTRYINDEX, pview.frame)
		if on_close != LUA_NOREF {
			lua_rawgeti(L, LUA_REGISTRYINDEX, i64(on_close))
			if lua_pcall(L, 0, 0, 0) != LUA_OK {
				plugin_logf("%s: UI on_close: %s", pview.name, lua_string(L, -1))
				lua_pop(L, 1)
			}
			luaL_unref(L, LUA_REGISTRYINDEX, on_close)
		}
	}
	pview.L = nil
	pview.frame, pview.on_close = LUA_NOREF, LUA_NOREF
	delete(pview.name)
	delete(pview.focus)
	pview.name, pview.focus = "", ""
	for k in pview.grids do delete(k)
	clear(&pview.grids)
	for k, img in pview.images {
		if img.ok do rl.UnloadTexture(img.tex)
		delete(k)
	}
	clear(&pview.images)
	eat_input()
}

// A plugin's Lua state is about to close.
plugin_view_forget :: proc(L: ^lua_State) {
	if pview.L != L do return
	pview.on_close = LUA_NOREF // don't call into a state that's going away
	plugin_view_close()
}

// Play_Rom's request, run by handle_app_input outside drawing (the game session blocks).
plugin_view_play_pending :: proc() -> bool {
	if pview.play == "" do return false
	path, plat_name := pview.play, pview.play_plat
	defer {
		delete(path)
		delete(plat_name)
	}
	pview.play, pview.play_plat = "", ""
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {
		set_status("Couldn't find %s", path)
		return true
	}
	plat, ok := rom_platform(ascii_lower(filepath.ext(path), context.temp_allocator))
	if plat_name != "" {
		ok = false
		for p in Retro_Platform do if p != .None && eq_fold(RETRO_PLATFORM_DIR[p], plat_name) {
			plat, ok = p, true
		}
	}
	if !ok {
		set_status("%s isn't a ROM Saber can play", filepath.base(path))
		return true
	}
	if plugin_rom_game.rom_path != "" do game_unload_art(&plugin_rom_game)
	plugin_rom_game = rom_game(fi, pview.name != "" ? pview.name : "Plugin", plat)
	game_load_art(&plugin_rom_game)
	play_game(&plugin_rom_game)
	return true
}

// Registers a focusable widget; true when it has the focus.
view_focusable :: proc(id: string) -> bool {
	append(&pview.order, strings.clone(id, context.temp_allocator))
	if pview.focus == "" {
		pview.focus = strings.clone(id)
	}
	return pview.focus == id
}

view_set_focus :: proc(id: string) {
	if pview.focus == id do return
	delete(pview.focus)
	pview.focus = strings.clone(id)
	pview.editing = false
}

// Cached texture of an image file; a few are loaded per frame.
view_image :: proc(path: string) -> (rl.Texture2D, bool) {
	if path == "" do return {}, false
	if img, found := &pview.images[path]; found {
		img.used = pview.frames
		return img.tex, img.ok
	}
	if pview.loads >= 4 do return {}, false
	pview.loads += 1
	tex, ok := load_texture_smooth(path, 384)
	pview.images[strings.clone(path)] = {tex, ok, pview.frames}
	return tex, ok
}

// Drops images not drawn for a while once the cache gets big.
view_images_trim :: proc() {
	if len(pview.images) < 400 do return
	old := make([dynamic]string, context.temp_allocator)
	for k, img in pview.images do if pview.frames - img.used > 300 do append(&old, k)
	for k in old {
		img := pview.images[k]
		if img.ok do rl.UnloadTexture(img.tex)
		delete_key(&pview.images, k)
		delete(k)
	}
}

draw_plugin_view :: proc(w, h: f32) {
	if !modal_fade(&pview.t, pview.open) do return
	page := rl.Rectangle{0, HEADER_H, w, h - HEADER_H - FOOTER_H}
	r := modal_panel(page, w - 48, page.height - 32, pview.t)
	if pview.t < 0.5 || !pview.open do return

	pview.x = r.x + 28
	pview.y = r.y + 24
	pview.w = r.width - 56
	pview.bottom = r.y + r.height - 20
	pview.order = make([dynamic]string, context.temp_allocator)
	pview.hints = make([dynamic]Hint, context.temp_allocator)
	pview.move = 0
	pview.loads = 0
	pview.osk_bar = nil

	L := pview.L
	top := lua_gettop(L)
	pview.in_frame = true
	lua_rawgeti(L, LUA_REGISTRYINDEX, i64(pview.frame))
	if lua_pcall(L, 0, 0, 0) != LUA_OK {
		msg := lua_string(L, -1)
		plugin_logf("%s: UI frame: %s", pview.name, msg)
		set_status("%s: %s", pview.name, msg)
		pview.close_req = true
	}
	lua_settop(L, top)
	pview.in_frame = false
	if bar, ok := pview.osk_bar.?; ok && pview.editing && pview.osk do draw_osk(bar)
	pview.inp = {}
	pview.frames += 1
	pview.edit_new = false

	// focus: step between widgets, or fall back to the first one
	at := -1
	for id, i in pview.order do if id == pview.focus do at = i
	if len(pview.order) > 0 {
		if at < 0 {
			view_set_focus(pview.order[0])
		} else if pview.move != 0 {
			next := clamp(at + pview.move, 0, len(pview.order) - 1)
			if next != at {
				view_set_focus(pview.order[next])
				sfx_click()
			}
		}
	}

	if len(pview.hints) > 0 {
		draw_hints(w, h, pview.hints[:])
	} else if pview.editing && pview.osk {
		draw_hints(w, h, []Hint{{"A", "Type"}, {"X", "Delete"}, {"Y", "Space"}, {"B", "Done"}})
	} else if pview.editing {
		draw_hints(w, h, []Hint{{"Enter", "Done"}})
	} else {
		draw_hints(w, h, []Hint{{"A", "Select"}, {"B", "Close"}})
	}

	if pview.close_req do plugin_view_close()
	else do view_images_trim()
}

// ---------------------------------------------------------------------------
// Search bar

OSK_ROWS :: [4]string{"1234567890", "QWERTYUIOP", "ASDFGHJKL-", "ZXCVBNM'.&"}
OSK_SPACE :: 40
OSK_DEL :: 41
OSK_DONE :: 42

// Moves the on-screen keyboard selection (40 character keys, then Space / Delete / Done).
osk_nav :: proc(sel: int, dx, dy: int) -> int {
	row, col: int
	if sel < 40 {
		row, col = sel / 10, sel % 10
	} else {
		cols := [3]int{1, 5, 8}
		row, col = 4, cols[sel - 40]
	}
	if dy != 0 do row = clamp(row + dy, 0, 4)
	if dx != 0 {
		if row == 4 {
			k := clamp(sel - 40 + dx, 0, 2) if sel >= 40 else 0
			return 40 + k
		}
		col = cycle(col, dx, 10)
	}
	if row == 4 do return col < 4 ? OSK_SPACE : col < 7 ? OSK_DEL : OSK_DONE
	return row * 10 + col
}

search_backspace :: proc(text: string) -> string {
	if text == "" do return text
	_, n := utf8.decode_last_rune_in_string(text)
	return text[:len(text) - n]
}

lua_ui_search_bar :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !view_in_frame(L) do return view_frame_error(L, "UI_SearchBar")
	id := strings.clone(lua_string(L, 1), context.temp_allocator)
	text := strings.clone(lua_string(L, 2), context.temp_allocator)
	placeholder := lua_type(L, 3) == LUA_TSTRING ? strings.clone(lua_string(L, 3), context.temp_allocator) : "Search"
	r := rl.Rectangle{pview.x, pview.y, pview.w, 56}
	pview.y += 56 + 18
	focused := view_focusable(id)
	inp := pview.inp
	old := text
	submitted := false

	if mouse_over(r, true) {
		hover_enter(fmt.tprintf("pview-%s", id))
		if rl.IsMouseButtonPressed(.LEFT) && !(focused && pview.editing) {
			view_set_focus(id)
			focused = true
			pview.editing, pview.edit_new, pview.osk = true, true, false
			sfx_click()
		}
	} else if focused && pview.editing && !pview.osk && rl.IsMouseButtonPressed(.LEFT) {
		pview.editing = false
		submitted = true
	}

	if focused && !pview.editing {
		switch {
		case inp.confirm:
			pview.editing, pview.edit_new, pview.osk = true, true, inp.using_pad
			pview.osk_sel = 0
			sfx_click()
		case inp.down: pview.move = 1
		case inp.up:   pview.move = -1
		}
	} else if focused && pview.editing && !pview.edit_new {
		// keyboard
		for ch := rl.GetCharPressed(); ch != 0; ch = rl.GetCharPressed() {
			if ch < 32 do continue
			text = fmt.tprintf("%s%c", text, ch)
			pview.osk = false
		}
		if rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE) {
			text = search_backspace(text)
			pview.osk = false
		}
		if (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)) && rl.IsKeyPressed(.V) {
			if clip := rl.GetClipboardText(); clip != nil do text = fmt.tprintf("%s%s", text, strings.trim_space(string(clip)))
		}
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) || rl.IsKeyPressed(.ESCAPE) {
			pview.editing = false
			submitted = true
			sfx_click()
		}
		// pad: on-screen keyboard
		if pview.editing && pview.osk {
			dx := int(inp.right) - int(inp.left)
			dy := int(inp.down) - int(inp.up)
			if dx != 0 || dy != 0 {
				pview.osk_sel = osk_nav(pview.osk_sel, dx, dy)
				sfx_click()
			}
			switch {
			case inp.cancel || inp.power || (inp.confirm && pview.osk_sel == OSK_DONE):
				pview.editing = false
				submitted = true
				sfx_back()
			case inp.action || (inp.confirm && pview.osk_sel == OSK_DEL):
				text = search_backspace(text)
				sfx_click()
			case inp.extra || (inp.confirm && pview.osk_sel == OSK_SPACE):
				text = fmt.tprintf("%s ", text)
				sfx_click()
			case inp.confirm:
				rows := OSK_ROWS
				ch := rows[pview.osk_sel / 10][pview.osk_sel % 10]
				if ch >= 'A' && ch <= 'Z' do ch += 'a' - 'A'
				text = fmt.tprintf("%s%c", text, ch)
				sfx_click()
			}
		}
	}

	// draw
	editing := focused && pview.editing
	if editing || focused {
		draw_glass(r, r.height * 0.5, mix_color(COL_PANEL_HI, COL_ACCENT, 0.2), 0.45, COL_ACCENT, editing ? 0.9 : 0.6, refract = 4)
	} else {
		draw_glass(r, r.height * 0.5, COL_PANEL_SOLID, 0.4, refract = 4)
	}
	icon_col := focused ? COL_TEXT : COL_MUTED
	c0 := rl.Vector2{r.x + 32, r.y + r.height * 0.5 - 2}
	rl.DrawRing(c0, 7, 9.5, 0, 360, 24, icon_col)
	rl.DrawLineEx(c0 + {6, 6}, c0 + {13, 13}, 3, icon_col)
	tx := r.x + 60
	tw := r.width - 60 - 24
	if text == "" {
		draw_t_fit(placeholder, tx, r.y + (r.height - 20) * 0.5, tw, 20, COL_MUTED, false)
	} else {
		// keep the end of a long query in view
		shown := text
		for len(shown) > 0 && measure_t(shown, 20) > tw - 12 {
			_, n := utf8.decode_rune_in_string(shown)
			shown = shown[n:]
		}
		draw_t(shown, tx, r.y + (r.height - 20) * 0.5, 20, COL_TEXT)
		tx += measure_t(shown, 20)
	}
	if editing && int(rl.GetTime() * 2) % 2 == 0 {
		rl.DrawRectangleRec({text == "" ? r.x + 60 : tx + 2, r.y + 16, 2, r.height - 32}, COL_ACCENT)
	}
	if editing && pview.osk do pview.osk_bar = r

	lua_pushstring(L, strings.clone_to_cstring(text, context.temp_allocator))
	lua_pushboolean(L, text != old ? 1 : 0)
	lua_pushboolean(L, submitted ? 1 : 0)
	return 3
}

// On-screen keyboard, floating under the search bar (over whatever is below it).
draw_osk :: proc(bar: rl.Rectangle) {
	KEY :: 54
	GAP :: 8
	kw := f32(10 * KEY + 9 * GAP)
	r := rl.Rectangle{bar.x + (bar.width - kw - 40) * 0.5, bar.y + bar.height + 12, kw + 40, 5 * KEY + 4 * GAP + 40}
	draw_soft_shadow(r, RADIUS, 1.4)
	draw_glass(r, RADIUS, COL_PANEL_SOLID, 0.85, COL_ACCENT, 0.3, refract = 2)
	rows := OSK_ROWS
	key :: proc(kr: rl.Rectangle, label: string, hot: bool) {
		if hot {
			draw_glass(kr, 12, mix_color(COL_PANEL_HI, COL_ACCENT, 0.35), 0.5, COL_ACCENT, 0.8, refract = 2)
		} else {
			rl.DrawRectangleRounded(kr, roundness(kr, 12), 6, with_alpha(COL_TINT, 22))
		}
		draw_t_center(label, kr.x + kr.width * 0.5, kr.y + (kr.height - 20) * 0.5, 20, hot ? COL_TEXT : COL_MUTED)
	}
	for row, ri in rows {
		for i in 0 ..< len(row) {
			kr := rl.Rectangle{r.x + 20 + f32(i) * (KEY + GAP), r.y + 20 + f32(ri) * (KEY + GAP), KEY, KEY}
			key(kr, row[i:i + 1], pview.osk_sel == ri * 10 + i)
		}
	}
	y := r.y + 20 + 4 * (KEY + GAP)
	x := r.x + 20
	spans := [3]int{4, 3, 3}
	labels := [3]string{"Space", "Delete", "Done"}
	for span, i in spans {
		kw := f32(span) * (KEY + GAP) - GAP
		key({x, y, kw, KEY}, labels[i], pview.osk_sel == 40 + i)
		x += kw + GAP
	}
}

// ---------------------------------------------------------------------------
// Grid

lua_ui_grid :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !view_in_frame(L) do return view_frame_error(L, "UI_Grid")
	id := strings.clone(lua_string(L, 1), context.temp_allocator)
	count := max(int(lua_tonumberx(L, 2, nil)), 0)
	cols := 6
	aspect: f32 = 1
	if lua_type(L, 3) == LUA_TTABLE {
		if lua_getfield(L, 3, "cols") == LUA_TNUMBER do cols = clamp(int(lua_tonumberx(L, -1, nil)), 1, 16)
		lua_pop(L, 1)
		if lua_getfield(L, 3, "aspect") == LUA_TNUMBER do aspect = clamp(f32(lua_tonumberx(L, -1, nil)), 0.3, 3)
		lua_pop(L, 1)
	}
	has_fn := lua_type(L, 4) == LUA_TFUNCTION

	area := rl.Rectangle{pview.x, pview.y, pview.w, pview.bottom - pview.y}
	pview.y = pview.bottom
	focused := view_focusable(id)
	gs, found := &pview.grids[id]
	if !found {
		pview.grids[strings.clone(id)] = {}
		gs = &pview.grids[id]
	}
	if gs.count != count {
		gs^ = {count = count}
	}
	inp := pview.inp
	picked := -1
	if focused && !pview.editing {
		if count > 0 {
			i := clamp(gs.sel, 0, count - 1)
			if inp.left && i % cols > 0 do i -= 1
			if inp.right && i + 1 < count && (i + 1) % cols != 0 do i += 1
			if inp.up {
				if i - cols >= 0 do i -= cols
				else do pview.move = -1
			}
			if inp.down {
				if i + cols < count do i += cols
				else if i / cols < (count - 1) / cols do i = count - 1
			}
			if i != gs.sel {
				gs.sel = i
				gs.follow = true
				sfx_click()
			}
			if inp.confirm do picked = gs.sel
		} else if inp.up {
			pview.move = -1
		}
	}

	gap: f32 = 18
	sb: f32 = 14 // scrollbar lane
	cell_w := (area.width - sb - gap * f32(cols - 1)) / f32(cols)
	art_h := (cell_w - 16) * aspect
	cell_h := art_h + 16 + TITLE_STRIP
	row_h := cell_h + gap
	rows := (count + cols - 1) / cols
	content := f32(rows) * row_h - gap
	max_scroll := max(content - area.height + 12, 0)

	if mouse_over(area, true) {
		if wheel := rl.GetMouseWheelMove(); wheel != 0 {
			gs.target -= wheel * row_h * 0.6
			gs.follow = false
		}
	}
	if gs.follow {
		row_y := f32(gs.sel / cols) * row_h
		if row_y < gs.target do gs.target = row_y
		if row_y + cell_h + 12 > gs.target + area.height do gs.target = row_y + cell_h + 12 - area.height
	}
	gs.target = clamp(gs.target, 0, max_scroll)
	gs.scroll = smooth_to(gs.scroll, gs.target, 14)

	push_clip({area.x - 16, area.y - 10, area.width + 32, area.height + 10})
	first_row := max(int((gs.scroll - 10) / row_h), 0)
	last_row := min(int((gs.scroll + area.height) / row_h) + 1, rows)
	for i in first_row * cols ..< min(last_row * cols, count) {
		r := rl.Rectangle{
			area.x + f32(i % cols) * (cell_w + gap),
			area.y + 6 + f32(i / cols) * row_h - gs.scroll,
			cell_w,
			cell_h,
		}
		if r.y + r.height < area.y - 10 || r.y > area.y + area.height do continue
		hi := focused && i == gs.sel
		if !(pview.editing && pview.osk) && mouse_over(r, true) && mouse_over(area, true) {
			hover_enter(fmt.tprintf("pview-%s-%d", id, i))
			if rl.IsMouseButtonPressed(.LEFT) {
				if hi {
					picked = i
				} else {
					view_set_focus(id)
					gs.sel = i
					sfx_click()
				}
			}
		}
		title, sub, image, badge: string
		progress: f32 = -1
		if has_fn {
			lua_pushvalue(L, 4)
			lua_pushinteger(L, i64(i + 1))
			if lua_pcall(L, 1, 1, 0) != LUA_OK {
				pop_clip()
				return lua_error(L) // the frame's pcall reports it
			}
			if lua_type(L, -1) == LUA_TTABLE {
				title = lua_field_string(L, -1, "title")
				sub = lua_field_string(L, -1, "sub")
				image = lua_field_string(L, -1, "image")
				badge = lua_field_string(L, -1, "badge")
				if lua_getfield(L, -1, "progress") == LUA_TNUMBER do progress = f32(lua_tonumberx(L, -1, nil))
				lua_pop(L, 1)
			}
			lua_pop(L, 1)
		}
		tex, has_tex := view_image(image)
		draw_card({tex = tex, has_tex = has_tex, title = title, contain = true, badge = badge, tag = sub}, r, hi)
		art := card_art_rect(r, hi)
		if !has_tex do draw_initials_tile(title, art)
		if progress >= 0 {
			t := clamp(progress, 0, 1)
			rl.DrawRectangleRounded(art, roundness(art, RADIUS - 4), 6, with_alpha(COL_SHADE, 160))
			bar := rl.Rectangle{art.x + 14, art.y + art.height - 22, art.width - 28, 6}
			rl.DrawRectangleRounded(bar, 1, 6, with_alpha(COL_TINT, 40))
			if t > 0 {
				rl.DrawRectangleRounded({bar.x, bar.y, max(bar.height, bar.width * t), bar.height}, 1, 6, COL_ACCENT)
			} else { // unknown: a sliding segment
				s := f32(rl.GetTime()) * 1.2
				f := s - f32(int(s))
				rl.DrawRectangleRounded({bar.x + (bar.width - bar.width * 0.3) * f, bar.y, bar.width * 0.3, bar.height}, 1, 6, COL_ACCENT)
			}
		}
	}
	pop_clip()
	if rows > 0 {
		vis := area.height / row_h
		if f32(rows) > vis {
			track := rl.Rectangle{area.x + area.width - 4, area.y, 4, area.height}
			rl.DrawRectangleRounded(track, 1, 4, COL_FAINT)
			th := max(track.height * vis / f32(rows), 24)
			ty := track.y + (track.height - th) * (max_scroll > 0 ? gs.scroll / max_scroll : 0)
			rl.DrawRectangleRounded({track.x, ty, track.width, th}, 1, 4, COL_ACCENT)
		}
	}

	if picked >= 0 {
		sfx_click()
		lua_pushinteger(L, i64(picked + 1))
	} else {
		lua_pushnil(L)
	}
	if count > 0 do lua_pushinteger(L, i64(gs.sel + 1))
	else do lua_pushnil(L)
	return 2
}

// ---------------------------------------------------------------------------
// Other Lua globals

view_in_frame :: proc(L: ^lua_State) -> bool {
	return pview.in_frame && pview.L == L
}

view_frame_error :: proc(L: ^lua_State, name: string) -> c.int {
	lua_pushstring(L, strings.clone_to_cstring(fmt.tprintf("%s: only works inside the UI_Open frame function", name), context.temp_allocator))
	return lua_error(L)
}

// UI_Open(frame [, on_close])
lua_ui_open :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if lua_type(L, 1) != LUA_TFUNCTION {
		lua_pushstring(L, "UI_Open: frame must be a function")
		return lua_error(L)
	}
	if pview.in_frame {
		lua_pushstring(L, "UI_Open: can't open a view from inside a frame")
		return lua_error(L)
	}
	plugin_view_open(L, dialog_ref_arg(L, 1), dialog_ref_arg(L, 2))
	return 0
}

lua_ui_close :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if pview.L == L do pview.close_req = true
	if !pview.in_frame && pview.L == L do plugin_view_close()
	return 0
}

// UI_Title(text [, sub])
lua_ui_title :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !view_in_frame(L) do return view_frame_error(L, "UI_Title")
	draw_t_fit(lua_string(L, 1), pview.x, pview.y, pview.w, 28, COL_TEXT, true)
	pview.y += 40
	if lua_type(L, 2) == LUA_TSTRING || lua_type(L, 2) == LUA_TNUMBER {
		draw_t_fit(lua_string(L, 2), pview.x, pview.y, pview.w, 15, COL_MUTED, false)
		pview.y += 26
	}
	pview.y += 10
	return 0
}

// UI_Text(text [, color])
lua_ui_text :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !view_in_frame(L) do return view_frame_error(L, "UI_Text")
	col := COL_MUTED
	switch lua_string(L, 2) {
	case "text":   col = COL_TEXT
	case "accent": col = COL_ACCENT
	case "warn":   col = COL_WARN
	}
	for line in wrap_text(lua_string(L, 1), 17, pview.w) {
		draw_t(line, pview.x, pview.y, 17, col)
		pview.y += 24
	}
	pview.y += 8
	return 0
}

// UI_Hints({ {"A", "Play"}, ... })
lua_ui_hints :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !view_in_frame(L) do return view_frame_error(L, "UI_Hints")
	if lua_type(L, 1) != LUA_TTABLE do return 0
	clear(&pview.hints)
	for i in 1 ..= int(lua_rawlen(L, 1)) {
		if lua_rawgeti(L, 1, i64(i)) == LUA_TTABLE {
			lua_rawgeti(L, -1, 1)
			b := strings.clone(lua_string(L, -1), context.temp_allocator)
			lua_pop(L, 1)
			lua_rawgeti(L, -1, 2)
			label := strings.clone(lua_string(L, -1), context.temp_allocator)
			lua_pop(L, 1)
			if b != "" do append(&pview.hints, Hint{b, label})
		}
		lua_pop(L, 1)
	}
	return 0
}

// Play_Rom(path [, platform])
lua_play_rom :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	path := lua_plugin_path(L, lua_string(L, 1))
	if path == "" {
		lua_pushstring(L, "Play_Rom: missing path")
		return lua_error(L)
	}
	delete(pview.play)
	delete(pview.play_plat)
	pview.play = strings.clone(path)
	pview.play_plat = strings.clone(lua_string(L, 2))
	return 0
}
