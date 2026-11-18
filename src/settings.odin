package saber

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

Launch_Mode :: enum {
	Standalone,
	Autorun, // HKCU Run key: starts with Windows, Explorer still runs
	Shell,   // replaces Explorer for this account
}

LAUNCH_MODE_NAMES := [Launch_Mode]string {
	.Standalone = "Standalone",
	.Autorun    = "Autorun on Login",
	.Shell      = "Shellrun on Login",
}

LAUNCH_MODE_KEYS := [Launch_Mode]string {
	.Standalone = "standalone",
	.Autorun    = "autorun",
	.Shell      = "shell",
}

// What the emulation pause menu offers for save states. Read once per game (retro.save_mode),
// so it can only change between games, from the Settings tab.
Save_Mode :: enum {
	None,    // no states at all
	Suspend, // "Suspend": save + quit, resumed (once) on the next start
	Quick,   // one quicksave slot + Suspend
	Free,    // SAVE_SLOTS slots + Suspend
}

SAVE_MODE_NAMES := [Save_Mode]string {
	.None    = "None",
	.Suspend = "Suspend Only",
	.Quick   = "Quicksave",
	.Free    = "Free Save",
}

SAVE_MODE_KEYS := [Save_Mode]string {
	.None    = "none",
	.Suspend = "suspend",
	.Quick   = "quick",
	.Free    = "free",
}

Settings :: struct {
	launch_mode: Launch_Mode,
	ui_theme:    string,
	bkg:         string,
	bgm:         string,
	font:        string,
	volume:      f32,
	online_mode: bool, // plugins may use the internet; off = killswitch
	plugins_off: string, // disabled plugin folder names, ';'-separated; takes effect on restart
	ignore_drives: u32, // bit per letter (A = bit 0): fixed drives skipped by the game scan
	plugin_dirs: string, // extra plugin folders, ';'-separated, relative to the exe; APP/plugins always loads
	save_mode:   Save_Mode,
	autostart_app: string, // apps .toml file name launched once per sign-in (Autorun / Shell modes)
	shell_startup: bool, // as the account shell, start the sign-in programs Explorer would (Run keys, Startup folders)
	home_per_row: int, // Home: games per row before wrapping into a grid (0 = unlimited: one carousel row)
	hidden_tabs: bit_set[Screen], // header tabs turned off in Settings > Visible Tabs (never .Settings)
	bkg_auto:    Auto_State, // wallpaper autochange (autochange.odin)
	bgm_auto:    Auto_State, // music autochange
}

settings_load :: proc(path: string) -> Settings {
	s := Settings{volume = 0.7, font = "Arial", save_mode = .Suspend, shell_startup = true}
	if data, err := os.read_entire_file(path, context.allocator); err == nil {
		defer delete(data)
		text := string(data)
		ini_str(text, "ui_theme", &s.ui_theme)
		ini_str(text, "bkg", &s.bkg)
		ini_str(text, "bgm", &s.bgm)
		ini_str(text, "font", &s.font, nonempty = true)
		ini_str(text, "plugin_dirs", &s.plugin_dirs)
		ini_str(text, "autostart_app", &s.autostart_app)
		ini_str(text, "plugins_off", &s.plugins_off)
		s.online_mode = ini_bool(text, "online", false)
		s.shell_startup = ini_bool(text, "shell_startup", true)
		if v, found := ini_get(text, "ignore_drives"); found {
			for ch in transmute([]u8)v do if c := upper_byte(ch); c >= 'A' && c <= 'Z' do s.ignore_drives |= 1 << u32(c - 'A')
		}
		if v, found := ini_get(text, "save_states"); found {
			for key, m in SAVE_MODE_KEYS do if eq_fold(v, key) do s.save_mode = m
		}
		if v, found := ini_get(text, "home_per_row"); found {
			if n, ok := strconv.parse_int(v); ok do s.home_per_row = clamp(n, 0, HOME_PER_ROW_MAX)
		}
		if v, found := ini_get(text, "hidden_tabs"); found {
			for part in strings.split_iterator(&v, ";") {
				for key, sc in SCREEN_KEYS do if sc != .Settings && eq_fold(strings.trim_space(part), key) do s.hidden_tabs += {sc}
			}
		}
		if v, found := ini_get(text, "bkg_auto"); found do s.bkg_auto.mode = auto_parse(v)
		ini_str(text, "bkg_auto_period", &s.bkg_auto.period)
		ini_str(text, "bkg_auto_seen", &s.bkg_auto.seen)
		if v, found := ini_get(text, "bgm_auto"); found do s.bgm_auto.mode = auto_parse(v)
		ini_str(text, "bgm_auto_period", &s.bgm_auto.period)
		ini_str(text, "bgm_auto_seen", &s.bgm_auto.seen)
		if v, found := ini_get(text, "volume"); found {
			if n, ok := strconv.parse_f32(v); ok do s.volume = clamp(n, 0, 1)
		}
	}
	// The system (registry / autostart entry) is the source of truth; the ini value is informational.
	s.launch_mode = detect_launch_mode()
	return s
}

settings_save :: proc(path: string, s: Settings) {
	text := fmt.tprintf(
		"[saber]\nlaunch_mode=%s\nui_theme=%s\nbkg=%s\nbgm=%s\nfont=%s\nvolume=%.2f\nonline=%d\nplugins_off=%s\nplugin_dirs=%s\nignore_drives=%s\nsave_states=%s\nshell_startup=%d\nautostart_app=%s\nhome_per_row=%d\nhidden_tabs=%s\nbkg_auto=%s\nbkg_auto_period=%s\nbkg_auto_seen=%s\nbgm_auto=%s\nbgm_auto_period=%s\nbgm_auto_seen=%s\n",
		LAUNCH_MODE_KEYS[s.launch_mode],
		s.ui_theme,
		s.bkg,
		s.bgm,
		s.font,
		s.volume,
		int(s.online_mode),
		s.plugins_off,
		s.plugin_dirs,
		drive_letters(s.ignore_drives),
		SAVE_MODE_KEYS[s.save_mode],
		int(s.shell_startup),
		s.autostart_app,
		s.home_per_row,
		hidden_tabs_string(s.hidden_tabs),
		AUTO_CHANGE_KEYS[s.bkg_auto.mode], s.bkg_auto.period, s.bkg_auto.seen,
		AUTO_CHANGE_KEYS[s.bgm_auto.mode], s.bgm_auto.period, s.bgm_auto.seen,
	)
	_ = os.write_entire_file(path, text)
}

save_settings :: proc() {
	settings_save(app.settings_path, app.settings)
}

paths_equal :: proc(a, b: string) -> bool {
	if a == "" || b == "" do return false
	norm :: proc(p: string) -> string {
		c, _ := filepath.clean(strings.trim(strings.trim_space(p), `"`), context.temp_allocator)
		c, _ = strings.replace_all(c, "/", "\\", context.temp_allocator)
		return c
	}
	return eq_fold(norm(a), norm(b))
}

SCREEN_KEYS := [Screen]string {
	.Main     = "home",
	.Library  = "games",
	.Movies   = "movies",
	.Apps     = "apps",
	.Plugins  = "plugins",
	.Settings = "settings",
}

// "games;movies" (temp)
hidden_tabs_string :: proc(hidden: bit_set[Screen]) -> string {
	b := strings.builder_make(context.temp_allocator)
	for sc in hidden {
		if strings.builder_len(b) > 0 do strings.write_string(&b, ";")
		strings.write_string(&b, SCREEN_KEYS[sc])
	}
	return strings.to_string(b)
}

// Settings can never be hidden, so there is always somewhere to turn tabs back on.
tab_visible :: proc(s: Screen) -> bool {
	return s == .Settings || s not_in app.settings.hidden_tabs
}

// Home, or the first visible tab when Home is hidden.
home_tab :: proc() -> Screen {
	for sc in SCREEN_ORDER do if tab_visible(sc) do return sc
	return .Settings
}
