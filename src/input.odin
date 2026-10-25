package saber

import rl "vendor:raylib"

// Every pad is read: controllers often reconnect under a new index after a game
// or Steam Input has had them, which used to leave the launcher deaf.
MAX_PADS :: 4
STICK_DEAD :: 0.52
NAV_FIRST :: 0.28
NAV_REPEAT :: 0.11

Nav_Dir :: enum {
	None,
	Left,
	Right,
	Up,
	Down,
}

Input :: struct {
	up, down, left, right: bool,
	confirm:               bool, // A
	cancel:                bool, // B
	menu_l:                bool, // LB
	menu_r:                bool, // RB
	power:                 bool, // Select / Back
	extra:                 bool, // Y
	using_pad:             bool,
	mouse_eaten:           bool, // a modal took this frame's mouse: screens below ignore hover/clicks
	repeat_dir:            Nav_Dir,
	repeat_at:             f64,
}

input: Input

eat_input :: proc() {
	input.up, input.down, input.left, input.right = false, false, false, false
	input.confirm, input.cancel, input.menu_l, input.menu_r = false, false, false, false
	input.power, input.extra = false, false
}

input_poll :: proc() {
	eat_input()
	input.mouse_eaten = false

	if rl.GetMouseDelta() != {} || rl.IsMouseButtonPressed(.LEFT) {
		input.using_pad = false
	}

	// Digital directions (d-pad, keys) win over the stick, so a drifting or resting
	// stick can't cancel or hijack a deliberate press.
	dx, dy: f32
	ax, ay: f32
	for p in 0 ..< i32(MAX_PADS) {
		if !rl.IsGamepadAvailable(p) {
			continue
		}
		if rl.IsGamepadButtonDown(p, .LEFT_FACE_LEFT) { dx -= 1 }
		if rl.IsGamepadButtonDown(p, .LEFT_FACE_RIGHT) { dx += 1 }
		if rl.IsGamepadButtonDown(p, .LEFT_FACE_UP) { dy -= 1 }
		if rl.IsGamepadButtonDown(p, .LEFT_FACE_DOWN) { dy += 1 }
		sx := rl.GetGamepadAxisMovement(p, .LEFT_X)
		sy := rl.GetGamepadAxisMovement(p, .LEFT_Y)
		if abs(sx) > abs(ax) { ax = sx }
		if abs(sy) > abs(ay) { ay = sy }
		if rl.IsGamepadButtonPressed(p, .RIGHT_FACE_DOWN) { input.confirm = true }
		if rl.IsGamepadButtonPressed(p, .RIGHT_FACE_RIGHT) { input.cancel = true }
		if rl.IsGamepadButtonPressed(p, .LEFT_TRIGGER_1) { input.menu_l = true }
		if rl.IsGamepadButtonPressed(p, .RIGHT_TRIGGER_1) { input.menu_r = true }
		if rl.IsGamepadButtonPressed(p, .MIDDLE_LEFT) || rl.IsGamepadButtonPressed(p, .MIDDLE_RIGHT) { input.power = true }
		if rl.IsGamepadButtonPressed(p, .RIGHT_FACE_UP) { input.extra = true }
	}

	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) { dx -= 1 }
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) { dx += 1 }
	if rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) { dy -= 1 }
	if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) { dy += 1 }
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE) { input.confirm = true }
	if rl.IsKeyPressed(.BACKSPACE) { input.cancel = true }
	if rl.IsKeyPressed(.Q) || rl.IsKeyPressed(.LEFT_BRACKET) { input.menu_l = true }
	if rl.IsKeyPressed(.E) || rl.IsKeyPressed(.RIGHT_BRACKET) { input.menu_r = true }
	if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.TAB) { input.power = true }
	if rl.IsKeyPressed(.F5) || rl.IsKeyPressed(.Y) { input.extra = true }

	dir := Nav_Dir.None
	if dy != 0 {
		dir = dy < 0 ? .Up : .Down
	} else if dx != 0 {
		dir = dx < 0 ? .Left : .Right
	} else if max(abs(ax), abs(ay)) >= STICK_DEAD {
		if abs(ax) > abs(ay) {
			dir = ax < 0 ? .Left : .Right
		} else {
			dir = ay < 0 ? .Up : .Down
		}
	}

	now := rl.GetTime()
	fire := false
	if dir == .None {
		input.repeat_dir = .None
	} else if dir != input.repeat_dir {
		input.repeat_dir = dir
		input.repeat_at = now + NAV_FIRST
		fire = true
	} else if now >= input.repeat_at {
		input.repeat_at = now + NAV_REPEAT
		fire = true
	}
	if fire {
		input.using_pad = true
		switch dir {
		case .Left: input.left = true
		case .Right: input.right = true
		case .Up: input.up = true
		case .Down: input.down = true
		case .None:
		}
	}
	if input.confirm || input.cancel || input.menu_l || input.menu_r || input.power {
		input.using_pad = true
	}
}

// Moves a grid/list selection; returns true when it changed.
nav_grid :: proc(sel: ^int, count, cols: int) -> bool {
	if count <= 0 {
		return false
	}
	old := sel^
	i := clamp(sel^, 0, count - 1)
	if input.left { i = (i - 1 + count) % count }
	if input.right { i = (i + 1) % count }
	if input.up && i - cols >= 0 { i -= cols }
	if input.down {
		if i + cols < count {
			i += cols
		} else if i / cols < (count - 1) / cols {
			i = count - 1 // jump to the last item of a shorter final row
		}
	}
	sel^ = i
	if i != old {
		sfx_click()
		return true
	}
	return false
}

SCREEN_ORDER :: [SCREEN_COUNT]Screen{.Main, .Library, .Movies, .Apps, .Plugins, .Settings}

go_screen :: proc(next: Screen) {
	if next == app.screen {
		return
	}
	dir := int(next) - int(app.screen)
	if dir > SCREEN_COUNT / 2 { dir -= SCREEN_COUNT }
	if dir < -SCREEN_COUNT / 2 { dir += SCREEN_COUNT }
	app.swipe_from = app.screen
	app.screen = next
	app.swipe_dir = f32(dir)
	app.swipe_t = 0
	app.dropdown_open = false
	sfx_click()
}

cycle_screen :: proc(delta: int) {
	order := SCREEN_ORDER
	go_screen(order[(int(app.screen) + delta + SCREEN_COUNT) % SCREEN_COUNT])
}

update_swipe :: proc() {
	app.swipe_t = min(1, app.swipe_t + rl.GetFrameTime() * 4)
}

draw_screen_body :: proc(s: Screen, w, h: f32) {
	switch s {
	case .Main:
		draw_main(w, h)
	case .Library:
		draw_library(w, h)
	case .Movies:
		draw_movies(w, h)
	case .Apps:
		draw_apps(w, h)
	case .Plugins:
		draw_plugins(w, h)
	case .Settings:
		draw_settings(w, h)
	}
}

// Only the page content slides; header and footer are drawn on top afterwards.
draw_screens :: proc(w, h: f32) {
	if app.swipe_t >= 1 {
		draw_screen_body(app.screen, w, h)
		return
	}
	e := ease_out(app.swipe_t)
	draw_offset(app.swipe_from, -e * w * app.swipe_dir, w, h)
	draw_offset(app.screen, (1 - e) * w * app.swipe_dir, w, h)
	draw_dx = 0
}

draw_offset :: proc(s: Screen, dx, w, h: f32) {
	draw_dx = dx // lets push_clip translate scissor rects with the camera
	rl.BeginMode2D({offset = {dx, 0}, zoom = 1})
	draw_screen_body(s, w, h)
	rl.EndMode2D()
}

ease_out :: proc(t: f32) -> f32 {
	u := 1 - t
	return 1 - u * u * u
}
