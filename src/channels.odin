package saber

// Channels (Wii style): small programs that run inside Saber, full screen, through its Lua API.
//
// APP/channels/<folder>/
//   info.toml                   name = "...", description = "...", author = "...", version = "..."
//                               background = "bkg.glsl" (or true = bkg.glsl; a .glsl/.frag/.fs or a picture,
//                               relative to the folder): Saber draws it full screen before every frame()
//                               (read at scan time; the Lua only runs once the channel is started)
//   channel.lua                 returns the channel table (below)
//   thumbnail.png|jpg|...       tile + preview banner art, or
//   thumbnail.glsl|frag|fs      a live GLSL fragment shader, Shadertoy style:
//                                 void mainImage(out vec4 fragColor, in vec2 fragCoord)
//                               with iResolution (vec3, pixels), iTime (seconds), iMouse (vec4);
//                               Saber rounds the corners itself.
//   bgm.mp3|ogg|wav|flac        music while the channel runs
//   jingle.mp3|ogg|wav|flac     played once when the preview opens, over the menu music (faded down)
//   logo.png|jpg|...            optional: drawn centred over the thumbnail (shader or picture)
//
// channel.lua:
//   return {
//     on_start = function() end,                -- once, when Start is pressed
//     frame    = function(dt, w, h) end,        -- every frame: draw the whole screen
//     on_close = function() end,                -- leaving the channel
//   }
//   The returned table is the global CHANNEL. Globals: CHANNEL_DIR (= PLUGIN_DIR, relative paths
//   resolve there), SABER_DIR, WALLPAPER_DIR, MUSIC_DIR, saber.log / saber.version, every plugin
//   API (Dialog_*, Http_*, UI_Open..., Play_Rom, List_Dir, Unzip...) plus:
//
//   Draw_Rect(x, y, w, h, color [, radius])            Draw_Outline(x, y, w, h, color [, thick [, radius]])
//   Draw_Circle(x, y, r, color)                        Draw_Line(x1, y1, x2, y2, color [, thick])
//   Draw_Gradient(x, y, w, h, top, bottom)             Draw_Text(text, x, y [, size [, color [, align]]])
//   Text_Width(text [, size])                          Draw_Image(path, x, y, w, h [, {fit=, alpha=, radius=}])
//   Draw_Shader(path, x, y, w, h [, {alpha=, radius=}])  a Shadertoy-style .glsl (like thumbnail.glsl), e.g. bkg.glsl
//   Image_Size(path) -> w, h | nil                     Draw_Wallpaper()   Draw_Panel(x, y, w, h [, focused])
//   Input() -> {up, down, left, right, a, b, x, y, lb, rb, start} (pressed this frame)
//   Mouse() -> x, y, clicked, down                     Screen_Size() -> w, h      Time() -> seconds
//   Play_Sfx("click" | "back" | "over" | "start")     Channel_Close()
//   Colors: "#rrggbb[aa]", {r, g, b [, a]}, or a theme name: text muted accent warn bg panel white black.
//   fit: "stretch" (default) | "cover" | "contain". align: "left" | "center" | "right".
//
// Select / Esc opens the Home menu (Resume, Restart, Close): the channel never gets that button.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

Channel :: struct {
	name:        string,
	description: string,
	author:      string,
	version:     string,
	folder:      string,
	dir:         string,
	bgm:         string, // music path, "" = none
	jingle:      string, // preview jingle path, "" = none
	background:  string, // info.toml background= (full path), drawn under frame(); "" = none
	thumb:       rl.Texture2D,
	has_thumb:   bool,
	logo:        rl.Texture2D,
	has_logo:    bool,
	shader:      Thumb_Shader,
	rect:        rl.Rectangle, // where its tile was drawn last (the preview zooms out of it)
}

CHANNEL_COLS :: 4
CHANNEL_SLOTS :: 12 // empty slots fill the grid up to this, like the Wii menu
CHANNEL_ASPECT :: 0.6 // tile height / width

Channel_Menu_Row :: enum {
	Resume,
	Restart,
	Close,
}

CHANNEL_MENU_LABELS := [Channel_Menu_Row]string {
	.Resume  = "Resume",
	.Restart = "Restart Channel",
	.Close   = "Close Channel",
}

Channels :: struct {
	dir:         string,
	list:        [dynamic]Channel,
	sel:         int,
	scroll:      f32,
	log:         ^os.File,
	// preview
	preview:     bool,
	preview_t:   f32,
	preview_idx: int,
	preview_btn: int, // 0 = Back, 1 = Start
	// running channel
	running:     int, // index in list, -1 = none
	L:           ^lua_State,
	start_req:   int, // -1 = none; started by channels_update (outside drawing)
	close_req:   bool,
	rescan_req:  bool, // Rescan_Channels(): done once no channel runs
	restart_req: bool,
	started:     f64,
	in_frame:    bool,
	inp:         Input,
	images:      map[string]View_Image,
	loads:       int,
	frames:      u64,
	// Home menu (Select / Esc while running)
	menu_open:   bool,
	menu_t:      f32,
	menu_sel:    int,
	// music
	music:       rl.Music,
	has_music:   bool,
	music_path:  string,
	jingle:      rl.Music, // preview jingle, over the ducked theme music
	has_jingle:  bool,
	jingle_wait: f32, // seconds before the jingle starts (the theme fades down meanwhile)
	bgm_wait:    f32, // >0: bgm starts this long after the start fade has finished
	bgm_pending: string, // bgm path waiting for bgm_wait
	duck:        f32, // 0..1, how far the theme music is faded down
	// shared GPU bits
	white:       rl.Texture2D,
	round:       rl.Shader,
	round_ok:    bool,
	round_src:   i32,
	round_size:  i32,
	round_rad:   i32,
	gpu_ready:   bool,
}

chan := Channels{running = -1, start_req = -1}

channel_logf :: proc(format: string, args: ..any) {
	if chan.log == nil do return
	fmt.fprintfln(chan.log, format, ..args)
}

channel_running :: proc() -> bool {
	return chan.running >= 0 && chan.L != nil
}

// ---------------------------------------------------------------------------
// Scan

channels_scan :: proc() {
	if channel_running() do return // indices must stay put while one runs
	if chan.dir == "" {
		chan.dir = path_join({app.exe_dir, "channels"})
		os.make_directory_all(chan.dir)
		if f, err := os.open(tjoin({chan.dir, "channels.log"}), {.Write, .Create, .Trunc}); err == nil do chan.log = f
	}
	channels_gpu_init()
	if chan.preview do channel_preview_close(false)
	channels_free_list()

	fis, ok := list_dir(chan.dir)
	if !ok do return
	slice.sort_by(fis, proc(a, b: os.File_Info) -> bool { return ascii_lower(a.name, context.temp_allocator) < ascii_lower(b.name, context.temp_allocator) })
	for fi in fis {
		if fi.type != .Directory do continue
		if !os.exists(tjoin({fi.fullpath, "channel.lua"})) do continue
		ch := Channel{folder = strings.clone(fi.name), dir = strings.clone(fi.fullpath)}
		// basic info comes from info.toml, so nothing of the channel runs before it's started
		if info, err := os.read_entire_file(tjoin({fi.fullpath, "info.toml"}), context.temp_allocator); err == nil {
			text := string(info)
			ini_str(text, "name", &ch.name, true)
			ini_str(text, "description", &ch.description)
			ini_str(text, "author", &ch.author)
			ini_str(text, "version", &ch.version)
			if bg, found := ini_get(text, "background"); found && bg != "" && bg != "0" && !eq_fold(bg, "false") {
				if bg == "1" || eq_fold(bg, "true") do bg = "bkg.glsl"
				ch.background = filepath.is_abs(bg) ? strings.clone(bg) : path_join({fi.fullpath, bg})
			}
		}
		if ch.name == "" do ch.name = strings.clone(fi.name)
		channel_load_assets(&ch)
		append(&chan.list, ch)
	}
	chan.sel = clamp(chan.sel, 0, max(0, len(chan.list) - 1))
	channel_logf("%d channel(s) found in %s", len(chan.list), chan.dir)
}

channel_load_assets :: proc(ch: ^Channel) {
	files, _ := list_dir(ch.dir)
	for fi in files {
		if fi.type == .Directory do continue
		stem := ascii_lower(fi.name[:len(fi.name) - len(ext_lower(fi.name))], context.temp_allocator)
		switch {
		case stem == "bgm" && has_ext(fi.name, ..MUS_EXTS) && ch.bgm == "":
			ch.bgm = strings.clone(fi.fullpath)
		case stem == "jingle" && has_ext(fi.name, ..MUS_EXTS) && ch.jingle == "":
			ch.jingle = strings.clone(fi.fullpath)
		case stem == "thumbnail" && has_ext(fi.name, ".glsl", ".frag", ".fs") && !ch.shader.ok:
			channel_load_shader(ch, fi.fullpath)
		case stem == "logo" && has_ext(fi.name, ..IMG_EXTS) && !ch.has_logo:
			ch.logo, ch.has_logo = load_texture_smooth(fi.fullpath, 1024)
		case stem == "thumbnail" && has_ext(fi.name, ..IMG_EXTS) && !ch.has_thumb:
			ch.thumb, ch.has_thumb = load_texture_smooth(fi.fullpath, 1280)
			if !ch.has_thumb do channel_logf("%s: can't load %s", ch.folder, fi.name)
		}
	}
}

CHANNEL_THUMB_HEAD :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
out vec4 finalColor;
uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform float saberRadius;
float saber_round_box(vec2 p, vec2 size, float r) {
	vec2 q = abs(p - size * 0.5) - size * 0.5 + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
#line 1
`

CHANNEL_THUMB_TAIL :: `
void main() {
	vec2 fc = vec2(fragTexCoord.x, 1.0 - fragTexCoord.y) * iResolution.xy;
	vec4 col = vec4(0.0, 0.0, 0.0, 1.0);
	mainImage(col, fc);
	float d = saber_round_box(fc, iResolution.xy, saberRadius);
	finalColor = vec4(col.rgb, clamp(col.a, 0.0, 1.0) * clamp(0.5 - d, 0.0, 1.0) * fragColor.a);
}
`

// A Shadertoy-style thumbnail (CHANNEL_THUMB_HEAD + file + CHANNEL_THUMB_TAIL); also used by plugin
// views for .glsl/.frag/.fs images.
Thumb_Shader :: struct {
	sh:                                     rl.Shader,
	ok:                                     bool,
	loc_res, loc_time, loc_mouse, loc_rad:  i32,
}

thumb_shader_load :: proc(path: string) -> (ts: Thumb_Shader) {
	src, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	code := strings.concatenate({CHANNEL_THUMB_HEAD, string(src), CHANNEL_THUMB_TAIL}, context.temp_allocator)
	sh := rl.LoadShaderFromMemory(nil, strings.clone_to_cstring(code, context.temp_allocator))
	if !rl.IsShaderValid(sh) || sh.id == rlgl.GetShaderIdDefault() do return
	ts.sh, ts.ok = sh, true
	ts.loc_res = rl.GetShaderLocation(sh, "iResolution")
	ts.loc_time = rl.GetShaderLocation(sh, "iTime")
	ts.loc_mouse = rl.GetShaderLocation(sh, "iMouse")
	ts.loc_rad = rl.GetShaderLocation(sh, "saberRadius")
	return
}

thumb_shader_unload :: proc(ts: ^Thumb_Shader) {
	if ts.ok do rl.UnloadShader(ts.sh)
	ts^ = {}
}

thumb_shader_draw :: proc(ts: ^Thumb_Shader, r: rl.Rectangle, radius: f32, tint := rl.WHITE) {
	if !ts.ok do return
	if !chan.gpu_ready do channels_gpu_init()
	rl.BeginShaderMode(ts.sh)
	res := [3]f32{r.width, r.height, 1}
	t := f32(rl.GetTime())
	m := rl.GetMousePosition()
	mouse := [4]f32{m.x - r.x, r.height - (m.y - r.y), 0, 0}
	rad := min(radius, min(r.width, r.height) * 0.5)
	rl.SetShaderValue(ts.sh, ts.loc_res, &res, .VEC3)
	rl.SetShaderValue(ts.sh, ts.loc_time, &t, .FLOAT)
	rl.SetShaderValue(ts.sh, ts.loc_mouse, &mouse, .VEC4)
	rl.SetShaderValue(ts.sh, ts.loc_rad, &rad, .FLOAT)
	rl.DrawTexturePro(chan.white, {0, 0, 1, 1}, r, {}, 0, tint)
	rl.EndShaderMode()
}

channel_load_shader :: proc(ch: ^Channel, path: string) {
	ch.shader = thumb_shader_load(path)
	if !ch.shader.ok do channel_logf("%s: %s didn't compile (GLSL 330, needs mainImage(out vec4, in vec2))", ch.folder, path)
}

channels_free_list :: proc() {
	for &ch in chan.list {
		if ch.has_thumb do rl.UnloadTexture(ch.thumb)
		if ch.has_logo do rl.UnloadTexture(ch.logo)
		thumb_shader_unload(&ch.shader)
		delete(ch.name)
		delete(ch.description)
		delete(ch.author)
		delete(ch.version)
		delete(ch.folder)
		delete(ch.dir)
		delete(ch.bgm)
		delete(ch.jingle)
		delete(ch.background)
	}
	clear(&chan.list)
}

CHANNEL_ROUND_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
out vec4 finalColor;
uniform sampler2D texture0;
uniform vec4 src;   // source rect, normalized
uniform vec2 size;  // destination size in pixels
uniform float radius;
void main() {
	vec2 p = (fragTexCoord - src.xy) / src.zw * size;
	vec2 q = abs(p - size * 0.5) - size * 0.5 + radius;
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
	vec4 c = texture(texture0, fragTexCoord) * fragColor;
	finalColor = vec4(c.rgb, c.a * clamp(0.5 - d, 0.0, 1.0));
}
`

channels_gpu_init :: proc() {
	if chan.gpu_ready do return
	chan.gpu_ready = true
	img := rl.GenImageColor(1, 1, rl.WHITE)
	chan.white = rl.LoadTextureFromImage(img)
	rl.UnloadImage(img)
	chan.round = rl.LoadShaderFromMemory(nil, CHANNEL_ROUND_FS)
	chan.round_ok = rl.IsShaderValid(chan.round) && chan.round.id != rlgl.GetShaderIdDefault()
	if chan.round_ok {
		chan.round_src = rl.GetShaderLocation(chan.round, "src")
		chan.round_size = rl.GetShaderLocation(chan.round, "size")
		chan.round_rad = rl.GetShaderLocation(chan.round, "radius")
	}
}

channels_shutdown :: proc() {
	if channel_running() do channel_stop()
	channel_music_stop()
	channel_jingle_stop()
	channels_free_list()
	if chan.gpu_ready {
		rl.UnloadTexture(chan.white)
		if chan.round_ok do rl.UnloadShader(chan.round)
		chan.gpu_ready = false
	}
	if chan.log != nil do os.close(chan.log)
	chan.log = nil
}

// ---------------------------------------------------------------------------
// Drawing helpers

// A texture inside `dest` with rounded corners; fit: 0 stretch, 1 cover, 2 contain.
draw_texture_rounded :: proc(tex: rl.Texture2D, dest: rl.Rectangle, radius: f32, fit := 1, tint := rl.WHITE) {
	tw, th := f32(tex.width), f32(tex.height)
	if tw <= 0 || th <= 0 || dest.width <= 0 || dest.height <= 0 do return
	src := rl.Rectangle{0, 0, tw, th}
	dst := dest
	switch fit {
	case 1:
		s := max(dest.width / tw, dest.height / th)
		sw, sh := dest.width / s, dest.height / s
		src = {(tw - sw) * 0.5, (th - sh) * 0.5, sw, sh}
	case 2:
		s := min(dest.width / tw, dest.height / th)
		dst = {dest.x + (dest.width - tw * s) * 0.5, dest.y + (dest.height - th * s) * 0.5, tw * s, th * s}
	}
	if radius <= 0 || !chan.round_ok {
		rl.DrawTexturePro(tex, src, dst, {}, 0, tint)
		return
	}
	rl.BeginShaderMode(chan.round)
	srcn := [4]f32{src.x / tw, src.y / th, src.width / tw, src.height / th}
	size := [2]f32{dst.width, dst.height}
	rad := min(radius, min(dst.width, dst.height) * 0.5)
	rl.SetShaderValue(chan.round, chan.round_src, &srcn, .VEC4)
	rl.SetShaderValue(chan.round, chan.round_size, &size, .VEC2)
	rl.SetShaderValue(chan.round, chan.round_rad, &rad, .FLOAT)
	rl.DrawTexturePro(tex, src, dst, {}, 0, tint)
	rl.EndShaderMode()
}

// The channel's thumbnail (live shader, picture, or an initials tile) in r.
draw_channel_thumb :: proc(ch: ^Channel, r: rl.Rectangle, radius: f32, alpha: f32 = 1) {
	tint := fade_color(rl.WHITE, alpha)
	switch {
	case ch.shader.ok:
		thumb_shader_draw(&ch.shader, r, radius, tint)
	case ch.has_thumb:
		draw_texture_rounded(ch.thumb, r, radius, 1, tint)
	case:
		h: u32 = 2166136261
		for i in 0 ..< len(ch.name) do h = (h ~ u32(ch.name[i])) * 16777619
		col := rl.ColorFromHSV(f32(h % 360), 0.45, 0.62)
		rl.DrawRectangleRounded(r, roundness(r, radius), 8, fade_color(col, alpha))
		size := min(r.height * 0.22, 64)
		draw_t_center(ch.name, r.x + r.width * 0.5, r.y + (r.height - size) * 0.5, size, fade_color(rl.WHITE, alpha))
	}
	if ch.has_logo {
		// the middle ~55% of the tile, aspect kept
		inset := rl.Rectangle{r.x + r.width * 0.2, r.y + r.height * 0.22, r.width * 0.6, r.height * 0.56}
		draw_texture_contain(ch.logo, inset, tint)
	}
}

// ---------------------------------------------------------------------------
// The CHANNELS tab

handle_channels_input :: proc() {
	n := len(chan.list)
	if n == 0 do return
	nav_grid(&chan.sel, n, CHANNEL_COLS)
	if input.confirm do channel_preview_open(chan.sel)
}

draw_channels :: proc(w, h: f32) {
	top := f32(HEADER_H + 28)
	draw_heading("CHANNELS", len(chan.list), top)
	grid_top := top + 40
	info_h: f32 = 86
	bottom := h - FOOTER_H - 20 - info_h
	area := rl.Rectangle{PAD + 20, grid_top, w - PAD * 2 - 40, bottom - grid_top}
	n := len(chan.list)
	sel := clamp(chan.sel, 0, max(n - 1, 0))

	gap: f32 = 26
	cell_w := (area.width - gap * f32(CHANNEL_COLS - 1)) / f32(CHANNEL_COLS)
	cell_h := cell_w * CHANNEL_ASPECT
	// three rows always fit: shrink the tiles on short screens
	if fit_h := (area.height - gap * 2 - 16) / 3; cell_h > fit_h {
		cell_h = fit_h
		cell_w = cell_h / CHANNEL_ASPECT
	}
	row_h := cell_h + gap
	grid_w := cell_w * CHANNEL_COLS + gap * (CHANNEL_COLS - 1)
	left := area.x + (area.width - grid_w) * 0.5
	slots := max(CHANNEL_SLOTS, (n + CHANNEL_COLS - 1) / CHANNEL_COLS * CHANNEL_COLS)
	rows := slots / CHANNEL_COLS

	row_y := f32(sel / CHANNEL_COLS) * row_h
	target := chan.scroll
	if row_y < target do target = row_y
	if row_y + cell_h + 16 > target + area.height do target = row_y + cell_h + 16 - area.height
	target = clamp(target, 0, max(f32(rows) * row_h - gap + 16 - area.height, 0))
	chan.scroll = smooth_to(chan.scroll, target, 14)

	push_clip({0, area.y - 14, w, area.height + 14})
	for i in 0 ..< slots {
		r := rl.Rectangle{left + f32(i % CHANNEL_COLS) * (cell_w + gap), area.y + 6 + f32(i / CHANNEL_COLS) * row_h - chan.scroll, cell_w, cell_h}
		if r.y + r.height < area.y - 14 || r.y > area.y + area.height do continue
		if i >= n {
			// empty slot
			rl.DrawRectangleRounded(r, roundness(r, RADIUS), 8, with_alpha(COL_TINT, 10))
			rl.DrawRectangleRoundedLinesEx(r, roundness(r, RADIUS), 8, 1.5, COL_FAINT)
			continue
		}
		ch := &chan.list[i]
		hi := i == sel && !chan.preview
		if hi {
			grow: f32 = 6
			r = {r.x - grow, r.y - grow, r.width + grow * 2, r.height + grow * 2}
		}
		ch.rect = r
		if mouse_over(r) {
			hover_enter(fmt.tprintf("chan-%d", i))
			if rl.IsMouseButtonPressed(.LEFT) {
				if i == chan.sel {
					channel_preview_open(i)
				} else {
					chan.sel = i
					sfx_click()
				}
			}
		}
		draw_soft_shadow(r, RADIUS, hi ? 1.3 : 0.8)
		draw_channel_thumb(ch, r, RADIUS)
		rl.DrawRectangleRoundedLinesEx(r, roundness(r, RADIUS), 8, hi ? 2 : 1.5, with_alpha(rl.WHITE, hi ? 150 : 70))
		if hi do draw_focus_ring(r)
	}
	pop_clip()

	iy := bottom + 18
	if n == 0 {
		draw_t_center("No channels yet", w * 0.5, iy, 26, COL_TEXT)
		draw_t_center("Add a folder with a channel.lua to APP/channels, then press Y.", w * 0.5, iy + 38, 16, COL_MUTED)
		return
	}
	ch := &chan.list[sel]
	draw_t_center(ch.name, w * 0.5, iy, 28, COL_TEXT)
	if measure_t(ch.description, 16) > w - PAD * 2 {
		draw_t_fit(ch.description, PAD, iy + 40, w - PAD * 2, 16, COL_MUTED, false)
	} else {
		draw_t_center(ch.description, w * 0.5, iy + 40, 16, COL_MUTED)
	}
}

// ---------------------------------------------------------------------------
// Preview: the tile zooms up, its jingle plays, Start / Back

channel_preview_open :: proc(i: int) {
	if i < 0 || i >= len(chan.list) || input_locked() do return
	chan.sel = i
	chan.preview = true
	chan.preview_idx = i
	chan.preview_btn = 1
	chan.preview_t = 0
	channel_jingle_play(chan.list[i].jingle)
	sfx_click()
}

channel_preview_close :: proc(sound := true) {
	chan.preview = false
	channel_jingle_stop()
	if sound do sfx_back()
}

channel_preview_input :: proc() {
	if input.left || input.right {
		chan.preview_btn = input.left ? 0 : 1
		sfx_click()
	}
	switch {
	case input.cancel || input.power: channel_preview_close()
	case input.confirm:
		if chan.preview_btn == 0 do channel_preview_close()
		else do chan.start_req = chan.preview_idx
	}
}

draw_channel_preview :: proc(w, h: f32) {
	if !modal_fade(&chan.preview_t, chan.preview, 9) do return
	if chan.preview_idx >= len(chan.list) {
		chan.preview = false
		return
	}
	ch := &chan.list[chan.preview_idx]
	t := chan.preview_t
	e := ease_out(t)
	area := rl.Rectangle{0, HEADER_H, w, h - HEADER_H - FOOTER_H}
	rl.DrawRectangleRec(area, with_alpha(COL_SHADE, u8(200 * t)))

	bw := min(area.width - PAD * 4, (area.height - 190) / CHANNEL_ASPECT)
	bh := bw * CHANNEL_ASPECT
	banner := rl.Rectangle{(w - bw) * 0.5, area.y + 24, bw, bh}
	from := ch.rect
	if from.width <= 0 do from = banner
	r := rl.Rectangle{
		from.x + (banner.x - from.x) * e,
		from.y + (banner.y - from.y) * e,
		from.width + (banner.width - from.width) * e,
		from.height + (banner.height - from.height) * e,
	}
	draw_soft_shadow(r, RADIUS + 8, 1.6 * t)
	draw_channel_thumb(ch, r, RADIUS + 8 * e, min(1, t * 3))
	rl.DrawRectangleRoundedLinesEx(r, roundness(r, RADIUS + 8 * e), 8, 2, with_alpha(rl.WHITE, u8(110 * t)))
	if t < 0.4 do return

	a := clamp((t - 0.4) / 0.6, 0, 1)
	y := banner.y + banner.height + 20
	draw_t_center(ch.name, w * 0.5, y, 30, fade_color(COL_TEXT, a))
	meta := ch.description
	if ch.author != "" do meta = meta != "" ? fmt.tprintf("%s  ·  by %s", meta, ch.author) : fmt.tprintf("by %s", ch.author)
	if ch.version != "" do meta = fmt.tprintf("%s  ·  v%s", meta, ch.version)
	if meta != "" {
		if measure_t(meta, 16) > w - PAD * 2 do draw_t_fit(meta, PAD, y + 42, w - PAD * 2, 16, fade_color(COL_MUTED, a), true)
		else do draw_t_center(meta, w * 0.5, y + 42, 16, fade_color(COL_MUTED, a))
	}

	// Back / Start, Wii style at the bottom corners of the banner
	btn_w: f32 = 260
	btn_h: f32 = 56
	by := area.y + area.height - btn_h - 18
	back := rl.Rectangle{banner.x, by, btn_w, btn_h}
	start := rl.Rectangle{banner.x + banner.width - btn_w, by, btn_w, btn_h}
	if chan.preview && t > 0.9 {
		if mouse_over(back, true) do chan.preview_btn = 0
		if mouse_over(start, true) do chan.preview_btn = 1
		if ui_button("chan-back", back, "Back", chan.preview_btn == 0, true) do channel_preview_close()
		if ui_button("chan-start", start, "Start", chan.preview_btn == 1, true) do chan.start_req = chan.preview_idx
	} else {
		ui_button("", back, "Back", false, true)
		ui_button("", start, "Start", false, true)
	}
}

// ---------------------------------------------------------------------------
// Music

channel_music_play :: proc(path: string) {
	if path == "" {
		channel_music_stop()
		return
	}
	if chan.has_music && chan.music_path == path do return
	channel_music_stop()
	chan.music = rl.LoadMusicStream(strings.clone_to_cstring(path, context.temp_allocator))
	if !rl.IsMusicValid(chan.music) {
		channel_logf("can't play %s", path)
		return
	}
	chan.has_music = true
	chan.music_path = strings.clone(path)
	chan.music.looping = true
	rl.SetMusicVolume(chan.music, app.settings.volume)
	rl.PlayMusicStream(chan.music)
	if theme.has_music do rl.PauseMusicStream(theme.music)
}

channel_music_stop :: proc() {
	if !chan.has_music do return
	rl.StopMusicStream(chan.music)
	rl.UnloadMusicStream(chan.music)
	chan.has_music = false
	delete(chan.music_path)
	chan.music_path = ""
	if theme.has_music && !explorer.has_music do rl.ResumeMusicStream(theme.music)
}

// ---------------------------------------------------------------------------
// Running a channel

channel_jingle_play :: proc(path: string) {
	channel_jingle_stop()
	if path == "" do return
	chan.jingle = rl.LoadMusicStream(strings.clone_to_cstring(path, context.temp_allocator))
	if !rl.IsMusicValid(chan.jingle) {
		channel_logf("can't play %s", path)
		return
	}
	chan.has_jingle = true
	chan.jingle.looping = false
	chan.jingle_wait = 0.5
}

channel_jingle_stop :: proc() {
	if !chan.has_jingle do return
	rl.StopMusicStream(chan.jingle)
	rl.UnloadMusicStream(chan.jingle)
	chan.has_jingle = false
}

// Main loop, before input: starts / stops channels outside drawing and feeds the music.
channels_update :: proc() {
	if chan.has_music {
		rl.SetMusicVolume(chan.music, app.settings.volume)
		rl.UpdateMusicStream(chan.music)
		if theme.has_music && rl.IsMusicStreamPlaying(theme.music) do rl.PauseMusicStream(theme.music) // e.g. music autochange
	}
	if chan.has_jingle {
		rl.SetMusicVolume(chan.jingle, app.settings.volume)
		if chan.jingle_wait > 0 {
			chan.jingle_wait -= rl.GetFrameTime()
			if chan.jingle_wait <= 0 do rl.PlayMusicStream(chan.jingle)
		} else {
			rl.UpdateMusicStream(chan.jingle)
			if !rl.IsMusicStreamPlaying(chan.jingle) do channel_jingle_stop() // played once
		}
	}
	if chan.bgm_wait > 0 && !scene_fading() {
		chan.bgm_wait -= rl.GetFrameTime()
		if chan.bgm_wait <= 0 {
			if channel_running() do channel_music_play(chan.bgm_pending)
			delete(chan.bgm_pending)
			chan.bgm_pending = ""
		}
	}
	// the theme music fades down under a jingle and back up after it
	{
		target: f32 = chan.has_jingle ? 1 : 0
		if chan.duck != target || target > 0 {
			step := rl.GetFrameTime() * 3
			chan.duck = target > chan.duck ? min(target, chan.duck + step) : max(target, chan.duck - step)
			if theme.has_music do rl.SetMusicVolume(theme.music, app.settings.volume * (1 - 0.8 * chan.duck))
		}
	}
	// loads / unloads run while the screen is black (scene_fade_run); a request waits if a fade is busy
	if chan.restart_req && scene_fade_run(proc(i: int) {
		if i < 0 do return
		channel_stop(keep_music = true)
		channel_start(i)
	}, chan.running) {
		chan.restart_req = false
	}
	if chan.close_req && scene_fade_run(proc(_: int) {
		if !channel_running() do return
		channel_stop()
		sfx_back()
	}, 0) {
		chan.close_req = false
	}
	if i := chan.start_req; i >= 0 && scene_fade_run(proc(i: int) {
		if !channel_running() && i < len(chan.list) do channel_start(i)
	}, i, 0.5) {
		chan.start_req = -1
	}
	if chan.rescan_req && !channel_running() && !scene_fading() {
		chan.rescan_req = false
		channels_scan()
	}
}

CHANNEL_API := [?]struct {
	name: cstring,
	fn:   lua_CFunction,
} {
	{"Draw_Rect", lua_ch_draw_rect},
	{"Draw_Outline", lua_ch_draw_outline},
	{"Draw_Circle", lua_ch_draw_circle},
	{"Draw_Line", lua_ch_draw_line},
	{"Draw_Gradient", lua_ch_draw_gradient},
	{"Draw_Text", lua_ch_draw_text},
	{"Text_Width", lua_ch_text_width},
	{"Draw_Image", lua_ch_draw_image},
	{"Draw_Shader", lua_ch_draw_shader},
	{"Image_Size", lua_ch_image_size},
	{"Draw_Wallpaper", lua_ch_draw_wallpaper},
	{"Draw_Panel", lua_ch_draw_panel},
	{"Input", lua_ch_input},
	{"Mouse", lua_ch_mouse},
	{"Screen_Size", lua_ch_screen_size},
	{"Time", lua_ch_time},
	{"Play_Sfx", lua_ch_play_sfx},
	{"Channel_Close", lua_ch_close},
}

channel_start :: proc(i: int) {
	ch := &chan.list[i]
	L := lua_new_state()
	luaL_openlibs(L)
	lua_createtable(L, 0, 4)
	lua_pushcclosure(L, lua_saber_log, 0)
	lua_setfield(L, -2, "log")
	push_field(L, "version", saber_version())
	lua_setglobal(L, "saber")
	lua_set_global_string(L, "PLUGIN_DIR", ch.dir)
	lua_set_global_string(L, "CHANNEL_DIR", ch.dir)
	lua_set_global_string(L, "SABER_DIR", app.exe_dir)
	lua_set_global_string(L, "WALLPAPER_DIR", theme.bkg_dir)
	lua_set_global_string(L, "MUSIC_DIR", theme.bgm_dir)
	for f in PLUGIN_API do lua_register(L, f.name, f.fn)
	for f in CHANNEL_API do lua_register(L, f.name, f.fn)

	fail :: proc(L: ^lua_State, ch: ^Channel, msg: string) {
		channel_logf("%s: %s", ch.folder, msg)
		set_status("%s: %s", ch.name, msg)
		lua_close(L)
		sfx_back()
	}
	path := strings.clone_to_cstring(tjoin({ch.dir, "channel.lua"}), context.temp_allocator)
	if luaL_loadfilex(L, path, nil) != LUA_OK || lua_pcall(L, 0, 1, 0) != LUA_OK {
		fail(L, ch, lua_string(L, -1))
		return
	}
	if lua_type(L, -1) != LUA_TTABLE {
		fail(L, ch, "channel.lua must return a table")
		return
	}
	lua_setglobal(L, "CHANNEL")
	lua_watch_install(L)

	chan.L = L
	chan.running = i
	chan.started = rl.GetTime()
	chan.preview = false
	chan.preview_t = 0
	chan.menu_open = false
	chan.menu_t = 0
	chan.inp = {}
	channel_jingle_stop()
	// the bgm starts 0.5 s after the fade-in; the menu music stops now
	if theme.has_music do rl.PauseMusicStream(theme.music)
	delete(chan.bgm_pending)
	chan.bgm_pending = strings.clone(ch.bgm)
	chan.bgm_wait = 0.5
	scene_switch(.Channel)
	sfx_start()
	channel_logf("%s: started", ch.folder)
	if !channel_call("on_start") do chan.close_req = true
	eat_input()
}

// Calls CHANNEL[name]() if it exists; false on a Lua error (logged and shown).
channel_call :: proc(name: cstring, args: ..f64) -> bool {
	L := chan.L
	top := lua_gettop(L)
	defer lua_settop(L, top)
	lua_getglobal(L, "CHANNEL")
	if lua_getfield(L, -1, name) != LUA_TFUNCTION do return true
	for a in args do lua_pushnumber(L, a)
	lua_watch_begin(L)
	status := lua_pcall(L, c.int(len(args)), 0, 0)
	lua_watch_end()
	if status != LUA_OK {
		msg := lua_string(L, -1)
		ch := &chan.list[chan.running]
		channel_logf("%s: %s: %s", ch.folder, name, msg)
		set_status("%s: %s", ch.name, msg)
		return false
	}
	return true
}

channel_stop :: proc(keep_music := false) {
	if !channel_running() do return
	L := chan.L
	ch := &chan.list[chan.running]
	channel_call("on_close")
	lua_state_forget(L)
	lua_close(L)
	channel_logf("%s: closed", ch.folder)
	chan.L = nil
	chan.running = -1
	chan.menu_open = false
	chan.menu_t = 0
	for k, &img in chan.images {
		if img.ok do rl.UnloadTexture(img.tex)
		thumb_shader_unload(&img.sh)
		delete(k)
	}
	clear(&chan.images)
	if !keep_music {
		chan.bgm_wait = 0
		if !chan.has_music && theme.has_music && !explorer.has_music do rl.ResumeMusicStream(theme.music) // closed before its bgm began
		channel_music_stop()
	}
	if !keep_music do scene_switch(.Menu) // a restart stays in the Channel scene
	eat_input()
}

// Drops everything Saber still holds that points into a Lua state that's about to close.
lua_state_forget :: proc(L: ^lua_State) {
	for i := len(plugin_dialogs) - 1; i >= 0; i -= 1 {
		if plugin_dialogs[i].L == L {
			dialog_free(&plugin_dialogs[i])
			ordered_remove(&plugin_dialogs, i)
		}
	}
	for r in http_requests {
		if r.L != L do continue
		if r.callback != LUA_NOREF do luaL_unref(r.L, LUA_REGISTRYINDEX, r.callback)
		r.callback = LUA_NOREF
		r.L = nil
	}
	plugin_view_forget(L)
}

// Display name of whatever owns a Lua state (a plugin or the running channel).
lua_owner_name :: proc(L: ^lua_State) -> string {
	if p := plugin_for_state(L); p != nil do return p.name
	if L != nil && L == chan.L && chan.running >= 0 do return chan.list[chan.running].name
	return "Plugin"
}

// Input while a channel runs: Select / Esc is Saber's (the Home menu), the rest is the channel's.
channel_input :: proc() {
	if chan.menu_open {
		channel_menu_input()
		return
	}
	if input.power && !input.menu {
		chan.menu_open = true
		chan.menu_sel = 0
		sfx_click()
		return
	}
	chan.inp = input
}

// info.toml background=: a shader (cached in chan.images like Draw_Shader) or a picture, cover-fit.
channel_draw_background :: proc(path: string, w, h: f32) {
	r := rl.Rectangle{0, 0, w, h}
	if has_ext(path, ".glsl", ".frag", ".fs") {
		img, found := &chan.images[path]
		if !found {
			sh := thumb_shader_load(path)
			if !sh.ok do channel_logf("background %s didn't compile (GLSL 330, needs mainImage(out vec4, in vec2))", path)
			chan.images[strings.clone(path)] = {sh = sh}
			img = &chan.images[path]
		}
		img.used = chan.frames
		thumb_shader_draw(&img.sh, r, 0)
		return
	}
	if tex, ok := ch_image(path); ok do draw_texture_rounded(tex, r, 0, 1)
}

// Draws the running channel over the whole window (in place of the menus).
draw_channel_frame :: proc(w, h: f32) {
	rl.DrawRectangle(0, 0, i32(w), i32(h), rl.BLACK)
	chan.loads = 0
	if ch := &chan.list[chan.running]; ch.background != "" do channel_draw_background(ch.background, w, h)
	chan.in_frame = true
	ok := channel_call("frame", f64(rl.GetFrameTime()), f64(w), f64(h))
	chan.in_frame = false
	chan.inp = {}
	chan.frames += 1
	if !ok do chan.close_req = true
	channel_images_trim()
}

channel_images_trim :: proc() {
	if len(chan.images) < 48 do return
	old := make([dynamic]string, context.temp_allocator)
	for k, img in chan.images do if chan.frames - img.used > 120 do append(&old, k)
	for k in old {
		img := chan.images[k]
		if img.ok do rl.UnloadTexture(img.tex)
		thumb_shader_unload(&img.sh)
		delete_key(&chan.images, k)
		delete(k)
	}
}

// ---------------------------------------------------------------------------
// Home menu (Select / Esc inside a channel)

channel_menu_input :: proc() {
	n := len(Channel_Menu_Row)
	nav_list(&chan.menu_sel, n)
	if input.cancel || input.power {
		chan.menu_open = false
		sfx_back()
		return
	}
	if input.confirm do channel_menu_choose(Channel_Menu_Row(chan.menu_sel))
}

channel_menu_choose :: proc(row: Channel_Menu_Row) {
	switch row {
	case .Resume:
		chan.menu_open = false
		sfx_back()
	case .Restart:
		chan.menu_open = false
		chan.restart_req = true
	case .Close:
		chan.close_req = true
	}
}

draw_channel_menu :: proc(w, h: f32) {
	if !modal_fade(&chan.menu_t, chan.menu_open && channel_running()) do return
	if !channel_running() do return
	bh: f32 = 54
	gap: f32 = 10
	rows := len(Channel_Menu_Row)
	r := modal_panel({0, 0, w, h}, 480, 104 + f32(rows) * (bh + gap) + 14, chan.menu_t)
	if chan.menu_t < 0.5 do return
	draw_t_fit(chan.list[chan.running].name, r.x + 28, r.y + 26, r.width - 56, 26, COL_TEXT, false)
	draw_t("Home Menu", r.x + 28, r.y + 62, 15, COL_MUTED)
	y := r.y + 104
	for row in Channel_Menu_Row {
		br := rl.Rectangle{r.x + 24, y, r.width - 48, bh}
		if chan.menu_open {
			if mouse_over(br, true) do chan.menu_sel = int(row)
			if ui_button(fmt.tprintf("chan-menu-%d", int(row)), br, CHANNEL_MENU_LABELS[row], int(row) == chan.menu_sel, true) do channel_menu_choose(row)
		} else {
			ui_button("", br, CHANNEL_MENU_LABELS[row], false, true)
		}
		y += bh + gap
	}
	draw_hints(w, h, []Hint{{"A", "Select"}, {"B", "Resume"}})
}

// ---------------------------------------------------------------------------
// Lua API (only during the running channel's frame, except Input / Mouse / Time / Screen_Size)

ch_in_frame :: proc(L: ^lua_State, name: string) -> bool {
	if chan.in_frame && chan.L == L do return true
	lua_pushstring(L, strings.clone_to_cstring(fmt.tprintf("%s: only works inside the channel's frame function", name), context.temp_allocator))
	return false
}

ch_num :: proc(L: ^lua_State, idx: c.int, def: f32 = 0) -> f32 {
	t := lua_type(L, idx)
	if t != LUA_TNUMBER && t != LUA_TSTRING do return def
	return f32(lua_tonumberx(L, idx, nil))
}

hex_digit :: proc(ch: u8) -> (u8, bool) {
	switch ch {
	case '0' ..= '9': return ch - '0', true
	case 'a' ..= 'f': return ch - 'a' + 10, true
	case 'A' ..= 'F': return ch - 'A' + 10, true
	}
	return 0, false
}

// "#rrggbb[aa]", {r, g, b [, a]} (or r=, g=, b=, a=), or a theme color name.
ch_color :: proc(L: ^lua_State, idx: c.int, def: rl.Color) -> rl.Color {
	switch lua_type(L, idx) {
	case LUA_TSTRING:
		s := lua_string(L, idx)
		if strings.has_prefix(s, "#") && (len(s) == 7 || len(s) == 9) {
			out := [4]u8{0, 0, 0, 255}
			for k in 0 ..< (len(s) - 1) / 2 {
				hi, ok1 := hex_digit(s[1 + k * 2])
				lo, ok2 := hex_digit(s[2 + k * 2])
				if !ok1 || !ok2 do return def
				out[k] = hi * 16 + lo
			}
			return {out[0], out[1], out[2], out[3]}
		}
		switch ascii_lower(s, context.temp_allocator) {
		case "text":   return COL_TEXT
		case "muted":  return COL_MUTED
		case "accent": return COL_ACCENT
		case "warn":   return COL_WARN
		case "bg":     return COL_BG
		case "panel":  return COL_PANEL_SOLID
		case "white":  return rl.WHITE
		case "black":  return rl.BLACK
		}
	case LUA_TTABLE:
		comp :: proc(L: ^lua_State, idx: c.int, i: i64, key: cstring, def: u8) -> u8 {
			v := def
			if lua_rawgeti(L, idx, i) == LUA_TNUMBER {
				v = u8(clamp(lua_tonumberx(L, -1, nil), 0, 255))
			} else {
				lua_pop(L, 1)
				if lua_getfield(L, idx, key) == LUA_TNUMBER do v = u8(clamp(lua_tonumberx(L, -1, nil), 0, 255))
			}
			lua_pop(L, 1)
			return v
		}
		idx := idx < 0 ? lua_gettop(L) + idx + 1 : idx
		return {comp(L, idx, 1, "r", 0), comp(L, idx, 2, "g", 0), comp(L, idx, 3, "b", 0), comp(L, idx, 4, "a", 255)}
	}
	return def
}

lua_ch_draw_rect :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !ch_in_frame(L, "Draw_Rect") do return lua_error(L)
	r := rl.Rectangle{ch_num(L, 1), ch_num(L, 2), ch_num(L, 3), ch_num(L, 4)}
	col := ch_color(L, 5, rl.WHITE)
	if rad := ch_num(L, 6); rad > 0 {
		rl.DrawRectangleRounded(r, roundness(r, rad), 10, col)
	} else {
		rl.DrawRectangleRec(r, col)
	}
	return 0
}

lua_ch_draw_outline :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !ch_in_frame(L, "Draw_Outline") do return lua_error(L)
	r := rl.Rectangle{ch_num(L, 1), ch_num(L, 2), ch_num(L, 3), ch_num(L, 4)}
	col := ch_color(L, 5, rl.WHITE)
	thick := ch_num(L, 6, 2)
	if rad := ch_num(L, 7); rad > 0 {
		rl.DrawRectangleRoundedLinesEx(r, roundness(r, rad), 10, thick, col)
	} else {
		rl.DrawRectangleLinesEx(r, thick, col)
	}
	return 0
}

lua_ch_draw_circle :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !ch_in_frame(L, "Draw_Circle") do return lua_error(L)
	rl.DrawCircleV({ch_num(L, 1), ch_num(L, 2)}, ch_num(L, 3), ch_color(L, 4, rl.WHITE))
	return 0
}

lua_ch_draw_line :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !ch_in_frame(L, "Draw_Line") do return lua_error(L)
	rl.DrawLineEx({ch_num(L, 1), ch_num(L, 2)}, {ch_num(L, 3), ch_num(L, 4)}, ch_num(L, 6, 2), ch_color(L, 5, rl.WHITE))
	return 0
}

lua_ch_draw_gradient :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !ch_in_frame(L, "Draw_Gradient") do return lua_error(L)
	top := ch_color(L, 5, rl.BLACK)
	rl.DrawRectangleGradientV(i32(ch_num(L, 1)), i32(ch_num(L, 2)), i32(ch_num(L, 3)), i32(ch_num(L, 4)), top, ch_color(L, 6, top))
	return 0
}

// Draw_Text(text, x, y [, size [, color [, align]]])
lua_ch_draw_text :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !ch_in_frame(L, "Draw_Text") do return lua_error(L)
	text := strings.clone(lua_string(L, 1), context.temp_allocator)
	x, y := ch_num(L, 2), ch_num(L, 3)
	size := clamp(ch_num(L, 4, 20), 6, 400)
	col := ch_color(L, 5, COL_TEXT)
	switch lua_string(L, 6) {
	case "center": draw_t_center(text, x, y, size, col)
	case "right":  draw_t_right(text, x, y, size, col)
	case:          draw_t(text, x, y, size, col)
	}
	return 0
}

lua_ch_text_width :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	lua_pushnumber(L, f64(measure_t(lua_string(L, 1), clamp(ch_num(L, 2, 20), 6, 400))))
	return 1
}

// Cached texture of a channel image; one new image is loaded per frame (decoding can be slow).
ch_image :: proc(path: string) -> (rl.Texture2D, bool) {
	if path == "" do return {}, false
	if img, found := &chan.images[path]; found {
		img.used = chan.frames
		return img.tex, img.ok
	}
	if chan.loads >= 1 do return {}, false
	chan.loads += 1
	tex, ok := load_texture_smooth(path, 2048)
	chan.images[strings.clone(path)] = {tex = tex, ok = ok, used = chan.frames}
	return tex, ok
}

// Draw_Image(path, x, y, w, h [, {fit = "stretch"|"cover"|"contain", alpha = 0..1, radius = px}]) -> drawn
lua_ch_draw_image :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !ch_in_frame(L, "Draw_Image") do return lua_error(L)
	tex, ok := ch_image(lua_plugin_path(L, lua_string(L, 1)))
	if !ok {
		lua_pushboolean(L, 0)
		return 1
	}
	r := rl.Rectangle{ch_num(L, 2), ch_num(L, 3), ch_num(L, 4), ch_num(L, 5)}
	fit := 0
	alpha: f32 = 1
	radius: f32 = 0
	if lua_type(L, 6) == LUA_TTABLE {
		switch lua_field_string(L, 6, "fit") {
		case "cover":   fit = 1
		case "contain": fit = 2
		}
		if lua_getfield(L, 6, "alpha") == LUA_TNUMBER do alpha = clamp(f32(lua_tonumberx(L, -1, nil)), 0, 1)
		lua_pop(L, 1)
		if lua_getfield(L, 6, "radius") == LUA_TNUMBER do radius = f32(lua_tonumberx(L, -1, nil))
		lua_pop(L, 1)
	}
	draw_texture_rounded(tex, r, radius, fit, fade_color(rl.WHITE, alpha))
	lua_pushboolean(L, 1)
	return 1
}

// Draw_Shader(path, x, y, w, h [, {alpha, radius}]) -> true | false (missing / didn't compile)
lua_ch_draw_shader :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !ch_in_frame(L, "Draw_Shader") do return lua_error(L)
	path := lua_plugin_path(L, lua_string(L, 1))
	img, found := &chan.images[path]
	if !found {
		sh := thumb_shader_load(path)
		if !sh.ok do channel_logf("%s didn't compile (GLSL 330, needs mainImage(out vec4, in vec2))", path)
		chan.images[strings.clone(path)] = {sh = sh}
		img = &chan.images[path]
	}
	img.used = chan.frames
	if !img.sh.ok {
		lua_pushboolean(L, 0)
		return 1
	}
	r := rl.Rectangle{ch_num(L, 2), ch_num(L, 3), ch_num(L, 4), ch_num(L, 5)}
	alpha: f32 = 1
	radius: f32 = 0
	if lua_type(L, 6) == LUA_TTABLE {
		if lua_getfield(L, 6, "alpha") == LUA_TNUMBER do alpha = clamp(f32(lua_tonumberx(L, -1, nil)), 0, 1)
		lua_pop(L, 1)
		if lua_getfield(L, 6, "radius") == LUA_TNUMBER do radius = f32(lua_tonumberx(L, -1, nil))
		lua_pop(L, 1)
	}
	thumb_shader_draw(&img.sh, r, radius, fade_color(rl.WHITE, alpha))
	lua_pushboolean(L, 1)
	return 1
}

lua_ch_image_size :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	tex, ok := ch_image(lua_plugin_path(L, lua_string(L, 1)))
	if !ok {
		lua_pushnil(L)
		return 1
	}
	lua_pushnumber(L, f64(tex.width))
	lua_pushnumber(L, f64(tex.height))
	return 2
}

lua_ch_draw_wallpaper :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !ch_in_frame(L, "Draw_Wallpaper") do return lua_error(L)
	draw_wallpaper(f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
	return 0
}

lua_ch_draw_panel :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if !ch_in_frame(L, "Draw_Panel") do return lua_error(L)
	draw_panel({ch_num(L, 1), ch_num(L, 2), ch_num(L, 3), ch_num(L, 4)}, lua_toboolean(L, 5) != 0)
	return 0
}

lua_ch_input :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	inp := chan.L == L ? chan.inp : Input{}
	lua_createtable(L, 0, 11)
	set :: proc(L: ^lua_State, key: cstring, v: bool) {
		lua_pushboolean(L, v ? 1 : 0)
		lua_setfield(L, -2, key)
	}
	set(L, "up", inp.up)
	set(L, "down", inp.down)
	set(L, "left", inp.left)
	set(L, "right", inp.right)
	set(L, "a", inp.confirm)
	set(L, "b", inp.cancel)
	set(L, "x", inp.action)
	set(L, "y", inp.extra)
	set(L, "lb", inp.menu_l)
	set(L, "rb", inp.menu_r)
	set(L, "start", inp.menu)
	return 1
}

lua_ch_mouse :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	m := rl.GetMousePosition()
	free := chan.L == L && !chan.menu_open && !pview.open && !plugin_dialog_open()
	lua_pushnumber(L, f64(m.x))
	lua_pushnumber(L, f64(m.y))
	lua_pushboolean(L, free && rl.IsMouseButtonPressed(.LEFT) ? 1 : 0)
	lua_pushboolean(L, free && rl.IsMouseButtonDown(.LEFT) ? 1 : 0)
	return 4
}

lua_ch_screen_size :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	lua_pushnumber(L, f64(rl.GetScreenWidth()))
	lua_pushnumber(L, f64(rl.GetScreenHeight()))
	return 2
}

lua_ch_time :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	lua_pushnumber(L, rl.GetTime() - chan.started)
	return 1
}

lua_ch_play_sfx :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	switch lua_string(L, 1) {
	case "click": play_sfx(.Click)
	case "back":  play_sfx(.Back)
	case "over":  play_sfx(.Over)
	case "start": play_sfx(.Start)
	}
	return 0
}

lua_ch_close :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if chan.L == L do chan.close_req = true
	return 0
}
