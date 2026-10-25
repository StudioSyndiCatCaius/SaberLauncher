package saber

// Settings > "Check for updates": runs `SaberUpdater.exe --check` hidden on a
// worker thread; if a newer release exists, starts the updater with
// `-y --wait --restart` (it waits for us to exit, swaps the exes and relaunches
// Saber) and quits.

import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	GetExitCodeProcess :: proc(hProcess: win.HANDLE, lpExitCode: ^win.DWORD) -> win.BOOL ---
}

Update_State :: enum i32 {
	Idle,
	Checking,
	Up_To_Date,
	Available,
	Failed,
}

update_state: Update_State // read/written atomically
update_worker: ^thread.Thread

UPDATE_STATUS := [Update_State]string {
	.Idle       = "Check now",
	.Checking   = "Checking...",
	.Up_To_Date = "Up to date",
	.Available  = "Updating...",
	.Failed     = "Check failed",
}

updater_path :: proc() -> string {
	return path_join({app.exe_dir, "SaberUpdater.exe"})
}

update_get_state :: proc() -> Update_State {
	return Update_State(sync.atomic_load(cast(^i32)&update_state))
}

update_check_start :: proc() {
	if update_get_state() == .Checking || update_get_state() == .Available do return
	if !app.settings.online_mode {
		set_status("Online Mode is off")
		return
	}
	if !os.exists(updater_path()) {
		set_status("SaberUpdater.exe not found")
		sync.atomic_store(cast(^i32)&update_state, i32(Update_State.Failed))
		return
	}
	if update_worker != nil {
		thread.join(update_worker)
		thread.destroy(update_worker)
	}
	sync.atomic_store(cast(^i32)&update_state, i32(Update_State.Checking))
	update_worker = thread.create_and_start(update_check_worker)
}

@(private = "file")
update_check_worker :: proc() {
	code, ok := run_hidden_wait(updater_path(), "--check")
	result := Update_State.Failed
	if ok && code == 0 do result = .Up_To_Date
	if ok && code == 10 do result = .Available
	sync.atomic_store(cast(^i32)&update_state, i32(result))
}

@(private = "file")
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

// Called once per frame from the main loop.
update_poll :: proc() {
	@(static) last := Update_State.Idle
	s := update_get_state()
	if s == last do return
	last = s
	#partial switch s {
	case .Up_To_Date:
		set_status("Saber is up to date")
	case .Failed:
		set_status("Update check failed (offline?)")
	case .Available:
		exe := win.utf8_to_wstring(updater_path())
		r := win.ShellExecuteW(nil, win.L("open"), exe, win.L("-y --wait --restart"), win.utf8_to_wstring(app.exe_dir), win.SW_SHOWNORMAL)
		if uintptr(rawptr(r)) <= 32 {
			set_status("Could not start SaberUpdater.exe")
			sync.atomic_store(cast(^i32)&update_state, i32(Update_State.Failed))
			return
		}
		set_status("Installing update, Saber will restart...")
		app.quit = true
	}
}
