package saber

// Finds an app that's already installed on this PC (app.lua `locate`, see app_store.odin).
// Each candidate is either
//   "reg:HKCU\Software\Valve\Steam\SteamExe"      registry value (last part = value name; HKLM also
//                                                  tries the 32-bit view), or
//   "%ProgramFiles(x86)%\Steam\steam.exe"          a path, environment variables expanded.
// A candidate may name the exe itself or the folder holding `exe`. First existing file wins.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

app_locate :: proc(candidates: []string, exe: string) -> string {
	for cand in candidates {
		c := strings.trim_space(cand)
		values: [2]string
		if strings.has_prefix(c, "reg:") {
			values = reg_locate_values(c[4:])
		} else {
			values[0] = expand_env(c)
		}
		for v in values {
			p := strings.trim(strings.trim_space(v), "\"")
			if p == "" do continue
			p, _ = strings.replace_all(p, "/", "\\", context.temp_allocator)
			if os.is_file(p) do return p
			if exe != "" {
				full := path_join({p, filepath.base(exe)})
				if os.is_file(full) do return full
			}
		}
	}
	return ""
}

// "HKLM\SOFTWARE\Valve\Steam\InstallPath" -> the value (HKLM: 64-bit view, then 32-bit view).
reg_locate_values :: proc(spec: string) -> (out: [2]string) {
	s, _ := strings.replace_all(spec, "/", "\\", context.temp_allocator)
	first := strings.index_byte(s, '\\')
	last := strings.last_index_byte(s, '\\')
	if first < 0 || last <= first do return
	root_name := strings.to_upper(s[:first], context.temp_allocator)
	subkey, name := s[first + 1:last], s[last + 1:]
	switch root_name {
	case "HKCU", "HKEY_CURRENT_USER":
		out[0] = reg_read_value(win.HKEY_CURRENT_USER, subkey, name, 0)
	case "HKLM", "HKEY_LOCAL_MACHINE":
		out[0] = reg_read_value(win.HKEY_LOCAL_MACHINE, subkey, name, RRF_SUBKEY_WOW6464KEY)
		out[1] = reg_read_value(win.HKEY_LOCAL_MACHINE, subkey, name, RRF_SUBKEY_WOW6432KEY)
	}
	return
}

RRF_RT_REG_EXPAND_SZ :: 0x00000004
RRF_SUBKEY_WOW6464KEY :: 0x00010000
RRF_SUBKEY_WOW6432KEY :: 0x00020000

// REG_SZ / REG_EXPAND_SZ (expanded) value, "" when missing.
reg_read_value :: proc(root: win.HKEY, subkey, name: string, view: u32) -> string {
	buf: [1024]u16
	size := u32(size_of(buf))
	status := win.RegGetValueW(root, win.utf8_to_wstring(subkey), win.utf8_to_wstring(name), win.RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | view, nil, raw_data(buf[:]), &size)
	if status != 0 do return ""
	n := int(size / 2)
	if n > 0 && buf[n - 1] == 0 do n -= 1
	return wide_to_utf8(raw_data(buf[:]), n)
}

expand_env :: proc(s: string) -> string {
	if strings.index_byte(s, '%') < 0 do return s
	buf: [1024]u16
	n := win.ExpandEnvironmentStringsW(win.utf8_to_wstring(s), raw_data(buf[:]), len(buf))
	if n == 0 || n > len(buf) do return s
	return wide_to_utf8(raw_data(buf[:]), int(n) - 1)
}

// Runs exe with args in dir and waits (up to timeout_ms) for it to exit. Used for app installers /
// uninstallers; safe on worker threads. ran = false when it couldn't start or timed out.
run_and_wait :: proc(exe, args, dir: string, timeout_ms: u32) -> (code: u32, ran: bool) {
	cmd := args != "" ? fmt.tprintf("\"%s\" %s", exe, args) : fmt.tprintf("\"%s\"", exe)
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW)}
	pi: win.PROCESS_INFORMATION
	if !win.CreateProcessW(win.utf8_to_wstring(exe), win.utf8_to_wstring(cmd), nil, nil, false, 0, nil, win.utf8_to_wstring(dir), &si, &pi) {
		return 0, false
	}
	defer win.CloseHandle(pi.hProcess)
	defer win.CloseHandle(pi.hThread)
	if win.WaitForSingleObject(pi.hProcess, timeout_ms) != win.WAIT_OBJECT_0 do return 0, false
	win.GetExitCodeProcess(pi.hProcess, &code)
	return code, true
}
