package saber

// Lua plugins: every APP/plugins/<name>/plugin.lua (plus optional icon.png) is run in its own Lua state and must return a table.
//
//   return {
//     name     = "PlayStation Info",   -- shown in logs/UI
//     platform = "ps1",                -- optional: only consulted for games of this platform
//     system   = { name=, manufacturer=, released= },        -- optional platform facts
//     games    = { ["SLUS-00892"] = { title=, year=, developer=, publisher=, genre=, disc=, discs= } },
//     on_game  = function(game) return { ...same fields as a games entry... } end,  -- optional
//     actions  = { id = { name=, description=, online=, Do=function() end } },  -- Plugins tab
//     settings = { ... }, on_disc = function(game) end   -- see plugin_hooks.odin
//   on_game / games entries may also return box = "<image path>" (cover art).
//   }
//
// `game` passed to on_game: { serial, platform, label, title }.
// Lua API: saber.log(msg), saber.version, plus globals PLUGIN_DIR, Dialog_Info / Dialog_Process / Dialog_Menu (plugin_dialogs.odin), Online / Http_Get / Http_Download / Http_Pending (online.odin). Errors go to APP/plugins/plugins.log.
// Earlier sources win: games table first, then on_game, plugins in file-name order.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

Plugin :: struct {
	name:        string,
	file:        string, // folder name
	dir:         string,
	icon:        rl.Texture2D, // dir/icon.png
	has_icon:    bool,
	platform:    string,
	version:     string,
	author:      string,
	description: string,
	game_count:  int,
	system:      [dynamic]Meta_Line, // string/number fields of the `system` table
	actions:     [dynamic]Plugin_Action,
	settings:    [dynamic]Plugin_Setting,
	L:           ^lua_State,
}

// An entry of the plugin's `actions` table: id = { name=, description=, Do=function() }.
// `Do` (or `run`) may return a string, shown as the status message.
Plugin_Action :: struct {
	id:          string,
	name:        string,
	description: string,
	runnable:    bool,
	fn:          cstring, // "Do" (or the older "run")
	online:      bool,    // needs Online Mode; disabled while it's off
}

Meta_Line :: struct {
	label: string,
	value: string,
}

plugins: [dynamic]Plugin
plugin_log: ^os.File

// Loads APP/plugins, then every folder in Saber.ini `plugin_dirs=` (';'-separated, relative
// to the exe). A plugin whose folder name was already loaded from an earlier directory is skipped.
plugins_init :: proc() {
	dir := path_join({app.exe_dir, "plugins"})
	os.make_directory_all(dir)
	if f, ferr := os.open(path_join({dir, "plugins.log"}), {.Write, .Create, .Trunc}); ferr == nil {
		plugin_log = f
	}
	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, dir)
	for d in strings.split(app.settings.plugin_dirs, ";", context.temp_allocator) {
		d := strings.trim(strings.trim_space(d), `"`)
		if d == "" do continue
		append(&dirs, filepath.is_abs(d) ? d : path_join({app.exe_dir, d}))
	}
	loaded := make(map[string]bool, allocator = context.temp_allocator)
	for d in dirs {
		fis, err := os.read_all_directory_by_path(d, context.allocator)
		if err != nil {
			plugin_logf("plugin_dirs: can't read %s", d)
			continue
		}
		defer os.file_info_slice_delete(fis, context.allocator)
		slice.sort_by(fis, proc(a, b: os.File_Info) -> bool { return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator) })
		for fi in fis {
			if fi.type != .Directory do continue
			main := path_join({fi.fullpath, "plugin.lua"})
			if !os.exists(main) do continue
			key := strings.to_lower(fi.name, context.temp_allocator)
			if loaded[key] {
				plugin_logf("%s: skipped, a plugin named %s is already loaded", fi.fullpath, fi.name)
				continue
			}
			loaded[key] = true
			plugin_load(main, fi.name, fi.fullpath)
		}
	}
	plugin_logf("%d plugin(s) loaded", len(plugins))
}

plugins_shutdown :: proc() {
	for &d in plugin_dialogs do dialog_free(&d)
	clear(&plugin_dialogs)
	for p in plugins {
		lua_close(p.L)
		if p.has_icon do rl.UnloadTexture(p.icon)
	}
	clear(&plugins)
	if plugin_log != nil do os.close(plugin_log)
	plugin_log = nil
}

plugin_logf :: proc(format: string, args: ..any) {
	if plugin_log == nil do return
	fmt.fprintfln(plugin_log, format, ..args)
}

plugin_load :: proc(path, file, dir: string) {
	L := luaL_newstate()
	luaL_openlibs(L)
	lua_createtable(L, 0, 4)
	lua_pushcclosure(L, lua_saber_log, 0)
	lua_setfield(L, -2, "log")

	lua_pushstring(L, strings.clone_to_cstring(saber_version(), context.temp_allocator))
	lua_setfield(L, -2, "version")
	lua_setglobal(L, "saber")
	lua_register(L, "Dialog_Info", lua_dialog_info)
	lua_register(L, "Dialog_Process", lua_dialog_process)
	lua_register(L, "Dialog_Menu", lua_dialog_menu)
	lua_pushstring(L, strings.clone_to_cstring(dir, context.temp_allocator))
	lua_setglobal(L, "PLUGIN_DIR")
	lua_pushstring(L, strings.clone_to_cstring(app.exe_dir, context.temp_allocator))
	lua_setglobal(L, "SABER_DIR")
	lua_register(L, "Setting", lua_setting)
	lua_register(L, "Plugins_GetSetting", lua_plugins_get_setting)
	lua_register(L, "Set_Art", lua_set_art)
	lua_register(L, "Disc_Games", lua_disc_games)
	lua_register(L, "List_Dir", lua_list_dir)
	lua_register(L, "Unzip", lua_unzip)
	lua_register(L, "Online", lua_online)
	lua_register(L, "Http_Get", lua_http_get)
	lua_register(L, "Http_Download", lua_http_download)
	lua_register(L, "Http_Pending", lua_http_pending)

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if luaL_loadfilex(L, cpath, nil) != LUA_OK || lua_pcall(L, 0, 1, 0) != LUA_OK {
		plugin_logf("%s: %s", file, lua_string(L, -1))
		lua_close(L)
		return
	}
	if lua_type(L, -1) != LUA_TTABLE {
		plugin_logf("%s: must return a table", file)
		lua_close(L)
		return
	}
	lua_setglobal(L, "PLUGIN")

	p := Plugin{L = L, file = strings.clone(file), dir = strings.clone(dir)}
	p.icon, p.has_icon = load_texture_smooth(path_join({dir, "icon.png"}), 256)
	lua_getglobal(L, "PLUGIN")
	p.name = strings.clone(lua_field_string(L, -1, "name"))
	if p.name == "" do p.name = strings.clone(file)
	p.platform = strings.to_lower(lua_field_string(L, -1, "platform"))
	p.version = strings.clone(lua_field_string(L, -1, "version"))
	p.author = strings.clone(lua_field_string(L, -1, "author"))
	p.description = strings.clone(lua_field_string(L, -1, "description"))
	if lua_getfield(L, -1, "system") == LUA_TTABLE {
		for key in lua_table_keys(L) {
			v := lua_field_string(L, -1, strings.clone_to_cstring(key, context.temp_allocator))
			if v != "" do append(&p.system, Meta_Line{strings.clone(key), strings.clone(v)})
		}
	}
	lua_pop(L, 1)
	if lua_getfield(L, -1, "games") == LUA_TTABLE {
		lua_pushnil(L)
		for lua_next(L, -2) != 0 {
			p.game_count += 1
			lua_pop(L, 1)
		}
	}
	lua_pop(L, 1)
	if lua_getfield(L, -1, "actions") == LUA_TTABLE {
		for key in lua_table_keys(L) {
			a := Plugin_Action{id = strings.clone(key)}
			ckey := strings.clone_to_cstring(key, context.temp_allocator)
			if lua_getfield(L, -1, ckey) == LUA_TTABLE {
				a.name = strings.clone(lua_field_string(L, -1, "name"))
				if lua_getfield(L, -1, "online") == LUA_TBOOLEAN do a.online = lua_toboolean(L, -1) != 0
				lua_pop(L, 1)
				a.description = strings.clone(lua_field_string(L, -1, "description"))
				a.fn = "Do"
				if lua_getfield(L, -1, "Do") != LUA_TFUNCTION {
					lua_pop(L, 1)
					a.fn = "run"
					lua_getfield(L, -1, "run")
				}
				a.runnable = lua_type(L, -1) == LUA_TFUNCTION
				lua_pop(L, 1)
			}
			lua_pop(L, 1)
			if a.name == "" do a.name = a.id
			append(&p.actions, a)
		}
	}
	lua_pop(L, 1)
	plugin_load_settings(&p)
	lua_pop(L, 1)
	append(&plugins, p)
	plugin_logf("loaded %s (%s)", p.name, file)
}

// Sorted string keys of the table on top of the stack.
lua_table_keys :: proc(L: ^lua_State) -> []string {
	keys := make([dynamic]string, context.temp_allocator)
	lua_pushnil(L)
	for lua_next(L, -2) != 0 {
		if lua_type(L, -2) == LUA_TSTRING do append(&keys, strings.clone(lua_string(L, -2), context.temp_allocator))
		lua_pop(L, 1)
	}
	slice.sort(keys[:])
	return keys[:]
}

// Calls PLUGIN.actions[id].run(); returns its message (or the Lua error).
plugin_run_action :: proc(p: ^Plugin, a: ^Plugin_Action) -> string {
	if a.online && !online_enabled() do return fmt.tprintf("\"%s\" needs Online Mode (Settings)", a.name)
	if !a.runnable do return fmt.tprintf("%s: \"%s\" isn't implemented yet", p.name, a.name)
	L := p.L
	top := lua_gettop(L)
	defer lua_settop(L, top)
	lua_getglobal(L, "PLUGIN")
	lua_getfield(L, -1, "actions")
	lua_getfield(L, -1, strings.clone_to_cstring(a.id, context.temp_allocator))
	lua_getfield(L, -1, a.fn)
	if lua_pcall(L, 0, 1, 0) != LUA_OK {
		msg := lua_string(L, -1)
		plugin_logf("%s: %s: %s", p.name, a.id, msg)
		return fmt.tprintf("%s failed: %s", a.name, msg)
	}
	if lua_type(L, -1) == LUA_TSTRING do return strings.clone(lua_string(L, -1), context.temp_allocator)
	if plugin_dialog_open() do return "" // the action opened a dialog; it reports for itself
	return fmt.tprintf("%s: done", a.name)
}

lua_saber_log :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	plugin_logf("[lua] %s", lua_string(L, 1))
	return 0
}

saber_version :: proc() -> string {
	data, err := os.read_entire_file(path_join({app.exe_dir, "version.ini"}), context.temp_allocator)
	if err != nil do return "dev"
	if v, ok := ini_get(string(data), "version"); ok do return v
	return strings.trim_space(string(data))
}

// Reads t[key] as a string (numbers are formatted) from the table at idx; "" if missing.
lua_field_string :: proc(L: ^lua_State, idx: c.int, key: cstring) -> string {
	t := lua_getfield(L, idx, key)
	defer lua_pop(L, 1)
	if t == LUA_TSTRING || t == LUA_TNUMBER {
		if t == LUA_TNUMBER {
			n := lua_tonumberx(L, -1, nil)
			if n == f64(i64(n)) do return fmt.tprintf("%d", i64(n))
		}
		return strings.clone(lua_string(L, -1), context.temp_allocator)
	}
	return ""
}

// Fields a plugin can fill, in display order.
GAME_META_FIELDS := [?]struct{ key: cstring, label: string } {
	{"developer", "Developer"},
	{"publisher", "Publisher"},
	{"year", "Released"},
	{"genre", "Genre"},
	{"players", "Players"},
	{"region", "Region"},
}

Game_Meta :: struct {
	title:    string,
	box:      string, // cover image path
	disc:     string,
	discs:    string,
	system:   string,
	fields:   [len(GAME_META_FIELDS)]string,
}

// Copies the fields of the table on top of the stack into `m`, keeping values already set.
read_game_meta :: proc(L: ^lua_State, m: ^Game_Meta) {
	fill :: proc(dst: ^string, v: string) {
		if dst^ == "" && v != "" do dst^ = v
	}
	fill(&m.title, lua_field_string(L, -1, "title"))
	fill(&m.box, lua_field_string(L, -1, "box"))
	fill(&m.disc, lua_field_string(L, -1, "disc"))
	fill(&m.discs, lua_field_string(L, -1, "discs"))
	for f, i in GAME_META_FIELDS do fill(&m.fields[i], lua_field_string(L, -1, f.key))
}

// Fills title / tags / info of a disc game from the plugins.
// from_ini: a _Saber game; its own title, tags and box art win over the plugins'.
plugins_apply :: proc(g: ^Game, from_ini := false) {
	plat := RETRO_PLATFORM_DIR[g.meta_platform]
	m: Game_Meta
	for &p in plugins {
		if p.platform != "" && p.platform != plat do continue
		L := p.L
		top := lua_gettop(L)
		lua_getglobal(L, "PLUGIN")

		if lua_getfield(L, -1, "system") == LUA_TTABLE && m.system == "" {
			name := lua_field_string(L, -1, "name")
			maker := lua_field_string(L, -1, "manufacturer")
			year := lua_field_string(L, -1, "released")
			switch {
			case name == "":
			case maker != "" && year != "": m.system = fmt.tprintf("%s (%s, %s)", name, maker, year)
			case maker != "":               m.system = fmt.tprintf("%s (%s)", name, maker)
			case:                           m.system = name
			}
		}
		lua_pop(L, 1)

		if lua_getfield(L, -1, "games") == LUA_TTABLE {
			key := strings.clone_to_cstring(g.disc_serial, context.temp_allocator)
			if lua_getfield(L, -1, key) == LUA_TTABLE do read_game_meta(L, &m)
			lua_pop(L, 1)
		}
		lua_pop(L, 1)

		if lua_getfield(L, -1, "on_game") == LUA_TFUNCTION {
			lua_createtable(L, 0, 4)
			push_field(L, "serial", g.disc_serial)
			push_field(L, "platform", plat)
			push_field(L, "label", g.drive_label)
			push_field(L, "title", g.title)
			push_rom_fields(L, g)
			if lua_pcall(L, 1, 1, 0) != LUA_OK {
				plugin_logf("%s: on_game: %s", p.name, lua_string(L, -1))
			} else if lua_type(L, -1) == LUA_TTABLE {
				read_game_meta(L, &m)
			}
		}
		lua_settop(L, top)
	}

	if m.box != "" && os.exists(m.box) && !(from_ini && g.has_box) do game_set_box(g, m.box)
	if !from_ini {
		if m.title != "" {
			delete(g.title)
			g.title = strings.clone(m.title)
		}
		tags := make([dynamic]string, context.temp_allocator)
		append(&tags, RETRO_PLATFORM_NAME[g.meta_platform])
		if year := m.fields[2]; year != "" do append(&tags, year)
		if m.disc != "" && m.discs != "" && m.discs != "1" do append(&tags, fmt.tprintf("Disc %s of %s", m.disc, m.discs))
		if g.rom_path == "" do append(&tags, g.disc_serial)
		delete(g.tags)
		g.tags = strings.join(tags[:], "  ·  ")
	}

	clear(&g.info)
	for f, i in GAME_META_FIELDS {
		if m.fields[i] != "" do append(&g.info, Meta_Line{f.label, strings.clone(m.fields[i])})
	}
	if m.system != "" do append(&g.info, Meta_Line{"System", strings.clone(m.system)})
	if g.rom_path == "" {
		append(&g.info, Meta_Line{"Serial", strings.clone(g.disc_serial)})
	} else {
		append(&g.info, Meta_Line{"File", strings.clone(filepath.base(g.rom_path))})
		if g.rom_crc != "" do append(&g.info, Meta_Line{"CRC32", strings.clone(g.rom_crc)})
	}
}

push_field :: proc(L: ^lua_State, key: cstring, value: string) {
	lua_pushstring(L, strings.clone_to_cstring(value, context.temp_allocator))
	lua_setfield(L, -2, key)
}
