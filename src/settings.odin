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

Settings :: struct {
	launch_mode: Launch_Mode,
	ui_theme:    string,
	bkg:         string,
	bgm:         string,
	font:        string,
	volume:      f32,
	online_mode: bool, // plugins may use the internet; off = killswitch
	plugins_off: string, // disabled plugin folder names, ';'-separated; takes effect on restart
	plugin_dirs: string, // extra plugin folders, ';'-separated, relative to the exe; APP/plugins always loads
}

settings_load :: proc(path: string) -> Settings {
	s := Settings{volume = 0.7, font = "Arial"}
	if data, err := os.read_entire_file(path, context.allocator); err == nil {
		defer delete(data)
		text := string(data)
		if v, found := ini_get(text, "ui_theme"); found {
			s.ui_theme = strings.clone(v)
		}
		if v, found := ini_get(text, "bkg"); found {
			s.bkg = strings.clone(v)
		}
		if v, found := ini_get(text, "bgm"); found {
			s.bgm = strings.clone(v)
		}
		if v, found := ini_get(text, "font"); found && v != "" {
			s.font = strings.clone(v)
		}
		if v, found := ini_get(text, "plugin_dirs"); found {
			s.plugin_dirs = strings.clone(v)
		}
		if v, found := ini_get(text, "online"); found {
			s.online_mode = v == "1" || strings.equal_fold(v, "true")
		}
		if v, found := ini_get(text, "plugins_off"); found {
			s.plugins_off = strings.clone(v)
		}
		if v, found := ini_get(text, "volume"); found {
			if n, ok := strconv.parse_f32(v); ok {
				s.volume = clamp(n, 0, 1)
			}
		}
	}
	// The system (registry / autostart entry) is the source of truth; the ini value is informational.
	s.launch_mode = detect_launch_mode()
	return s
}

settings_save :: proc(path: string, s: Settings) {
	text := fmt.tprintf(
		"[saber]\nlaunch_mode=%s\nui_theme=%s\nbkg=%s\nbgm=%s\nfont=%s\nvolume=%.2f\nonline=%d\nplugins_off=%s\nplugin_dirs=%s\n",
		LAUNCH_MODE_KEYS[s.launch_mode],
		s.ui_theme,
		s.bkg,
		s.bgm,
		s.font,
		s.volume,
		int(s.online_mode),
		s.plugins_off,
		s.plugin_dirs,
	)
	_ = os.write_entire_file(path, text)
}

save_settings :: proc() {
	settings_save(app.settings_path, app.settings)
}

paths_equal :: proc(a, b: string) -> bool {
	if a == "" || b == "" {
		return false
	}
	norm :: proc(p: string) -> string {
		c, _ := filepath.clean(strings.trim(strings.trim_space(p), `"`), context.temp_allocator)
		c, _ = strings.replace_all(c, "/", "\\", context.temp_allocator)
		return c
	}
	return strings.equal_fold(norm(a), norm(b))
}
