package saber

import "core:fmt"
import "core:strings"
import win "core:sys/windows"

// Small Windows-only helpers; platform_linux.odin has the same procs.

// One quoted command-line argument.
quote_arg :: proc(s: string) -> string {
	return fmt.tprintf("\"%s\"", s)
}

// Command line that starts a program with its arguments.
exe_command :: proc(exe_path, args: string) -> string {
	return args != "" ? fmt.tprintf("\"%s\" %s", exe_path, args) : fmt.tprintf("\"%s\"", exe_path)
}

// Command line that runs a game's PLAY.bat.
bat_command :: proc(bat_path: string) -> string {
	return fmt.tprintf("cmd.exe /c \"%s\"", bat_path)
}

open_steam_big_picture :: proc() {
	win.ShellExecuteW(nil, win.L("open"), win.L("steam://open/bigpicture"), nil, nil, win.SW_SHOWNORMAL)
}

sleep_ms :: proc(ms: u32) {
	win.Sleep(ms)
}

// One Saber per session: a hidden second copy would keep reacting to the pad.
single_instance :: proc() -> bool {
	instance_mutex = CreateMutexW(nil, true, win.L("Local\\SaberLauncher"))
	return win.GetLastError() != win.ERROR_ALREADY_EXISTS
}

instance_mutex: win.HANDLE

// Starts a fresh Saber; call last, after everything is shut down.
restart_self :: proc() -> bool {
	if instance_mutex != nil { // last handle closed = mutex gone, so the new copy passes single_instance
		win.CloseHandle(instance_mutex)
		instance_mutex = nil
	}
	r := win.ShellExecuteW(nil, win.L("open"), win.utf8_to_wstring(exe_full_path()), nil, win.utf8_to_wstring(app.exe_dir), win.SW_SHOWNORMAL)
	return uintptr(rawptr(r)) > 32
}

// ntdll's _snprintf: linking a CRT printf clashes with static raylib's CRT.
load_snprintf :: proc() -> Snprintf_Proc {
	if nt := win.GetModuleHandleW(win.L("ntdll.dll")); nt != nil {
		return auto_cast win.GetProcAddress(nt, "_snprintf")
	}
	return nil
}

// RETRO_CORES names are Windows file names; the same name on this platform.
core_file_name :: proc(name: string) -> string {
	return name
}

// Folders searched for cores after APP/libretro/cores and APP/libretro.
SYSTEM_CORE_DIRS :: []string{}

updater_path :: proc() -> string {
	return path_join({app.exe_dir, "SaberUpdater.exe"})
}

run_hidden_wait :: proc(exe, args: string) -> (code: u32, ok: bool) {
	cmd := win.utf8_to_wstring(strings.concatenate({"\"", exe, "\" ", args}, context.temp_allocator))
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW)}
	pi: win.PROCESS_INFORMATION
	if !win.CreateProcessW(nil, cmd, nil, nil, false, win.CREATE_NO_WINDOW, nil, win.utf8_to_wstring(app.exe_dir), &si, &pi) {
		return 0, false
	}
	defer win.CloseHandle(pi.hProcess)
	defer win.CloseHandle(pi.hThread)
	win.WaitForSingleObject(pi.hProcess, win.INFINITE)
	exit: win.DWORD
	if !win.GetExitCodeProcess(pi.hProcess, &exit) do return 0, false
	return u32(exit), true
}

// Starts the updater without waiting for it.
start_updater :: proc(args: string) -> bool {
	r := win.ShellExecuteW(nil, win.L("open"), win.utf8_to_wstring(updater_path()), win.utf8_to_wstring(args), win.utf8_to_wstring(app.exe_dir), win.SW_SHOWNORMAL)
	return uintptr(rawptr(r)) > 32
}
