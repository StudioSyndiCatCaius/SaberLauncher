package saber

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

Shell_App :: struct {
	title:     string,
	exe:       string,
	args:      string,
	img_file:  string,
	toml_file: string,
	dir:       string, // folder of the .toml: relative exe / img start here
	icon:      rl.Texture2D,
	has_icon:  bool,
}

scan_apps :: proc(out: ^[dynamic]Shell_App, apps_dir: string) {
	if !os.exists(apps_dir) {
		return
	}
	fis, err := os.read_all_directory_by_path(apps_dir, context.allocator)
	if err != nil {
		return
	}
	defer os.file_info_slice_delete(fis, context.allocator)

	// APP/apps/<Name>.toml, or one folder down: APP/apps/<Name>/<Name>.toml (store installs)
	for fi in fis {
		if fi.type == .Directory {
			if !strings.has_suffix(fi.name, ".part") do scan_apps_in(out, fi.fullpath)
			continue
		}
		base := fi.name if fi.name != "" else filepath.base(fi.fullpath)
		ext := strings.to_lower(filepath.ext(base), context.temp_allocator)
		if ext != ".toml" {
			continue
		}
		if a, ok := app_from_toml(fi.fullpath, apps_dir); ok {
			append(out, a)
		}
	}
}

// .toml files directly in one app folder.
scan_apps_in :: proc(out: ^[dynamic]Shell_App, dir: string) {
	fis, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil do return
	defer os.file_info_slice_delete(fis, context.allocator)
	for fi in fis {
		if fi.type == .Directory || !strings.equal_fold(filepath.ext(fi.name), ".toml") do continue
		if a, ok := app_from_toml(fi.fullpath, dir); ok do append(out, a)
	}
}

app_from_toml :: proc(toml_path, apps_dir: string) -> (Shell_App, bool) {
	data, err := os.read_entire_file(toml_path, context.allocator)
	if err != nil {
		return {}, false
	}
	defer delete(data)
	text := string(data)

	a: Shell_App
	a.toml_file = strings.clone(toml_path)
	a.dir = strings.clone(apps_dir)
	stem := filepath.stem(toml_path)
	if v, found := ini_get(text, "name"); found && v != "" {
		a.title = strings.clone(v)
	} else {
		a.title = strings.clone(stem)
	}
	if v, found := ini_get(text, "exe"); found && v != "" {
		a.exe = strings.clone(v)
	} else if v, found := ini_get(text, "path"); found {
		a.exe = strings.clone(v)
	}
	if v, found := ini_get(text, "exe_args"); found {
		a.args = strings.clone(v)
	} else if v, found := ini_get(text, "launch_args"); found {
		a.args = strings.clone(v)
	} else if v, found := ini_get(text, "args"); found {
		a.args = strings.clone(v)
	}

	img := ""
	if v, found := ini_get(text, "img"); found && v != "" {
		img = v
	}
	a.img_file = resolve_app_image(apps_dir, stem, img)
	app_load_icon(&a)
	return a, true
}

resolve_app_image :: proc(apps_dir, stem, img: string) -> string {
	if strings.trim_space(img) != "" {
		p := strings.trim_space(img)
		if strings.has_prefix(p, "./") || strings.has_prefix(p, ".\\") {
			p = p[2:]
		}
		if filepath.is_abs(p) {
			return strings.clone(p)
		}
		local := path_join({apps_dir, p}) // next to the .toml
		if os.exists(local) {
			return local
		}
		joined := path_join({app.exe_dir, p})
		if os.exists(joined) {
			return joined
		}
		return local
	}
	for ext in ([]string{".png", ".jpg", ".jpeg", ".webp"}) {
		cand := path_join({apps_dir, fmt.tprintf("%s%s", stem, ext)})
		if os.exists(cand) {
			return cand
		}
	}
	return ""
}

app_load_icon :: proc(a: ^Shell_App) {
	a.icon, a.has_icon = load_texture_smooth(a.img_file)
}

app_unload_icon :: proc(a: ^Shell_App) {
	if a.has_icon {
		rl.UnloadTexture(a.icon)
		a.has_icon = false
	}
}

unload_all_apps :: proc() {
	for &a in app.shell_apps {
		app_unload_icon(&a)
	}
}

resolve_app_exe :: proc(a: ^Shell_App) -> (string, bool) {
	exe := strings.trim_space(a.exe)
	if exe == "" {
		return "", false
	}
	if filepath.is_abs(exe) {
		return exe, os.exists(exe)
	}
	if a.dir != "" {
		if from_dir := path_join({a.dir, exe}); os.exists(from_dir) do return from_dir, true
	}
	from_apps := path_join({app.apps_dir, exe})
	if os.exists(from_apps) {
		return from_apps, true
	}
	from_exe := path_join({app.exe_dir, exe})
	if os.exists(from_exe) {
		return from_exe, true
	}
	return exe, os.exists(exe)
}

is_steam_exe :: proc(path: string) -> bool {
	base := filepath.base(path)
	return strings.equal_fold(base, "steam.exe") || base == "steam"
}

shell_app_launch :: proc(a: ^Shell_App) -> (ok: bool, detached: bool, err: string) {
	exe_path, has := resolve_app_exe(a)
	if !has {
		if strings.trim_space(a.exe) == "" {
			return false, false, fmt.tprintf("No exe set for %s — edit APP/apps .toml", a.title)
		}
		return false, false, fmt.tprintf("Missing exe: %s", a.exe)
	}

	cmd := exe_command(exe_path, strings.trim_space(a.args))
	pi, created := spawn_process(exe_path, cmd, filepath.dir(exe_path))
	if !created {
		return false, false, fmt.tprintf("Could not launch %s", a.title)
	}
	if is_steam_exe(exe_path) {
		open_steam_big_picture()
	}
	_, detached = run_session(pi, .App, a.title, filepath.base(exe_path))
	return true, detached, ""
}

// Autostart: one app (by its .toml file name) that Saber opens right after starting at
// sign-in in Autorun / Shell mode. Closing it lands back in Saber. Once per sign-in, so
// restarts / crash recovery / manual launches later in the session never reopen it.
AUTOSTART_DONE_VALUE :: "SaberAutostartDone"

app_is_autostart :: proc(a: ^Shell_App) -> bool {
	return app.settings.autostart_app != "" && strings.equal_fold(app.settings.autostart_app, filepath.base(a.toml_file))
}

toggle_autostart_app :: proc(a: ^Shell_App) {
	if app_is_autostart(a) {
		app.settings.autostart_app = ""
		set_status("%s no longer starts at sign-in", a.title)
	} else {
		app.settings.autostart_app = strings.clone(filepath.base(a.toml_file))
		if app.settings.launch_mode == .Standalone {
			set_status("%s will autostart  ·  set Launch mode to Autorun or Shellrun in Settings", a.title)
		} else {
			set_status("%s will open at sign-in  ·  closing it returns to Saber", a.title)
		}
	}
	save_settings()
	sfx_click()
}

autostart_app_on_login :: proc() {
	if app.settings.autostart_app == "" || app.settings.launch_mode == .Standalone do return
	if reg_read_sz(VOLATILE_ENV, AUTOSTART_DONE_VALUE) != "" do return
	_ = reg_write_sz(VOLATILE_ENV, AUTOSTART_DONE_VALUE, "1")
	for &a, i in app.shell_apps {
		if app_is_autostart(&a) {
			app.selected_app = i
			go_screen(.Apps)
			draw_splash(fmt.tprintf("Starting %s", a.title))
			activate_item(.Apps, i)
			return
		}
	}
	set_status("Autostart app %s not found in APP/apps", app.settings.autostart_app)
}

// Reloads APP/apps (store installs / removals, Register_App) without touching anything else.
apps_rescan :: proc() {
	unload_all_apps()
	for a in app.shell_apps {
		delete(a.title)
		delete(a.exe)
		delete(a.args)
		delete(a.img_file)
		delete(a.toml_file)
		delete(a.dir)
	}
	clear(&app.shell_apps)
	scan_apps(&app.shell_apps, app.apps_dir)
	app.selected_app = clamp(app.selected_app, 0, max(0, len(app.shell_apps) - 1))
}

// Y on APPS flips between the grid and GET APPS (the app store).
apps_toggle_page :: proc() {
	app.apps_page = 1 - app.apps_page
	store.armed = -1
	if app.apps_page == 1 {
		store_on_open()
		sfx_click()
	} else {
		apps_rescan() // picks up .toml files added by hand meanwhile
		sfx_back()
	}
}

// "APPS 3   GET APPS (Y)"
draw_apps_tabs :: proc(y: f32) {
	if draw_page_tabs(y, {fmt.tprintf("APPS  %d", len(app.shell_apps)), "GET APPS"}, app.apps_page) do apps_toggle_page()
}

draw_apps :: proc(w, h: f32) {
	if app.apps_page == 1 {
		draw_app_store(w, h)
		return
	}
	draw_grid_page(.Apps, "APPS", "No apps yet. Press Y to get some, or add a .toml (name, exe, exe_args) to APP/apps.", w, h)
}
