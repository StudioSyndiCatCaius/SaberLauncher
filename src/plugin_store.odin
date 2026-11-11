package saber

// Plugin / app store (PLUGINS > GET PLUGINS, APPS > GET APPS): installs single plugins and apps
// from GitHub repos.
//
// Repos come from `pluginrepos.txt` in any plugins folder (APP/plugins and `plugin_dirs=`), one per
// line: `https://github.com/<owner>/<repo>`, optionally `/tree/<branch>`, or just `<owner>/<repo>`.
// `#` starts a comment. In a repo, `Plugins/<name>/plugin.lua` (or a top-level `<name>/plugin.lua`)
// is one plugin and `Apps/<name>/app.lua` is one app (installed by app_store.odin).
//
// Refresh = one GitHub API call per repo (git/trees, recursive), plus plugin.lua (name, version,
// author, description) and icon.png of each plugin from raw.githubusercontent.com.
// Install downloads only that plugin's files into APP/plugins/.store/stage/<folder>/, then moves
// them into APP/plugins/<folder>/ (files the repo doesn't have, like settings.ini, are kept).
// New plugins load right away; updates of a loaded plugin apply after a restart.
// Installs write a `.saber_store` marker (the repo); only marked plugins can be deleted
// (PLUGINS page > Delete Plugin), so the built-in ones are safe.
// Everything needs Online Mode.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

Store_Repo :: struct {
	owner, name, branch: string, // branch "HEAD" = the default branch
	err:                 string,
}

Store_State :: enum {
	Available,
	Installing,
	Installed, // this session
	Failed,
}

Store_Kind :: enum {
	Plugin,
	App,
}

Store_Plugin :: struct {
	kind:        Store_Kind,
	repo:        int,
	folder:      string,          // install folder name (last part of prefix)
	prefix:      string,          // repo folder: "Plugins/GameWiki", "GameWiki", "Apps/QuiverLauncher"
	files:       [dynamic]string, // repo paths, "<prefix>/..."
	name:        string,
	version:     string,
	author:      string,
	description: string,
	icon:        rl.Texture2D,
	has_icon:    bool,
	thumb:       rl.Texture2D, // apps: screenshot (thumb.png/.jpg or `thumb` URL)
	has_thumb:   bool,
	packed_art:  [2]bool,      // icon / thumb ship in the repo folder (wins over URLs in app.lua)
	state:       Store_State,
	err:         string,
	// install progress
	queue:       [dynamic]string,
	done:        int,
	// app installs (app_store.odin)
	link:        bool,          // app.lua only locates an existing install (no download)
	step:        string,        // what an app install is doing ("" = fetching its files)
	req:         ^Http_Request, // running payload download
	spec:        App_Spec,
	job:         ^App_Job,
}

store: struct {
	loaded:  bool, // refreshed at least once
	gen:     int,  // bumped on refresh; stale callbacks are ignored
	pending: int,  // tree requests still running
	repos:   [dynamic]Store_Repo,
	plugins: [dynamic]Store_Plugin,
	sel:     [Store_Kind]int, // per page: 0 = Refresh row, 1.. = entries of that kind
	armed:   int,              // app removal: store index waiting for the second X, -1 = none
	message: string,
}

store_dir :: proc() -> string {
	return path_join({app.exe_dir, "plugins", ".store"})
}

store_raw_url :: proc(repo: ^Store_Repo, path: string) -> string {
	enc, _ := strings.replace_all(path, " ", "%20", context.temp_allocator)
	return fmt.tprintf("https://raw.githubusercontent.com/%s/%s/%s/%s", repo.owner, repo.name, repo.branch, enc)
}

// "https://github.com/o/r/tree/b", "github.com/o/r.git", "o/r" -> owner, repo, branch
store_parse_repo :: proc(line: string) -> (r: Store_Repo, ok: bool) {
	s := strings.trim_space(line)
	if i := strings.index_byte(s, '#'); i >= 0 do s = strings.trim_space(s[:i])
	if s == "" do return
	for prefix in ([]string{"https://", "http://", "www.", "github.com/"}) {
		s = strings.trim_prefix(s, prefix)
	}
	parts := strings.split(strings.trim(s, "/"), "/", context.temp_allocator)
	if len(parts) < 2 || parts[0] == "" || parts[1] == "" do return
	r.owner = strings.clone(parts[0])
	r.name = strings.clone(strings.trim_suffix(parts[1], ".git"))
	r.branch = strings.clone(len(parts) >= 4 && parts[2] == "tree" ? parts[3] : "HEAD")
	return r, true
}

store_clear :: proc() {
	for &p in store.plugins {
		for f in p.files do delete(f)
		delete(p.files)
		delete(p.queue)
		delete(p.folder)
		delete(p.prefix)
		delete(p.step)
		app_spec_free(&p.spec)
		delete(p.name)
		delete(p.version)
		delete(p.author)
		delete(p.description)
		delete(p.err)
		if p.has_icon do rl.UnloadTexture(p.icon)
		if p.has_thumb do rl.UnloadTexture(p.thumb)
	}
	clear(&store.plugins)
	for r in store.repos {
		delete(r.owner)
		delete(r.name)
		delete(r.branch)
		delete(r.err)
	}
	clear(&store.repos)
}

store_set_message :: proc(format: string, args: ..any) {
	delete(store.message)
	store.message = fmt.aprintf(format, ..args)
}

store_refresh :: proc() {
	for &p in store.plugins {
		if p.state == .Installing {
			set_status("Wait for %s to finish installing", p.name)
			return
		}
	}
	store_clear()
	store.gen += 1
	store.loaded = true
	store.sel = {}
	store.armed = -1
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for d in plugin_dir_list() {
		data, err := os.read_entire_file(path_join({d, "pluginrepos.txt"}), context.temp_allocator)
		if err != nil do continue
		it := string(data)
		for line in strings.split_lines_iterator(&it) {
			r, ok := store_parse_repo(line)
			if !ok do continue
			key := strings.to_lower(fmt.tprintf("%s/%s", r.owner, r.name), context.temp_allocator)
			if seen[key] do continue
			seen[key] = true
			append(&store.repos, r)
		}
	}
	if len(store.repos) == 0 {
		store_set_message("No repos: add GitHub links to plugins/pluginrepos.txt (one per line)")
		return
	}
	if !online_enabled() {
		store_set_message("Turn on Online Mode (Settings) to browse plugins")
		return
	}
	store.pending = len(store.repos)
	store_set_message("Loading %d repo(s)...", len(store.repos))
	for &r, i in store.repos {
		url := fmt.tprintf("https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1", r.owner, r.name, r.branch)
		http_start_native(url, "", store_on_tree, {store.gen, i})
	}
}

store_on_tree :: proc(req: ^Http_Request) {
	if req.user[0] != store.gen do return
	store.pending -= 1
	defer if store.pending == 0 do store_set_message("%d plugin(s), %d app(s) in %d repo(s)", store_count(.Plugin), store_count(.App), len(store.repos))
	repo := &store.repos[req.user[1]]
	if !req.ok {
		repo.err = strings.clone(req.status == 403 ? "GitHub rate limit reached, try again later" : req.err)
		plugin_logf("store: %s/%s: %s", repo.owner, repo.name, repo.err)
		return
	}
	Tree :: struct {
		tree: []struct {
			path: string,
			kind: string `json:"type"`,
		},
	}
	t: Tree
	if json.unmarshal(req.body, &t, allocator = context.temp_allocator) != nil {
		repo.err = strings.clone("Unexpected reply from GitHub")
		return
	}
	// Plugins/<name>/plugin.lua, <name>/plugin.lua (older repos), Apps/<name>/app.lua
	for e in t.tree {
		if e.kind != "blob" do continue
		parts := strings.split(e.path, "/", context.temp_allocator)
		kind: Store_Kind
		switch {
		case len(parts) == 2 && parts[1] == "plugin.lua" && !strings.equal_fold(parts[0], "plugins") && !strings.equal_fold(parts[0], "apps"):
			kind = .Plugin
		case len(parts) == 3 && strings.equal_fold(parts[0], "plugins") && parts[2] == "plugin.lua":
			kind = .Plugin
		case len(parts) == 3 && strings.equal_fold(parts[0], "apps") && parts[2] == "app.lua":
			kind = .App
		case:
			continue
		}
		p := Store_Plugin{kind = kind, repo = req.user[1], folder = strings.clone(parts[len(parts) - 2])}
		p.prefix = strings.clone(e.path[:len(e.path) - len(parts[len(parts) - 1]) - 1])
		p.name = strings.clone(p.folder)
		has_icon := false
		thumb := ""
		for f in t.tree {
			if f.kind != "blob" || !strings.has_prefix(f.path, fmt.tprintf("%s/", p.prefix)) do continue
			rel := f.path[len(p.prefix) + 1:]
			if kind == .App && (rel == "thumb.png" || rel == "thumb.jpg") do thumb = rel // store preview only
			// apps: only the recipe, its icon and the files/ seed folder (no stray copies)
			if kind == .App && rel != "app.lua" && rel != "icon.png" && !strings.has_prefix(rel, "files/") do continue
			append(&p.files, strings.clone(f.path))
			if rel == "icon.png" do has_icon = true
		}
		p.packed_art = {has_icon, thumb != ""}
		append(&store.plugins, p)
		idx := len(store.plugins) - 1
		http_start_native(store_raw_url(repo, e.path), "", store_on_meta, {store.gen, idx})
		if has_icon {
			http_start_native(store_raw_url(repo, fmt.tprintf("%s/icon.png", p.prefix)), store_art_cache(idx, "icon", ".png"), store_on_icon, {store.gen, idx})
		}
		if thumb != "" {
			http_start_native(store_raw_url(repo, fmt.tprintf("%s/%s", p.prefix, thumb)), store_art_cache(idx, "thumb", filepath.ext(thumb)), store_on_thumb, {store.gen, idx})
		}
	}
}

store_on_meta :: proc(req: ^Http_Request) {
	if req.user[0] != store.gen || !req.ok do return
	p := &store.plugins[req.user[1]]
	src := string(req.body)
	if v := lua_string_field(src, "name"); v != "" {
		delete(p.name)
		p.name = v
	}
	delete(p.version)
	delete(p.author)
	delete(p.description)
	p.version = lua_string_field(src, "version")
	p.author = lua_string_field(src, "author")
	p.description = lua_string_field(src, "description")
	if p.kind == .App && p.state != .Installing {
		delete(p.spec.download)
		p.spec.download = lua_string_field(src, "download")
		p.link = p.spec.download == "" && strings.contains(src, "locate")
		// art from URLs in app.lua, unless the repo folder ships its own
		is_url :: proc(s: string) -> bool {return strings.has_prefix(s, "https://") || strings.has_prefix(s, "http://")}
		idx := req.user[1]
		if icon := lua_string_field(src, "icon"); !p.packed_art[0] && is_url(icon) {
			http_start_native(icon, store_art_cache(idx, "icon", url_ext(icon)), store_on_icon, {store.gen, idx})
		}
		if thumb := lua_string_field(src, "thumb"); !p.packed_art[1] && is_url(thumb) {
			http_start_native(thumb, store_art_cache(idx, "thumb", url_ext(thumb)), store_on_thumb, {store.gen, idx})
		}
	}
}

// .store/icons/<owner>_<repo>_<kind>_<folder>[_thumb].<ext>
store_art_cache :: proc(idx: int, what, ext: string) -> string {
	p := &store.plugins[idx]
	repo := &store.repos[p.repo]
	suffix := what == "icon" ? "" : fmt.tprintf("_%s", what)
	return path_join({store_dir(), "icons", fmt.tprintf("%s_%s_%v_%s%s%s", repo.owner, repo.name, p.kind, p.folder, suffix, ext)})
}

// ".png" / ".jpg" from a URL (query stripped), ".png" when unsure
url_ext :: proc(url: string) -> string {
	u := url
	if i := strings.index_any(u, "?#"); i >= 0 do u = u[:i]
	ext := strings.to_lower(filepath.ext(u), context.temp_allocator)
	switch ext {
	case ".png", ".jpg", ".jpeg", ".webp", ".bmp": return ext
	}
	return ".png"
}

store_on_icon :: proc(req: ^Http_Request) {
	if req.user[0] != store.gen || !req.ok do return
	p := &store.plugins[req.user[1]]
	if p.has_icon do rl.UnloadTexture(p.icon)
	p.icon, p.has_icon = load_texture_smooth(req.path, 256)
}

store_on_thumb :: proc(req: ^Http_Request) {
	if req.user[0] != store.gen || !req.ok do return
	p := &store.plugins[req.user[1]]
	if p.has_thumb do rl.UnloadTexture(p.thumb)
	p.thumb, p.has_thumb = load_texture_smooth(req.path, 1024)
}

// First `key = "text" [.. "more"]` in a Lua source (the plugin's returned table, by convention).
lua_string_field :: proc(src, key: string) -> string {
	it := src
	for line in strings.split_lines_iterator(&it) {
		s := strings.trim_left_space(line)
		if !strings.has_prefix(s, key) do continue
		s = strings.trim_left_space(s[len(key):])
		if !strings.has_prefix(s, "=") do continue
		s = strings.trim_left_space(s[1:])
		if !strings.has_prefix(s, `"`) do continue
		// rest of the source from here, so `..` continuations on the next lines work
		rest := src[int(uintptr(raw_data(s)) - uintptr(raw_data(src))):]
		out := strings.builder_make()
		for strings.has_prefix(rest, `"`) {
			i := 1
			for i < len(rest) && rest[i] != '"' {
				if rest[i] == '\\' && i + 1 < len(rest) {
					i += 1
					switch rest[i] {
					case 'n': strings.write_byte(&out, '\n')
					case 't': strings.write_byte(&out, ' ')
					case: strings.write_byte(&out, rest[i])
					}
				} else {
					strings.write_byte(&out, rest[i])
				}
				i += 1
			}
			rest = strings.trim_left_space(rest[min(i + 1, len(rest)):])
			if !strings.has_prefix(rest, "..") do break
			rest = strings.trim_left_space(rest[2:])
		}
		return strings.to_string(out)
	}
	return ""
}

// The loaded (or turned off) plugin with this folder name, if any.
store_installed :: proc(p: ^Store_Plugin) -> ^Plugin {
	if p.kind != .Plugin do return nil
	for &q in plugins do if strings.equal_fold(q.file, p.folder) do return &q
	return nil
}

store_is_installed :: proc(p: ^Store_Plugin) -> bool {
	return p.kind == .App ? app_store_installed(p) : store_installed(p) != nil
}

store_count :: proc(kind: Store_Kind) -> int {
	n := 0
	for &p in store.plugins do if p.kind == kind do n += 1
	return n
}

// Store indices of one kind, in list order.
store_list :: proc(kind: Store_Kind) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for &p, i in store.plugins do if p.kind == kind do append(&out, i)
	return out[:]
}

// Where p's repo files are staged: .store/stage/<plugins|apps>/<folder>/<path inside the folder>.
store_stage_dir :: proc(p: ^Store_Plugin) -> string {
	return path_join({store_dir(), "stage", p.kind == .App ? "apps" : "plugins", p.folder})
}

store_rel :: proc(p: ^Store_Plugin, repo_path: string) -> string {
	return repo_path[len(p.prefix) + 1:]
}

store_install :: proc(idx: int) {
	p := &store.plugins[idx]
	if p.state == .Installing do return
	if !online_enabled() {
		set_status("Turn on Online Mode (Settings) to download %s", p.kind == .App ? "apps" : "plugins")
		sfx_back()
		return
	}
	clear(&p.queue)
	for f in p.files do append(&p.queue, f)
	p.done = 0
	p.state = .Installing
	delete(p.step)
	p.step = ""
	os.remove_all(store_stage_dir(p))
	store_next_file(idx)
	sfx_click()
}

store_next_file :: proc(idx: int) {
	p := &store.plugins[idx]
	if len(p.queue) == 0 {
		if p.kind == .App do app_store_staged(idx)
		else do store_finish_install(p)
		return
	}
	f := pop(&p.queue)
	repo := &store.repos[p.repo]
	http_start_native(store_raw_url(repo, f), path_join({store_stage_dir(p), store_rel(p, f)}), store_on_file, {store.gen, idx})
}

store_on_file :: proc(req: ^Http_Request) {
	if req.user[0] != store.gen do return
	p := &store.plugins[req.user[1]]
	if !req.ok {
		p.state = .Failed
		delete(p.err)
		p.err = strings.clone(req.err)
		set_status("%s: download failed (%s)", p.name, req.err)
		os.remove_all(store_stage_dir(p))
		return
	}
	p.done += 1
	store_next_file(req.user[1])
}

store_finish_install :: proc(p: ^Store_Plugin) {
	stage := store_stage_dir(p)
	dest_root := path_join({app.exe_dir, "plugins"})
	for f in p.files {
		rel := store_rel(p, f)
		dst := path_join({dest_root, p.folder, rel})
		os.make_directory_all(filepath.dir(dst))
		os.remove(dst)
		if os.rename(path_join({stage, rel}), dst) != nil {
			p.state = .Failed
			delete(p.err)
			p.err = fmt.aprintf("Couldn't write %s", dst)
			set_status("%s: %s", p.name, p.err)
			return
		}
	}
	os.remove_all(stage)
	repo := &store.repos[p.repo]
	_ = os.write_entire_file(path_join({dest_root, p.folder, STORE_MARKER}), transmute([]u8)fmt.tprintf("%s/%s\n", repo.owner, repo.name))
	p.state = .Installed
	if q := store_installed(p); q != nil {
		set_status("%s updated: restart Saber to apply (Settings > Restart Saber)", p.name)
	} else {
		dir := path_join({dest_root, p.folder})
		plugin_load(path_join({dir, "plugin.lua"}), p.folder, dir)
		set_status("%s installed", p.name)
	}
	plugin_logf("store: installed %s from %s/%s", p.folder, store.repos[p.repo].owner, store.repos[p.repo].name)
}

STORE_MARKER :: ".saber_store"
COL_STORE_OK :: rl.Color{64, 196, 104, 255}

// Installed from the store into APP/plugins (built-in plugins have no marker).
plugin_is_downloaded :: proc(p: ^Plugin) -> bool {
	root := path_join({app.exe_dir, "plugins"})
	return strings.equal_fold(filepath.dir(p.dir), root) && os.exists(path_join({p.dir, STORE_MARKER}))
}

// Unloads a store-installed plugin and deletes its folder.
plugin_delete :: proc(idx: int) {
	p := &plugins[idx]
	if !plugin_is_downloaded(p) do return
	if p.L != nil {
		// drop everything still pointing into its Lua state
		for i := len(plugin_dialogs) - 1; i >= 0; i -= 1 {
			if plugin_dialogs[i].L == p.L {
				dialog_free(&plugin_dialogs[i])
				ordered_remove(&plugin_dialogs, i)
			}
		}
		for r in http_requests {
			if r.L != p.L do continue
			if r.callback != LUA_NOREF do luaL_unref(r.L, LUA_REGISTRYINDEX, r.callback)
			r.callback = LUA_NOREF
			r.L = nil
		}
		lua_close(p.L)
	}
	if p.has_icon do rl.UnloadTexture(p.icon)
	name := strings.clone(p.name, context.temp_allocator)
	err := os.remove_all(p.dir)
	for &sp in store.plugins do if sp.kind == .Plugin && strings.equal_fold(sp.folder, p.file) do sp.state = .Available
	plugin_logf("store: deleted %s (%s)", p.file, p.dir)
	ordered_remove(&plugins, idx)
	app.plugin_sel = clamp(app.plugin_sel, 0, max(0, len(plugins) - 1))
	app.plugin_focus = 0
	app.plugin_action = 0
	if err != nil {
		set_status("%s removed, but some files couldn't be deleted", name)
	} else {
		set_status("%s deleted", name)
	}
	sfx_back()
}

// Green ring that fills while downloading, and a green tick circle once installed.
draw_store_badge :: proc(cx, cy: f32, p: ^Store_Plugin) {
	R :: 11
	switch {
	case p.state == .Installing:
		t := store_progress(p)
		spin := f32(rl.GetTime()) * 360
		rl.DrawRing({cx, cy}, R - 3, R, 0, 360, 32, with_alpha(COL_STORE_OK, 60))
		rl.DrawRing({cx, cy}, R - 3, R, spin, spin + max(30, 360 * t), 32, COL_STORE_OK)
	case store_is_installed(p) || p.state == .Installed:
		rl.DrawCircleV({cx, cy}, R, COL_STORE_OK)
		a := rl.Vector2{cx - 5, cy}
		b := rl.Vector2{cx - 1.5, cy + 4}
		c := rl.Vector2{cx + 5.5, cy - 4}
		rl.DrawLineEx(a, b, 2.5, rl.WHITE)
		rl.DrawLineEx(b, c, 2.5, rl.WHITE)
	}
}

// 0..1 for the badge: the repo files, then (apps) the download and the unpacking.
store_progress :: proc(p: ^Store_Plugin) -> f32 {
	files := len(p.files) > 0 ? f32(p.done) / f32(len(p.files)) : 0
	if p.kind != .App do return files
	return files * 0.05 + app_store_progress(p) * 0.95
}

store_on_open :: proc() {
	if !store.loaded || (len(store.plugins) == 0 && store.pending == 0 && online_enabled()) do store_refresh()
}

// ---------------------------------------------------------------------------
// UI (shared by GET PLUGINS and GET APPS; `kind` picks the entries)

handle_store_input :: proc(kind: Store_Kind) {
	list := store_list(kind)
	sel := &store.sel[kind]
	n := 1 + len(list)
	sel^ = clamp(sel^, 0, n - 1)
	old := sel^
	if input.up && sel^ > 0 {
		sel^ -= 1
		sfx_click()
	}
	if input.down && sel^ < n - 1 {
		sel^ += 1
		sfx_click()
	}
	if sel^ != old do store.armed = -1
	if input.confirm {
		handle_store_click(kind, sel^)
	} else if input.action && kind == .App && sel^ > 0 {
		app_store_remove_press(list[sel^ - 1])
	}
}

handle_store_click :: proc(kind: Store_Kind, i: int) {
	if i == 0 {
		store_refresh()
		sfx_click()
	} else {
		store_install(store_list(kind)[i - 1])
	}
}

store_plugin_status :: proc(p: ^Store_Plugin) -> string {
	if p.kind == .App {
		switch p.state {
		case .Installing: return app_store_step_label(p)
		case .Failed:     return "Failed"
		case .Installed:  return "Installed"
		case .Available:
		}
		if !app_store_installed(p) do return ""
		iv := app_store_installed_version(p)
		if p.version != "" && iv != "" && p.version != iv do return fmt.tprintf("Update (v%s)", iv)
		return "Installed"
	}
	q := store_installed(p)
	switch p.state {
	case .Installing: return fmt.tprintf("Downloading %d/%d", p.done + 1, len(p.files))
	case .Failed:     return "Failed"
	case .Installed:  return q != nil && q.L != nil && q.version != p.version ? "Restart to apply" : "Installed"
	case .Available:
	}
	if q == nil do return ""
	if p.version != "" && q.version != "" && p.version != q.version do return fmt.tprintf("Update (v%s)", q.version)
	return "Installed"
}

draw_store :: proc(kind: Store_Kind, w, h, y0, bottom: f32) {
	list := store_list(kind)
	sel := &store.sel[kind]
	n := 1 + len(list)
	sel^ = clamp(sel^, 0, n - 1)
	// keep the selection in view
	visible := max(1, int((bottom - y0) / (PLUGIN_ROW_H + ROW_GAP)))
	first := clamp(sel^ - visible + 1, 0, max(0, n - visible))

	for i in first ..< n {
		r := rl.Rectangle{PAD, y0 + f32(i - first) * (PLUGIN_ROW_H + ROW_GAP), PLUGIN_LIST_W, PLUGIN_ROW_H}
		if r.y + r.height > bottom do break
		is_sel := i == sel^
		if mouse_over(r) && rl.IsMouseButtonPressed(.LEFT) {
			if is_sel {
				handle_store_click(kind, i)
			} else {
				sel^ = i
				store.armed = -1
				sfx_click()
			}
		}
		draw_panel(r, is_sel)
		if is_sel do rl.DrawRectangleRounded({r.x + 8, r.y + 16, 3, r.height - 32}, 1, 4, COL_ACCENT)
		tx := r.x + 24
		if i == 0 {
			draw_t_fit("Refresh", tx, r.y + 11, r.width - 40, 19, is_sel ? COL_TEXT : COL_MUTED, is_sel)
			draw_t_fit(store.message, tx, r.y + 37, r.width - 40, 14, COL_MUTED, is_sel)
			continue
		}
		p := &store.plugins[list[i - 1]]
		if p.has_icon {
			draw_texture_fit(p.icon, r.x + 14, r.y + 10, 44, 44)
			tx = r.x + 72
		}
		draw_store_badge(r.x + r.width - 26, r.y + r.height * 0.5, p)
		draw_t_fit(p.name, tx, r.y + 11, r.width - tx + r.x - 52, 19, is_sel ? COL_TEXT : COL_MUTED, is_sel)
		sub := fmt.tprintf("%s/%s", store.repos[p.repo].owner, store.repos[p.repo].name)
		if st := store_plugin_status(p); st != "" do sub = fmt.tprintf("%s  ·  %s", st, sub)
		draw_t_fit(sub, tx, r.y + 37, r.width - tx + r.x - 52, 14, COL_MUTED, false)
	}

	// detail
	r := rl.Rectangle{PAD + PLUGIN_LIST_W + 24, y0, w - PAD * 2 - PLUGIN_LIST_W - 24, bottom - y0}
	draw_panel(r, false, with_alpha(COL_PANEL_SOLID, 214))
	x := r.x + 28
	iw := r.width - 56
	y := r.y + 24
	what := kind == .App ? "app" : "plugin"
	if sel^ == 0 {
		draw_t(kind == .App ? "GET APPS" : "GET PLUGINS", x, y, 28, COL_TEXT)
		y += 44
		draw_t_fit(fmt.tprintf("%ss from the GitHub repos listed in plugins/pluginrepos.txt.", kind == .App ? "Apps" : "Plugins"), x, y, iw, 16, COL_TEXT, false)
		y += 28
		draw_t_fit(fmt.tprintf("Pick one to download just that %s. Press A here to reload the lists.", what), x, y, iw, 16, COL_MUTED, false)
		y += 40
		for &repo, ri in store.repos {
			if y > r.y + r.height - 40 do break
			draw_t_fit(fmt.tprintf("%s/%s", repo.owner, repo.name), x, y, iw * 0.5, 16, COL_TEXT, false)
			count := 0
			for &p in store.plugins do if p.repo == ri && p.kind == kind do count += 1
			note := repo.err != "" ? repo.err : store.pending > 0 ? "..." : fmt.tprintf("%d %s(s)", count, what)
			draw_t_fit(note, x + iw * 0.5, y, iw * 0.5, 16, repo.err != "" ? COL_ACCENT : COL_MUTED, false)
			y += 26
		}
		return
	}
	idx := list[sel^ - 1]
	p := &store.plugins[idx]
	tx := x
	if p.has_icon {
		draw_texture_fit(p.icon, x, y - 4, 64, 64)
		tx = x + 80
	}
	draw_t_fit(p.name, tx, y, iw - (tx - x), 28, COL_TEXT, true)
	y += 40
	byline := make([dynamic]string, context.temp_allocator)
	if p.version != "" do append(&byline, fmt.tprintf("v%s", p.version))
	if p.author != "" do append(&byline, fmt.tprintf("by %s", p.author))
	append(&byline, fmt.tprintf("%s/%s", store.repos[p.repo].owner, store.repos[p.repo].name))
	draw_t_fit(strings.join(byline[:], "  ·  ", context.temp_allocator), tx, y, iw - (tx - x), 15, COL_ACCENT, false)
	y += p.has_icon ? 40 : 28
	if p.description != "" {
		draw_t_fit(p.description, x, y, iw, 16, COL_TEXT, true)
		y += 30
	}
	if kind == .App {
		if p.link || app_store_linked(p) {
			draw_t_fit("Uses the copy already installed on this PC (nothing is downloaded)", x, y, iw, 15, COL_MUTED, false)
		} else {
			draw_t(fmt.tprintf("Installs to APP/apps/%s", p.folder), x, y, 15, COL_MUTED)
		}
		y += 26
		if host := url_host(p.spec.download); host != "" {
			draw_t_fit(fmt.tprintf("Downloads from %s", host), x, y, iw, 15, COL_MUTED, false)
			y += 26
		}
		if iv := app_store_installed_version(p); iv != "" {
			draw_t(fmt.tprintf("Installed: v%s", iv), x, y, 15, COL_MUTED)
			y += 26
		}
	} else {
		draw_t(fmt.tprintf("%d file(s), installs to APP/plugins/%s", len(p.files), p.folder), x, y, 15, COL_MUTED)
		y += 26
		if q := store_installed(p); q != nil && q.version != "" {
			draw_t(fmt.tprintf("Installed: v%s", q.version), x, y, 15, COL_MUTED)
			y += 26
		}
	}
	if p.state == .Failed && p.err != "" {
		draw_t_fit(p.err, x, y, iw, 15, COL_ACCENT, false)
		y += 26
	}

	y += 14
	ar := rl.Rectangle{x, y, iw, ACTION_ROW_H}
	label := "Download"
	st := store_plugin_status(p)
	switch {
	case p.state == .Installing:        label = st
	case strings.has_prefix(st, "Update"): label = "Update"
	case st == "Installed" || st == "Restart to apply": label = p.link ? "Find again" : "Reinstall"
	case p.link:                        label = "Find on PC"
	}
	draw_panel(ar, true)
	draw_t_fit(label, ar.x + 18, ar.y + 9, iw - 140, 18, COL_TEXT, true)
	desc := "Downloads only this plugin's files"
	if kind == .App do desc = p.link ? "Looks for it on this PC and adds it to APPS" : "Downloads the app and adds it to APPS"
	if !online_enabled() do desc = "Needs Online Mode (Settings)"
	draw_t_fit(desc, ar.x + 18, ar.y + 33, iw - 140, 14, COL_MUTED, false)
	if p.state != .Installing {
		draw_t_right(label, ar.x + ar.width - 44, ar.y + 19, 17, COL_TEXT)
		draw_glyph("A", ar.x + ar.width - 26, ar.y + ar.height * 0.5)
	}
	if mouse_over(ar) && rl.IsMouseButtonPressed(.LEFT) do store_install(idx)

	if kind == .App && p.state != .Installing && app_store_installed(p) {
		rr := rl.Rectangle{x, y + ACTION_ROW_H + 10, iw, ACTION_ROW_H}
		armed := store.armed == idx
		draw_panel(rr, armed)
		draw_t_fit(armed ? "Press X again to remove" : "Remove", rr.x + 18, rr.y + 9, iw - 140, 18, armed ? COL_ACCENT : COL_TEXT, armed)
		rm_desc := app_store_linked(p) ? fmt.tprintf("Removes the APPS card only (%s stays installed)", p.name) : fmt.tprintf("Deletes APP/apps/%s and its APPS card", p.folder)
		draw_t_fit(rm_desc, rr.x + 18, rr.y + 33, iw - 140, 14, COL_MUTED, false)
		draw_t_right("Remove", rr.x + rr.width - 44, rr.y + 19, 17, COL_TEXT)
		draw_glyph("X", rr.x + rr.width - 26, rr.y + rr.height * 0.5)
		if mouse_over(rr) && rl.IsMouseButtonPressed(.LEFT) do app_store_remove_press(idx)
	}
}

// "https://github.com/a/b/..." -> "github.com"
url_host :: proc(url: string) -> string {
	s := url
	if i := strings.index(s, "://"); i >= 0 do s = s[i + 3:]
	if i := strings.index_byte(s, '/'); i >= 0 do s = s[:i]
	return s
}
