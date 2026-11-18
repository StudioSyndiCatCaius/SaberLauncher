package saber

import "core:fmt"
import rl "vendor:raylib"

// Settings > Background: A / click opens a tile grid of every image in bkg_dir.
// Thumbnails load a few per frame and are freed when the picker closes.

BKG_COLS :: 4

bkg_picker: struct {
	open:   bool,
	sel:    int,
	t:      f32,
	scroll: f32,
	thumbs: [dynamic]rl.Texture2D,
	tried:  [dynamic]bool,
	loaded: [dynamic]bool,
}

bkg_picker_open :: proc() {
	if len(theme.bkg_files) == 0 {
		set_status("No images in APP/assets/bkg")
		return
	}
	bkg_picker_free()
	n := len(theme.bkg_files)
	resize(&bkg_picker.thumbs, n)
	resize(&bkg_picker.tried, n)
	resize(&bkg_picker.loaded, n)
	bkg_picker.open = true
	bkg_picker.sel = index_of_name(theme.bkg_files[:], app.settings.bkg)
	bkg_picker.t = 0
	bkg_picker.scroll = -1
	app.settings_focus = int(Settings_Row.Wallpaper)
	sfx_click()
}

bkg_picker_close :: proc() {
	bkg_picker.open = false
	sfx_back()
}

bkg_picker_free :: proc() {
	for &tex, i in bkg_picker.thumbs do unload_tex(&tex, &bkg_picker.loaded[i])
	clear(&bkg_picker.thumbs)
	clear(&bkg_picker.tried)
	clear(&bkg_picker.loaded)
}

bkg_picker_pick :: proc(i: int) {
	if i < 0 || i >= len(theme.bkg_files) do return
	theme_apply_bkg(theme.bkg_files[i])
	save_settings()
	sfx_click()
	bkg_picker.open = false
}

bkg_picker_input :: proc() {
	if input.cancel || input.power {
		bkg_picker_close()
		return
	}
	nav_grid(&bkg_picker.sel, len(theme.bkg_files), BKG_COLS)
	if input.confirm do bkg_picker_pick(bkg_picker.sel)
}

bkg_picker_draw :: proc(w, h: f32) {
	if !modal_fade(&bkg_picker.t, bkg_picker.open, 18) {
		if len(bkg_picker.thumbs) > 0 do bkg_picker_free()
		return
	}
	t := bkg_picker.t
	r := modal_panel({0, 0, w, h}, min(w - PAD * 2, 1200), h - HEADER_H - FOOTER_H - 20, t)
	if t < 0.5 do return

	draw_t("Background", r.x + 28, r.y + 22, 26, COL_TEXT)
	draw_t(fmt.tprintf("%d images in APP/assets/bkg", len(theme.bkg_files)), r.x + 28, r.y + 56, 15, COL_MUTED)

	n := len(theme.bkg_files)
	if len(bkg_picker.thumbs) != n do return // list changed under us; reopen to refresh
	gap: f32 = 16
	grid := rl.Rectangle{r.x + 24, r.y + 92, r.width - 48, r.height - 92 - 20}
	tw := (grid.width - gap * f32(BKG_COLS - 1)) / BKG_COLS
	th := tw * 9 / 16
	label_h: f32 = 26
	step := th + label_h + gap
	rows := (n + BKG_COLS - 1) / BKG_COLS
	content := f32(rows) * step - gap

	// keep the selected row visible; the mouse wheel scrolls too
	sel_y := f32(bkg_picker.sel / BKG_COLS) * step
	target := bkg_picker.scroll < 0 ? sel_y - (grid.height - step) * 0.5 : bkg_picker.scroll
	if bkg_picker.open && mouse_over(grid, true) {
		if wheel := rl.GetMouseWheelMove(); wheel != 0 do target -= wheel * step * 0.5
	}
	if input.using_pad || bkg_picker.scroll < 0 {
		if sel_y < target do target = sel_y
		if sel_y + step - gap > target + grid.height do target = sel_y + step - gap - grid.height
	}
	target = clamp(target, 0, max(content - grid.height, 0))
	bkg_picker.scroll = bkg_picker.scroll < 0 ? target : smooth_to(bkg_picker.scroll, target, 14)

	push_clip(grid)
	loads := 0
	clicked_inside := false
	for name, i in theme.bkg_files {
		col, row := i % BKG_COLS, i / BKG_COLS
		tile := rl.Rectangle{grid.x + f32(col) * (tw + gap), grid.y + f32(row) * step - bkg_picker.scroll, tw, th}
		if tile.y + th + label_h < grid.y || tile.y > grid.y + grid.height do continue
		if !bkg_picker.tried[i] && loads < 2 {
			bkg_picker.tried[i] = true
			bkg_picker.thumbs[i], bkg_picker.loaded[i] = load_texture_smooth(tjoin({theme.bkg_dir, name}), 480)
			loads += 1
		}
		hit := rl.Rectangle{tile.x, tile.y, tw, th + label_h}
		if bkg_picker.open && mouse_over(grid, true) && mouse_over(hit, true) {
			clicked_inside = true
			if list_row_mouse("bkgpick", i, hit, &bkg_picker.sel) do bkg_picker_pick(i)
		}
		focused := i == bkg_picker.sel
		current := eq_fold(name, app.settings.bkg)
		draw_panel(tile, focused)
		if bkg_picker.loaded[i] {
			draw_texture_cover(bkg_picker.thumbs[i], {tile.x + 4, tile.y + 4, tw - 8, th - 8})
		} else {
			draw_t_center("...", tile.x + tw * 0.5, tile.y + th * 0.5 - 10, 18, COL_MUTED)
		}
		if focused do rl.DrawRectangleRoundedLinesEx(tile, 0.08, 6, 3, COL_ACCENT)
		if current {
			rl.DrawCircleV({tile.x + tw - 20, tile.y + 20}, 11, COL_ACCENT)
			c := rl.Vector2{tile.x + tw - 20, tile.y + 20}
			rl.DrawLineEx({c.x - 5, c.y}, {c.x - 1, c.y + 4}, 2.5, rl.WHITE)
			rl.DrawLineEx({c.x - 1, c.y + 4}, {c.x + 5, c.y - 4}, 2.5, rl.WHITE)
		}
		draw_t_fit(name, tile.x + 4, tile.y + th + 4, tw - 8, 16, focused ? COL_TEXT : COL_MUTED, focused)
	}
	pop_clip()
	draw_scrollbar({r.x + r.width - 12, grid.y, 4, grid.height}, bkg_picker.scroll / max(step, 1), int(grid.height / step), rows, COL_ACCENT)

	if bkg_picker.open && !clicked_inside && !input.using_pad && rl.IsMouseButtonPressed(.LEFT) && !rl.CheckCollisionPointRec(rl.GetMousePosition(), r) {
		bkg_picker_close()
	}
}
