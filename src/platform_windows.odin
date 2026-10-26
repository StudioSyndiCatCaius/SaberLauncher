package saber

import "core:fmt"
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
	CreateMutexW(nil, true, win.L("Local\\SaberLauncher"))
	return win.GetLastError() != win.ERROR_ALREADY_EXISTS
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
