package saber

import "core:strings"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	GetExitCodeProcess :: proc(hProcess: win.HANDLE, lpExitCode: ^win.DWORD) -> win.BOOL ---
}

updater_path :: proc() -> string {
	return path_join({app.exe_dir, "SaberUpdater.exe"})
}

run_hidden_wait :: proc(exe, args: string) -> (code: u32, ok: bool) {
	cmd := win.utf8_to_wstring(fmt_quote_cmd(exe, args))
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW)}
	pi: win.PROCESS_INFORMATION
	if !win.CreateProcessW(nil, cmd, nil, nil, false, win.CREATE_NO_WINDOW, nil, win.utf8_to_wstring(app.exe_dir), &si, &pi) {
		return 0, false
	}
	defer win.CloseHandle(pi.hProcess)
	defer win.CloseHandle(pi.hThread)
	win.WaitForSingleObject(pi.hProcess, win.INFINITE)
	exit: win.DWORD
	if !GetExitCodeProcess(pi.hProcess, &exit) do return 0, false
	return u32(exit), true
}

@(private = "file")
fmt_quote_cmd :: proc(exe, args: string) -> string {
	return strings.concatenate({"\"", exe, "\" ", args}, context.temp_allocator)
}

// Starts the updater without waiting for it.
start_updater :: proc(args: string) -> bool {
	r := win.ShellExecuteW(nil, win.L("open"), win.utf8_to_wstring(updater_path()), win.utf8_to_wstring(args), win.utf8_to_wstring(app.exe_dir), win.SW_SHOWNORMAL)
	return uintptr(rawptr(r)) > 32
}
