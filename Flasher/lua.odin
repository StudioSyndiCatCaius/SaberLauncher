package flasher

import "core:c"

// Minimal Lua 5.4 bindings against the static lib built by lua/build_lua.bat
// (vendor:lua only ships a DLL on Windows, which would break the single-exe build).

foreign import liblua "lua/lua54_static.lib"

lua_State :: struct {}
lua_CFunction :: #type proc "c" (L: ^lua_State) -> c.int

LUA_OK :: 0
LUA_MULTRET :: -1
LUA_TNIL :: 0
LUA_TBOOLEAN :: 1
LUA_TNUMBER :: 3
LUA_TSTRING :: 4
LUA_TTABLE :: 5
LUA_TFUNCTION :: 6

@(default_calling_convention = "c")
foreign liblua {
	luaL_newstate :: proc() -> ^lua_State ---
	luaL_openlibs :: proc(L: ^lua_State) ---
	lua_close :: proc(L: ^lua_State) ---
	luaL_loadfilex :: proc(L: ^lua_State, filename: cstring, mode: cstring) -> c.int ---
	lua_pcallk :: proc(L: ^lua_State, nargs, nresults, errfunc: c.int, ctx: c.intptr_t, k: rawptr) -> c.int ---
	lua_callk :: proc(L: ^lua_State, nargs, nresults: c.int, ctx: c.intptr_t, k: rawptr) ---
	lua_gettop :: proc(L: ^lua_State) -> c.int ---
	lua_settop :: proc(L: ^lua_State, idx: c.int) ---
	lua_pushvalue :: proc(L: ^lua_State, idx: c.int) ---
	lua_type :: proc(L: ^lua_State, idx: c.int) -> c.int ---
	lua_tolstring :: proc(L: ^lua_State, idx: c.int, len: ^c.size_t) -> cstring ---
	lua_tonumberx :: proc(L: ^lua_State, idx: c.int, isnum: ^c.int) -> f64 ---
	lua_toboolean :: proc(L: ^lua_State, idx: c.int) -> c.int ---
	lua_pushnil :: proc(L: ^lua_State) ---
	lua_pushnumber :: proc(L: ^lua_State, n: f64) ---
	lua_pushinteger :: proc(L: ^lua_State, n: i64) ---
	lua_pushstring :: proc(L: ^lua_State, s: cstring) -> cstring ---
	lua_pushboolean :: proc(L: ^lua_State, b: c.int) ---
	lua_pushcclosure :: proc(L: ^lua_State, fn: lua_CFunction, n: c.int) ---
	lua_getglobal :: proc(L: ^lua_State, name: cstring) -> c.int ---
	lua_setglobal :: proc(L: ^lua_State, name: cstring) ---
	lua_getfield :: proc(L: ^lua_State, idx: c.int, k: cstring) -> c.int ---
	lua_setfield :: proc(L: ^lua_State, idx: c.int, k: cstring) ---
	lua_createtable :: proc(L: ^lua_State, narr, nrec: c.int) ---
	lua_error :: proc(L: ^lua_State) -> c.int ---
	luaL_checklstring :: proc(L: ^lua_State, arg: c.int, l: ^c.size_t) -> cstring ---
	luaL_traceback :: proc(L, L1: ^lua_State, msg: cstring, level: c.int) ---
}

lua_pop :: proc(L: ^lua_State, n: c.int) {
	lua_settop(L, -n - 1)
}

lua_pcall :: proc(L: ^lua_State, nargs, nresults, errfunc: c.int) -> c.int {
	return lua_pcallk(L, nargs, nresults, errfunc, 0, nil)
}

lua_call :: proc(L: ^lua_State, nargs, nresults: c.int) {
	lua_callk(L, nargs, nresults, 0, nil)
}

lua_register :: proc(L: ^lua_State, name: cstring, fn: lua_CFunction) {
	lua_pushcclosure(L, fn, 0)
	lua_setglobal(L, name)
}

lua_string :: proc(L: ^lua_State, idx: c.int) -> string {
	n: c.size_t
	s := lua_tolstring(L, idx, &n)
	if s == nil do return ""
	return string((cast([^]u8)s)[:n])
}
