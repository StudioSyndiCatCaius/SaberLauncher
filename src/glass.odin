package saber

import "core:math"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// Liquid glass: what sits behind the UI is captured into `scene` each frame and
// blurred at quarter size. Panels then draw with a shader that samples that blur
// through a rounded-rect lens (bent at the rim), tints it, and lights the edge.

Glass_Layer :: enum {
	Wall, // wallpaper only (or the game frame in-game)
	Over, // wallpaper + the menus under an open dialog
}

Glass :: struct {
	tried, ok:    bool,
	shader, blur: rl.Shader,
	loc_backdrop: i32,
	loc_screen:   i32,
	loc_rect:     i32,
	loc_tint:     i32,
	loc_glow:     i32,
	loc_params:   i32,
	loc_dir:      i32,
	w, h:         i32,
	scene:        rl.RenderTexture2D,
	half:         rl.RenderTexture2D,
	ping, pong:   rl.RenderTexture2D,
	layers:       [Glass_Layer]rl.RenderTexture2D,
	source:       Glass_Layer,
}

glass: Glass

GLASS_BLUR_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
out vec4 finalColor;
uniform sampler2D texture0;
uniform vec2 dir;
void main() {
	vec3 c = texture(texture0, fragTexCoord).rgb * 0.2270270270;
	c += texture(texture0, fragTexCoord + dir * 1.3846153846).rgb * 0.3162162162;
	c += texture(texture0, fragTexCoord - dir * 1.3846153846).rgb * 0.3162162162;
	c += texture(texture0, fragTexCoord + dir * 3.2307692308).rgb * 0.0702702703;
	c += texture(texture0, fragTexCoord - dir * 3.2307692308).rgb * 0.0702702703;
	finalColor = vec4(c, 1.0);
}
`

GLASS_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
out vec4 finalColor;
uniform sampler2D backdrop;
uniform vec2 screen;
uniform vec4 rect;   // x, y, w, h (top-left pixels)
uniform vec4 tint;   // rgb, a = how much of it replaces the backdrop
uniform vec4 glow;   // rgb, a = focus strength
uniform vec4 params; // radius, alpha, light theme, refraction px

float sd_round(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec3 behind(vec2 px) {
	vec2 uv = clamp(vec2(px.x / screen.x, 1.0 - px.y / screen.y), vec2(0.001), vec2(0.999));
	return texture(backdrop, uv).rgb;
}

void main() {
	float radius = params.x;
	vec2 px = vec2(gl_FragCoord.x, screen.y - gl_FragCoord.y);
	vec2 hb = rect.zw * 0.5;
	vec2 p = px - (rect.xy + hb);
	float d = sd_round(p, hb, radius);
	float cover = clamp(0.5 - d, 0.0, 1.0);
	if (cover <= 0.0) discard;

	// outward normal of the rounded rect
	vec2 q = abs(p) - hb + radius;
	vec2 n = (q.x > 0.0 || q.y > 0.0) ? normalize(max(q, vec2(0.0))) : (q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
	n *= vec2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);

	// bezel: 0 across the flat middle, 1 at the rim; the backdrop bends inward there
	float bezel = max(min(min(hb.x, hb.y), radius * 1.5 + 10.0), 1.0);
	float e = clamp(1.0 + d / bezel, 0.0, 1.0);
	float bend = e * e * e;
	vec2 off = -n * bend * params.w;
	vec3 col = vec3(behind(px + off * 1.12).r, behind(px + off).g, behind(px + off * 0.88).b);

	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(vec3(lum), col, 1.35);
	col = mix(col, tint.rgb, tint.a);

	vec3 white = vec3(1.0);
	float v = clamp((px.y - rect.y) / max(rect.w, 1.0), 0.0, 1.0);
	col = mix(col, white, (1.0 - v) * (0.05 + 0.05 * params.z));
	col = mix(col, white, bend * (0.10 + 0.08 * params.z));

	// specular rim: bright where the edge faces the light (top-left) and its opposite corner
	vec2 L = normalize(vec2(-0.55, -0.85));
	float spec = pow(abs(dot(n, L)), 2.0);
	float rim = clamp(1.0 + d / 1.6, 0.0, 1.0);
	float inner = clamp(1.0 + (d + 1.6) / 2.0, 0.0, 1.0) * (1.0 - rim);
	col *= 1.0 - inner * 0.10;
	col = mix(col, white, rim * (0.16 + 0.64 * spec));

	col = mix(col, glow.rgb, rim * glow.a * 0.85);
	col += glow.rgb * bend * 0.22 * glow.a;

	finalColor = vec4(col, cover * params.y);
}
`

glass_init :: proc() {
	glass.tried = true
	glass.shader = rl.LoadShaderFromMemory(nil, GLASS_FS)
	glass.blur = rl.LoadShaderFromMemory(nil, GLASS_BLUR_FS)
	def := rlgl.GetShaderIdDefault()
	glass.ok = glass.shader.id != def && glass.blur.id != def
	if !glass.ok {
		return
	}
	glass.loc_backdrop = rl.GetShaderLocation(glass.shader, "backdrop")
	glass.loc_screen = rl.GetShaderLocation(glass.shader, "screen")
	glass.loc_rect = rl.GetShaderLocation(glass.shader, "rect")
	glass.loc_tint = rl.GetShaderLocation(glass.shader, "tint")
	glass.loc_glow = rl.GetShaderLocation(glass.shader, "glow")
	glass.loc_params = rl.GetShaderLocation(glass.shader, "params")
	glass.loc_dir = rl.GetShaderLocation(glass.blur, "dir")
}

glass_unload_targets :: proc() {
	if glass.w == 0 {
		return
	}
	rl.UnloadRenderTexture(glass.scene)
	rl.UnloadRenderTexture(glass.half)
	rl.UnloadRenderTexture(glass.ping)
	rl.UnloadRenderTexture(glass.pong)
	for l in glass.layers {
		rl.UnloadRenderTexture(l)
	}
	glass.w, glass.h = 0, 0
}

glass_shutdown :: proc() {
	glass_unload_targets()
	if glass.ok {
		rl.UnloadShader(glass.shader)
		rl.UnloadShader(glass.blur)
	}
	glass.ok = false
}

glass_target :: proc(w, h: i32) -> rl.RenderTexture2D {
	rt := rl.LoadRenderTexture(max(w, 1), max(h, 1))
	rl.SetTextureFilter(rt.texture, .BILINEAR)
	rl.SetTextureWrap(rt.texture, .CLAMP)
	return rt
}

// Loads the shaders once and (re)sizes the targets to the window.
glass_ready :: proc(w, h: f32) -> bool {
	if !glass.tried {
		glass_init()
	}
	iw, ih := i32(w), i32(h)
	if !glass.ok || iw <= 0 || ih <= 0 {
		return false
	}
	if iw != glass.w || ih != glass.h {
		glass_unload_targets()
		glass.scene = glass_target(iw, ih)
		glass.half = glass_target(iw / 2, ih / 2)
		glass.ping = glass_target(iw / 4, ih / 4)
		glass.pong = glass_target(iw / 4, ih / 4)
		for &l in glass.layers {
			l = glass_target(iw / 4, ih / 4)
		}
		glass.w, glass.h = iw, ih
	}
	return true
}

// Everything drawn between begin and end becomes the backdrop for `layer`.
glass_capture_begin :: proc(w, h: f32) -> bool {
	if !glass_ready(w, h) {
		return false
	}
	rl.BeginTextureMode(glass.scene)
	return true
}

glass_capture_end :: proc(layer: Glass_Layer) {
	rl.EndTextureMode()
	glass_pass(glass.scene, glass.half, {})
	glass_pass(glass.half, glass.ping, {})
	tw := 1 / f32(glass.ping.texture.width)
	th := 1 / f32(glass.ping.texture.height)
	glass_pass(glass.ping, glass.pong, {tw, 0})
	glass_pass(glass.pong, glass.ping, {0, th})
	glass_pass(glass.ping, glass.pong, {tw * 2, 0})
	glass_pass(glass.pong, glass.layers[layer], {0, th * 2})
}

// Copy (dir = 0) or one blur direction; always writes opaque pixels.
glass_pass :: proc(src, dst: rl.RenderTexture2D, dir: [2]f32) {
	dir := dir
	rl.BeginTextureMode(dst)
	rl.BeginShaderMode(glass.blur)
	rl.SetShaderValue(glass.blur, glass.loc_dir, &dir, .VEC2)
	sw, sh := f32(src.texture.width), f32(src.texture.height)
	rl.DrawTexturePro(src.texture, {0, 0, sw, -sh}, {0, 0, f32(dst.texture.width), f32(dst.texture.height)}, {}, 0, rl.WHITE)
	rl.EndShaderMode()
	rl.EndTextureMode()
}

// Puts the last capture on screen as-is.
glass_draw_scene :: proc() {
	glass_pass_to_screen(glass.scene)
}

glass_pass_to_screen :: proc(src: rl.RenderTexture2D) {
	dir := [2]f32{}
	rl.BeginShaderMode(glass.blur)
	rl.SetShaderValue(glass.blur, glass.loc_dir, &dir, .VEC2)
	sw, sh := f32(src.texture.width), f32(src.texture.height)
	rl.DrawTexturePro(src.texture, {0, 0, sw, -sh}, {0, 0, sw, sh}, {}, 0, rl.WHITE)
	rl.EndShaderMode()
}

color_vec4 :: proc(c: rl.Color, a: f32) -> [4]f32 {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, a}
}

// Soft shadow made of a few widening, faint rounded rects.
draw_soft_shadow :: proc(r: rl.Rectangle, radius: f32, alpha: f32) {
	base := ui_theme_light ? f32(16) : f32(34)
	for i in 0 ..< 4 {
		g := f32(i) * 3
		s := rl.Rectangle{r.x - g, r.y + 6 - g + f32(i) * 1.5, r.width + g * 2, r.height + g * 2}
		rl.DrawRectangleRounded(s, roundness(s, radius + g), 8, rl.Color{0, 0, 0, u8(base * alpha * (1 - f32(i) * 0.2))})
	}
}

// One glass pane. `tint_amt` is how much of `tint` covers the backdrop (frost),
// `glow_amt` lights the rim and bezel with `glow` (focus).
draw_glass :: proc(r: rl.Rectangle, radius: f32, tint: rl.Color, tint_amt: f32, glow := rl.Color{}, glow_amt: f32 = 0, alpha: f32 = 1, refract: f32 = 14) {
	if r.width <= 0 || r.height <= 0 || alpha <= 0.004 {
		return
	}
	radius := min(radius, min(r.width, r.height) * 0.5)
	if !glass.ok || glass.w == 0 {
		rr := roundness(r, radius)
		rl.DrawRectangleRounded(r, rr, 8, with_alpha(tint, u8(255 * alpha * clamp(0.55 + tint_amt, 0, 1))))
		rl.DrawRectangleRoundedLinesEx(r, rr, 8, 1, glow_amt > 0 ? with_alpha(glow, u8(255 * glow_amt * alpha)) : COL_FAINT)
		return
	}
	screen := [2]f32{f32(glass.w), f32(glass.h)}
	rect := [4]f32{r.x + draw_dx, r.y, r.width, r.height}
	t := color_vec4(tint, tint_amt)
	g := color_vec4(glow, glow_amt)
	params := [4]f32{radius, alpha, ui_theme_light ? 1 : 0, refract}
	rl.BeginShaderMode(glass.shader)
	rl.SetShaderValue(glass.shader, glass.loc_screen, &screen, .VEC2)
	rl.SetShaderValue(glass.shader, glass.loc_rect, &rect, .VEC4)
	rl.SetShaderValue(glass.shader, glass.loc_tint, &t, .VEC4)
	rl.SetShaderValue(glass.shader, glass.loc_glow, &g, .VEC4)
	rl.SetShaderValue(glass.shader, glass.loc_params, &params, .VEC4)
	rl.SetShaderValueTexture(glass.shader, glass.loc_backdrop, glass.layers[glass.source].texture)
	rl.DrawRectangleRec({r.x - 1, r.y - 1, r.width + 2, r.height + 2}, rl.WHITE)
	rl.EndShaderMode()
}

// Large, slow colour blobs so the glass has something to bend when there is no wallpaper.
draw_ambient_orbs :: proc(w, h: f32) {
	t := f32(rl.GetTime())
	size := max(w, h)
	orbs := [3]struct {
		col:       rl.Color,
		x, y, rad: f32,
		sp:        f32,
	} {
		{COL_ACCENT, 0.22, 0.30, 0.55, 0.07},
		{COL_WARN, 0.80, 0.70, 0.50, 0.05},
		{mix_color(COL_ACCENT, COL_WARN, 0.5), 0.60, 0.15, 0.40, 0.09},
	}
	for o, i in orbs {
		ph := f32(i) * 2.1
		c := rl.Vector2{
			w * (o.x + 0.08 * math.sin(t * o.sp + ph)),
			h * (o.y + 0.10 * math.cos(t * o.sp * 0.8 + ph)),
		}
		rl.DrawCircleGradient(c, size * o.rad, with_alpha(o.col, ui_theme_light ? 70 : 95), with_alpha(o.col, 0))
	}
}

mix_color :: proc(a, b: rl.Color, t: f32) -> rl.Color {
	return {
		u8(f32(a.r) + (f32(b.r) - f32(a.r)) * t),
		u8(f32(a.g) + (f32(b.g) - f32(a.g)) * t),
		u8(f32(a.b) + (f32(b.b) - f32(a.b)) * t),
		u8(f32(a.a) + (f32(b.a) - f32(a.a)) * t),
	}
}
