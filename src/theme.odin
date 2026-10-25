package saber

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

Theme :: struct {
	bkg_dir:     string,
	bgm_dir:     string,
	sfx_dir:     string,
	bkg_files:   [dynamic]string,
	bgm_files:   [dynamic]string,
	bkg_tex:     rl.Texture2D,
	has_bkg:     bool,
	music:       rl.Music,
	has_music:   bool,
	sfx_click:   rl.Sound,
	sfx_back:    rl.Sound,
	sfx_over:    rl.Sound,
	sfx_start:   rl.Sound,
	has_click:   bool,
	has_back:    bool,
	has_over:    bool,
	has_start:   bool,
	hover_id:    string,
}

theme: Theme

// Active palette; set by apply_ui_theme from UI_THEMES.
COL_BG: rl.Color
COL_PANEL: rl.Color
COL_PANEL_HI: rl.Color
COL_PANEL_SOLID: rl.Color // menus, dropdowns, detail panel
COL_ACCENT: rl.Color
COL_ACCENT_SOFT: rl.Color
COL_TEXT: rl.Color
COL_MUTED: rl.Color
COL_FAINT: rl.Color // hairline borders
COL_TINT: rl.Color  // base for subtle fills: white on dark themes, black on light
COL_SHADE: rl.Color // header/footer/vignette/dim tint
COL_WARN: rl.Color
COL_SHADOW: rl.Color

Ui_Theme :: struct {
	name:                       string,
	bg, panel, panel_hi, solid: rl.Color,
	accent, text, muted:        rl.Color,
	shade, warn:                rl.Color,
	light:                      bool,
}

// Each inspired by a console's menu.
UI_THEMES := [?]Ui_Theme {
	{"Saber", {8, 10, 18, 255}, {14, 18, 32, 196}, {22, 30, 52, 226}, {14, 18, 32, 244}, {92, 204, 255, 255}, {238, 242, 250, 255}, {148, 160, 186, 255}, {6, 8, 16, 255}, {255, 128, 150, 255}, false},
	// Dreamcast: deep blue with the orange swirl
	{"Dreamcast", {10, 18, 52, 255}, {18, 32, 84, 200}, {30, 52, 120, 230}, {16, 30, 78, 246}, {255, 122, 34, 255}, {244, 246, 255, 255}, {150, 168, 210, 255}, {6, 12, 36, 255}, {255, 90, 90, 255}, false},
	// PS2: black void with soft blue light
	{"PlayStation 2", {2, 3, 10, 255}, {10, 14, 34, 190}, {20, 32, 78, 226}, {8, 12, 30, 246}, {96, 140, 255, 255}, {220, 228, 255, 255}, {120, 134, 176, 255}, {0, 0, 6, 255}, {255, 110, 130, 255}, false},
	// PS3 XMB: charcoal with a white glow
	{"PlayStation 3", {18, 18, 22, 255}, {36, 36, 42, 180}, {64, 64, 74, 220}, {28, 28, 34, 246}, {235, 238, 245, 255}, {250, 250, 252, 255}, {160, 162, 172, 255}, {10, 10, 14, 255}, {255, 120, 120, 255}, false},
	// PS Vita: LiveArea blue on deep navy
	{"PS Vita", {6, 16, 40, 255}, {12, 34, 78, 196}, {22, 64, 140, 228}, {10, 30, 70, 246}, {38, 160, 255, 255}, {240, 248, 255, 255}, {140, 176, 220, 255}, {4, 12, 30, 255}, {255, 110, 150, 255}, false},
	// Wii: white channels, Wii blue
	{"Wii", {232, 234, 238, 255}, {250, 250, 252, 220}, {255, 255, 255, 245}, {248, 248, 250, 250}, {52, 190, 237, 255}, {70, 72, 80, 255}, {140, 144, 154, 255}, {214, 218, 226, 255}, {220, 60, 70, 255}, true},
	// Wii U: soft grey-white, teal-cyan accent
	{"Wii U", {220, 226, 232, 255}, {244, 247, 250, 222}, {255, 255, 255, 246}, {242, 245, 248, 250}, {0, 168, 206, 255}, {50, 56, 66, 255}, {124, 134, 148, 255}, {200, 208, 218, 255}, {226, 70, 60, 255}, true},
	// Switch: basic black, neon blue focus
	{"Switch", {45, 45, 45, 255}, {60, 60, 60, 210}, {74, 74, 74, 236}, {52, 52, 52, 248}, {0, 194, 228, 255}, {255, 255, 255, 255}, {170, 170, 170, 255}, {35, 35, 35, 255}, {255, 70, 85, 255}, false},
	// Switch: basic white
	{"Switch Light", {235, 235, 235, 255}, {250, 250, 250, 225}, {255, 255, 255, 248}, {245, 245, 245, 250}, {0, 168, 220, 255}, {45, 45, 45, 255}, {130, 130, 130, 255}, {215, 215, 215, 255}, {230, 0, 18, 255}, true},
}

ui_theme_light: bool

index_of_ui_theme :: proc(name: string) -> int {
	for t, i in UI_THEMES {
		if strings.equal_fold(t.name, name) {
			return i
		}
	}
	return 0
}

with_alpha :: proc(c: rl.Color, a: u8) -> rl.Color {
	return {c.r, c.g, c.b, a}
}

apply_ui_theme :: proc(name: string) {
	t := UI_THEMES[index_of_ui_theme(name)]
	app.settings.ui_theme = t.name
	ui_theme_light = t.light
	COL_BG = t.bg
	COL_PANEL = t.panel
	COL_PANEL_HI = t.panel_hi
	COL_PANEL_SOLID = t.solid
	COL_ACCENT = t.accent
	COL_ACCENT_SOFT = with_alpha(t.accent, 70)
	COL_TEXT = t.text
	COL_MUTED = t.muted
	COL_SHADE = t.shade
	COL_WARN = t.warn
	COL_TINT = t.light ? rl.Color{0, 0, 0, 255} : rl.Color{255, 255, 255, 255}
	COL_FAINT = with_alpha(COL_TINT, t.light ? 30 : 22)
	COL_SHADOW = rl.Color{0, 0, 0, t.light ? 40 : 90}
}

cycle_ui_theme :: proc(delta: int) {
	n := len(UI_THEMES)
	apply_ui_theme(UI_THEMES[(index_of_ui_theme(app.settings.ui_theme) + delta + n) % n].name)
	save_settings()
	sfx_click()
}

IMG_EXTS :: []string{".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif"}
MUS_EXTS :: []string{".mp3", ".ogg", ".wav", ".flac"}

// Card art is drawn well below its native size; mipmaps keep it from shimmering.
load_texture_smooth :: proc(path: string, max_px: i32 = 1024) -> (rl.Texture2D, bool) {
	if path == "" || !os.exists(path) {
		return {}, false
	}
	tex: rl.Texture2D
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	if ext == ".png" || ext == ".bmp" || ext == ".gif" || ext == ".tga" || ext == ".qoi" {
		tex = rl.LoadTexture(strings.clone_to_cstring(path, context.temp_allocator))
	}
	if tex.id == 0 {
		// this raylib build has no JPG/WebP decoder; let Windows decode it (needs backslashes)
		win_path, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
		img, ok := shell_image(win_path, max_px, max_px, still = true)
		if !ok {
			return {}, false
		}
		tex = rl.LoadTextureFromImage(img)
		rl.UnloadImage(img)
		if tex.id == 0 {
			return {}, false
		}
	}
	rl.GenTextureMipmaps(&tex)
	rl.SetTextureFilter(tex, .TRILINEAR)
	return tex, true
}

first_existing_dir :: proc(candidates: []string) -> string {
	for c in candidates {
		if os.exists(c) {
			return c
		}
	}
	return candidates[0]
}

theme_init :: proc() {
	theme.bkg_dir = first_existing_dir({
		path_join({app.exe_dir, "assets", "bkg"}),
		path_join({app.exe_dir, "bkg"}),
	})
	theme.bgm_dir = first_existing_dir({
		path_join({app.exe_dir, "assets", "bgm"}),
		path_join({app.exe_dir, "bgm"}),
	})
	theme.sfx_dir = path_join({app.exe_dir, "assets", "sounds"})

	apply_ui_theme(app.settings.ui_theme)
	refresh_media_lists()
	theme_apply_bkg(app.settings.bkg)
	theme_apply_bgm(app.settings.bgm)
	load_sfx()
}

theme_shutdown :: proc() {
	unload_bkg()
	unload_bgm()
	if theme.has_click { rl.UnloadSound(theme.sfx_click) }
	if theme.has_back { rl.UnloadSound(theme.sfx_back) }
	if theme.has_over { rl.UnloadSound(theme.sfx_over) }
	if theme.has_start { rl.UnloadSound(theme.sfx_start) }
}

refresh_media_lists :: proc() {
	clear(&theme.bkg_files)
	clear(&theme.bgm_files)
	collect_media(&theme.bkg_files, theme.bkg_dir, IMG_EXTS)
	collect_media(&theme.bgm_files, theme.bgm_dir, MUS_EXTS)
	slice.sort_by(theme.bkg_files[:], proc(a, b: string) -> bool { return a < b })
	slice.sort_by(theme.bgm_files[:], proc(a, b: string) -> bool { return a < b })
}

collect_media :: proc(out: ^[dynamic]string, dir: string, exts: []string) {
	if !os.exists(dir) {
		return
	}
	fis, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return
	}
	defer os.file_info_slice_delete(fis, context.allocator)
	for fi in fis {
		if fi.type == .Directory {
			continue
		}
		ext := strings.to_lower(filepath.ext(fi.name), context.temp_allocator)
		ok := false
		for e in exts {
			if ext == e {
				ok = true
				break
			}
		}
		if ok {
			append(out, strings.clone(fi.name))
		}
	}
}

index_of_name :: proc(list: []string, name: string) -> int {
	if name == "" {
		return 0
	}
	for f, i in list {
		if strings.equal_fold(f, name) {
			return i
		}
	}
	return 0
}

unload_bkg :: proc() {
	if theme.has_bkg {
		rl.UnloadTexture(theme.bkg_tex)
		theme.has_bkg = false
	}
}

unload_bgm :: proc() {
	if theme.has_music {
		rl.StopMusicStream(theme.music)
		rl.UnloadMusicStream(theme.music)
		theme.has_music = false
	}
}

theme_apply_bkg :: proc(name: string) {
	unload_bkg()
	if len(theme.bkg_files) == 0 {
		app.settings.bkg = ""
		return
	}
	idx := index_of_name(theme.bkg_files[:], name)
	app.settings.bkg = theme.bkg_files[idx]
	path := path_join({theme.bkg_dir, app.settings.bkg})
	theme.bkg_tex, theme.has_bkg = load_texture_smooth(path, 2560)
}

theme_apply_bgm :: proc(name: string) {
	unload_bgm()
	if len(theme.bgm_files) == 0 {
		app.settings.bgm = ""
		return
	}
	idx := index_of_name(theme.bgm_files[:], name)
	app.settings.bgm = theme.bgm_files[idx]
	path := path_join({theme.bgm_dir, app.settings.bgm})
	theme.music = rl.LoadMusicStream(strings.clone_to_cstring(path, context.temp_allocator))
	theme.has_music = rl.IsMusicValid(theme.music)
	if theme.has_music {
		theme.music.looping = true
		rl.SetMusicVolume(theme.music, app.settings.volume)
		rl.PlayMusicStream(theme.music)
	}
}

cycle_bkg :: proc(delta: int) {
	if len(theme.bkg_files) == 0 {
		return
	}
	i := index_of_name(theme.bkg_files[:], app.settings.bkg)
	n := len(theme.bkg_files)
	i = (i + delta % n + n) % n
	theme_apply_bkg(theme.bkg_files[i])
	save_settings()
	sfx_click()
}

cycle_bgm :: proc(delta: int) {
	if len(theme.bgm_files) == 0 {
		return
	}
	i := index_of_name(theme.bgm_files[:], app.settings.bgm)
	n := len(theme.bgm_files)
	i = (i + delta % n + n) % n
	theme_apply_bgm(theme.bgm_files[i])
	save_settings()
	sfx_click()
}

load_sfx :: proc() {
	try_sfx :: proc(name: string) -> (rl.Sound, bool) {
		p := path_join({theme.sfx_dir, name})
		if !os.exists(p) {
			return {}, false
		}
		s := rl.LoadSound(strings.clone_to_cstring(p, context.temp_allocator))
		return s, s.frameCount > 0
	}
	theme.sfx_click, theme.has_click = try_sfx("click.mp3")
	theme.sfx_back, theme.has_back = try_sfx("back.mp3")
	theme.sfx_over, theme.has_over = try_sfx("rollover.mp3")
	theme.sfx_start, theme.has_start = try_sfx("gamestart.ogg")
}

sfx_click :: proc() {
	if theme.has_click { rl.PlaySound(theme.sfx_click) }
}
sfx_back :: proc() {
	if theme.has_back { rl.PlaySound(theme.sfx_back) }
}
sfx_start :: proc() {
	if theme.has_start { rl.PlaySound(theme.sfx_start) }
}

hover_enter :: proc(id: string) -> bool {
	if theme.hover_id == id {
		return false
	}
	delete(theme.hover_id)
	theme.hover_id = strings.clone(id)
	if theme.has_over {
		rl.PlaySound(theme.sfx_over)
	}
	return true
}

theme_update :: proc() {
	if theme.has_music {
		rl.UpdateMusicStream(theme.music)
		if !rl.IsMusicStreamPlaying(theme.music) {
			rl.PlayMusicStream(theme.music)
		}
	}
}

theme_pause_for_game :: proc() {
	if theme.has_music {
		rl.PauseMusicStream(theme.music)
	}
}

theme_resume_after_game :: proc() {
	if theme.has_music {
		rl.ResumeMusicStream(theme.music)
	}
}

draw_background :: proc(w, h: f32) {
	rl.ClearBackground(COL_BG)
	if theme.has_bkg {
		// slow drift; one quad per frame
		t := f32(rl.GetTime())
		zoom := 1.05 + 0.02 * math.sin(t * 0.1)
		tw := f32(theme.bkg_tex.width)
		th := f32(theme.bkg_tex.height)
		scale := max(w / tw, h / th) * zoom
		dw := tw * scale
		dh := th * scale
		ox := (w - dw) * 0.5 + math.sin(t * 0.06) * 14
		oy := (h - dh) * 0.5 + math.cos(t * 0.045) * 8
		rl.DrawTexturePro(theme.bkg_tex, {0, 0, tw, th}, {ox, oy, dw, dh}, {}, 0, rl.WHITE)
	}
	// darken for legibility, heavier at the edges
	rl.DrawRectangle(0, 0, i32(w), i32(h), with_alpha(COL_SHADE, ui_theme_light ? 140 : 110))
	band := i32(h * 0.35)
	rl.DrawRectangleGradientV(0, 0, i32(w), band, with_alpha(COL_SHADE, 170), with_alpha(COL_SHADE, 0))
	rl.DrawRectangleGradientV(0, i32(h) - band, i32(w), band, with_alpha(COL_SHADE, 0), with_alpha(COL_SHADE, 190))
}
