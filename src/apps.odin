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

// ---------------------------------------------------------------------------
// Actions menu (X / right-click on an APPS card): Open, Autostart, Delete, [Uninstall], Close.
// Delete (press twice) = app_delete_toml without the uninstaller: store installs lose their app/
// folder, linked / hand-made apps only lose the card (.toml + art). Uninstall (press twice, only for
// store installs with an `uninstall=` command) runs that uninstaller first, then deletes the same.

App_Menu_Row :: enum {
	Open,
	Autostart,
	Delete,
	Uninstall,
	Close,
}

app_menu: struct {
	open:     bool,
	t:        f32,
	sel:      int,
	toml_buf: [512]u8,
	toml:     string, // the card's .toml: a rescan replaces the list, so it is looked up again
	armed:    bool,   // Delete / Uninstall pressed once (the selected row)
}

app_menu_open :: proc(i: int) {
	if input_locked() || i < 0 || i >= len(app.shell_apps) do return
	app_menu.toml = fmt.bprint(app_menu.toml_buf[:], app.shell_apps[i].toml_file)
	app_menu.sel = 0
	app_menu.armed = false
	app_menu.open = true
	sfx_click()
}

app_menu_index :: proc() -> int {
	for &a, i in app.shell_apps do if a.toml_file == app_menu.toml do return i
	return -1
}

app_menu_rows :: proc(a: ^Shell_App) -> []App_Menu_Row {
	rows := make([dynamic]App_Menu_Row, context.temp_allocator)
	append(&rows, App_Menu_Row.Open, App_Menu_Row.Autostart, App_Menu_Row.Delete)
	if plan := app_delete_plan(a.toml_file); plan.program != "" && plan.uninstall != "" do append(&rows, App_Menu_Row.Uninstall)
	append(&rows, App_Menu_Row.Close)
	return rows[:]
}

app_menu_input :: proc() {
	i := app_menu_index()
	if i < 0 {
		app_menu.open = false
		return
	}
	rows := app_menu_rows(&app.shell_apps[i])
	n := len(rows)
	app_menu.sel = clamp(app_menu.sel, 0, n - 1)
	if input.up || input.down {
		app_menu.sel = (app_menu.sel + (input.up ? n - 1 : 1)) % n
		app_menu.armed = false
		sfx_click()
	}
	if input.cancel || input.action || input.power {
		app_menu.open = false
		sfx_back()
		return
	}
	if input.confirm do app_menu_choose(i, rows[app_menu.sel])
}

app_menu_choose :: proc(i: int, row: App_Menu_Row) {
	a := &app.shell_apps[i]
	switch row {
	case .Open:
		app_menu.open = false
		app.pending_open = [2]int{int(Screen.Apps), i}
	case .Autostart:
		toggle_autostart_app(a)
	case .Delete, .Uninstall:
		if !app_menu.armed {
			app_menu.armed = true
			sfx_click()
			return
		}
		app_menu.open = false
		name := strings.clone(a.title, context.temp_allocator)
		ok := app_delete_toml(strings.clone(a.toml_file, context.temp_allocator), name, uninstall = row == .Uninstall) // a is gone after this
		set_status(ok ? "%s deleted" : "%s deleted, but some files couldn't be removed (is it running?)", name)
		sfx_back()
	case .Close:
		app_menu.open = false
		sfx_back()
	}
}

app_menu_label :: proc(a: ^Shell_App, row: App_Menu_Row, selected: bool) -> string {
	armed := app_menu.armed && selected
	switch row {
	case .Open:      return "Open"
	case .Autostart: return app_is_autostart(a) ? "Don't Autostart" : "Autostart at Sign-in"
	case .Delete:
		if !armed do return "Delete"
		return app_delete_plan(a.toml_file).program != "" ? "Press Again: Delete Card and App Folder" : "Press Again: Remove Card"
	case .Uninstall: return armed ? "Press Again: Run Uninstaller and Delete" : "Uninstall"
	case .Close:     return "Close"
	}
	return ""
}

draw_app_menu :: proc(w, h: f32) {
	app_menu.t = smooth_to(app_menu.t, app_menu.open ? 1 : 0, 16)
	if app_menu.t < 0.02 && !app_menu.open do return
	i := app_menu_index()
	if i < 0 {
		app_menu.open = false
		return
	}
	a := &app.shell_apps[i]
	rows := app_menu_rows(a)
	app_menu.sel = clamp(app_menu.sel, 0, len(rows) - 1)
	labels := make([]string, len(rows), context.temp_allocator)
	for row, k in rows do labels[k] = app_menu_label(a, row, k == app_menu.sel)
	plan := app_delete_plan(a.toml_file)
	sub := "Delete removes the card; the program itself stays installed"
	switch {
	case plan.program != "" && plan.uninstall != "": sub = "Delete: just Saber's copy  ·  Uninstall: also runs its uninstaller"
	case plan.program != "":                         sub = "Installed by Saber: Delete removes its folder too"
	}
	if clicked := draw_modal_menu(a.title, sub, labels, app_menu.sel, app_menu.t, w, h, app_menu.open); clicked >= 0 {
		if clicked != app_menu.sel do app_menu.armed = false
		app_menu.sel = clicked
		app_menu_choose(i, rows[clicked])
	}
}
