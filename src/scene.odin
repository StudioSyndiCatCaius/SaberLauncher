package saber

// Scenes: what the main loop runs besides the global systems.
//
//   GLOBAL (every scene): input, HTTP callbacks, install / BIOS / app store / update jobs,
//          drive *detection* (masks, removal notices), plugin dialogs, the install / drive cards.
//   Menu:    the tabs and their modals, glass wallpaper capture, theme music, wallpaper / music
//            autochange, drive *scans* and the plugin hooks they fire.
//   Channel: the running channel, its Home menu, its plugin views / dialogs, its music.
//
// While a channel runs, a disc or drive change is only noted: the scan (and on_disc / on_scan)
// starts once the Menu is back, and plugins' dialogs wait there too. The Menu keeps everything
// loaded, so coming back is instant.

import "base:runtime"
import "core:time"
import rl "vendor:raylib"

Scene :: enum {
	Menu,
	Channel,
}

scene: Scene

scene_switch :: proc(next: Scene) {
	if next == scene do return
	// leave
	switch scene {
	case .Menu:
		if theme.has_music do rl.PauseMusicStream(theme.music)
	case .Channel:
	}
	scene = next
	// enter
	switch next {
	case .Menu:
		// theme music comes back through theme_update; deferred drive scans start in poll_drive_changes
		if theme.has_music && !chan.has_music && !explorer.has_music do rl.ResumeMusicStream(theme.music)
	case .Channel:
	}
	eat_input()
}

// The scene's per-frame updates (before input).
scene_update :: proc() {
	if scene == .Channel && !channel_running() {
		channel_music_stop()
		scene_switch(.Menu) // e.g. a restart whose channel failed to load
	}
	switch scene {
	case .Menu:
		theme_update()
		autochange_update()
	case .Channel:
	}
}

scene_draw :: proc(w, h: f32) {
	switch scene {
	case .Menu:    draw_menu_scene(w, h)
	case .Channel: draw_channel_scene(w, h)
	}
}

draw_menu_scene :: proc(w, h: f32) {
	// Glass backdrops: the wallpaper for menu panels, and under a dialog the
	// menus too, which are then drawn once into the capture instead of twice.
	update_swipe()
	under_dialog := false
	if glass_capture_begin(w, h) {
		draw_wallpaper(w, h)
		glass_capture_end(.Wall)
		if dialog_visible() {
			glass_capture_begin(w, h)
			draw_menus(w, h)
			glass_capture_end(.Over)
			under_dialog = true
		}
	}

	rl.BeginDrawing()
	if under_dialog {
		glass_draw_scene()
	} else {
		draw_wallpaper(w, h)
		draw_menus(w, h)
	}
	glass.source = under_dialog ? .Over : .Wall
	draw_drive_scan_card(w, h)
	draw_install_card(w, h)
	draw_download_card(w, h)
	draw_batch_card(w, h)
	draw_power_dialog(w, h)
	draw_game_menu(w, h)
	draw_home_menu(w, h)
	draw_app_menu(w, h)
	draw_bios_menu(w, h)
	draw_file_explorer(w, h)
	draw_channel_preview(w, h)
	draw_plugin_view(w, h)
	draw_plugin_dialog(w, h)
	emu_menu_draw(w, h)
	glass.source = .Wall
	draw_scene_fade(w, h)
	rl.EndDrawing()
}

// Something glassy is drawn over the channel: its frame is captured as their backdrop.
channel_overlay_visible :: proc() -> bool {
	return chan.menu_open || chan.menu_t >= 0.02 || pview.open || pview.t >= 0.02 || plugin_dialog_open() ||
		install.running || install.card_t >= 0.02 || download_card_visible() || download_running() != nil || batch_card_visible() || drive_scan.card_t >= 0.02 || drive_notice.at > 0 && rl.GetTime() - drive_notice.at < DRIVE_NOTICE_SEC
}

draw_channel_scene :: proc(w, h: f32) {
	// no wallpaper capture: the channel covers the whole window
	under := false
	if channel_overlay_visible() && glass_capture_begin(w, h) {
		draw_channel_frame(w, h)
		glass_capture_end(.Over)
		under = true
	}
	rl.BeginDrawing()
	if under do glass_draw_scene()
	else do draw_channel_frame(w, h)
	glass.source = .Over
	draw_scene_toast(w, h)
	draw_drive_scan_card(w, h)
	draw_install_card(w, h)
	draw_download_card(w, h)
	draw_batch_card(w, h)
	draw_plugin_view(w, h)
	draw_plugin_dialog(w, h)
	draw_channel_menu(w, h)
	glass.source = .Wall
	draw_scene_fade(w, h)
	rl.EndDrawing()
}

// The status line has no footer inside a channel: a small pill at the top instead.
draw_scene_toast :: proc(w, h: f32) {
	age := rl.GetTime() - app.status_at
	if app.status == "" || age >= STATUS_SECONDS do return
	a := clamp(f32(STATUS_SECONDS - age), 0, 1) * clamp(f32(age) * 6, 0, 1)
	tw := min(measure_t(app.status, 17), w - PAD * 4)
	r := rl.Rectangle{(w - tw) * 0.5 - 20, 18, tw + 40, 38}
	rl.DrawRectangleRounded(r, 1, 12, with_alpha(rl.BLACK, u8(170 * a)))
	draw_t_fit(app.status, r.x + 20, r.y + 10, tw, 17, with_alpha(rl.WHITE, u8(255 * a)), false)
}

// ---------------------------------------------------------------------------
// Fade: a very short fade to black; the load work (scripts, on_start / on_close) runs while the
// screen is fully black, then it fades back in. Input is held during the whole thing.

FADE_OUT_SEC :: 0.12
FADE_IN_SEC :: 0.2

scene_fade: struct {
	t:     f32, // 0 = clear, 1 = black
	out:   bool, // fading out toward running `run`
	shown: bool, // a fully black frame has been presented
	run:   proc(arg: int),
	arg:   int,
	hold:  f32, // seconds to stay black after run (before fading in)
}

// Fades out, runs run(arg) on black, fades in. false = a fade is already going (try again later).
scene_fade_run :: proc(run: proc(arg: int), arg: int, hold: f32 = 0) -> bool {
	if scene_fade.run != nil || scene_fade.hold > 0 do return false
	scene_fade.run, scene_fade.arg = run, arg
	scene_fade.hold = hold
	scene_fade.out, scene_fade.shown = true, false
	return true
}

scene_fading :: proc() -> bool {
	return scene_fade.run != nil || scene_fade.t > 0 || scene_fade.hold > 0
}

// Start of the frame, before channels_update.
scene_fade_update :: proc() {
	dt := min(rl.GetFrameTime(), 1.0 / 30) // a slow load mustn't swallow the fade-in
	if scene_fade.out {
		scene_fade.t = min(1, scene_fade.t + dt / FADE_OUT_SEC)
		if scene_fade.t >= 1 && scene_fade.shown {
			run, arg := scene_fade.run, scene_fade.arg
			scene_fade.out = false
			run(arg)
			scene_fade.run = nil
		}
	} else if scene_fade.hold > 0 {
		scene_fade.hold -= dt
	} else if scene_fade.t > 0 {
		scene_fade.t = max(0, scene_fade.t - dt / FADE_IN_SEC)
	}
}

// Last thing drawn in a frame.
draw_scene_fade :: proc(w, h: f32) {
	if scene_fade.t <= 0 do return
	rl.DrawRectangle(0, 0, i32(w), i32(h), with_alpha(rl.BLACK, u8(255 * scene_fade.t)))
	if scene_fade.t >= 1 do scene_fade.shown = true
}

// ---------------------------------------------------------------------------
// Watchdog: a channel's Lua that runs too long in one call is stopped instead of freezing Saber.

LUA_MASKCOUNT :: 1 << 3
LUA_WATCH_COUNT :: 100_000 // instructions between checks
LUA_WATCH_LIMIT :: 5 * time.Second

lua_watch: struct {
	L:     ^lua_State,
	start: time.Tick,
	on:    bool,
}

// Arms the watchdog for a call into L (only the running channel's state is watched).
lua_watch_begin :: proc(L: ^lua_State) {
	if L == nil || L != chan.L do return
	lua_watch.L = L
	lua_watch.start = time.tick_now()
	lua_watch.on = true
}

lua_watch_end :: proc() {
	lua_watch.on = false
}

lua_watch_install :: proc(L: ^lua_State) {
	lua_sethook(L, lua_watch_hook, LUA_MASKCOUNT, LUA_WATCH_COUNT)
}

lua_watch_hook :: proc "c" (L: ^lua_State, ar: rawptr) {
	context = runtime.default_context()
	if !lua_watch.on || lua_watch.L != L do return
	if time.tick_since(lua_watch.start) < LUA_WATCH_LIMIT do return
	lua_watch.on = false
	lua_pushstring(L, "stopped: the channel didn't respond for 5 seconds")
	lua_error(L)
}
