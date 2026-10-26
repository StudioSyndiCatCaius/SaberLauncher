package saber

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import rl "vendor:raylib"
import win "core:sys/windows"

Screen :: enum {
	Main,
	Library,
	Movies,
	Apps,
	Plugins,
	Settings,
}

SCREEN_COUNT :: len(Screen)

App :: struct {
	screen:          Screen,
	exe_dir:         string,
	games_dir:       string,
	apps_dir:        string,
	movies_dir:      string,
	settings_path:   string,
	settings:        Settings,
	in_shell:        bool, // started by Winlogon in place of Explorer
	drive_games:     [dynamic]Game,
	library_games:   [dynamic]Game,
	shell_apps:      [dynamic]Shell_App,
	movies:          [dynamic]Movie,
	selected_drive:  int,
	selected_lib:    int,
	selected_app:    int,
	selected_movie:  int,
	plugin_sel:      int,
	plugin_action:   int,
	plugin_focus:    int, // 0 = plugin list, 1 = actions
	scroll:          [Screen]f32,
	status_buf:      [256]u8,
	status:          string, // view into status_buf; survives the per-frame temp reset
	status_at:       f64,
	scan_buf:        [128]u8,
	scan_message:    string,
	quit:            bool,
	drive_mask:      u32,
	drive_rescan_at: f64,
	fit_check_at:    f64,
	media_sig:       u64,
	settings_focus:  int,
	dropdown_open:   bool,
	dropdown_sel:    int,
	dropdown_t:      f32,
	slider_drag:     bool,
	power_open:      bool,
	power_sel:       int,
	power_confirm:   Power_Action, // .Cancel = none pending; otherwise awaiting Yes/No
	power_t:         f32,
	pause_sel:       int,
	pause_t:         f32,
	carousel_x:      f32,
	carousel_ready:  bool,
	tab_x, tab_w:    f32,
	swipe_t:         f32,
	swipe_dir:       f32,
	swipe_from:      Screen,
}

app: App

WINDOW_TITLE :: "SABER"
TARGET_FPS :: 60
STATUS_SECONDS :: 6.0

main :: proc() {
	// One Saber per session: a hidden second copy would keep reacting to the pad.
	CreateMutexW(nil, true, win.L("Local\\SaberLauncher"))
	if win.GetLastError() == win.ERROR_ALREADY_EXISTS {
		return
	}
	app.exe_dir = exe_directory()
	if app.exe_dir != "" {
		win.SetCurrentDirectoryW(win.utf8_to_wstring(app.exe_dir))
	}
	app.games_dir = path_join({app.exe_dir, "games"})
	app.apps_dir = path_join({app.exe_dir, "apps"})
	app.movies_dir = path_join({app.exe_dir, "movies"})
	app.settings_path = path_join({app.exe_dir, "Saber.ini"})
	app.settings = settings_load(app.settings_path)
	app.selected_drive = 0
	app.swipe_t = 1

	app.in_shell = is_acting_as_shell()
	if app.in_shell {
		// at login the display stack may still be settling
		time.sleep(800 * time.Millisecond)
	}
	rl.SetTraceLogLevel(.WARNING)
	// hidden until the splash is drawn, otherwise Windows shows a blank white window while loading
	rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_ALWAYS_RUN, .MSAA_4X_HINT, .WINDOW_HIDDEN})
	rl.InitWindow(1280, 720, WINDOW_TITLE)
	rl.SetExitKey(.KEY_NULL)
	rl.SetTargetFPS(TARGET_FPS)
	rl.ToggleBorderlessWindowed()
	apply_ui_theme(app.settings.ui_theme)
	font_init()
	draw_splash("Starting")
	rl.ClearWindowState({.WINDOW_HIDDEN})
	restore_after_child()
	draw_splash("Starting")
	rl.InitAudioDevice()
	draw_splash("Loading theme")
	theme_init()
	xinput_init()

	draw_splash("Loading plugins")
	plugins_init()
	media_watch_start()
	draw_splash("Scanning drives and library")
	rescan_all()
	play_disc_from_args()

	for !app.quit {
		if rl.WindowShouldClose() && !app.in_shell {
			break // Alt+F4; ignored as a shell so the session never ends on a black screen
		}
		keep_fullscreen()
		poll_drive_changes()
		theme_update()
		if rl.IsKeyPressed(.F11) {
			rl.ToggleBorderlessWindowed()
		}
		input_poll()
		online_update()
		update_poll()
		handle_app_input()

		w := f32(rl.GetScreenWidth())
		h := f32(rl.GetScreenHeight())

		rl.BeginDrawing()
		draw_background(w, h)
		update_swipe()
		draw_screens(w, h)
		draw_header(w)
		draw_footer(w, h)
		draw_power_dialog(w, h)
		draw_plugin_dialog(w, h)
		emu_menu_draw(w, h)
		rl.EndDrawing()

		free_all(context.temp_allocator)
	}

	unload_all_games()
	unload_all_apps()
	unload_all_movies()
	online_shutdown()
	plugins_shutdown()
	font_shutdown()
	theme_shutdown()
	rl.CloseAudioDevice()
	rl.CloseWindow()
}

// `Saber.exe --play-disc F` boots the console disc in F: right away;
// `Saber.exe --play-rom F:\game.nes` the ROM game at that path.
play_disc_from_args :: proc() {
	args := os.args
	for i in 1 ..< len(args) - 1 {
		if args[i] == "--play-rom" && args[i + 1] != "" {
			for &g, gi in app.drive_games {
				if g.rom_path != "" && strings.equal_fold(g.rom_path, args[i + 1]) {
					app.selected_drive = gi
					activate_item(.Main, gi)
					return
				}
			}
			set_status("No ROM game at %s", args[i + 1])
			continue
		}
		if args[i] != "--play-disc" || args[i + 1] == "" {
			continue
		}
		letter := args[i + 1][0] &~ 0x20
		for &g, gi in app.drive_games {
			if g.platform != .None && g.disc_letter == letter {
				app.selected_drive = gi
				activate_item(.Main, gi)
				return
			}
		}
		set_status("No playable disc in %c:", letter)
	}
}

exe_directory :: proc() -> string {
	full := exe_full_path()
	if full == "" {
		return "."
	}
	return strings.clone(filepath.dir(full)) // dir() is a view into a temp string
}

set_status :: proc(format: string, args: ..any) {
	app.status = fmt.bprintf(app.status_buf[:], format, ..args)
	app.status_at = rl.GetTime()
}

DRIVE_SETTLE_SEC :: 0.6

poll_drive_changes :: proc() {
	mask := current_drive_mask()
	now := rl.GetTime()
	if mask != app.drive_mask {
		app.drive_mask = mask
		app.drive_rescan_at = now + DRIVE_SETTLE_SEC
		set_status("Drive change detected…")
	}
	{
		if sig := optical_media_signature(); sig != app.media_sig {
			app.media_sig = sig
			app.drive_rescan_at = now + DRIVE_SETTLE_SEC
			set_status("Disc change detected…")
		}
	}
	if app.drive_rescan_at != 0 && now >= app.drive_rescan_at {
		app.drive_rescan_at = 0
		rescan_drives()
		set_status("Drives updated  ·  %d inserted", len(app.drive_games))
	}
}

// One startup frame between blocking load steps: title, accent bar, current step.
draw_splash :: proc(step: string) {
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())
	cy := h * 0.5
	title_size: f32 = 96
	tw := measure_t("SABER", title_size)
	x := (w - tw) * 0.5

	rl.BeginDrawing()
	rl.ClearBackground(COL_BG)
	rl.DrawRectangleGradientV(0, 0, i32(w), i32(h), with_alpha(COL_SHADE, 0), with_alpha(COL_SHADE, 120))
	rl.DrawRectangleRounded({x - 30, cy - 52, 8, 84}, 1, 4, COL_ACCENT)
	draw_t("SABER", x, cy - 58, title_size, COL_TEXT)
	draw_t_center(step, w * 0.5, cy + 60, 22, COL_MUTED)
	rl.EndDrawing()
	free_all(context.temp_allocator)
}

rescan_drives :: proc() {
	for &g in app.drive_games {
		game_unload_art(&g)
	}
	clear(&app.drive_games)
	scan_portable_drives(&app.drive_games)
	app.selected_drive = clamp(app.selected_drive, 0, max(0, len(app.drive_games) - 1))
	update_scan_message()
	plugins_discs_changed()
}

rescan_all :: proc() {
	unload_all_games()
	unload_all_apps()
	unload_all_movies()
	clear(&app.drive_games)
	clear(&app.library_games)
	clear(&app.shell_apps)
	clear(&app.movies)
	scan_library(&app.library_games, app.games_dir)
	scan_portable_drives(&app.drive_games)
	scan_apps(&app.shell_apps, app.apps_dir)
	scan_movies(&app.movies, app.movies_dir)
	app.selected_drive = clamp(app.selected_drive, 0, max(0, len(app.drive_games) - 1))
	app.selected_lib = clamp(app.selected_lib, 0, max(0, len(app.library_games) - 1))
	app.selected_app = clamp(app.selected_app, 0, max(0, len(app.shell_apps) - 1))
	app.selected_movie = clamp(app.selected_movie, 0, max(0, len(app.movies) - 1))
	app.drive_mask = current_drive_mask()
	app.media_sig = optical_media_signature()
	app.drive_rescan_at = 0
	update_scan_message()
	plugins_discs_changed()
}

update_scan_message :: proc() {
	app.scan_message = fmt.bprintf(
		app.scan_buf[:],
		"%d inserted  ·  %d games  ·  %d movies  ·  %d apps",
		len(app.drive_games),
		len(app.library_games),
		len(app.movies),
		len(app.shell_apps),
	)
}

unload_all_games :: proc() {
	for &g in app.drive_games {
		game_unload_art(&g)
	}
	for &g in app.library_games {
		game_unload_art(&g)
	}
}

power_blocking :: proc() -> bool {
	return app.power_open || app.power_t > 0.08
}

input_locked :: proc() -> bool {
	return power_blocking() || app.swipe_t < 1 || input.mouse_eaten
}

open_power_dialog :: proc() {
	app.power_open = true
	app.power_sel = 0
	app.power_confirm = .Cancel
	sfx_click()
}

handle_app_input :: proc() {
	if emu_menu.open {
		emu_menu_input()
		eat_input()
		input.mouse_eaten = true
		return
	}
	if plugin_dialog_open() {
		handle_plugin_dialog_input()
		eat_input()
		input.mouse_eaten = true // also on the frame it closes, so the click can't reach a card
		return
	}
	if power_blocking() {
		handle_power_input()
		eat_input()
		return
	}
	if app.swipe_t < 1 {
		return
	}
	if app.dropdown_open {
		handle_dropdown_input()
		eat_input()
		return
	}
	if input.power {
		open_power_dialog()
		eat_input()
		return
	}
	if input.menu_l || input.menu_r {
		cycle_screen(input.menu_l ? -1 : 1)
		eat_input()
		return
	}
	if input.cancel && app.screen == .Plugins && app.plugin_focus == 1 {
		app.plugin_focus = 0
		sfx_back()
		eat_input()
		return
	}
	if input.cancel {
		if app.screen != .Main {
			sfx_back()
			go_screen(.Main)
		}
		eat_input()
		return
	}
	if input.extra {
		rescan_all()
		set_status("Rescanned drives, library, movies and apps")
		sfx_click()
	}
	switch app.screen {
	case .Main:
		if len(app.drive_games) > 0 {
			if input.left && app.selected_drive > 0 {
				app.selected_drive -= 1
				sfx_click()
			}
			if input.right && app.selected_drive < len(app.drive_games) - 1 {
				app.selected_drive += 1
				sfx_click()
			}
			if input.confirm {
				activate_item(.Main, app.selected_drive)
			}
		}
	case .Library, .Movies, .Apps:
		sel := grid_selection(app.screen)
		nav_grid(sel, grid_count(app.screen), grid_layout(app.screen).cols)
		if input.confirm {
			activate_item(app.screen, sel^)
		}
	case .Plugins:
		handle_plugins_input()
	case .Settings:
		handle_settings_input()
	}
}

Settings_Row :: enum {
	Ui_Theme,
	Wallpaper,
	Music,
	Volume,
	Font,
	Online_Mode,
	Emulation,
	Launch_Mode,
	Updates,
	Desktop,
}

SETTINGS_ROWS :: len(Settings_Row)

handle_settings_input :: proc() {
	if input.up {
		app.settings_focus = (app.settings_focus - 1 + SETTINGS_ROWS) % SETTINGS_ROWS
		sfx_click()
	}
	if input.down {
		app.settings_focus = (app.settings_focus + 1) % SETTINGS_ROWS
		sfx_click()
	}
	step := 0
	if input.left { step = -1 }
	if input.right { step = 1 }
	switch Settings_Row(app.settings_focus) {
	case .Ui_Theme:
		if step != 0 { cycle_ui_theme(step) }
		if input.confirm { cycle_ui_theme(1) }
	case .Wallpaper:
		if step != 0 { cycle_bkg(step) }
		if input.confirm { cycle_bkg(1) }
	case .Music:
		if step != 0 { cycle_bgm(step) }
		if input.confirm { cycle_bgm(1) }
	case .Volume:
		if step != 0 {
			set_volume(app.settings.volume + f32(step) * 0.05)
			sfx_click()
		}
	case .Font:
		if step != 0 { cycle_font(step) }
		if input.confirm { cycle_font(1) }
	case .Online_Mode:
		if step != 0 || input.confirm { set_online_mode(!app.settings.online_mode) }
	case .Emulation:
		if input.confirm {
			emu_open(false)
		}
	case .Launch_Mode:
		if input.confirm {
			open_dropdown()
		}
	case .Updates:
		if input.confirm {
			update_check_start()
			sfx_click()
		}
	case .Desktop:
		if input.confirm {
			open_desktop()
			set_status("Started Explorer")
			sfx_click()
		}
	}
}

set_volume :: proc(v: f32) {
	app.settings.volume = clamp(f32(int(v * 100 + 0.5)) / 100, 0, 1)
	if theme.has_music {
		rl.SetMusicVolume(theme.music, app.settings.volume)
	}
	save_settings()
}

open_dropdown :: proc() {
	app.dropdown_open = true
	app.dropdown_sel = int(app.settings.launch_mode)
	app.dropdown_t = 0
	app.settings_focus = int(Settings_Row.Launch_Mode)
	sfx_click()
}

handle_dropdown_input :: proc() {
	n := len(Launch_Mode)
	if input.up {
		app.dropdown_sel = (app.dropdown_sel - 1 + n) % n
		sfx_click()
	}
	if input.down {
		app.dropdown_sel = (app.dropdown_sel + 1) % n
		sfx_click()
	}
	if input.cancel || input.power {
		app.dropdown_open = false
		sfx_back()
		return
	}
	if input.confirm {
		choose_launch_mode(Launch_Mode(app.dropdown_sel))
	}
}

choose_launch_mode :: proc(mode: Launch_Mode) {
	app.dropdown_open = false
	if mode == app.settings.launch_mode {
		sfx_back()
		return
	}
	ok, err := apply_launch_mode(mode)
	if !ok {
		set_status("%s", err)
		sfx_back()
		return
	}
	app.settings.launch_mode = mode
	save_settings()
	switch mode {
	case .Standalone:
		set_status("Saber won't start on its own. Next sign-in uses the desktop.")
	case .Autorun:
		set_status("Saber will open after the next sign-in, on top of the desktop.")
	case .Shell:
		set_status("This account will boot straight into Saber after the next sign-in.")
	}
	sfx_click()
}

Power_Action :: enum {
	Cancel,
	Quit,
	Quit_To_Desktop,
	Log_Out,
	Restart,
	Shut_Down,
}

POWER_LABELS := [Power_Action]string {
	.Cancel          = "Cancel",
	.Quit            = "Quit Saber",
	.Quit_To_Desktop = "Quit to Desktop",
	.Log_Out         = "Log Out",
	.Restart         = "Restart",
	.Shut_Down       = "Shut Down",
}

// As the account shell there is no desktop to fall back to, so "quit" starts Explorer.
// Log out / restart / shut down are only offered when Saber runs on login (autorun or shell).
power_actions :: proc() -> []Power_Action {
	@(static) shell := [?]Power_Action{.Quit_To_Desktop, .Log_Out, .Restart, .Shut_Down}
	@(static) autorun := [?]Power_Action{.Cancel, .Quit, .Log_Out, .Restart, .Shut_Down}
	@(static) standalone := [?]Power_Action{.Cancel, .Quit}
	if app.in_shell {
		return shell[:]
	}
	return app.settings.launch_mode == .Standalone ? standalone[:] : autorun[:]
}

power_labels :: proc() -> []string {
	@(static) labels: [len(Power_Action)]string
	if app.power_confirm != .Cancel {
		labels[0] = "Cancel"
		labels[1] = POWER_LABELS[app.power_confirm]
		return labels[:2]
	}
	actions := power_actions()
	for a, i in actions {
		labels[i] = POWER_LABELS[a]
	}
	return labels[:len(actions)]
}

handle_power_input :: proc() {
	if !app.power_open {
		return
	}
	n := len(power_labels())
	if input.up {
		app.power_sel = (app.power_sel - 1 + n) % n
		sfx_click()
	}
	if input.down {
		app.power_sel = (app.power_sel + 1) % n
		sfx_click()
	}
	if input.cancel && app.power_confirm != .Cancel {
		cancel_power_confirm()
		return
	}
	if input.cancel || input.power {
		app.power_open = false
		sfx_back()
		return
	}
	if input.confirm {
		apply_power_choice()
	}
}

cancel_power_confirm :: proc() {
	for a, i in power_actions() {
		if a == app.power_confirm {
			app.power_sel = i
		}
	}
	app.power_confirm = .Cancel
	sfx_back()
}

apply_power_choice :: proc() {
	if pending := app.power_confirm; pending != .Cancel {
		if app.power_sel == 0 {
			cancel_power_confirm()
			return
		}
		app.power_confirm = .Cancel
		run_power_action(pending)
		return
	}
	actions := power_actions()
	if app.power_sel < 0 || app.power_sel >= len(actions) {
		return
	}
	action := actions[app.power_sel]
	#partial switch action {
	case .Log_Out, .Restart, .Shut_Down:
		app.power_confirm = action
		app.power_sel = 0 // default to Cancel
		sfx_click()
		return
	}
	run_power_action(action)
}

run_power_action :: proc(action: Power_Action) {
	switch action {
	case .Cancel:
		app.power_open = false
		sfx_back()
	case .Quit:
		app.quit = true
	case .Quit_To_Desktop:
		open_desktop()
		app.quit = true
	case .Log_Out:
		if !system_logoff() {
			set_status("Could not log off")
			app.power_open = false
		}
	case .Restart:
		if !system_restart() {
			set_status("Could not restart")
			app.power_open = false
		}
	case .Shut_Down:
		if !system_shutdown() {
			set_status("Could not shut down")
			app.power_open = false
		}
	}
}

grid_count :: proc(s: Screen) -> int {
	#partial switch s {
	case .Main:
		return len(app.drive_games)
	case .Library:
		return len(app.library_games)
	case .Movies:
		return len(app.movies)
	case .Apps:
		return len(app.shell_apps)
	}
	return 0
}

grid_selection :: proc(s: Screen) -> ^int {
	#partial switch s {
	case .Main:
		return &app.selected_drive
	case .Library:
		return &app.selected_lib
	case .Movies:
		return &app.selected_movie
	}
	return &app.selected_app
}

activate_item :: proc(s: Screen, i: int) {
	if input_locked() || i < 0 || i >= grid_count(s) {
		return
	}
	#partial switch s {
	case .Main, .Library:
		g := s == .Main ? &app.drive_games[i] : &app.library_games[i]
		if ok, err := game_launch(g); !ok {
			set_status("%s", err)
		} else {
			set_status("Played %s  ·  %s total", g.title, format_playtime(g.playtime_seconds))
		}
	case .Movies:
		m := &app.movies[i]
		if ok, err := movie_launch(m); !ok {
			set_status("%s", err)
		} else {
			set_status("Finished %s", m.title)
		}
	case .Apps:
		a := &app.shell_apps[i]
		ok, detached, err := shell_app_launch(a)
		if !ok {
			set_status("%s", err)
		} else if detached {
			set_status("%s is still running in the background", a.title)
		} else {
			set_status("Closed %s", a.title)
		}
	}
}
