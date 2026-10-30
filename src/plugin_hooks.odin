package saber

// Plugin settings, the disc-inserted hook, and the art / game / file globals.
//
// Settings (declared by the plugin, saved to <plugin>/settings.ini, edited on the Plugins tab):
//   settings = {
//     auto  = { name = "Download on disc insert", description = "...", type = "boolean", default = true, order = 1 },
//     style = { name = "Cover style", type = "enum", options = { "Flat", "3D" }, default = 1 },  -- index or text
//   }
//   Setting("style") -> "Flat"      Plugins_GetSetting("EasyGameCovers", "auto") -> true
//   ("bool"/"boolean" and "choice"/"enum" are both accepted)
//
// Hooks:   on_disc = function(game) end           -- a disc (or identified _Saber game) appeared; also at startup
//          on_scan = function(games) end          -- after every drive scan: all identified games present now
//          on_online = function(enabled) end      -- Online Mode switched
//          on_setting = function(key, value) end  -- one of this plugin's settings changed
//          game = { serial, platform, title, label, letter, root, kind = "disc" | "folder" }
// Globals: Set_Art(serial, path)           -- use `path` as the cover of every game with that serial (nil clears)
//          Disc_Games()                    -> array of game tables for the discs inserted right now
//          List_Dir(path)                  -> array of file names (relative paths = the plugin's folder)

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

Plugin_Setting_Kind :: enum {
	Bool,
	Choice,
}

Plugin_Setting :: struct {
	key:     string,
	name:        string,
	description: string,
	kind:    Plugin_Setting_Kind,
	options: [dynamic]string, // Choice
	value:   int,             // Bool: 0/1, Choice: option index
	order:   int,
}

// Reads PLUGIN.settings (table on top of the stack is PLUGIN) and the saved values.
plugin_load_settings :: proc(p: ^Plugin) {
	L := p.L
	if lua_getfield(L, -1, "settings") != LUA_TTABLE {
		lua_pop(L, 1)
		return
	}
	for key in lua_table_keys(L) {
		ckey := strings.clone_to_cstring(key, context.temp_allocator)
		if lua_getfield(L, -1, ckey) != LUA_TTABLE {
			lua_pop(L, 1)
			continue
		}
		s := Plugin_Setting{key = strings.clone(key)}
		s.name = strings.clone(lua_field_string(L, -1, "name"))
		if s.name == "" do s.name = strings.clone(key)
		s.order = strconv.parse_int(lua_field_string(L, -1, "order")) or_else 0
		s.description = strings.clone(lua_field_string(L, -1, "description"))
		kind := strings.to_lower(lua_field_string(L, -1, "type"), context.temp_allocator)
		if kind == "choice" || kind == "enum" {
			s.kind = .Choice
			if lua_getfield(L, -1, "options") == LUA_TTABLE {
				for i in 1 ..= int(lua_rawlen(L, -1)) {
					lua_rawgeti(L, -1, i64(i))
					append(&s.options, strings.clone(lua_string(L, -1)))
					lua_pop(L, 1)
				}
			}
			lua_pop(L, 1)
			if len(s.options) == 0 do append(&s.options, strings.clone("-"))
			// default: option text, or a 1-based option index
			lua_getfield(L, -1, "default")
			if lua_type(L, -1) == LUA_TNUMBER {
				s.value = clamp(int(lua_tonumberx(L, -1, nil)) - 1, 0, len(s.options) - 1)
			} else {
				def := lua_string(L, -1)
				for o, i in s.options do if o == def do s.value = i
			}
			lua_pop(L, 1)
		} else {
			lua_getfield(L, -1, "default")
			s.value = lua_toboolean(L, -1) != 0 ? 1 : 0
			lua_pop(L, 1)
		}
		lua_pop(L, 1)
		append(&p.settings, s)
	}
	lua_pop(L, 1)
	slice.sort_by(p.settings[:], proc(a, b: Plugin_Setting) -> bool {
		if a.order != b.order do return a.order < b.order
		return a.key < b.key
	})

	data, err := os.read_entire_file(path_join({p.dir, "settings.ini"}), context.temp_allocator)
	if err != nil do return
	for &s in p.settings {
		v, found := ini_get(string(data), s.key)
		if !found do continue
		switch s.kind {
		case .Bool:
			s.value = v == "1" || strings.equal_fold(v, "true") ? 1 : 0
		case .Choice:
			for o, i in s.options do if o == v do s.value = i
		}
	}
}

setting_value_label :: proc(s: ^Plugin_Setting) -> string {
	switch s.kind {
	case .Bool:   return s.value != 0 ? "On" : "Off"
	case .Choice: return s.options[s.value]
	}
	return ""
}

plugin_change_setting :: proc(p: ^Plugin, s: ^Plugin_Setting, step: int) {
	switch s.kind {
	case .Bool:   s.value = 1 - s.value
	case .Choice: s.value = (s.value + step + len(s.options)) % len(s.options)
	}
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "[settings]\n")
	for &o in p.settings do fmt.sbprintf(&sb, "%s=%s\n", o.key, o.kind == .Bool ? (o.value != 0 ? "1" : "0") : o.options[o.value])
	_ = os.write_entire_file(path_join({p.dir, "settings.ini"}), strings.to_string(sb))
	sfx_click()
	changed_setting = s
	plugin_call_hook(p, "on_setting", 2, proc(L: ^lua_State) {
		s := changed_setting
		lua_pushstring(L, strings.clone_to_cstring(s.key, context.temp_allocator))
		switch s.kind {
		case .Bool:   lua_pushboolean(L, c.int(s.value))
		case .Choice: lua_pushstring(L, strings.clone_to_cstring(s.options[s.value], context.temp_allocator))
		}
	})
}

// Setting(key) -> bool / string / nil, for the calling plugin
lua_setting :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	return push_setting(L, plugin_for_state(L), lua_string(L, 1))
}

// Plugins_GetSetting(plugin, key): plugin = folder name or display name
lua_plugins_get_setting :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	name := lua_string(L, 1)
	for &p in plugins {
		if strings.equal_fold(p.file, name) || strings.equal_fold(p.name, name) do return push_setting(L, &p, lua_string(L, 2))
	}
	lua_pushnil(L)
	return 1
}

push_setting :: proc(L: ^lua_State, p: ^Plugin, key: string) -> c.int {
	if p != nil {
		for &s in p.settings {
			if s.key != key do continue
			switch s.kind {
			case .Bool:   lua_pushboolean(L, c.int(s.value))
			case .Choice: lua_pushstring(L, strings.clone_to_cstring(s.options[s.value], context.temp_allocator))
			}
			return 1
		}
	}
	lua_pushnil(L)
	return 1
}

// ---------------------------------------------------------------------------
// Discs

push_game_table :: proc(L: ^lua_State, g: ^Game) {
	lua_createtable(L, 0, 5)
	push_field(L, "serial", g.disc_serial)
	push_field(L, "platform", RETRO_PLATFORM_DIR[g.meta_platform])
	push_field(L, "title", g.title)
	push_field(L, "label", g.drive_label)
	push_field(L, "letter", g.disc_letter != 0 ? fmt.tprintf("%c", g.disc_letter) : "")
	push_field(L, "root", g.root)
	// folder = a _Saber game on a drive, rom = a ROM file on a drive
	push_field(L, "kind", g.rom_path != "" ? "rom" : g.platform != .None ? "disc" : "folder")
	push_rom_fields(L, g)
}

// ROMs: file = file name without extension, crc = CRC32 hex ("" when not hashed)
push_rom_fields :: proc(L: ^lua_State, g: ^Game) {
	if g.rom_path == "" do return
	push_field(L, "file", g.rom_name)
	push_field(L, "crc", g.rom_crc)
}

seen_discs: [dynamic]string // "F:SLUS-00892" of the discs present at the last scan

// Calls on_disc for every disc that wasn't there at the previous scan.
plugins_discs_changed :: proc() {
	now := make([dynamic]string, context.temp_allocator)
	for &g in app.drive_games {
		if !game_identified(&g) do continue
		key := fmt.tprintf("%s|%s", g.root, g.disc_serial)
		append(&now, key)
		if slice.contains(seen_discs[:], key) do continue
		plugin_logf("disc inserted: %s (%s)", g.title, key)
		plat := RETRO_PLATFORM_DIR[g.meta_platform]
		for &p in plugins {
			if p.L == nil || (p.platform != "" && p.platform != plat) do continue
			L := p.L
			top := lua_gettop(L)
			lua_getglobal(L, "PLUGIN")
			if lua_getfield(L, -1, "on_disc") == LUA_TFUNCTION {
				push_game_table(L, &g)
				if lua_pcall(L, 1, 0, 0) != LUA_OK do plugin_logf("%s: on_disc: %s", p.name, lua_string(L, -1))
			}
			lua_settop(L, top)
		}
	}
	for s in seen_discs do delete(s)
	clear(&seen_discs)
	for k in now do append(&seen_discs, strings.clone(k))

	// on_scan(games): every identified game present right now, after every scan
	plugins_broadcast("on_scan", 1, proc(L: ^lua_State) { lua_disc_games(L) })
}

// Discs, and _Saber games that declare serial= and platform=.
game_identified :: proc(g: ^Game) -> bool {
	return g.disc_serial != "" && g.meta_platform != .None
}

// Calls PLUGIN.<hook>(args...) on every plugin that defines it. `push` pushes the arguments.
plugins_broadcast :: proc(hook: cstring, nargs: c.int, push: proc(L: ^lua_State)) {
	for &p in plugins do plugin_call_hook(&p, hook, nargs, push)
}

plugin_call_hook :: proc(p: ^Plugin, hook: cstring, nargs: c.int, push: proc(L: ^lua_State)) {
	L := p.L
	if L == nil do return
	top := lua_gettop(L)
	defer lua_settop(L, top)
	lua_getglobal(L, "PLUGIN")
	if lua_getfield(L, -1, hook) != LUA_TFUNCTION do return
	push(L)
	if lua_pcall(L, nargs, 0, 0) != LUA_OK do plugin_logf("%s: %s: %s", p.name, hook, lua_string(L, -1))
}

changed_setting: ^Plugin_Setting

// Set_Art(serial, path)
lua_set_art :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	serial := lua_string(L, 1)
	path := lua_type(L, 2) == LUA_TSTRING ? lua_string(L, 2) : ""
	n := 0
	for &g in app.drive_games {
		if !game_identified(&g) || !strings.equal_fold(g.disc_serial, serial) do continue
		game_set_box(&g, path)
		n += 1
	}
	for &g in app.library_games {
		if !game_identified(&g) || !strings.equal_fold(g.disc_serial, serial) do continue
		game_set_box(&g, path)
		n += 1
	}
	lua_pushinteger(L, i64(n))
	return 1
}

game_set_box :: proc(g: ^Game, path: string) {
	if g.has_box {
		rl.UnloadTexture(g.box)
		g.has_box = false
	}
	delete(g.box_file)
	g.box_file = strings.clone(path)
	if path != "" do g.box, g.has_box = load_texture_smooth(path)
}

// Disc_Games()
lua_disc_games :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	lua_createtable(L, 0, 0)
	i: i64 = 1
	for &g in app.drive_games {
		if !game_identified(&g) do continue
		push_game_table(L, &g)
		lua_rawseti(L, -2, i)
		i += 1
	}
	return 1
}

// List_Dir(path)
lua_list_dir :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	path := lua_string(L, 1)
	if !filepath.is_abs(path) {
		lua_getglobal(L, "PLUGIN_DIR")
		path = path_join({lua_string(L, -1), path})
		lua_pop(L, 1)
	}
	lua_createtable(L, 0, 0)
	fis, err := os.read_all_directory_by_path(path, context.allocator)
	if err != nil do return 1
	defer os.file_info_slice_delete(fis, context.allocator)
	i: i64 = 1
	for fi in fis {
		if fi.type != .Regular do continue
		lua_pushstring(L, strings.clone_to_cstring(fi.name, context.temp_allocator))
		lua_rawseti(L, -2, i)
		i += 1
	}
	return 1
}

// Unzip(zip, dest_dir) -> true | nil, error. Extracts every file into dest_dir, keeping folders
// (relative paths = plugin folder). Runs on the main thread: meant for a few MB at a time.
lua_unzip :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	paths: [2]string
	for &p, i in paths {
		p = lua_string(L, c.int(i + 1))
		if p != "" && !filepath.is_abs(p) {
			lua_getglobal(L, "PLUGIN_DIR")
			p = path_join({lua_string(L, -1), p})
			lua_pop(L, 1)
		}
	}
	fail :: proc(L: ^lua_State, msg: string) -> c.int {
		lua_pushnil(L)
		lua_pushstring(L, strings.clone_to_cstring(msg, context.temp_allocator))
		return 2
	}
	if paths[0] == "" || paths[1] == "" do return fail(L, "Unzip: missing zip or destination")
	// stored entries alias `data`, inflated ones are fresh buffers: all on the frame arena
	context.allocator = context.temp_allocator
	data, err := os.read_entire_file(paths[0], context.allocator)
	if err != nil do return fail(L, fmt.tprintf("can't read %s", paths[0]))
	files, zerr := zip_extract(data, nil)
	if zerr != "" do return fail(L, zerr)
	os.make_directory_all(paths[1])
	for name, content in files {
		out := path_join({paths[1], name})
		os.make_directory_all(filepath.dir(out))
		if os.write_entire_file(out, content) != nil {
			return fail(L, fmt.tprintf("can't write %s (in use?)", name))
		}
	}
	lua_pushboolean(L, 1)
	return 1
}
