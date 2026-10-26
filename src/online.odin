package saber

// Online Mode: the single switch for everything that touches the network (off by default).
// Plugins only get internet through these functions, and only while it's on:
//
//   Online()                                  -> true when Online Mode is on
//   Http_Get(url, function(ok, body, status) end)            -- body = error text when not ok
//   Http_Download(url, path, function(ok, err, status) end)  -- relative paths = the plugin's folder
//   Http_Pending()                            -> requests still running (handy for Dialog_Process)
//
// Requests run on worker threads; callbacks fire from the main loop. Turning Online Mode
// off is a killswitch: new requests fail at once, running transfers stop at the next chunk
// and report "Online mode was turned off", and actions marked `online = true` are disabled.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"

// The transfer itself is http_fetch, in online_<os>.odin (wininet / libcurl).

HTTP_MAX_BYTES :: 256 * 1024 * 1024

// Read by worker threads between chunks; bumped every time Online Mode turns off.
online_gen: u64

online_enabled :: proc() -> bool {
	return app.settings.online_mode
}

set_online_mode :: proc(on: bool) {
	if app.settings.online_mode == on do return
	app.settings.online_mode = on
	if !on do sync.atomic_add(&online_gen, 1)
	save_settings()
	plugins_broadcast("on_online", 1, proc(L: ^lua_State) { lua_pushboolean(L, online_enabled() ? 1 : 0) })
	set_status(on ? "Online Mode on: plugins may use the internet" : "Online Mode off: all online activity stopped")
	sfx_click()
}

Http_Request :: struct {
	// set by the main thread
	L:        ^lua_State,
	callback: c.int,
	url:      string,
	path:     string, // "" = keep the body in memory (Http_Get)
	gen:      u64,
	// set by the worker
	ok:       bool,
	status:   int,
	body:     []u8,
	err:      string,
	done:     bool, // atomic
	worker:   ^thread.Thread,
}

http_requests: [dynamic]^Http_Request

http_pending :: proc() -> int {
	return len(http_requests)
}

http_start :: proc(L: ^lua_State, url, path: string, callback: c.int) {
	r := new(Http_Request)
	r.L = L
	r.callback = callback
	r.url = strings.clone(url)
	r.path = strings.clone(path)
	r.gen = sync.atomic_load(&online_gen)
	append(&http_requests, r)
	if !online_enabled() {
		r.err = strings.clone("Online Mode is off (Settings)")
		sync.atomic_store(&r.done, true)
		return
	}
	r.worker = thread.create_and_start_with_data(r, http_worker)
}

// Online Mode went off (or was toggled) since the request started.
http_killed :: proc(r: ^Http_Request) -> bool {
	return sync.atomic_load(&online_gen) != r.gen
}

http_worker :: proc(data: rawptr) {
	r := (^Http_Request)(data)
	context = runtime.default_context()
	defer sync.atomic_store(&r.done, true)
	defer free_all(context.temp_allocator)

	body := make([dynamic]u8)
	if !http_fetch(r, &body) { // sets r.err
		delete(body)
		return
	}
	status := r.status
	if status != 200 {
		delete(body)
		r.err = fmt.aprintf("HTTP %d", status)
		return
	}
	if r.path != "" {
		os.make_directory_all(filepath.dir(r.path))
		if os.write_entire_file(r.path, body[:]) != nil {
			r.err = fmt.aprintf("Couldn't write %s", r.path)
			delete(body)
			return
		}
		delete(body)
	} else {
		r.body = body[:]
	}
	r.ok = true
}

// Delivers finished requests to their Lua callbacks. Called once per frame.
online_update :: proc() {
	for i := 0; i < len(http_requests); {
		r := http_requests[i]
		if !sync.atomic_load(&r.done) {
			i += 1
			continue
		}
		ordered_remove(&http_requests, i)
		if r.worker != nil {
			thread.join(r.worker)
			thread.destroy(r.worker)
		}
		if r.ok && sync.atomic_load(&online_gen) != r.gen {
			r.ok = false // finished just as the killswitch flipped
			r.err = strings.clone("Online Mode was turned off")
		}
		http_deliver(r)
		http_free(r)
	}
}

http_deliver :: proc(r: ^Http_Request) {
	if r.callback == LUA_NOREF do return
	L := r.L
	lua_rawgeti(L, LUA_REGISTRYINDEX, i64(r.callback))
	lua_pushboolean(L, r.ok ? 1 : 0)
	switch {
	case !r.ok:
		lua_pushstring(L, strings.clone_to_cstring(r.err, context.temp_allocator))
	case r.path != "":
		lua_pushstring(L, strings.clone_to_cstring(r.path, context.temp_allocator))
	case:
		lua_pushlstring(L, raw_data(r.body), c.size_t(len(r.body)))
	}
	lua_pushinteger(L, i64(r.status))
	if lua_pcall(L, 3, 0, 0) != LUA_OK {
		p := plugin_for_state(L)
		name := p != nil ? p.name : "Plugin"
		msg := lua_string(L, -1)
		plugin_logf("%s: http callback: %s", name, msg)
		set_status("%s: %s", name, msg)
		lua_pop(L, 1)
	}
}

http_free :: proc(r: ^Http_Request) {
	if r.callback != LUA_NOREF do luaL_unref(r.L, LUA_REGISTRYINDEX, r.callback)
	delete(r.url)
	delete(r.path)
	delete(r.body)
	delete(r.err)
	free(r)
}

// Waits for workers on exit; with Online Mode forced off they stop at the next chunk.
online_shutdown :: proc() {
	sync.atomic_add(&online_gen, 1)
	for r in http_requests {
		if r.worker != nil {
			thread.join(r.worker)
			thread.destroy(r.worker)
		}
		r.callback = LUA_NOREF // Lua states are about to close
		http_free(r)
	}
	clear(&http_requests)
}

// ---------------------------------------------------------------------------
// Lua globals

lua_online :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	lua_pushboolean(L, online_enabled() ? 1 : 0)
	return 1
}

lua_http_pending :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	lua_pushinteger(L, i64(http_pending()))
	return 1
}

// Http_Get(url, callback)
lua_http_get :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	http_start(L, lua_string(L, 1), "", dialog_ref_arg(L, 2))
	return 0
}

// Http_Download(url, path, callback); relative paths land in the plugin's folder.
lua_http_download :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	path := lua_string(L, 2)
	if path == "" {
		lua_pushstring(L, "Http_Download: missing path")
		return lua_error(L)
	}
	if !filepath.is_abs(path) {
		lua_getglobal(L, "PLUGIN_DIR") // set before the plugin's code runs, so this works during load too
		path = path_join({lua_string(L, -1), path})
		lua_pop(L, 1)
	}
	http_start(L, lua_string(L, 1), path, dialog_ref_arg(L, 3))
	return 0
}
