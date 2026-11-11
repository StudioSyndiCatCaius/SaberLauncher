package saber

// GET APPS page (APPS > Y): the store's apps as a card grid like APPS itself, with a Refresh
// tile at the end, and the focused app's details (screenshot, icon, description, actions) on the
// right. Art: the app's icon.png / `icon` URL; `thumb.png` / `thumb` URL is the screenshot.
// Apps without an icon get a coloured tile with their initials.

import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

APP_STORE_COLS :: 4

app_store_scroll: f32

// Selection: 0 ..< apps = an app, apps = the Refresh tile.
handle_app_store_input :: proc() {
	list := store_list(.App)
	n := len(list) + 1
	sel := &store.sel[.App]
	sel^ = clamp(sel^, 0, n - 1)
	if nav_grid(sel, n, APP_STORE_COLS) do store.armed = -1
	if input.confirm {
		app_store_activate(sel^)
	} else if input.action && sel^ < len(list) {
		app_store_remove_press(list[sel^])
	}
}

app_store_activate :: proc(i: int) {
	list := store_list(.App)
	if i >= len(list) {
		store_refresh()
		sfx_click()
		return
	}
	store_install(list[i])
}

// The focused app, nil on the Refresh tile.
app_store_selected :: proc() -> ^Store_Plugin {
	list := store_list(.App)
	i := store.sel[.App]
	return i >= 0 && i < len(list) ? &store.plugins[list[i]] : nil
}

app_store_action_label :: proc(p: ^Store_Plugin) -> string {
	st := store_plugin_status(p)
	switch {
	case p.state == .Installing:           return st
	case strings.has_prefix(st, "Update"): return "Update"
	case st == "Installed":                return p.link || app_store_linked(p) ? "Find again" : "Reinstall"
	case p.link:                           return "Find on PC"
	}
	return "Download"
}

draw_app_store :: proc(w, h: f32) {
	top := f32(HEADER_H + 28)
	draw_apps_tabs(top)
	grid_top := top + 36
	bottom := h - FOOTER_H - 20
	left_w := math.round(w * 0.6)
	area := rl.Rectangle{PAD, grid_top, left_w - PAD - 16, bottom - grid_top}
	detail := rl.Rectangle{left_w + 8, grid_top, w - left_w - 8 - PAD, area.height}

	list := store_list(.App)
	n := len(list) + 1
	sel := clamp(store.sel[.App], 0, n - 1)
	store.sel[.App] = sel

	gap: f32 = 18
	cell_w := (area.width - gap * f32(APP_STORE_COLS - 1)) / f32(APP_STORE_COLS)
	cell_h := cell_w + TITLE_STRIP + 16
	row_h := cell_h + gap
	// keep the focused row in view
	row_y := f32(sel / APP_STORE_COLS) * row_h
	target := app_store_scroll
	if row_y < target do target = row_y
	if row_y + cell_h + 10 > target + area.height do target = row_y + cell_h + 10 - area.height
	app_store_scroll = smooth_to(app_store_scroll, max(target, 0), 14)

	push_clip({0, area.y - 12, left_w, area.height + 12})
	for i in 0 ..< n {
		r := rl.Rectangle{
			area.x + f32(i % APP_STORE_COLS) * (cell_w + gap),
			area.y + f32(i / APP_STORE_COLS) * row_h - app_store_scroll,
			cell_w,
			cell_h,
		}
		if r.y + r.height < area.y - 12 || r.y > area.y + area.height do continue
		if mouse_over(r) {
			hover_enter(fmt.tprintf("store-app-%d", i))
			if rl.IsMouseButtonPressed(.LEFT) {
				if i == sel {
					app_store_activate(i)
				} else {
					store.sel[.App] = i
					store.armed = -1
					sfx_click()
				}
			}
		}
		if i < len(list) {
			draw_store_app_card(&store.plugins[list[i]], r, i == sel)
		} else {
			draw_store_refresh_card(r, i == sel)
		}
	}
	pop_clip()

	draw_app_store_detail(detail, sel < len(list) ? list[sel] : -1)
}

// Art rect inside a card, as draw_card lays it out.
card_art_rect :: proc(r: rl.Rectangle, hi: bool) -> rl.Rectangle {
	box := r
	if hi do box.y -= 6
	return {box.x + 8, box.y + 8, box.width - 16, box.height - 16 - TITLE_STRIP}
}

draw_store_app_card :: proc(p: ^Store_Plugin, r: rl.Rectangle, hi: bool) {
	st := store_plugin_status(p)
	badge := ""
	switch {
	case p.state == .Failed:               badge = "Failed"
	case strings.has_prefix(st, "Update"): badge = "Update"
	case p.link && st == "":               badge = "On your PC"
	}
	draw_card({tex = p.icon, has_tex = p.has_icon, title = p.name, contain = true, badge = badge}, r, hi)
	art := card_art_rect(r, hi)
	if !p.has_icon do draw_initials_tile(p.name, art)

	if p.state == .Installing {
		t := clamp(store_progress(p), 0, 1)
		rl.DrawRectangleRounded(art, roundness(art, RADIUS - 4), 6, with_alpha(COL_SHADE, 160))
		draw_t_center(fmt.tprintf("%d%%", int(t * 100)), art.x + art.width * 0.5, art.y + art.height * 0.5 - 18, 26, COL_TEXT)
		bar := rl.Rectangle{art.x + 16, art.y + art.height - 24, art.width - 32, 6}
		rl.DrawRectangleRounded(bar, 1, 6, with_alpha(COL_TINT, 40))
		if t > 0 do rl.DrawRectangleRounded({bar.x, bar.y, max(bar.height, bar.width * t), bar.height}, 1, 6, COL_STORE_OK)
	} else if store_is_installed(p) || p.state == .Installed {
		draw_store_badge(art.x + art.width - 20, art.y + 20, p)
	}
}

// Coloured tile (hue from the name) with the name's initials.
draw_initials_tile :: proc(name: string, art: rl.Rectangle) {
	h: u32 = 2166136261
	for i in 0 ..< len(name) do h = (h ~ u32(name[i])) * 16777619
	col := rl.ColorFromHSV(f32(h % 360), 0.45, 0.62)
	rl.DrawRectangleRounded(art, roundness(art, RADIUS - 4), 6, with_alpha(col, 210))
	initials := make([dynamic]u8, context.temp_allocator)
	for word in strings.fields(name, context.temp_allocator) {
		if len(initials) >= 2 do break
		append(&initials, word[0])
	}
	text := strings.to_upper(string(initials[:]), context.temp_allocator)
	size := min(art.height * 0.4, 72)
	draw_t_center(text, art.x + art.width * 0.5, art.y + (art.height - size) * 0.5, size, rl.WHITE)
}

draw_store_refresh_card :: proc(r: rl.Rectangle, hi: bool) {
	draw_card({title = "Refresh"}, r, hi)
	art := card_art_rect(r, hi)
	c := rl.Vector2{art.x + art.width * 0.5, art.y + art.height * 0.42}
	R := min(art.width, art.height) * 0.16
	spin := store.pending > 0 ? f32(rl.GetTime()) * 300 : 0
	col := hi ? COL_TEXT : COL_MUTED
	rl.DrawRing(c, R - 4, R, spin + 40, spin + 330, 32, col)
	// arrow head at the arc's end
	a := (spin + 40) * math.RAD_PER_DEG
	tip := rl.Vector2{c.x + math.cos(a) * (R - 2), c.y + math.sin(a) * (R - 2)}
	tang := rl.Vector2{-math.sin(a), math.cos(a)}
	rad := rl.Vector2{math.cos(a), math.sin(a)}
	rl.DrawTriangle(tip - tang * 9, tip + rad * 7, tip - rad * 7, col)
	rl.DrawTriangle(tip - tang * 9, tip - rad * 7, tip + rad * 7, col)
	draw_t_center(store.pending > 0 ? "Loading..." : "Reload the list", c.x, art.y + art.height * 0.72, 14, COL_MUTED)
}

draw_app_store_detail :: proc(r: rl.Rectangle, idx: int) {
	draw_panel(r, false, with_alpha(COL_PANEL_SOLID, 214))
	x := r.x + 28
	iw := r.width - 56
	y := r.y + 28

	if idx < 0 {
		draw_t("GET APPS", x, y, 28, COL_TEXT)
		y += 46
		for line in wrap_text("Apps from the GitHub repos in plugins/pluginrepos.txt. Downloaded apps go to APP/apps; apps like Steam are only looked up on this PC and linked.", 16, iw) {
			draw_t(line, x, y, 16, COL_TEXT)
			y += 24
		}
		y += 8
		draw_t_fit(store.message, x, y, iw, 15, COL_MUTED, false)
		y += 34
		for &repo, ri in store.repos {
			if y > r.y + r.height - 40 do break
			draw_t_fit(fmt.tprintf("%s/%s", repo.owner, repo.name), x, y, iw * 0.6, 16, COL_TEXT, false)
			count := 0
			for &p in store.plugins do if p.repo == ri && p.kind == .App do count += 1
			note := repo.err != "" ? repo.err : store.pending > 0 ? "..." : fmt.tprintf("%d app(s)", count)
			draw_t_fit(note, x + iw * 0.6, y, iw * 0.4, 16, repo.err != "" ? COL_ACCENT : COL_MUTED, false)
			y += 26
		}
		return
	}

	p := &store.plugins[idx]
	ICON :: 76
	// hero screenshot, faded into the panel; the icon overlaps its bottom edge
	if p.has_thumb {
		hero := rl.Rectangle{r.x + 10, r.y + 10, r.width - 20, min((r.width - 20) * 0.5625, r.height * 0.36)}
		push_clip(hero)
		draw_texture_cover(p.thumb, hero)
		fade := hero.height * 0.45
		rl.DrawRectangleGradientV(i32(hero.x), i32(hero.y + hero.height - fade), i32(hero.width), i32(fade) + 1, with_alpha(COL_PANEL_SOLID, 0), with_alpha(COL_PANEL_SOLID, 235))
		pop_clip()
		y = hero.y + hero.height - ICON * 0.5
	}
	icon := rl.Rectangle{x, y, ICON, ICON}
	if p.has_icon {
		rl.DrawRectangleRounded(icon, roundness(icon, 14), 8, with_alpha(COL_SHADE, 90))
		draw_texture_contain(p.icon, {icon.x + 6, icon.y + 6, icon.width - 12, icon.height - 12})
	} else {
		draw_initials_tile(p.name, icon)
	}
	tx := x + ICON + 18
	tw := iw - ICON - 18
	draw_t_fit(p.name, tx, y + 8, tw, 28, COL_TEXT, true)
	byline := make([dynamic]string, context.temp_allocator)
	if p.version != "" do append(&byline, fmt.tprintf("v%s", p.version))
	if p.author != "" do append(&byline, fmt.tprintf("by %s", p.author))
	draw_t_fit(strings.join(byline[:], "  ·  ", context.temp_allocator), tx, y + 46, tw, 15, COL_ACCENT, false)
	y += ICON + 20

	if p.description != "" {
		for line, i in wrap_text(p.description, 16, iw) {
			if i >= 5 do break
			draw_t(line, x, y, 16, COL_TEXT)
			y += 24
		}
		y += 10
	}

	kv :: proc(label, value: string, x: f32, y: ^f32, w: f32, col := COL_TEXT) {
		if value == "" do return
		draw_t(label, x, y^, 15, COL_MUTED)
		draw_t_fit(value, x + 110, y^ - 1, w - 110, 16, col, false)
		y^ += 28
	}
	linked := app_store_linked(p)
	switch {
	case p.link || linked: kv("Source", "Your installed copy (nothing is downloaded)", x, &y, iw)
	case:                  kv("Source", url_host(p.spec.download), x, &y, iw)
	}
	if !p.link && !linked do kv("Installs to", fmt.tprintf("APP/apps/%s", p.folder), x, &y, iw)
	if iv := app_store_installed_version(p); iv != "" do kv("Installed", fmt.tprintf("v%s", iv), x, &y, iw)
	else if app_store_installed(p) do kv("Installed", "Yes", x, &y, iw)
	kv("Repo", fmt.tprintf("%s/%s", store.repos[p.repo].owner, store.repos[p.repo].name), x, &y, iw, COL_MUTED)
	if p.state == .Failed && p.err != "" do kv("Error", p.err, x, &y, iw, COL_ACCENT)

	// actions, anchored to the bottom of the panel
	can_remove := p.state != .Installing && app_store_installed(p)
	rows := can_remove ? 2 : 1
	ay := max(y + 12, r.y + r.height - 24 - f32(rows) * (ACTION_ROW_H + 10) + 10)
	ar := rl.Rectangle{x, ay, iw, ACTION_ROW_H}
	label := app_store_action_label(p)
	draw_panel(ar, true)
	if p.state == .Installing {
		t := clamp(store_progress(p), 0, 1)
		rl.DrawRectangleRounded({ar.x + 2, ar.y + ar.height - 6, (ar.width - 4) * t, 4}, 1, 6, COL_STORE_OK)
	}
	draw_t_fit(label, ar.x + 18, ar.y + 9, iw - 150, 18, COL_TEXT, true)
	desc := p.link ? "Looks for it on this PC and adds it to APPS" : "Downloads the app and adds it to APPS"
	if !online_enabled() do desc = "Needs Online Mode (Settings)"
	draw_t_fit(desc, ar.x + 18, ar.y + 33, iw - 150, 14, COL_MUTED, false)
	if p.state != .Installing {
		draw_t_right(label, ar.x + ar.width - 44, ar.y + 19, 17, COL_TEXT)
		draw_glyph("A", ar.x + ar.width - 26, ar.y + ar.height * 0.5)
	}
	if mouse_over(ar) && rl.IsMouseButtonPressed(.LEFT) do store_install(idx)

	if can_remove {
		rr := rl.Rectangle{x, ar.y + ACTION_ROW_H + 10, iw, ACTION_ROW_H}
		armed := store.armed == idx
		draw_panel(rr, armed)
		draw_t_fit(armed ? "Press X again to remove" : "Remove", rr.x + 18, rr.y + 9, iw - 150, 18, armed ? COL_ACCENT : COL_TEXT, armed)
		rm := linked ? fmt.tprintf("Removes the APPS card only (%s stays installed)", p.name) : fmt.tprintf("Deletes APP/apps/%s and its APPS card", p.folder)
		draw_t_fit(rm, rr.x + 18, rr.y + 33, iw - 150, 14, COL_MUTED, false)
		draw_t_right("Remove", rr.x + rr.width - 44, rr.y + 19, 17, COL_TEXT)
		draw_glyph("X", rr.x + rr.width - 26, rr.y + rr.height * 0.5)
		if mouse_over(rr) && rl.IsMouseButtonPressed(.LEFT) do app_store_remove_press(idx)
	}
}
