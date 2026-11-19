package saber

import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

Theme :: struct {
	bkg_dir:     string,
	bgm_dir:     string,
	sfx_dir:     string,
	bkg_files:   [dynamic]string,
	bgm_files:   [dynamic]string,
	bkg_tex:     rl.Texture2D,
	has_bkg:     bool,
	bkg_shader:  Bkg_Shader,
	music:       rl.Music,
	has_music:   bool,
	sfx:         [Sfx]rl.Sound,
	has_sfx:     [Sfx]bool,
	hover_id:    string,
}

theme: Theme

// the menu music begins 0.5 s after the first menu frame
theme_music_since: f64
theme_music_ready: bool

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
	// Liquid Glass: clear panes over a deep indigo, ice-blue light
	{"Liquid Glass", {10, 12, 30, 255}, {40, 48, 80, 190}, {70, 84, 130, 220}, {24, 28, 52, 244}, {140, 200, 255, 255}, {248, 250, 255, 255}, {176, 186, 214, 255}, {8, 10, 24, 255}, {255, 120, 190, 255}, false},
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
	for t, i in UI_THEMES do if eq_fold(t.name, name) do return i
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
	apply_ui_theme(UI_THEMES[cycle(index_of_ui_theme(app.settings.ui_theme), delta, len(UI_THEMES))].name)
	save_settings()
	sfx_click()
}

IMG_EXTS :: []string{".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif"}
SHADER_EXTS :: []string{".glsl", ".frag", ".fs"}
BKG_EXTS :: []string{".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif", ".glsl", ".frag", ".fs"}
MUS_EXTS :: []string{".mp3", ".ogg", ".wav", ".flac"}

// Card art is drawn well below its native size; mipmaps keep it from shimmering.
load_texture_smooth :: proc(path: string, max_px: i32 = 1024) -> (rl.Texture2D, bool) {
	img, ok := load_image_smooth(path, max_px)
	if !ok do return {}, false
	defer rl.UnloadImage(img)
	return texture_from_image(img)
}

// CPU-side decode only, so it can run off the main thread (drive scans).
load_image_smooth :: proc(path: string, max_px: i32 = 1024) -> (rl.Image, bool) {
	if path == "" || !os.exists(path) do return {}, false
	if has_ext(path, ".png", ".bmp", ".gif", ".tga", ".qoi") {
		img := rl.LoadImage(strings.clone_to_cstring(path, context.temp_allocator))
		if img.data != nil do return img, true
	}
	// this raylib build has no JPG/WebP decoder; let the OS decode it
	return shell_image(path, max_px, max_px, still = true)
}

texture_from_image :: proc(img: rl.Image) -> (rl.Texture2D, bool) {
	tex := rl.LoadTextureFromImage(img)
	if tex.id == 0 do return {}, false
	rl.GenTextureMipmaps(&tex)
	rl.SetTextureFilter(tex, .TRILINEAR)
	return tex, true
}

first_existing_dir :: proc(candidates: []string) -> string {
	for c in candidates do if os.exists(c) do return c
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
	unload_tex(&theme.bkg_tex, &theme.has_bkg)
	bkg_shader_unload(&theme.bkg_shader)
	unload_bgm()
	for s, i in theme.sfx do if theme.has_sfx[i] do rl.UnloadSound(s)
	glass_shutdown()
}

refresh_media_lists :: proc() {
	clear(&theme.bkg_files)
	clear(&theme.bgm_files)
	collect_media(&theme.bkg_files, theme.bkg_dir, BKG_EXTS)
	collect_media(&theme.bgm_files, theme.bgm_dir, MUS_EXTS)
	slice.sort_by(theme.bkg_files[:], proc(a, b: string) -> bool { return a < b })
	slice.sort_by(theme.bgm_files[:], proc(a, b: string) -> bool { return a < b })
}

collect_media :: proc(out: ^[dynamic]string, dir: string, exts: []string) {
	fis, _ := list_dir(dir)
	for fi in fis do if fi.type != .Directory && has_ext(fi.name, ..exts) do append(out, strings.clone(fi.name))
}

index_of_name :: proc(list: []string, name: string) -> int {
	for f, i in list do if eq_fold(f, name) do return i
	return 0
}

// Frees a texture that may not have loaded.
unload_tex :: proc(tex: ^rl.Texture2D, has: ^bool) {
	if has^ do rl.UnloadTexture(tex^)
	has^ = false
}

unload_bgm :: proc() {
	if theme.has_music {
		rl.StopMusicStream(theme.music)
		rl.UnloadMusicStream(theme.music)
		theme.has_music = false
	}
}

theme_apply_bkg :: proc(name: string) {
	unload_tex(&theme.bkg_tex, &theme.has_bkg)
	bkg_shader_unload(&theme.bkg_shader)
	if len(theme.bkg_files) == 0 {
		app.settings.bkg = ""
		return
	}
	idx := index_of_name(theme.bkg_files[:], name)
	app.settings.bkg = theme.bkg_files[idx]
	path := path_join({theme.bkg_dir, app.settings.bkg})
	if has_ext(path, ..SHADER_EXTS) {
		theme.bkg_shader = bkg_shader_load(path)
	} else {
		theme.bkg_tex, theme.has_bkg = load_texture_smooth(path, 2560)
	}
}

// Shadertoy-style wallpaper: the file defines mainImage(out vec4, in vec2)
// and gets iResolution (vec3, pixels), iTime (seconds), iMouse (vec4).
Bkg_Shader :: struct {
	shader:                   rl.Shader,
	ok:                       bool,
	loc_res, loc_time, loc_mouse: i32,
}

BKG_SHADER_HEAD :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
out vec4 finalColor;
uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
#line 1
`

BKG_SHADER_TAIL :: `
void main() {
	vec2 fc = vec2(fragTexCoord.x, 1.0 - fragTexCoord.y) * iResolution.xy;
	vec4 col = vec4(0.0, 0.0, 0.0, 1.0);
	mainImage(col, fc);
	finalColor = vec4(col.rgb, fragColor.a);
}
`

bkg_shader_load :: proc(path: string) -> (b: Bkg_Shader) {
	src, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(src) == 0 do return
	code := strings.concatenate({BKG_SHADER_HEAD, string(src), BKG_SHADER_TAIL}, context.temp_allocator)
	sh := rl.LoadShaderFromMemory(nil, strings.clone_to_cstring(code, context.temp_allocator))
	if !rl.IsShaderValid(sh) || sh.id == rlgl.GetShaderIdDefault() do return
	b.shader, b.ok = sh, true
	b.loc_res = rl.GetShaderLocation(sh, "iResolution")
	b.loc_time = rl.GetShaderLocation(sh, "iTime")
	b.loc_mouse = rl.GetShaderLocation(sh, "iMouse")
	return
}

bkg_shader_unload :: proc(b: ^Bkg_Shader) {
	if b.ok do rl.UnloadShader(b.shader)
	b.ok = false
}

bkg_shader_draw :: proc(b: ^Bkg_Shader, r: rl.Rectangle) {
	white := rl.Texture2D{id = rlgl.GetTextureIdDefault(), width = 1, height = 1, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
	res := [3]f32{r.width, r.height, 1}
	t := f32(rl.GetTime())
	m := rl.GetMousePosition()
	mouse := [4]f32{m.x - r.x, r.height - (m.y - r.y), 0, 0}
	rl.BeginShaderMode(b.shader)
	rl.SetShaderValue(b.shader, b.loc_res, &res, .VEC3)
	rl.SetShaderValue(b.shader, b.loc_time, &t, .FLOAT)
	rl.SetShaderValue(b.shader, b.loc_mouse, &mouse, .VEC4)
	rl.DrawTexturePro(white, {0, 0, 1, 1}, r, {}, 0, rl.WHITE)
	rl.EndShaderMode()
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
		if theme_music_ready do rl.PlayMusicStream(theme.music)
	}
}

// Steps the wallpaper / music through its folder.
cycle_bkg :: proc(delta: int) {
	cycle_media(theme.bkg_files[:], app.settings.bkg, delta, theme_apply_bkg)
}

cycle_bgm :: proc(delta: int) {
	cycle_media(theme.bgm_files[:], app.settings.bgm, delta, theme_apply_bgm)
}

cycle_media :: proc(files: []string, current: string, delta: int, apply: proc(name: string)) {
	if len(files) == 0 do return
	apply(files[cycle(index_of_name(files, current), delta, len(files))])
	save_settings()
	sfx_click()
}

Sfx :: enum {
	Click,
	Back,
	Over,
	Start,
}

SFX_FILES := [Sfx]string {
	.Click = "click.mp3",
	.Back  = "back.mp3",
	.Over  = "rollover.mp3",
	.Start = "gamestart.ogg",
}

load_sfx :: proc() {
	for name, s in SFX_FILES {
		p := path_join({theme.sfx_dir, name})
		if !os.exists(p) do continue
		theme.sfx[s] = rl.LoadSound(strings.clone_to_cstring(p, context.temp_allocator))
		theme.has_sfx[s] = theme.sfx[s].frameCount > 0
	}
}

play_sfx :: proc(s: Sfx) {
	if theme.has_sfx[s] do rl.PlaySound(theme.sfx[s])
}

sfx_click :: proc() { play_sfx(.Click) }
sfx_back :: proc() { play_sfx(.Back) }
sfx_start :: proc() { play_sfx(.Start) }

hover_enter :: proc(id: string) -> bool {
	if theme.hover_id == id do return false
	delete(theme.hover_id)
	theme.hover_id = strings.clone(id)
	play_sfx(.Over)
	return true
}

theme_update :: proc() {
	if !theme_music_ready {
		if theme_music_since == 0 do theme_music_since = rl.GetTime()
		if rl.GetTime() - theme_music_since < 0.5 do return
		theme_music_ready = true
	}
	if theme.has_music && !explorer.has_music && !chan.has_music { // a channel plays its own
		rl.UpdateMusicStream(theme.music)
		if !rl.IsMusicStreamPlaying(theme.music) do rl.PlayMusicStream(theme.music)
	}
}

theme_pause_for_game :: proc() {
	if theme.has_music do rl.PauseMusicStream(theme.music)
	if chan.has_music do rl.PauseMusicStream(chan.music)
}

theme_resume_after_game :: proc() {
	if chan.has_music {
		rl.ResumeMusicStream(chan.music)
	} else if theme.has_music {
		rl.ResumeMusicStream(theme.music)
	}
}

// Wallpaper and its shading; also captured as the glass backdrop.
draw_wallpaper :: proc(w, h: f32) {
	rl.ClearBackground(COL_BG)
	if theme.bkg_shader.ok {
		bkg_shader_draw(&theme.bkg_shader, {0, 0, w, h})
	} else if !theme.has_bkg {
		draw_ambient_orbs(w, h)
	} else {
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
	// Wallpaper opacity: 0.5 = this shading as designed, 1 = none, 0 = twice as dark
	k := 2 * (1 - app.settings.bkg_opacity)
	sa :: proc(a, k: f32) -> u8 { return u8(clamp(a * k, 0, 255)) }
	rl.DrawRectangle(0, 0, i32(w), i32(h), with_alpha(COL_SHADE, sa(ui_theme_light ? 140 : 110, k)))
	band := i32(h * 0.35)
	rl.DrawRectangleGradientV(0, 0, i32(w), band, with_alpha(COL_SHADE, sa(170, k)), with_alpha(COL_SHADE, 0))
	rl.DrawRectangleGradientV(0, i32(h) - band, i32(w), band, with_alpha(COL_SHADE, 0), with_alpha(COL_SHADE, sa(190, k)))
}
