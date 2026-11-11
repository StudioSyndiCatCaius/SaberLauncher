package saber

// App store (APPS > Y "GET APPS"), on top of the plugin store (plugin_store.odin).
//
// A repo's `Apps/<Folder>/` holds:
//   app.lua    returns { name, version, author, description, locate, download, exe, args, icon }
//              locate   = list of places an existing install may be (app_locate_windows.odin:
//                         "reg:HKCU\\...\\Value" or paths with %ENV% vars). Found -> the app is only
//                         *linked*: the .toml points at that exe, nothing is downloaded, and Remove
//                         only drops the card (Steam & co. are never touched). Checked before download.
//              download = URL of a .zip (unpacked; a single top-level folder is stripped) or of any
//                         other file (saved as-is); optional, apps can also ship only files/.
//                         No download and nothing located = "isn't installed on this PC".
//              installer = the download is an installer: run it with these arguments (`{dir}` = the
//                         install folder, e.g. "/S /D={dir}" for NSIS) and wait, instead of unpacking.
//              uninstall = command run (and waited for) before Remove deletes the folder, relative to the
//                         install folder, `{dir}` allowed (e.g. "uninstall.exe /S _?={dir}").
//              exe      = program to start, relative to the install folder (required).
//              args     = command line, optional.
//              icon     = URL of a picture, or a path inside the install folder (optional).
//   icon.png   card art (copied to APP/apps/<Folder>/<Folder>.png); wins over `icon`.
//   files/...  copied into the install folder, but only where no such file exists yet
//              (default settings / configs; the user's own changes survive updates).
// Install: the repo files are staged in .store/stage/apps/<Folder>/, the download goes next to
// them, a worker thread unpacks into APP/apps/<Folder>/app/ (over an older install, so data the app
// keeps there survives) and then APP/apps/<Folder>/<Folder>.toml is written (name, exe, exe_args,
// version, store) and the APPS grid is rescanned right away. A .toml with `store=` is a store app
// (X twice removes it); its folder is only deleted when `<Folder>/.saber_store` marks it as ours,
// its art only when the toml says `store_art`.
//
// Plugins can register apps too: Register_App(id, {name, exe, args, img}) / Unregister_App(id).

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"

App_Spec :: struct {
	name, version, exe, args, download, icon, installer, uninstall: string,
	locate: [dynamic]string,
}

App_Job :: struct {
	payload: string, // downloaded file, "" = none
	dest:    string, // APP/apps/<Folder>/app
	seed:    string, // staged files/ folder
	installer: string, // run payload with these args (`{dir}` filled in) instead of unpacking
	err:     string,
	done:    bool, // atomic
	written: i64,  // atomic, files unpacked
	total:   i64,  // atomic
	worker:  ^thread.Thread,
}

app_spec_free :: proc(s: ^App_Spec) {
	delete(s.name)
	delete(s.version)
	delete(s.exe)
	delete(s.args)
	delete(s.download)
	delete(s.icon)
	delete(s.installer)
	delete(s.uninstall)
	for l in s.locate do delete(l)
	delete(s.locate)
	s^ = {}
}

// Layout: APP/apps/<Folder>/<Folder>.toml + <Folder>.png, the program in APP/apps/<Folder>/app/.
app_dir_of :: proc(id: string) -> string {
	return path_join({app.apps_dir, id})
}

app_store_dest :: proc(p: ^Store_Plugin) -> string {
	return path_join({app_dir_of(p.folder), APP_PROGRAM_DIR})
}

app_store_toml :: proc(p: ^Store_Plugin) -> string {
	return path_join({app_dir_of(p.folder), fmt.tprintf("%s.toml", p.folder)})
}

APP_PROGRAM_DIR :: "app"

// A key of APP/apps/<Folder>/<Folder>.toml ("" when there's no such file / key).
app_store_toml_get :: proc(p: ^Store_Plugin, key: string) -> string {
	data, err := os.read_entire_file(app_store_toml(p), context.temp_allocator)
	if err != nil do return ""
	v, _ := ini_get(string(data), key)
	return v
}

// Installed or linked by the store (a hand-made .toml of the same name doesn't count).
app_store_installed :: proc(p: ^Store_Plugin) -> bool {
	return app_store_toml_get(p, "store") != ""
}

app_store_linked :: proc(p: ^Store_Plugin) -> bool {
	return app_store_toml_get(p, "linked") != ""
}

app_store_installed_version :: proc(p: ^Store_Plugin) -> string {
	return app_store_toml_get(p, "version")
}

// Runs app.lua in a throwaway Lua state and reads its table.
app_spec_read :: proc(path: string) -> (spec: App_Spec, err: string) {
	L := luaL_newstate()
	defer lua_close(L)
	luaL_openlibs(L)
	lua_pushstring(L, strings.clone_to_cstring(app.exe_dir, context.temp_allocator))
	lua_setglobal(L, "SABER_DIR")
	if luaL_loadfilex(L, strings.clone_to_cstring(path, context.temp_allocator), nil) != LUA_OK || lua_pcall(L, 0, 1, 0) != LUA_OK {
		return {}, fmt.tprintf("app.lua: %s", lua_string(L, -1))
	}
	if lua_type(L, -1) != LUA_TTABLE do return {}, "app.lua must return a table"
	field :: proc(L: ^lua_State, key: cstring) -> string {
		defer lua_pop(L, 1)
		if lua_getfield(L, -1, key) != LUA_TSTRING do return ""
		return strings.clone(strings.trim_space(lua_string(L, -1)))
	}
	spec.name = field(L, "name")
	spec.version = field(L, "version")
	spec.exe = field(L, "exe")
	spec.args = field(L, "args")
	spec.download = field(L, "download")
	spec.icon = field(L, "icon")
	spec.installer = field(L, "installer")
	spec.uninstall = field(L, "uninstall")
	if lua_getfield(L, -1, "locate") == LUA_TTABLE {
		for i: i64 = 1; ; i += 1 {
			if lua_rawgeti(L, -1, i) != LUA_TSTRING {
				lua_pop(L, 1)
				break
			}
			append(&spec.locate, strings.clone(lua_string(L, -1)))
			lua_pop(L, 1)
		}
	} else if lua_type(L, -1) == LUA_TSTRING {
		append(&spec.locate, strings.clone(lua_string(L, -1)))
	}
	lua_pop(L, 1)
	if spec.exe == "" {
		app_spec_free(&spec)
		return {}, "app.lua has no exe"
	}
	return spec, ""
}

app_store_fail :: proc(p: ^Store_Plugin, msg: string) {
	p.state = .Failed
	delete(p.err)
	p.err = strings.clone(msg)
	delete(p.step)
	p.step = ""
	set_status("%s: %s", p.name, msg)
	plugin_logf("store: app %s failed: %s", p.folder, msg)
	os.remove_all(store_stage_dir(p))
}

// The repo files are staged: read the recipe, then fetch the download (if any).
app_store_staged :: proc(idx: int) {
	p := &store.plugins[idx]
	spec, err := app_spec_read(path_join({store_stage_dir(p), "app.lua"}))
	if err != "" {
		app_store_fail(p, err)
		return
	}
	app_spec_free(&p.spec)
	p.spec = spec
	if spec.name != "" {
		delete(p.name)
		p.name = strings.clone(spec.name)
	}
	if len(spec.locate) > 0 {
		if found := app_locate(spec.locate[:], spec.exe); found != "" {
			app_store_link(idx, found)
			return
		}
		if spec.download == "" {
			app_store_fail(p, fmt.tprintf("%s isn't installed on this PC", p.name))
			return
		}
	}
	if spec.download == "" {
		app_store_unpack(idx, "")
		return
	}
	url := spec.download
	if i := strings.index_any(url, "?#"); i >= 0 do url = url[:i]
	name := filepath.base(url)
	if name == "" || name == "." || name == "/" do name = "download"
	p.req = http_start_native(spec.download, path_join({store_stage_dir(p), "payload", name}), app_store_on_payload, {store.gen, idx})
}

app_store_on_payload :: proc(req: ^Http_Request) {
	if req.user[0] != store.gen do return
	p := &store.plugins[req.user[1]]
	p.req = nil
	if !req.ok {
		app_store_fail(p, fmt.tprintf("download failed (%s)", req.err))
		return
	}
	app_store_unpack(req.user[1], req.path)
}

app_store_unpack :: proc(idx: int, payload: string) {
	p := &store.plugins[idx]
	j := new(App_Job)
	j.payload = strings.clone(payload)
	j.dest = strings.clone(app_store_dest(p))
	j.seed = strings.clone(path_join({store_stage_dir(p), "files"}))
	j.installer = strings.clone(p.spec.installer)
	p.job = j
	j.worker = thread.create_and_start_with_data(j, app_job_worker)
}

// Worker: unpack / copy the download into the install folder, then seed files/.
app_job_worker :: proc(data: rawptr) {
	j := (^App_Job)(data)
	context = runtime.default_context()
	defer sync.atomic_store(&j.done, true)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		j.err = strings.clone("out of memory")
		return
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer free_all(context.temp_allocator)
	fail :: proc(j: ^App_Job, format: string, args: ..any) {
		j.err = fmt.aprintf(format, ..args, allocator = runtime.heap_allocator())
	}

	if os.make_directory_all(j.dest) != nil && !os.exists(j.dest) {
		fail(j, "Couldn't create %s", j.dest)
		return
	}
	if j.payload != "" && j.installer != "" {
		args, _ := strings.replace_all(j.installer, "{dir}", win_path(j.dest))
		code, ran := run_and_wait(j.payload, args, filepath.dir(j.payload), 10 * 60 * 1000)
		if !ran {
			fail(j, "Couldn't run the installer")
			return
		}
		if code != 0 {
			fail(j, "The installer failed (exit code %d)", code)
			return
		}
	} else if j.payload != "" {
		if strings.equal_fold(filepath.ext(j.payload), ".zip") {
			zip, err := os.read_entire_file(j.payload, context.allocator)
			if err != nil {
				fail(j, "Couldn't read the download")
				return
			}
			files, zerr := zip_extract(zip, nil)
			if zerr != "" {
				fail(j, "Bad zip: %s", zerr)
				return
			}
			// one top-level folder for everything ("App-1.0/...") is stripped
			strip := ""
			for name in files {
				slash := strings.index_byte(name, '/')
				top := slash < 0 ? "" : name[:slash + 1]
				if strip == "" do strip = top
				if top == "" || top != strip {
					strip = ""
					break
				}
			}
			sync.atomic_store(&j.total, i64(len(files)))
			for name, content in files {
				rel := name[len(strip):]
				if rel == "" do continue
				out := path_join({j.dest, rel})
				os.make_directory_all(filepath.dir(out))
				if os.write_entire_file(out, content) != nil {
					fail(j, "Couldn't write %s (is the app running?)", rel)
					return
				}
				sync.atomic_add(&j.written, 1)
			}
		} else {
			out := path_join({j.dest, filepath.base(j.payload)})
			os.remove(out)
			if os.rename(j.payload, out) != nil {
				fail(j, "Couldn't write %s (is the app running?)", filepath.base(out))
				return
			}
		}
	}
	app_copy_missing(j.seed, j.dest)
}

// Copies src's tree into dst, skipping files dst already has.
app_copy_missing :: proc(src, dst: string) {
	fis, err := os.read_all_directory_by_path(src, context.allocator)
	if err != nil do return
	for fi in fis {
		to := path_join({dst, fi.name})
		if fi.type == .Directory {
			app_copy_missing(fi.fullpath, to)
			continue
		}
		if os.exists(to) do continue
		data, rerr := os.read_entire_file(fi.fullpath, context.allocator)
		if rerr != nil do continue
		os.make_directory_all(dst)
		_ = os.write_entire_file(to, data)
	}
}

// Main loop: finishes app installs whose worker is done.
app_store_update :: proc() {
	for &p, i in store.plugins {
		j := p.job
		if j == nil || !sync.atomic_load(&j.done) do continue
		thread.join(j.worker)
		thread.destroy(j.worker)
		p.job = nil
		if j.err != "" {
			app_store_fail(&p, j.err)
		} else {
			app_store_finish(i)
		}
		delete(j.payload)
		delete(j.dest)
		delete(j.seed)
	delete(j.installer)
		delete(j.err)
		free(j)
	}
}

app_store_shutdown :: proc() {
	for &p in store.plugins {
		if p.job == nil do continue
		thread.join(p.job.worker) // unpacking can't be interrupted halfway safely
		thread.destroy(p.job.worker)
		p.job = nil
	}
}

app_store_finish :: proc(idx: int) {
	p := &store.plugins[idx]
	repo := &store.repos[p.repo]
	dest := app_store_dest(p)
	_ = os.write_entire_file(path_join({dest, STORE_MARKER}), transmute([]u8)fmt.tprintf("%s/%s\n", repo.owner, repo.name))
	app_store_register(idx, fmt.tprintf("%s/%s", APP_PROGRAM_DIR, p.spec.exe), false)
}

// Found an existing install: only the .toml (absolute exe) and the card art.
app_store_link :: proc(idx: int, exe: string) {
	app_store_register(idx, exe, true)
}

// Writes APP/apps/<Folder>/<Folder>.toml + art, rescans APPS.
app_store_register :: proc(idx: int, exe: string, linked: bool) {
	p := &store.plugins[idx]
	spec := &p.spec
	repo := &store.repos[p.repo]
	stage := store_stage_dir(p)

	// card art: packed icon.png > icon URL > icon path inside the install
	img := ""
	store_art := false
	os.make_directory_all(app_dir_of(p.folder))
	icon_png := path_join({app_dir_of(p.folder), fmt.tprintf("%s.png", p.folder)})
	if data, err := os.read_entire_file(path_join({stage, "icon.png"}), context.temp_allocator); err == nil {
		store_art = os.write_entire_file(icon_png, data) == nil
	} else if strings.has_prefix(spec.icon, "http://") || strings.has_prefix(spec.icon, "https://") {
		http_start_native(spec.icon, icon_png, app_store_on_icon, {store.gen, idx})
		store_art = true
	} else if spec.icon != "" {
		img = linked ? path_join({filepath.dir(exe), spec.icon}) : fmt.tprintf("%s/%s", APP_PROGRAM_DIR, spec.icon)
	}

	slashes :: proc(s: string) -> string {
		out, _ := strings.replace_all(s, "\\", "/", context.temp_allocator)
		return out
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "name=\"%s\"\n", spec.name != "" ? spec.name : p.name)
	fmt.sbprintf(&b, "exe=\"%s\"\n", slashes(exe))
	fmt.sbprintf(&b, "exe_args=\"%s\"\n", spec.args)
	if img != "" do fmt.sbprintf(&b, "img=\"%s\"\n", slashes(img))
	version := spec.version != "" ? spec.version : p.version
	if version != "" do fmt.sbprintf(&b, "version=\"%s\"\n", version)
	fmt.sbprintf(&b, "store=\"%s/%s\"\n", repo.owner, repo.name)
	if linked do fmt.sbprintf(&b, "linked=\"1\"\n")
	if !linked && spec.uninstall != "" do fmt.sbprintf(&b, "uninstall=\"%s\"\n", spec.uninstall)
	if store_art do fmt.sbprintf(&b, "store_art=\"1\"\n")
	if os.write_entire_file(app_store_toml(p), b.buf[:]) != nil {
		app_store_fail(p, fmt.tprintf("Couldn't write %s", app_store_toml(p)))
		return
	}
	os.remove_all(stage)
	p.state = .Installed
	apps_rescan()
	if linked {
		set_status("Found %s  ·  it's on APPS now", p.name)
		plugin_logf("store: linked app %s -> %s", p.folder, exe)
	} else {
		set_status("%s installed  ·  it's on APPS now", p.name)
		plugin_logf("store: installed app %s from %s/%s", p.folder, repo.owner, repo.name)
	}
}

app_store_on_icon :: proc(req: ^Http_Request) {
	if req.ok do apps_rescan()
}

// 0..1 across the download (80%) and the unpacking (20%).
app_store_progress :: proc(p: ^Store_Plugin) -> f32 {
	if r := p.req; r != nil {
		got, total := sync.atomic_load(&r.got), sync.atomic_load(&r.total)
		return total > 0 ? 0.8 * f32(f64(got) / f64(total)) : 0.1
	}
	if j := p.job; j != nil {
		w, t := sync.atomic_load(&j.written), sync.atomic_load(&j.total)
		return 0.8 + (t > 0 ? 0.2 * f32(w) / f32(t) : 0)
	}
	return 0
}

app_store_step_label :: proc(p: ^Store_Plugin) -> string {
	MB :: 1024.0 * 1024.0
	if r := p.req; r != nil {
		got, total := sync.atomic_load(&r.got), sync.atomic_load(&r.total)
		if total > 0 do return fmt.tprintf("Downloading %d%%  (%.0f / %.0f MB)", int(100 * got / total), f64(got) / MB, f64(total) / MB)
		return fmt.tprintf("Downloading %.1f MB", f64(got) / MB)
	}
	if j := p.job; j != nil {
		w, t := sync.atomic_load(&j.written), sync.atomic_load(&j.total)
		return t > 0 ? fmt.tprintf("Unpacking %d/%d", w, t) : "Installing"
	}
	return fmt.tprintf("Fetching %d/%d", p.done + 1, len(p.files))
}

// X on an installed store app: the first press arms, the second removes.
app_store_remove_press :: proc(idx: int) {
	p := &store.plugins[idx]
	if p.state == .Installing || !app_store_installed(p) {
		sfx_back()
		return
	}
	if store.armed != idx {
		store.armed = idx
		set_status("Press X again to remove %s", p.name)
		sfx_click()
		return
	}
	store.armed = -1
	dir := app_store_dest(p)
	if !os.exists(path_join({dir, STORE_MARKER})) do dir = "" // linked app / not ours: never delete it
	if dir != "" do app_run_uninstaller(p, dir)
	ok := app_remove_files(p.folder, dir)
	p.state = .Available
	set_status(ok ? "%s removed" : "%s removed, but some files couldn't be deleted (is it running?)", p.name)
	plugin_logf("store: removed app %s", p.folder)
	sfx_back()
}

// Runs the recipe's uninstall command (from the installed .toml's `uninstall=`) and waits.
app_run_uninstaller :: proc(p: ^Store_Plugin, dir: string) {
	cmd := app_store_toml_get(p, "uninstall")
	if cmd == "" do return
	cmd, _ = strings.replace_all(cmd, "{dir}", win_path(dir), context.temp_allocator)
	// "uninstall.exe /S ..." -> exe + args (exe is relative to the install folder)
	exe, args := cmd, ""
	if i := strings.index(strings.to_lower(cmd, context.temp_allocator), ".exe"); i >= 0 {
		exe, args = cmd[:i + 4], strings.trim_space(cmd[i + 4:])
	}
	exe = strings.trim(exe, "\"")
	if !filepath.is_abs(exe) do exe = path_join({dir, exe})
	if !os.exists(exe) do return
	draw_splash(fmt.tprintf("Uninstalling %s", p.name))
	code, ran := run_and_wait(exe, args, dir, 2 * 60 * 1000)
	plugin_logf("store: uninstall %s: ran=%v code=%d", p.folder, ran, code)
}

win_path :: proc(p: string) -> string {
	out, _ := strings.replace_all(p, "/", "\\", context.temp_allocator)
	return out
}

// Deletes APP/apps/<id>/<id>.toml + its art (if the store made it) and (if given) the program
// folder, then APP/apps/<id>/ when nothing else is left in it; rescans.
app_remove_files :: proc(id: string, dir := "") -> bool {
	toml := fmt.tprintf("%s.toml", id)
	folder := app_dir_of(id)
	if strings.equal_fold(app.settings.autostart_app, toml) {
		app.settings.autostart_app = ""
		save_settings()
	}
	unload_all_apps() // textures of the art we're about to delete
	ok := true
	toml_path := path_join({folder, toml})
	ours := false
	if data, err := os.read_entire_file(toml_path, context.temp_allocator); err == nil {
		v, _ := ini_get(string(data), "store_art")
		ours = v != ""
	}
	os.remove(toml_path)
	if ours do os.remove(path_join({folder, fmt.tprintf("%s.png", id)}))
	if dir != "" && os.remove_all(dir) != nil do ok = false
	os.remove(folder) // only succeeds when empty: the user's own files there stay
	apps_rescan()
	return ok
}

// ---------------------------------------------------------------------------
// Lua: Register_App(id, {name, exe, args, img}) -> true | nil, err
//      Unregister_App(id)
// Writes / deletes APP/apps/<id>/<id>.toml; relative exe / img paths are relative to the plugin folder.
// The APPS grid updates right away.

app_id_ok :: proc(id: string) -> bool {
	if id == "" || id == "." || id == ".." do return false
	return strings.index_any(id, "/\\:*?\"<>|") < 0
}

lua_register_app :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	fail :: proc(L: ^lua_State, msg: string) -> c.int {
		lua_pushnil(L)
		lua_pushstring(L, strings.clone_to_cstring(msg, context.temp_allocator))
		return 2
	}
	id := lua_string(L, 1)
	if !app_id_ok(id) do return fail(L, "Register_App: bad id")
	if lua_type(L, 2) != LUA_TTABLE do return fail(L, "Register_App: second argument must be a table")
	lua_getglobal(L, "PLUGIN_DIR")
	plugin_dir := strings.clone(lua_string(L, -1), context.temp_allocator)
	lua_pop(L, 1)
	field :: proc(L: ^lua_State, key: cstring) -> string {
		defer lua_pop(L, 1)
		if lua_getfield(L, 2, key) != LUA_TSTRING do return ""
		return strings.clone(lua_string(L, -1), context.temp_allocator)
	}
	abs :: proc(dir, p: string) -> string {
		if p == "" || filepath.is_abs(p) do return p
		return path_join({dir, p})
	}
	name, exe, args, img := field(L, "name"), abs(plugin_dir, field(L, "exe")), field(L, "args"), abs(plugin_dir, field(L, "img"))
	if exe == "" do return fail(L, "Register_App: exe is required")
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "name=\"%s\"\n", name != "" ? name : id)
	fmt.sbprintf(&b, "exe=\"%s\"\n", exe)
	fmt.sbprintf(&b, "exe_args=\"%s\"\n", args)
	if img != "" do fmt.sbprintf(&b, "img=\"%s\"\n", img)
	if p := plugin_for_state(L); p != nil do fmt.sbprintf(&b, "plugin=\"%s\"\n", p.file)
	os.make_directory_all(app_dir_of(id))
	path := path_join({app_dir_of(id), fmt.tprintf("%s.toml", id)})
	if os.write_entire_file(path, b.buf[:]) != nil do return fail(L, fmt.tprintf("Couldn't write %s", path))
	apps_rescan()
	lua_pushboolean(L, 1)
	return 1
}

lua_unregister_app :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	id := lua_string(L, 1)
	if !app_id_ok(id) || !os.exists(path_join({app_dir_of(id), fmt.tprintf("%s.toml", id)})) {
		lua_pushboolean(L, 0)
		return 1
	}
	app_remove_files(id)
	lua_pushboolean(L, 1)
	return 1
}
