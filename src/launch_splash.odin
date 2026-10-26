package saber

import "core:math"
import rl "vendor:raylib"

// Console-style hand-off: the focused cover zooms to the middle over a backdrop
// blurred from its own art, then idles there until the game is ready. PC games
// hide Saber once they have a window (no desktop flash); emulated games fade the
// splash off their first frames.

SPLASH_IN_SEC :: 0.65
SPLASH_OUT_SEC :: 0.45
SPLASH_MAX_SEC :: 30.0 // a game that never shows a window: give up and hide like before

Launch_Splash :: struct {
	active:   bool,
	started:  f64,
	out_at:   f64, // != 0: fading away over the emulated game
	title:    string,
	box:      rl.Texture2D,
	has_box:  bool,
	from:     rl.Rectangle, // where the cover sat on screen when launched
	has_from: bool,
	ui:       rl.RenderTexture2D, // Saber as it looked at launch
	blur:     rl.RenderTexture2D, // tiny copy of the cover, stretched into the backdrop
	has_blur: bool,
}

splash: Launch_Splash
splash_focus_art: rl.Rectangle // art rect of the focused card, kept by draw_card

splash_begin :: proc(g: ^Game) {
	splash_end()
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())
	splash = {
		active   = true,
		title    = g.title,
		box      = g.box,
		has_box  = g.has_box,
		from     = splash_focus_art,
		has_from = splash_focus_art.width > 0,
	}
	if splash.has_box && splash.has_from {
		splash.from = contain_rect(splash.box, splash.from)
	}

	splash.ui = rl.LoadRenderTexture(i32(w), i32(h))
	eaten := input.mouse_eaten
	input.mouse_eaten = true // no hover or clicks while re-drawing the menu
	rl.BeginTextureMode(splash.ui)
	draw_background(w, h)
	draw_screens(w, h)
	draw_header(w)
	draw_footer(w, h)
	rl.EndTextureMode()
	input.mouse_eaten = eaten

	if splash.has_box {
		splash_make_blur()
	}
	sfx_start()
	theme_pause_for_game()
	splash.started = rl.GetTime()
}

splash_end :: proc() {
	if !splash.active {
		return
	}
	rl.UnloadRenderTexture(splash.ui)
	if splash.has_blur {
		rl.UnloadRenderTexture(splash.blur)
	}
	splash = {}
}

splash_intro_done :: proc() -> bool {
	return rl.GetTime() - splash.started >= SPLASH_IN_SEC
}

// Blocks until the cover has landed; the idle frame stays up while the caller loads.
splash_play_intro :: proc() {
	for splash.active && !splash_intro_done() {
		splash_frame()
	}
	splash_frame()
}

splash_frame :: proc() {
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)
	splash_draw(w, h, 1)
	rl.EndDrawing()
	free_all(context.temp_allocator)
}

// Drawn over an emulated game's first frames until it has faded away.
splash_draw_over_game :: proc(w, h: f32) {
	if !splash.active {
		return
	}
	now := rl.GetTime()
	if splash.out_at == 0 {
		splash.out_at = now
	}
	a := 1 - f32(now - splash.out_at) / SPLASH_OUT_SEC
	if a > 0 {
		splash_draw(w, h, a * a)
	}
}

// Downscale in steps so the last one averages the whole cover instead of sampling a few texels.
splash_make_blur :: proc() {
	sizes := [?][2]i32{{128, 72}, {32, 18}, {12, 7}}
	prev: rl.RenderTexture2D
	for s, i in sizes {
		rt := rl.LoadRenderTexture(s[0], s[1])
		rl.SetTextureFilter(rt.texture, .BILINEAR)
		rl.BeginTextureMode(rt)
		rl.ClearBackground(rl.BLACK)
		dest := rl.Rectangle{0, 0, f32(s[0]), f32(s[1])}
		if i == 0 {
			rl.DrawTexturePro(splash.box, {0, 0, f32(splash.box.width), f32(splash.box.height)}, dest, {}, 0, rl.WHITE)
		} else {
			// render textures are stored upside down
			rl.DrawTexturePro(prev.texture, {0, 0, f32(prev.texture.width), -f32(prev.texture.height)}, dest, {}, 0, rl.WHITE)
		}
		rl.EndTextureMode()
		if i > 0 {
			rl.UnloadRenderTexture(prev)
		}
		prev = rt
	}
	splash.blur = prev
	splash.has_blur = true
}

contain_rect :: proc(tex: rl.Texture2D, r: rl.Rectangle) -> rl.Rectangle {
	tw, th := f32(tex.width), f32(tex.height)
	if tw <= 0 || th <= 0 {
		return r
	}
	s := min(r.width / tw, r.height / th)
	return {r.x + (r.width - tw * s) * 0.5, r.y + (r.height - th * s) * 0.5, tw * s, th * s}
}

lerp_rect :: proc(a, b: rl.Rectangle, t: f32) -> rl.Rectangle {
	return {
		a.x + (b.x - a.x) * t,
		a.y + (b.y - a.y) * t,
		a.width + (b.width - a.width) * t,
		a.height + (b.height - a.height) * t,
	}
}

splash_draw :: proc(w, h, alpha: f32) {
	now := rl.GetTime()
	t := clamp(f32(now - splash.started) / SPLASH_IN_SEC, 0, 1)
	e := ease_out(t)
	fade :: proc(c: rl.Color, a: f32) -> rl.Color {
		return with_alpha(c, u8(f32(c.a) * clamp(a, 0, 1)))
	}

	// Saber as it was, under the backdrop fading in
	if t < 1 && alpha >= 1 {
		uw, uh := f32(splash.ui.texture.width), f32(splash.ui.texture.height)
		rl.DrawTexturePro(splash.ui.texture, {0, 0, uw, -uh}, {0, 0, w, h}, {}, 0, rl.WHITE)
	}
	bg_a := clamp(t * 1.6, 0, 1) * alpha
	if splash.has_blur {
		bw, bh := f32(splash.blur.texture.width), f32(splash.blur.texture.height)
		zoom := 1.15 + 0.03 * math.sin(f32(now) * 0.3)
		dw, dh := w * zoom, h * zoom
		rl.DrawTexturePro(splash.blur.texture, {0, 0, bw, -bh}, {(w - dw) * 0.5, (h - dh) * 0.5, dw, dh}, {}, 0, fade(rl.WHITE, bg_a))
		rl.DrawRectangle(0, 0, i32(w), i32(h), fade(with_alpha(COL_SHADE, 150), bg_a))
	} else {
		rl.DrawRectangle(0, 0, i32(w), i32(h), fade(COL_BG, bg_a))
	}
	band := i32(h * 0.4)
	rl.DrawRectangleGradientV(0, i32(h) - band, i32(w), band, with_alpha(COL_SHADE, 0), fade(with_alpha(COL_SHADE, 200), bg_a))

	// the cover flies from its card to the middle, then breathes
	max_h := h * 0.56
	max_w := w * 0.5
	slot := rl.Rectangle{(w - max_w) * 0.5, h * 0.42 - max_h * 0.5, max_w, max_h}
	dest: rl.Rectangle
	if splash.has_box {
		dest = contain_rect(splash.box, slot)
	} else {
		dw := max_h / 1.4
		dest = {(w - dw) * 0.5, slot.y, dw, max_h}
	}
	if t >= 1 {
		s := 1 + 0.01 * math.sin(f32(now - splash.started - SPLASH_IN_SEC) * 1.6)
		cx, cy := dest.x + dest.width * 0.5, dest.y + dest.height * 0.5
		dest = {cx - dest.width * s * 0.5, cy - dest.height * s * 0.5, dest.width * s, dest.height * s}
	}
	from := splash.from
	if !splash.has_from {
		cx, cy := dest.x + dest.width * 0.5, dest.y + dest.height * 0.5
		from = {cx - dest.width * 0.4, cy - dest.height * 0.4, dest.width * 0.8, dest.height * 0.8}
	}
	r := lerp_rect(from, dest, e)
	cover_a := splash.has_from ? alpha : clamp(t * 2, 0, 1) * alpha
	shadow := rl.Rectangle{r.x - 10, r.y + 6, r.width + 20, r.height + 20}
	rl.DrawRectangleRounded(shadow, roundness(shadow, 18), 8, fade(rl.Color{0, 0, 0, 110}, cover_a * e))
	if splash.has_box {
		rl.DrawTexturePro(splash.box, {0, 0, f32(splash.box.width), f32(splash.box.height)}, r, {}, 0, fade(rl.WHITE, cover_a))
	} else {
		rl.DrawRectangleRounded(r, roundness(r, RADIUS), 8, fade(with_alpha(COL_TINT, 20), cover_a))
		draw_t_center("NO ART", r.x + r.width * 0.5, r.y + r.height * 0.5 - 8, 15, fade(COL_MUTED, cover_a))
	}

	// title and a quiet loader once it has landed
	ta := clamp((t - 0.45) / 0.55, 0, 1) * alpha
	ty := dest.y + dest.height + 34
	draw_t_center(splash.title, w * 0.5, ty, 32, fade(COL_TEXT, ta))
	for i in 0 ..< 3 {
		p := 0.5 + 0.5 * math.sin(f32(now) * 4 - f32(i) * 0.9)
		x := w * 0.5 + f32(i - 1) * 18
		rl.DrawCircleV({x, ty + 70}, 4, fade(COL_ACCENT, ta * (0.3 + 0.7 * p)))
	}
}
