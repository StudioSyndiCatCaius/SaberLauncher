package saber

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import rl "vendor:raylib"
import win "core:sys/windows"

Game :: struct {
	root:             string,
	saber_dir:        string,
	title:            string,
	tags:             string,
	drive_label:      string,
	from_drive:       bool,
	logo_file:        string,
	box_file:         string,
	play_bat:         string,
	exe_name:         string,
	launch_args:      string,
	records_path:     string,
	date_first:       string,
	date_last:        string,
	playtime_seconds: int,
	box:              rl.Texture2D,
	logo:             rl.Texture2D,
	has_box:          bool,
	has_logo:         bool,
}

game_from_folder :: proc(root: string, drive_label: string, from_drive: bool) -> (Game, bool) {
	saber := path_join({root, "_Saber"})
	ini_path := path_join({saber, "saber.ini"})
	if !os.exists(ini_path) {
		return {}, false
	}

	g: Game
	g.root = strings.clone(root)
	g.saber_dir = strings.clone(saber)
	g.drive_label = strings.clone(drive_label)
	g.from_drive = from_drive
	g.title = strings.clone(filepath.base(root))
	g.play_bat = path_join({saber, "PLAY.bat"})
	g.records_path = path_join({saber, "records.ini"})

	if data, err := os.read_entire_file(ini_path, context.allocator); err == nil {
		defer delete(data)
		text := string(data)
		if v, found := ini_get(text, "title"); found && v != "" {
			delete(g.title)
			g.title = strings.clone(v)
		}
		if v, found := ini_get(text, "tags"); found {
			g.tags = strings.clone(v)
		}
		logo_name := "logo.png"
		box_name := "box.png"
		if v, found := ini_get(text, "logo"); found && v != "" {
			logo_name = v
		}
		if v, found := ini_get(text, "box"); found && v != "" {
			box_name = v
		}
		if v, found := ini_get(text, "exe"); found {
			g.exe_name = strings.clone(v)
		}
		if v, found := ini_get(text, "args"); found {
			g.launch_args = strings.clone(v)
		}
		g.logo_file = path_join({saber, logo_name})
		g.box_file = path_join({saber, box_name})
	}

	if rec, err := os.read_entire_file(g.records_path, context.allocator); err == nil {
		defer delete(rec)
		text := string(rec)
		if v, found := ini_get(text, "date_first_played"); found {
			g.date_first = strings.clone(strings.trim(v, "\""))
		}
		if v, found := ini_get(text, "date_last_played"); found {
			g.date_last = strings.clone(strings.trim(v, "\""))
		}
		if v, found := ini_get(text, "playtime_seconds"); found {
			g.playtime_seconds, _ = strconv.parse_int(v)
		}
	}

	game_load_art(&g)
	return g, true
}

game_load_art :: proc(g: ^Game) {
	g.box, g.has_box = load_texture_smooth(g.box_file)
	g.logo, g.has_logo = load_texture_smooth(g.logo_file)
}

game_unload_art :: proc(g: ^Game) {
	if g.has_box {
		rl.UnloadTexture(g.box)
		g.has_box = false
	}
	if g.has_logo {
		rl.UnloadTexture(g.logo)
		g.has_logo = false
	}
}

resolve_launch_exe :: proc(g: ^Game) -> (path: string, ok: bool) {
	exe := strings.trim_space(g.exe_name)
	if exe == "" {
		return "", false
	}
	if filepath.is_abs(exe) && os.exists(exe) {
		return exe, true
	}
	from_root := path_join({g.root, exe})
	if os.exists(from_root) {
		return from_root, true
	}
	from_saber := path_join({g.saber_dir, exe})
	if os.exists(from_saber) {
		return from_saber, true
	}
	return "", false
}

game_launch :: proc(g: ^Game) -> (ok: bool, err: string) {
	cmd: string
	wait_name: string
	fail_msg := "Failed to start game"

	if exe_path, has_exe := resolve_launch_exe(g); has_exe {
		args := strings.trim_space(g.launch_args)
		cmd = args != "" ? fmt.tprintf("\"%s\" %s", exe_path, args) : fmt.tprintf("\"%s\"", exe_path)
		wait_name = filepath.base(exe_path)
		fail_msg = fmt.tprintf("Failed to start %s", g.exe_name)
	} else if os.exists(g.play_bat) {
		cmd = fmt.tprintf("cmd.exe /c \"%s\"", g.play_bat)
		fail_msg = "Failed to start PLAY.bat"
	} else {
		if strings.trim_space(g.exe_name) != "" {
			return false, fmt.tprintf("Missing exe: %s", g.exe_name)
		}
		return false, "Missing exe in saber.ini and no PLAY.bat"
	}

	pi, created := spawn_process("", cmd, g.root)
	if !created {
		return false, fail_msg
	}
	elapsed, _ := run_session(pi, .Game, g.title, wait_name)

	g.playtime_seconds += max(elapsed, 0)
	today := today_iso()
	if g.date_first == "" {
		g.date_first = strings.clone(today)
	}
	delete(g.date_last)
	g.date_last = strings.clone(today)
	game_save_records(g)
	return true, ""
}

game_save_records :: proc(g: ^Game) {
	text := fmt.tprintf(
		"[records]\n\ndate_first_played=\"%s\"\ndate_last_played=\"%s\"\nplaytime_seconds=%d\n",
		g.date_first,
		g.date_last,
		g.playtime_seconds,
	)
	_ = os.write_entire_file(g.records_path, text)
}

format_playtime :: proc(seconds: int) -> string {
	h := seconds / 3600
	m := (seconds % 3600) / 60
	s := seconds % 60
	if h > 0 {
		return fmt.tprintf("%dh %02dm", h, m)
	}
	if m > 0 {
		return fmt.tprintf("%dm %02ds", m, s)
	}
	return fmt.tprintf("%ds", s)
}

today_iso :: proc() -> string {
	t := time.now()
	y, mo, d := time.date(t)
	return fmt.tprintf("%04d-%02d-%02d", y, int(mo), d)
}

path_join :: proc(parts: []string) -> string {
	p, _ := filepath.join(parts)
	return p
}

wide_to_utf8 :: proc(p: [^]u16, n: int) -> string {
	s, _ := win.wstring_to_utf8(win.wstring(p), n)
	return s
}

ini_get :: proc(text, key: string) -> (string, bool) {
	it := text
	for line in strings.split_lines_iterator(&it) {
		trim := strings.trim_space(line)
		if trim == "" || strings.has_prefix(trim, "[") || strings.has_prefix(trim, ";") || strings.has_prefix(trim, "#") {
			continue
		}
		eq := strings.index_byte(trim, '=')
		if eq < 0 {
			continue
		}
		k := strings.trim_space(trim[:eq])
		if !strings.equal_fold(k, key) {
			continue
		}
		v := strings.trim_space(trim[eq + 1:])
		if strings.has_prefix(v, "\"") && strings.has_suffix(v, "\"") && len(v) >= 2 {
			v = v[1:len(v) - 1]
		}
		return v, true
	}
	return "", false
}
