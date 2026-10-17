package saber

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

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

LAUNCH_MODE_HELP := [Launch_Mode]string {
	.Standalone = "Start Saber yourself; Windows boots to the desktop as usual.",
	.Autorun    = "Saber opens fullscreen after sign-in, with the desktop behind it.",
	.Shell      = "Saber replaces the desktop for this account (no Explorer).",
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
}

WINLOGON_SUBKEY :: "Software\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"
POLICIES_SUBKEY :: "Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\System"
RUN_SUBKEY :: "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
RUN_VALUE :: "Saber"

foreign import advapi32 "system:Advapi32.lib"

@(default_calling_convention = "system")
foreign advapi32 {
	RegDeleteValueW :: proc(hKey: win.HKEY, lpValueName: win.LPCWSTR) -> win.LSTATUS ---
	LookupPrivilegeValueW :: proc(lpSystemName: win.LPCWSTR, lpName: win.LPCWSTR, lpLuid: ^win.LUID) -> win.BOOL ---
	AdjustTokenPrivileges :: proc(
		TokenHandle: win.HANDLE,
		DisableAllPrivileges: win.BOOL,
		NewState: rawptr,
		BufferLength: win.DWORD,
		PreviousState: rawptr,
		ReturnLength: ^win.DWORD,
	) -> win.BOOL ---
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
		if v, found := ini_get(text, "volume"); found {
			if n, ok := strconv.parse_f32(v); ok {
				s.volume = clamp(n, 0, 1)
			}
		}
	}
	// The registry is the source of truth; the ini value is informational.
	s.launch_mode = detect_launch_mode()
	return s
}

settings_save :: proc(path: string, s: Settings) {
	text := fmt.tprintf(
		"[saber]\nlaunch_mode=%s\nui_theme=%s\nbkg=%s\nbgm=%s\nfont=%s\nvolume=%.2f\n",
		LAUNCH_MODE_KEYS[s.launch_mode],
		s.ui_theme,
		s.bkg,
		s.bgm,
		s.font,
		s.volume,
	)
	_ = os.write_entire_file(path, text)
}

save_settings :: proc() {
	settings_save(app.settings_path, app.settings)
}

exe_full_path :: proc() -> string {
	buf: [win.MAX_PATH]u16
	n := win.GetModuleFileNameW(nil, raw_data(buf[:]), u32(len(buf)))
	if n == 0 {
		return ""
	}
	return wide_to_utf8(raw_data(buf[:]), int(n))
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

detect_launch_mode :: proc() -> Launch_Mode {
	mine := exe_full_path()
	if paths_equal(reg_read_sz(WINLOGON_SUBKEY, "Shell"), mine) || paths_equal(reg_read_sz(POLICIES_SUBKEY, "Shell"), mine) {
		return .Shell
	}
	if paths_equal(reg_read_sz(RUN_SUBKEY, RUN_VALUE), mine) {
		return .Autorun
	}
	return .Standalone
}

// True when Saber was started by Winlogon instead of Explorer.
is_acting_as_shell :: proc() -> bool {
	return GetShellWindow != nil && GetShellWindow() == nil
}

reg_read_sz :: proc(subkey, name: string) -> string {
	buf: [win.MAX_PATH + 2]u16
	size := u32(size_of(buf))
	status := win.RegGetValueW(
		win.HKEY_CURRENT_USER,
		win.utf8_to_wstring(subkey),
		win.utf8_to_wstring(name),
		win.RRF_RT_REG_SZ,
		nil,
		raw_data(buf[:]),
		&size,
	)
	if status != 0 {
		return ""
	}
	n := int(size / 2)
	if n > 0 && buf[n - 1] == 0 {
		n -= 1
	}
	return wide_to_utf8(raw_data(buf[:]), n)
}

reg_write_sz :: proc(subkey, name, data: string) -> bool {
	key: win.HKEY
	disp: u32
	status := win.RegCreateKeyExW(win.HKEY_CURRENT_USER, win.utf8_to_wstring(subkey), 0, nil, 0, win.KEY_SET_VALUE, nil, &key, &disp)
	if status != 0 {
		return false
	}
	defer win.RegCloseKey(key)
	wdata := win.utf8_to_utf16(data, context.temp_allocator)
	cb := u32((len(wdata) + 1) * size_of(u16))
	status = win.RegSetValueExW(key, win.utf8_to_wstring(name), 0, win.REG_SZ, cast(^win.BYTE)raw_data(wdata), cb)
	return status == 0
}

reg_delete :: proc(subkey, name: string) -> bool {
	key: win.HKEY
	if win.RegOpenKeyExW(win.HKEY_CURRENT_USER, win.utf8_to_wstring(subkey), 0, win.KEY_SET_VALUE, &key) != 0 {
		return true
	}
	defer win.RegCloseKey(key)
	status := RegDeleteValueW(key, win.utf8_to_wstring(name))
	return status == 0 || status == win.LSTATUS(win.ERROR_FILE_NOT_FOUND)
}

apply_launch_mode :: proc(mode: Launch_Mode) -> (ok: bool, err: string) {
	path := exe_full_path()
	if path == "" {
		return false, "Could not resolve Saber.exe path"
	}
	want_shell := mode == .Shell
	want_run := mode == .Autorun

	if want_shell {
		ok1 := reg_write_sz(WINLOGON_SUBKEY, "Shell", path)
		ok2 := reg_write_sz(POLICIES_SUBKEY, "Shell", path)
		if !ok1 && !ok2 {
			return false, "Could not set Shell (Winlogon / Policies)"
		}
	} else {
		ok1 := reg_delete(WINLOGON_SUBKEY, "Shell")
		ok2 := reg_delete(POLICIES_SUBKEY, "Shell")
		if !ok1 && !ok2 {
			return false, "Could not remove Shell values"
		}
	}

	if want_run {
		if !reg_write_sz(RUN_SUBKEY, RUN_VALUE, fmt.tprintf("\"%s\"", path)) {
			return false, "Could not add Saber to startup (Run key)"
		}
	} else if !reg_delete(RUN_SUBKEY, RUN_VALUE) {
		return false, "Could not remove Saber from startup"
	}
	return true, ""
}

EWX_LOGOFF :: 0x00000000
EWX_SHUTDOWN :: 0x00000001
EWX_REBOOT :: 0x00000002
EWX_POWEROFF :: 0x00000008
EWX_FORCEIFHUNG :: 0x00000010
SE_SHUTDOWN_NAME :: "SeShutdownPrivilege"
SE_PRIVILEGE_ENABLED :: 0x00000002

Shutdown_Token_Privileges :: struct {
	PrivilegeCount: u32,
	Luid:           win.LUID,
	Attributes:     u32,
}

enable_shutdown_privilege :: proc() -> bool {
	tok: win.HANDLE
	if !win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_ADJUST_PRIVILEGES | win.TOKEN_QUERY, &tok) {
		return false
	}
	defer win.CloseHandle(tok)
	luid: win.LUID
	if !LookupPrivilegeValueW(nil, win.utf8_to_wstring(SE_SHUTDOWN_NAME), &luid) {
		return false
	}
	tp := Shutdown_Token_Privileges{PrivilegeCount = 1, Luid = luid, Attributes = SE_PRIVILEGE_ENABLED}
	return bool(AdjustTokenPrivileges(tok, false, &tp, 0, nil, nil))
}

system_logoff :: proc() -> bool {
	return ExitWindowsEx != nil && bool(ExitWindowsEx(EWX_LOGOFF | EWX_FORCEIFHUNG, 0))
}

system_restart :: proc() -> bool {
	_ = enable_shutdown_privilege()
	return ExitWindowsEx != nil && bool(ExitWindowsEx(EWX_REBOOT | EWX_FORCEIFHUNG, 0))
}

system_shutdown :: proc() -> bool {
	_ = enable_shutdown_privilege()
	return ExitWindowsEx != nil && bool(ExitWindowsEx(EWX_SHUTDOWN | EWX_POWEROFF | EWX_FORCEIFHUNG, 0))
}

open_desktop :: proc() {
	if pi, ok := spawn_process("", "explorer.exe", ""); ok {
		win.CloseHandle(pi.hProcess)
		win.CloseHandle(pi.hThread)
	}
}
