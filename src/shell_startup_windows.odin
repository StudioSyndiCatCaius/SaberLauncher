package saber

import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

// As the account shell Saber takes over a job of Explorer's: starting the programs that
// run at sign-in (Run keys + Startup folders: Steam, GPU / vendor tools, controller
// drivers, audio helpers...). Entries disabled in Task Manager's Startup tab are skipped.
// Once per sign-in: the flag lives in HKCU\Volatile Environment, which Windows clears at logoff.

STARTUP_APPROVED :: "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved"
VOLATILE_ENV :: "Volatile Environment"
STARTUP_DONE_VALUE :: "SaberStartupDone"
ERROR_NO_MORE_ITEMS :: win.LSTATUS(259)

run_startup_programs :: proc(self_exe: string) {
	if reg_read_sz(VOLATILE_ENV, STARTUP_DONE_VALUE) != "" do return
	_ = reg_write_sz(VOLATILE_ENV, STARTUP_DONE_VALUE, "1")
	win.CoInitializeEx(nil, .APARTMENTTHREADED) // ShellExecute on .lnk files

	started := 0
	started += startup_run_key(win.HKEY_CURRENT_USER, 0, "Run", self_exe)
	started += startup_run_key(win.HKEY_LOCAL_MACHINE, win.KEY_WOW64_64KEY, "Run", self_exe)
	started += startup_run_key(win.HKEY_LOCAL_MACHINE, win.KEY_WOW64_32KEY, "Run32", self_exe)
	user_folder := win.FOLDERID_Startup
	common_folder := win.FOLDERID_CommonStartup
	started += startup_folder(&user_folder, win.HKEY_CURRENT_USER, self_exe)
	started += startup_folder(&common_folder, win.HKEY_LOCAL_MACHINE, self_exe)
	crash_log_line("Shell: started %d startup program(s)", started)
}

// Task Manager's Startup tab: StartupApproved\<kind> holds a binary value per entry;
// an odd first byte means disabled. No value = enabled.
startup_disabled :: proc(root: win.HKEY, kind, name: string) -> bool {
	data: [16]u8
	size := u32(len(data))
	subkey := strings.concatenate({STARTUP_APPROVED, "\\", kind}, context.temp_allocator)
	if win.RegGetValueW(root, win.utf8_to_wstring(subkey), win.utf8_to_wstring(name), win.RRF_RT_REG_BINARY, nil, raw_data(data[:]), &size) != 0 {
		return false
	}
	return size > 0 && data[0] & 1 != 0
}

startup_is_self :: proc(cmd, self_exe: string) -> bool {
	return strings.contains(strings.to_lower(cmd, context.temp_allocator), strings.to_lower(filepath.base(self_exe), context.temp_allocator))
}

startup_run_key :: proc(root: win.HKEY, wow: u32, approved_kind: string, self_exe: string) -> int {
	key: win.HKEY
	if win.RegOpenKeyExW(root, win.utf8_to_wstring(RUN_SUBKEY), 0, win.KEY_READ | wow, &key) != 0 do return 0
	defer win.RegCloseKey(key)
	count := 0
	for i: u32 = 0; ; i += 1 {
		name_w: [512]u16
		name_n := u32(len(name_w))
		data_w: [2048]u16
		data_cb := u32(size_of(data_w) - 2)
		kind: u32
		status := win.RegEnumValueW(key, i, raw_data(name_w[:]), &name_n, nil, &kind, cast(^win.BYTE)raw_data(data_w[:]), &data_cb)
		if status == ERROR_NO_MORE_ITEMS do break
		if status != 0 || (kind != win.REG_SZ && kind != win.REG_EXPAND_SZ) do continue
		name := wide_to_utf8(raw_data(name_w[:]), int(name_n))
		n := int(data_cb / 2)
		for n > 0 && data_w[n - 1] == 0 do n -= 1
		data_w[n] = 0
		expanded: [4096]u16
		cmd: string
		if en := win.ExpandEnvironmentStringsW(win.wstring(raw_data(data_w[:])), raw_data(expanded[:]), len(expanded)); en > 1 && en <= len(expanded) {
			cmd = wide_to_utf8(raw_data(expanded[:]), int(en - 1))
		} else {
			cmd = wide_to_utf8(raw_data(data_w[:]), n)
		}
		cmd = strings.trim_space(cmd)
		if cmd == "" || startup_is_self(cmd, self_exe) || startup_disabled(root, approved_kind, name) do continue
		if pi, ok := spawn_process("", cmd, ""); ok {
			proc_release(pi)
			count += 1
		} else {
			crash_log_line("Shell: couldn't start startup entry %s (%s)", name, cmd)
		}
	}
	return count
}

startup_folder :: proc(folder: ^win.GUID, approved_root: win.HKEY, self_exe: string) -> int {
	path_w: win.LPWSTR
	if win.SHGetKnownFolderPath(folder, 0, nil, &path_w) != 0 || path_w == nil do return 0
	dir, _ := win.wstring_to_utf8(win.wstring(path_w), -1, context.temp_allocator)
	win.CoTaskMemFree(path_w)
	fis, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return 0
	count := 0
	for fi in fis {
		if fi.type == .Directory || strings.equal_fold(fi.name, "desktop.ini") do continue
		if startup_is_self(fi.name, self_exe) || startup_disabled(approved_root, "StartupFolder", fi.name) do continue
		full := path_join({dir, fi.name})
		r := win.ShellExecuteW(nil, win.L("open"), win.utf8_to_wstring(full), nil, win.utf8_to_wstring(dir), win.SW_SHOWNORMAL)
		if uintptr(rawptr(r)) > 32 {
			count += 1
		} else {
			crash_log_line("Shell: couldn't start %s", full)
		}
	}
	return count
}
