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

	for fi in fis {
		if fi.type == .Directory {
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

app_from_toml :: proc(toml_path, apps_dir: string) -> (Shell_App, bool) {
	data, err := os.read_entire_file(toml_path, context.allocator)
	if err != nil {
		return {}, false
	}
	defer delete(data)
	text := string(data)

	a: Shell_App
	a.toml_file = strings.clone(toml_path)
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
		joined := path_join({app.exe_dir, p})
		if os.exists(joined) {
			return joined
		}
		return path_join({apps_dir, p})
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
