package saber

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

Font_Choice :: struct {
	name: string,
	path: string,
}

SYSTEM_FONTS := [?][2]string {
	{"Segoe UI", "segoeui.ttf"},
	{"Arial", "arial.ttf"},
	{"Bahnschrift", "bahnschrift.ttf"},
	{"Tahoma", "tahoma.ttf"},
	{"Verdana", "verdana.ttf"},
	{"Trebuchet", "trebuc.ttf"},
	{"Georgia", "georgia.ttf"},
	{"Calibri", "calibri.ttf"},
	{"Consolas", "consola.ttf"},
	{"Impact", "impact.ttf"},
}

// Two atlases: small text sampled from a large atlas looks soft, large text from a
// small one looks blocky.
FONT_SMALL_PX :: 32
FONT_LARGE_PX :: 80
FONT_SPLIT :: 26

font_choices: [dynamic]Font_Choice
ui_font_sm: rl.Font
ui_font_lg: rl.Font
ui_font_ok: bool
ui_font_name: string
font_codepoints: [dynamic]rune

font_init :: proc() {
	// ASCII + Latin-1 (accented titles) + the punctuation the UI uses.
	for r in rune(32) ..= 126 {
		append(&font_codepoints, r)
	}
	for r in rune(0xA0) ..= 0xFF {
		append(&font_codepoints, r)
	}
	append(&font_codepoints, '—', '–', '…', '•', '’', '“', '”', '™')

	bundled := path_join({app.exe_dir, "assets", "fonts"})
	if fis, err := os.read_all_directory_by_path(bundled, context.temp_allocator); err == nil {
		slice.sort_by(fis, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
		for fi in fis {
			ext := strings.to_lower(filepath.ext(fi.name), context.temp_allocator)
			if fi.type != .Directory && (ext == ".ttf" || ext == ".otf") {
				append(&font_choices, Font_Choice{strings.clone(filepath.stem(fi.name)), strings.clone(fi.fullpath)})
			}
		}
	}
	for f in SYSTEM_FONTS {
		p := path_join({"C:\\Windows\\Fonts", f[1]})
		if os.exists(p) && index_of_font(f[0]) < 0 {
			append(&font_choices, Font_Choice{f[0], p})
		}
	}
	apply_font(app.settings.font)
}

font_shutdown :: proc() {
	unload_fonts()
}

unload_fonts :: proc() {
	if ui_font_ok {
		rl.UnloadFont(ui_font_sm)
		rl.UnloadFont(ui_font_lg)
		ui_font_ok = false
	}
}

index_of_font :: proc(name: string) -> int {
	for f, i in font_choices {
		if strings.equal_fold(f.name, name) {
			return i
		}
	}
	return -1
}

load_font_px :: proc(path: string, px: i32) -> rl.Font {
	f := rl.LoadFontEx(text_cs(path), px, raw_data(font_codepoints), i32(len(font_codepoints)))
	if f.glyphCount > 0 {
		rl.GenTextureMipmaps(&f.texture)
		rl.SetTextureFilter(f.texture, .TRILINEAR)
	}
	return f
}

apply_font :: proc(name: string) {
	unload_fonts()
	idx := max(index_of_font(name), 0)
	if idx < len(font_choices) {
		c := font_choices[idx]
		ui_font_sm = load_font_px(c.path, FONT_SMALL_PX)
		ui_font_lg = load_font_px(c.path, FONT_LARGE_PX)
		ui_font_ok = ui_font_sm.glyphCount > 0 && ui_font_lg.glyphCount > 0
		ui_font_name = c.name
		if !ui_font_ok {
			if ui_font_sm.glyphCount > 0 { rl.UnloadFont(ui_font_sm) }
			if ui_font_lg.glyphCount > 0 { rl.UnloadFont(ui_font_lg) }
		}
	}
	if !ui_font_ok {
		ui_font_sm = rl.GetFontDefault()
		ui_font_lg = ui_font_sm
		ui_font_name = "raylib"
	}
	app.settings.font = ui_font_name
}

cycle_font :: proc(delta: int) {
	n := len(font_choices)
	if n == 0 {
		return
	}
	i := (max(index_of_font(app.settings.font), 0) + delta + n) % n
	apply_font(font_choices[i].name)
	save_settings()
	sfx_click()
}

text_cs :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

font_for :: proc(size: f32) -> rl.Font {
	return size <= FONT_SPLIT ? ui_font_sm : ui_font_lg
}

measure_t :: proc(s: string, size: f32) -> f32 {
	if s == "" {
		return 0
	}
	return rl.MeasureTextEx(font_for(size), text_cs(s), size, size / 16).x
}

draw_t :: proc(s: string, x, y: f32, size: f32, col: rl.Color) {
	if s == "" {
		return
	}
	// snap to whole pixels so small text stays sharp
	rl.DrawTextEx(font_for(size), text_cs(s), {math.round(x), math.round(y)}, size, size / 16, col)
}

draw_t_center :: proc(s: string, cx, y: f32, size: f32, col: rl.Color) {
	draw_t(s, cx - measure_t(s, size) * 0.5, y, size, col)
}

draw_t_right :: proc(s: string, right, y: f32, size: f32, col: rl.Color) {
	draw_t(s, right - measure_t(s, size), y, size, col)
}

// Fits text into max_w: scrolls it (marquee) when focused, otherwise ellipsizes.
draw_t_fit :: proc(s: string, x, y, max_w, size: f32, col: rl.Color, marquee: bool) {
	if s == "" {
		return
	}
	w := measure_t(s, size)
	if w <= max_w {
		draw_t(s, x, y, size, col)
		return
	}
	if marquee {
		push_clip({x, y - 4, max_w, size + 10})
		span := w + 56
		// hold at the start for a moment each cycle
		t := math.mod(f32(rl.GetTime()) * 40, span + 60)
		off := max(t - 60, 0)
		draw_t(s, x - off, y, size, col)
		draw_t(s, x - off + span, y, size, col)
		pop_clip()
		return
	}
	ellipsis := "…"
	ew := measure_t(ellipsis, size)
	// binary search the longest prefix that fits (was a per-byte linear scan)
	lo, hi := 0, len(s)
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if measure_t(s[:mid], size) + ew <= max_w {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	for lo > 0 && lo < len(s) && (s[lo] & 0xc0) == 0x80 {
		lo -= 1
	}
	draw_t(strings.concatenate({strings.trim_right_space(s[:lo]), ellipsis}, context.temp_allocator), x, y, size, col)
}

smooth_to :: proc(cur, target, speed: f32) -> f32 {
	t := 1 - math.exp(-speed * rl.GetFrameTime())
	return cur + (target - cur) * t
}
