package flasher

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import rl "vendor:raylib"

// Settings tab: external library locations (GOG for now), saved in SaberFlasher.ini.
// Scripts read them through GetDir_GogGames([game]).

GOG_GUESSES :: []string {
	`C:\GOG Games`,
	`D:\GOG Games`,
	`C:\Program Files (x86)\GOG Galaxy\Games`,
	`C:\Program Files\GOG Galaxy\Games`,
	`D:\GOG Galaxy\Games`,
}

saved_gog: string // last value written to disk, to save on change

Gog_Install :: struct {
	name, path: string, // temp-allocated
}

// GOG Galaxy / offline installers record every game under HKLM\SOFTWARE\(WOW6432Node\)GOG.com\Games\<id>
// with `path` and `gameName` values, wherever the game was installed.
gog_registry_installs :: proc() -> []Gog_Install {
	out := make([dynamic]Gog_Install, context.temp_allocator)
	for root in ([]string{`SOFTWARE\WOW6432Node\GOG.com\Games`, `SOFTWARE\GOG.com\Games`}) {
		key: win.HKEY
		if win.RegOpenKeyExW(win.HKEY_LOCAL_MACHINE, win.utf8_to_wstring(root), 0, win.KEY_READ, &key) != 0 do continue
		defer win.RegCloseKey(key)
		for i: u32 = 0; ; i += 1 {
			name: [256]u16
			n := u32(len(name))
			if win.RegEnumKeyExW(key, i, win.LPWSTR(raw_data(name[:])), &n, nil, nil, nil, nil) != 0 do break
			sub := win.LPCWSTR(raw_data(name[:]))
			read :: proc(key: win.HKEY, sub: win.LPCWSTR, value: string) -> string {
				buf: [1024]u16
				sz := u32(size_of(buf))
				if win.RegGetValueW(key, sub, win.utf8_to_wstring(value), win.RRF_RT_REG_SZ, nil, &buf[0], &sz) != 0 do return ""
				return w2s(buf[:])
			}
			path := read(key, sub, "path")
			if path == "" || !os.is_dir(path) do continue
			dup := false
			for e in out do if strings.equal_fold(e.path, path) do dup = true
			if !dup do append(&out, Gog_Install{read(key, sub, "gameName"), path})
		}
	}
	return out[:]
}

detect_gog :: proc() -> (string, bool) {
	// most common parent folder of the registered installs (e.g. D:\Games\GOG)
	installs := gog_registry_installs()
	best, best_n := "", 0
	for a in installs {
		parent := strings.trim_right(a.path[:max(strings.last_index_byte(a.path, '\\'), 0)], "\\")
		n := 0
		for b in installs do if strings.has_prefix(strings.to_lower(b.path, context.temp_allocator), strings.to_lower(fmt.tprintf("%s\\", parent), context.temp_allocator)) do n += 1
		if n > best_n do best, best_n = parent, n
	}
	if best != "" do return best, true
	for g in GOG_GUESSES do if os.is_dir(g) do return g, true
	return "", false
}

// Game folders directly inside the GOG folder.
gog_game_count :: proc(dir: string) -> int {
	n := 0
	walk_dir(dir, proc(path: string, is_dir: bool, user: rawptr) -> bool {
		if is_dir do (^int)(user)^ += 1
		return false
	}, &n, recurse = false)
	return n
}

// Letters and digits only, lowercased: "Star Wars: KotOR" ~ "star wars kotor" ~ "StarWarsKOTOR".
loose_name :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for r in strings.to_lower(s, context.temp_allocator) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r > 127 do strings.write_rune(&sb, r)
	}
	return strings.to_string(sb)
}

// Finds `game`: in the GOG folder (exact name, then punctuation/case-insensitive), then among
// GOG's registered installs by folder name or game title, wherever they were installed.
find_gog_game :: proc(gog_dir, game: string) -> (string, bool) {
	if p, ok := find_gog_in_folder(gog_dir, game); ok do return p, true
	want := loose_name(game)
	if want == "" do return "", false
	for e in gog_registry_installs() {
		base := e.path[strings.last_index_byte(e.path, '\\') + 1:]
		if loose_name(base) == want || loose_name(e.name) == want do return e.path, true
	}
	return "", false
}

find_gog_in_folder :: proc(gog_dir, game: string) -> (string, bool) {
	if gog_dir == "" || !os.is_dir(gog_dir) do return "", false
	exact := fmt.tprintf("%s\\%s", strings.trim_right(gog_dir, "\\/"), game)
	if os.is_dir(exact) do return exact, true
	Ctx :: struct {
		want, found: string,
	}
	ctx := Ctx{want = loose_name(game)}
	if ctx.want == "" do return "", false
	walk_dir(gog_dir, proc(path: string, is_dir: bool, user: rawptr) -> bool {
		x := (^Ctx)(user)
		if is_dir && x.found == "" {
			base := path[strings.last_index_byte(path, '\\') + 1:]
			if loose_name(base) == x.want do x.found = strings.clone(path, context.temp_allocator)
		}
		return false
	}, &ctx, recurse = false)
	return ctx.found, ctx.found != ""
}

// GetDir_GogGames([game]) -> path | nil
//   no arg: the GOG games folder from Settings; with a game: that game's folder (nil if missing).
lua_GetDir_GogGames :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	if lua_type(L, 1) != LUA_TSTRING {
		if job.gog == "" || !os.is_dir(job.gog) {
			job_log("GOG folder isn't set (Flasher > Settings)")
			lua_pushnil(L)
		} else {
			lua_pushstring(L, cs(job.gog))
		}
		return 1
	}
	if p, ok := find_gog_game(job.gog, lua_string(L, 1)); ok {
		lua_pushstring(L, cs(p))
	} else {
		job_log(fmt.tprintf("GOG game not found: %s", lua_string(L, 1)))
		lua_pushnil(L)
	}
	return 1
}

draw_settings_page :: proc() {
	page_header("Settings", "Where Saber Flasher finds your other game libraries.")
	x, w := content_x(), content_w()

	r := rl.Rectangle{x, 116, w, 220}
	card(r)
	rounded({r.x + 28, r.y + 26, 44, 44}, 10, alpha(COL_ACCENT, 36))
	draw_icon(IC_GAME, r.x + 50, r.y + 48, 22, COL_ACCENT)
	draw_text("GOG", r.x + 88, r.y + 26, 18, COL_TEXT, true)
	draw_text("Folder your GOG games are installed in. Scripts use it via GetDir_GogGames(game).", r.x + 88, r.y + 52, 14, COL_MUTED)

	ix := r.x + 28
	iw := r.width - 56
	field_label(ix, r.y + 96, "GOG GAMES FOLDER", "e.g. C:\\GOG Games", iw)
	if path_input(&fields[F_GOG], {ix, r.y + 120, iw - 130, 44}, "Not set") {
		if p, ok := pick_folder("GOG games folder"); ok do field_set(&fields[F_GOG], p)
	}
	if button({ix + iw - 120, r.y + 120, 120, 44}, "Detect", .Secondary, IC_SEARCH) {
		if p, ok := detect_gog(); ok {
			field_set(&fields[F_GOG], p)
			set_status(fmt.tprintf("Found GOG games at %s", p), COL_OK)
		} else {
			set_status("Couldn't find a GOG games folder — pick it with the folder button.", COL_WARN)
		}
	}

	gog := field_str(&fields[F_GOG])
	sy := r.y + 178
	if gog == "" {
		pill(ix, sy, "Not set", COL_MUTED)
	} else if os.is_dir(gog) {
		n := gog_game_count(gog)
		px := ix + pill(ix, sy, fmt.tprintf("%d game folder%s", n, n == 1 ? "" : "s"), COL_OK, IC_CHECK) + 8
		if r := len(gog_registry_installs()); r > 0 do pill(px, sy, fmt.tprintf("%d installed via GOG", r), COL_ACCENT, IC_GAME)
	} else {
		pill(ix, sy, "Folder not found", COL_DANGER, IC_WARN)
	}

	// persist whenever it changes
	if gog != saved_gog && focused != &fields[F_GOG] do save_settings()
}
