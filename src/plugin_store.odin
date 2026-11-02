package saber

// Plugin store (PLUGINS > GET PLUGINS): installs single plugins from GitHub repos.
//
// Repos come from `pluginrepos.txt` in any plugins folder (APP/plugins and `plugin_dirs=`), one per
// line: `https://github.com/<owner>/<repo>`, optionally `/tree/<branch>`, or just `<owner>/<repo>`.
// `#` starts a comment. Every top-level folder of a repo with a `plugin.lua` is one plugin.
//
// Refresh = one GitHub API call per repo (git/trees, recursive), plus plugin.lua (name, version,
// author, description) and icon.png of each plugin from raw.githubusercontent.com.
// Install downloads only that plugin's files into APP/plugins/.store/stage/<folder>/, then moves
// them into APP/plugins/<folder>/ (files the repo doesn't have, like settings.ini, are kept).
// New plugins load right away; updates of a loaded plugin apply after a restart.
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

Store_Plugin :: struct {
	repo:        int,
	folder:      string,
	files:       [dynamic]string, // repo paths, "<folder>/..."
	name:        string,
	version:     string,
	author:      string,
	description: string,
	icon:        rl.Texture2D,
	has_icon:    bool,
	state:       Store_State,
	err:         string,
	// install progress
	queue:       [dynamic]string,
	done:        int,
}

store: struct {
	loaded:  bool, // refreshed at least once
	gen:     int,  // bumped on refresh; stale callbacks are ignored
	pending: int,  // tree requests still running
	repos:   [dynamic]Store_Repo,
	plugins: [dynamic]Store_Plugin,
	sel:     int,  // 0 = Refresh row, 1.. = plugins
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
		delete(p.name)
		delete(p.version)
		delete(p.author)
		delete(p.description)
		delete(p.err)
		if p.has_icon do rl.UnloadTexture(p.icon)
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
	store_clear()
	store.gen += 1
	store.loaded = true
	store.sel = 0
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
	defer if store.pending == 0 do store_set_message("%d plugin(s) in %d repo(s)", len(store.plugins), len(store.repos))
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
	// top-level folders with a plugin.lua
	for e in t.tree {
		dir, file := filepath.split(e.path)
		if e.kind != "blob" || file != "plugin.lua" || strings.count(e.path, "/") != 1 do continue
		p := Store_Plugin{repo = req.user[1], folder = strings.clone(strings.trim_suffix(dir, "/"))}
		p.name = strings.clone(p.folder)
		has_icon := false
		for f in t.tree {
			if f.kind != "blob" || !strings.has_prefix(f.path, fmt.tprintf("%s/", p.folder)) do continue
			append(&p.files, strings.clone(f.path))
			if f.path == fmt.tprintf("%s/icon.png", p.folder) do has_icon = true
		}
		append(&store.plugins, p)
		idx := len(store.plugins) - 1
		http_start_native(store_raw_url(repo, e.path), "", store_on_meta, {store.gen, idx})
		if has_icon {
			icon := path_join({store_dir(), "icons", fmt.tprintf("%s_%s_%s.png", repo.owner, repo.name, p.folder)})
			http_start_native(store_raw_url(repo, fmt.tprintf("%s/icon.png", p.folder)), icon, store_on_icon, {store.gen, idx})
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
}

store_on_icon :: proc(req: ^Http_Request) {
	if req.user[0] != store.gen || !req.ok do return
	p := &store.plugins[req.user[1]]
	p.icon, p.has_icon = load_texture_smooth(req.path, 256)
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
	for &q in plugins do if strings.equal_fold(q.file, p.folder) do return &q
	return nil
}

store_install :: proc(idx: int) {
	p := &store.plugins[idx]
	if p.state == .Installing do return
	if !online_enabled() {
		set_status("Turn on Online Mode (Settings) to download plugins")
		sfx_back()
		return
	}
	clear(&p.queue)
	for f in p.files do append(&p.queue, f)
	p.done = 0
	p.state = .Installing
	os.remove_all(path_join({store_dir(), "stage", p.folder}))
	store_next_file(idx)
	sfx_click()
}

store_next_file :: proc(idx: int) {
	p := &store.plugins[idx]
	if len(p.queue) == 0 {
		store_finish_install(p)
		return
	}
	f := pop(&p.queue)
	repo := &store.repos[p.repo]
	http_start_native(store_raw_url(repo, f), path_join({store_dir(), "stage", f}), store_on_file, {store.gen, idx})
}

store_on_file :: proc(req: ^Http_Request) {
	if req.user[0] != store.gen do return
	p := &store.plugins[req.user[1]]
	if !req.ok {
		p.state = .Failed
		delete(p.err)
		p.err = strings.clone(req.err)
		set_status("%s: download failed (%s)", p.name, req.err)
		os.remove_all(path_join({store_dir(), "stage", p.folder}))
		return
	}
	p.done += 1
	store_next_file(req.user[1])
}

store_finish_install :: proc(p: ^Store_Plugin) {
	stage := path_join({store_dir(), "stage"})
	dest_root := path_join({app.exe_dir, "plugins"})
	for f in p.files {
		dst := path_join({dest_root, f})
		os.make_directory_all(filepath.dir(dst))
		os.remove(dst)
		if os.rename(path_join({stage, f}), dst) != nil {
			p.state = .Failed
			delete(p.err)
			p.err = fmt.aprintf("Couldn't write %s", dst)
			set_status("%s: %s", p.name, p.err)
			return
		}
	}
	os.remove_all(path_join({stage, p.folder}))
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

store_on_open :: proc() {
	if !store.loaded || (len(store.plugins) == 0 && store.pending == 0 && online_enabled()) do store_refresh()
}

// ---------------------------------------------------------------------------
// UI

handle_store_input :: proc() {
	n := 1 + len(store.plugins)
	store.sel = clamp(store.sel, 0, n - 1)
	if input.up && store.sel > 0 {
		store.sel -= 1
		sfx_click()
	}
	if input.down && store.sel < n - 1 {
		store.sel += 1
		sfx_click()
	}
	if input.confirm {
		if store.sel == 0 {
			store_refresh()
			sfx_click()
		} else {
			store_install(store.sel - 1)
		}
	}
}

store_plugin_status :: proc(p: ^Store_Plugin) -> string {
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

draw_store :: proc(w, h, y0, bottom: f32) {
	n := 1 + len(store.plugins)
	store.sel = clamp(store.sel, 0, n - 1)
	// keep the selection in view
	visible := max(1, int((bottom - y0) / (PLUGIN_ROW_H + ROW_GAP)))
	first := clamp(store.sel - visible + 1, 0, max(0, n - visible))

	for i in first ..< n {
		r := rl.Rectangle{PAD, y0 + f32(i - first) * (PLUGIN_ROW_H + ROW_GAP), PLUGIN_LIST_W, PLUGIN_ROW_H}
		if r.y + r.height > bottom do break
		sel := i == store.sel
		if mouse_over(r) && rl.IsMouseButtonPressed(.LEFT) {
			if sel {
				handle_store_click(i)
			} else {
				store.sel = i
				sfx_click()
			}
		}
		draw_panel(r, sel)
		if sel do rl.DrawRectangleRounded({r.x + 8, r.y + 16, 3, r.height - 32}, 1, 4, COL_ACCENT)
		tx := r.x + 24
		if i == 0 {
			draw_t_fit("Refresh", tx, r.y + 11, r.width - 40, 19, sel ? COL_TEXT : COL_MUTED, sel)
			draw_t_fit(store.message, tx, r.y + 37, r.width - 40, 14, COL_MUTED, sel)
			continue
		}
		p := &store.plugins[i - 1]
		if p.has_icon {
			draw_texture_fit(p.icon, r.x + 14, r.y + 10, 44, 44)
			tx = r.x + 72
		}
		draw_t_fit(p.name, tx, r.y + 11, r.width - tx + r.x - 16, 19, sel ? COL_TEXT : COL_MUTED, sel)
		sub := fmt.tprintf("%s/%s", store.repos[p.repo].owner, store.repos[p.repo].name)
		if st := store_plugin_status(p); st != "" do sub = fmt.tprintf("%s  ·  %s", st, sub)
		draw_t_fit(sub, tx, r.y + 37, r.width - tx + r.x - 16, 14, COL_MUTED, false)
	}

	// detail
	r := rl.Rectangle{PAD + PLUGIN_LIST_W + 24, y0, w - PAD * 2 - PLUGIN_LIST_W - 24, bottom - y0}
	draw_panel(r, false, with_alpha(COL_PANEL_SOLID, 214))
	x := r.x + 28
	iw := r.width - 56
	y := r.y + 24
	if store.sel == 0 {
		draw_t("GET PLUGINS", x, y, 28, COL_TEXT)
		y += 44
		draw_t_fit("Plugins from the GitHub repos listed in plugins/pluginrepos.txt.", x, y, iw, 16, COL_TEXT, false)
		y += 28
		draw_t_fit("Pick one to download just that plugin. Press A here to reload the lists.", x, y, iw, 16, COL_MUTED, false)
		y += 40
		for &repo in store.repos {
			if y > r.y + r.height - 40 do break
			draw_t_fit(fmt.tprintf("%s/%s", repo.owner, repo.name), x, y, iw * 0.5, 16, COL_TEXT, false)
			count := 0
			for &p in store.plugins do if &store.repos[p.repo] == &repo do count += 1
			note := repo.err != "" ? repo.err : store.pending > 0 ? "..." : fmt.tprintf("%d plugin(s)", count)
			draw_t_fit(note, x + iw * 0.5, y, iw * 0.5, 16, repo.err != "" ? COL_ACCENT : COL_MUTED, false)
			y += 26
		}
		return
	}
	p := &store.plugins[store.sel - 1]
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
	draw_t(fmt.tprintf("%d file(s), installs to APP/plugins/%s", len(p.files), p.folder), x, y, 15, COL_MUTED)
	y += 26
	if q := store_installed(p); q != nil && q.version != "" {
		draw_t(fmt.tprintf("Installed: v%s", q.version), x, y, 15, COL_MUTED)
		y += 26
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
	case st == "Installed" || st == "Restart to apply": label = "Reinstall"
	}
	draw_panel(ar, true)
	draw_t_fit(label, ar.x + 18, ar.y + 9, iw - 140, 18, COL_TEXT, true)
	desc := online_enabled() ? "Downloads only this plugin's files" : "Needs Online Mode (Settings)"
	draw_t_fit(desc, ar.x + 18, ar.y + 33, iw - 140, 14, COL_MUTED, false)
	if p.state != .Installing {
		draw_t_right(label, ar.x + ar.width - 44, ar.y + 19, 17, COL_TEXT)
		draw_glyph("A", ar.x + ar.width - 26, ar.y + ar.height * 0.5)
	}
	if mouse_over(ar) && rl.IsMouseButtonPressed(.LEFT) do store_install(store.sel - 1)
}

handle_store_click :: proc(i: int) {
	if i == 0 {
		store_refresh()
		sfx_click()
	} else {
		store_install(i - 1)
	}
}
