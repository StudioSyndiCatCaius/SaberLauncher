package saber

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import win "core:sys/windows"

// Crash safety for the account shell, where a dead Saber leaves a black screen with
// nothing behind it.
//
// - Supervisor: when Saber starts as the shell, that first process stays tiny (no window,
//   no raylib) and runs the real Saber as a child with --supervised. A child that dies
//   abnormally is started again; three quick deaths in a row start Explorer instead.
//   Exit code 0 = quit (the supervisor ends too), SUPERVISED_RESTART = "Restart Saber".
// - Crash log (APP/crash.log): an unhandled exception writes its code, faulting module +
//   offset and the last crash_note() step; Odin panics / bounds errors print their
//   source location to stderr, which is pointed at the same file.

SUPERVISED_ARG :: "--supervised"
SUPERVISED_RESTART :: 75
CRASH_LOG :: "crash.log"
QUICK_CRASH_SEC :: 30
QUICK_CRASH_LIMIT :: 3
SM_SHUTTINGDOWN :: 0x2000

foreign import kernel32_crash "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32_crash {
	SetStdHandle :: proc(nStdHandle: win.DWORD, hHandle: win.HANDLE) -> win.BOOL ---
	GetModuleHandleExW :: proc(dwFlags: win.DWORD, lpModuleName: rawptr, phModule: ^win.HMODULE) -> win.BOOL ---
	SetErrorMode :: proc(uMode: win.UINT) -> win.UINT ---
}

SEM_NOGPFAULTERRORBOX :: 0x0002

GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS :: 0x4
GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT :: 0x2
STD_ERROR_HANDLE :: ~win.DWORD(0) - 12 + 1

// Last thing Saber started doing; written into the crash log. Fixed buffer: the
// exception handler must not allocate.
crash_step_buf: [160]u8
crash_step_len: int
crash_log_handle: win.HANDLE

crash_note :: proc(format: string, args: ..any) {
	s := fmt.bprintf(crash_step_buf[:], format, ..args)
	crash_step_len = len(s)
}

crash_log_path :: proc() -> string {
	return path_join({exe_directory(), CRASH_LOG})
}

// Appends one timestamped line (normal code paths only, it allocates).
crash_log_line :: proc(format: string, args: ..any) {
	now := time.now()
	y, mo, d := time.date(now)
	hh, mm, ss := time.clock(now)
	line := fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d  %s\r\n", y, int(mo), d, hh, mm, ss, fmt.tprintf(format, ..args))
	if crash_log_handle != nil {
		n: win.DWORD
		win.WriteFile(crash_log_handle, raw_data(line), win.DWORD(len(line)), &n, nil)
		return
	}
	f, err := os.open(crash_log_path(), {.Write, .Create, .Append})
	if err != nil do return
	defer os.close(f)
	os.write_string(f, line)
}

crash_open_log :: proc() -> win.HANDLE {
	h := win.CreateFileW(
		win.utf8_to_wstring(crash_log_path()),
		win.FILE_APPEND_DATA,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
		nil,
		win.OPEN_ALWAYS,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	return h == win.INVALID_HANDLE_VALUE ? nil : h
}

// Call first thing in the Saber process that draws (supervised or not).
crash_init :: proc() {
	crash_log_handle = crash_open_log()
	if crash_log_handle != nil {
		// a GUI exe has no stderr: Odin's panic / bounds-check messages land in the log
		SetStdHandle(STD_ERROR_HANDLE, crash_log_handle)
	}
	win.SetUnhandledExceptionFilter(crash_filter)
	if app.supervised {
		// no "Saber has stopped working" box: nobody may be there to close it, and the
		// dead process would linger until someone did, so the supervisor couldn't restart it
		SetErrorMode(SetErrorMode(0) | SEM_NOGPFAULTERRORBOX)
	}
}

crash_filter :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	if crash_log_handle == nil || info == nil || info.ExceptionRecord == nil {
		return win.EXCEPTION_CONTINUE_SEARCH
	}
	rec := info.ExceptionRecord
	addr := uintptr(rec.ExceptionAddress)

	// faulting module + offset, without allocating
	mod: win.HMODULE
	name_w: [260]u16
	name_n: win.DWORD
	if GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, rawptr(addr), &mod) {
		name_n = win.GetModuleFileNameW(mod, raw_data(name_w[:]), len(name_w))
	}
	// file name only, narrowed (module names are ASCII in practice)
	start := 0
	for i in 0 ..< int(name_n) do if name_w[i] == '\\' || name_w[i] == '/' do start = i + 1
	name: [128]u8
	nl := 0
	for i in start ..< int(name_n) {
		if nl >= len(name) do break
		ch := name_w[i]
		name[nl] = ch < 128 ? u8(ch) : '?'
		nl += 1
	}

	buf: [512]u8
	n := 0
	put :: proc "contextless" (buf: []u8, n: ^int, s: string) {
		for i in 0 ..< len(s) {
			if n^ >= len(buf) do return
			buf[n^] = s[i]
			n^ += 1
		}
	}
	put_hex :: proc "contextless" (buf: []u8, n: ^int, v: u64, digits: int) {
		HEX := "0123456789ABCDEF"
		for i := digits - 1; i >= 0; i -= 1 {
			if n^ >= len(buf) do return
			buf[n^] = HEX[(v >> (u64(i) * 4)) & 0xF]
			n^ += 1
		}
	}
	put(buf[:], &n, "\r\n*** CRASH  exception 0x")
	put_hex(buf[:], &n, u64(rec.ExceptionCode), 8)
	put(buf[:], &n, "  at ")
	if nl > 0 {
		put(buf[:], &n, string(name[:nl]))
		put(buf[:], &n, "+0x")
		put_hex(buf[:], &n, u64(addr - uintptr(mod)), 8)
	} else {
		put(buf[:], &n, "0x")
		put_hex(buf[:], &n, u64(addr), 16)
	}
	if rec.ExceptionCode == win.EXCEPTION_ACCESS_VIOLATION && rec.NumberParameters >= 2 {
		put(buf[:], &n, uintptr(rec.ExceptionInformation[0]) == 0 ? "  reading 0x" : "  writing 0x")
		put_hex(buf[:], &n, u64(uintptr(rec.ExceptionInformation[1])), 16)
	}
	put(buf[:], &n, "\r\n    while: ")
	put(buf[:], &n, crash_step_len > 0 ? string(crash_step_buf[:crash_step_len]) : "(nothing noted)")
	put(buf[:], &n, "\r\n")
	written: win.DWORD
	win.WriteFile(crash_log_handle, raw_data(buf[:]), win.DWORD(n), &written, nil)
	win.FlushFileBuffers(crash_log_handle)
	return win.EXCEPTION_CONTINUE_SEARCH // let Windows end the process; the supervisor restarts it
}

has_arg :: proc(name: string) -> bool {
	for a in os.args[1:] do if a == name do return true
	return false
}

shutting_down :: proc() -> bool {
	return GetSystemMetrics != nil && GetSystemMetrics(SM_SHUTTINGDOWN) != 0
}

// Runs the supervisor when Saber was started as the account shell. Returns true when
// this process was the supervisor (main should return), false to carry on as Saber.
shell_supervise :: proc() -> bool {
	if has_arg(SUPERVISED_ARG) {
		app.supervised = true
		return false
	}
	if !is_acting_as_shell() do return false
	if !single_instance() do return true

	// heap copies: the loop frees the temp allocator after every run
	exe := strings.clone(exe_full_path())
	dir := exe_directory()
	settings := settings_load(path_join({dir, "Saber.ini"}))
	if settings.shell_startup do run_startup_programs(exe)

	// pass the first start's arguments on (e.g. --play-disc), never after a crash
	extra := strings.builder_make()
	for a in os.args[1:] do fmt.sbprintf(&extra, " %s", quote_arg(a))
	first_args := strings.to_string(extra)

	quick_crashes := 0
	first := true
	for {
		cmd := fmt.tprintf("\"%s\" %s%s", exe, SUPERVISED_ARG, first ? first_args : "")
		first = false
		started := time.tick_now()
		pi, ok := spawn_process(exe, cmd, dir)
		if !ok {
			crash_log_line("Supervisor: couldn't start Saber (error %d); starting Explorer", win.GetLastError())
			open_desktop()
			return true
		}
		win.WaitForSingleObject(pi.hProcess, win.INFINITE)
		code: win.DWORD
		win.GetExitCodeProcess(pi.hProcess, &code)
		win.CloseHandle(pi.hProcess)
		win.CloseHandle(pi.hThread)
		free_all(context.temp_allocator)

		if code == 0 || shutting_down() do return true
		if code == SUPERVISED_RESTART {
			quick_crashes = 0
			continue
		}
		lived := time.duration_seconds(time.tick_since(started))
		quick_crashes = lived < QUICK_CRASH_SEC ? quick_crashes + 1 : 1
		crash_log_line("Supervisor: Saber ended with code 0x%08X after %.0f s", u32(code), lived)
		if quick_crashes >= QUICK_CRASH_LIMIT {
			crash_log_line("Supervisor: Saber keeps crashing; starting Explorer instead")
			open_desktop()
			return true
		}
		win.Sleep(500)
	}
}
