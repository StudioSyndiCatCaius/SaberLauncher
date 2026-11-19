package saber

// General Lua helpers for plugins and channels (nothing service-specific):
//
//   Json_Decode(text) -> value | nil, err     objects -> tables, arrays -> 1-based tables, null -> nil
//   Inflate(data [, raw]) -> string | nil, err  zlib (raw = true: bare deflate)
//   Make_Dir(path) -> true | nil, err          creates every missing folder
//   List_Dirs(dir) -> { "name", ... }          sub-folder names (List_Dir lists files)
//   Exists(path) -> bool                       file or folder
//   Rescan_Library()                           re-reads GAMES (after adding a game folder)
//   Rescan_Channels()                          re-reads CHANNELS (deferred until no channel runs)
//   Remove_Dir(path) -> true | nil, err        deletes a folder and everything in it (only inside SABER_DIR)
//   Relative paths = the plugin's / channel's folder.

import "base:runtime"
import "core:bytes"
import "core:c"
import "core:compress/zlib"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

lua_push_json :: proc(L: ^lua_State, v: json.Value, depth: int) {
	if depth > 200 {
		lua_pushnil(L)
		return
	}
	switch x in v {
	case json.Null:    lua_pushnil(L)
	case json.Boolean: lua_pushboolean(L, x ? 1 : 0)
	case json.Integer: lua_pushinteger(L, i64(x))
	case json.Float:
		if f64(i64(x)) == f64(x) && abs(f64(x)) < 1e15 {
			lua_pushinteger(L, i64(x))
		} else {
			lua_pushnumber(L, f64(x))
		}
	case json.String:
		s := string(x)
		lua_pushlstring(L, raw_data(s), c.size_t(len(s)))
	case json.Array:
		lua_createtable(L, c.int(len(x)), 0)
		for e, i in x {
			lua_push_json(L, e, depth + 1)
			lua_rawseti(L, -2, i64(i + 1))
		}
	case json.Object:
		lua_createtable(L, 0, c.int(len(x)))
		for k, e in x {
			if _, is_null := e.(json.Null); is_null do continue
			lua_push_json(L, e, depth + 1)
			lua_setfield(L, -2, strings.clone_to_cstring(k, context.temp_allocator))
		}
	}
}

lua_fail :: proc(L: ^lua_State, msg: string) -> c.int {
	lua_pushnil(L)
	lua_pushstring(L, strings.clone_to_cstring(msg, context.temp_allocator))
	return 2
}

lua_bytes :: proc(L: ^lua_State, idx: c.int) -> []u8 {
	n: c.size_t
	s := lua_tolstring(L, idx, &n)
	if s == nil do return nil
	return (cast([^]u8)s)[:n]
}

lua_json_decode :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	data := lua_bytes(L, 1)
	if data == nil do return lua_fail(L, "Json_Decode: expects a string")
	v, err := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	if err != nil do return lua_fail(L, "Json_Decode: not valid JSON")
	lua_push_json(L, v, 0)
	return 1
}

lua_inflate :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	data := lua_bytes(L, 1)
	if data == nil do return lua_fail(L, "Inflate: expects a string")
	out: bytes.Buffer
	defer bytes.buffer_destroy(&out)
	if zlib.inflate_from_byte_array(data, &out, raw = lua_toboolean(L, 2) != 0) != nil do return lua_fail(L, "Inflate: not zlib data")
	res := bytes.buffer_to_bytes(&out)
	lua_pushlstring(L, raw_data(res), c.size_t(len(res)))
	return 1
}

lua_make_dir :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	path := lua_plugin_path(L, lua_string(L, 1))
	if path == "" do return lua_fail(L, "Make_Dir: missing path")
	if err := os.make_directory_all(path); err != nil && !os.exists(path) do return lua_fail(L, "Make_Dir: couldn't create the folder")
	lua_pushboolean(L, 1)
	return 1
}

lua_list_dirs :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	lua_createtable(L, 0, 0)
	fis, ok := list_dir(lua_plugin_path(L, lua_string(L, 1)))
	if !ok do return 1
	i: i64 = 1
	for fi in fis {
		if fi.type != .Directory do continue
		lua_pushstring(L, strings.clone_to_cstring(fi.name, context.temp_allocator))
		lua_rawseti(L, -2, i)
		i += 1
	}
	return 1
}

lua_exists :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	path := lua_plugin_path(L, lua_string(L, 1))
	lua_pushboolean(L, path != "" && os.exists(path) ? 1 : 0)
	return 1
}

lua_rescan_library :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	rescan_library()
	update_scan_message()
	return 0
}

lua_rescan_channels :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	chan.rescan_req = true
	return 0
}

// Only below the APP folder, never the APP folder itself, never the running channel's own folder.
lua_remove_dir :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	path := lua_plugin_path(L, lua_string(L, 1))
	full, err := filepath.abs(path, context.temp_allocator)
	root, _ := filepath.abs(app.exe_dir, context.temp_allocator)
	rel, rerr := filepath.rel(root, full, context.temp_allocator)
	bad := path == "" || err != nil || rerr != nil || rel == "." || strings.has_prefix(rel, "..") || filepath.is_abs(rel)
	if !bad && channel_running() && chan.running < len(chan.list) {
		own, _ := filepath.abs(chan.list[chan.running].dir, context.temp_allocator)
		if eq_fold(own, full) do bad = true
	}
	if bad {
		lua_pushnil(L)
		lua_pushstring(L, "not allowed")
		return 2
	}
	if !os.exists(full) {
		lua_pushboolean(L, 1)
		return 1
	}
	if e := os.remove_all(full); e != nil {
		lua_pushnil(L)
		lua_pushstring(L, strings.clone_to_cstring(os.error_string(e), context.temp_allocator))
		return 2
	}
	lua_pushboolean(L, 1)
	return 1
}
