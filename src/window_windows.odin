package saber

import rl "vendor:raylib"
import win "core:sys/windows"

// All user32 calls go through this table. Static raylib exports CloseWindow, and
// pulling in core:sys/windows' User32.lib import makes the link fail on the clash.
AttachThreadInput: proc "system" (idAttach, idAttachTo: win.DWORD, fAttach: win.BOOL) -> win.BOOL
AllowSetForegroundWindow: proc "system" (dwProcessId: win.DWORD) -> win.BOOL
GetShellWindow: proc "system" () -> win.HWND
ExitWindowsEx: proc "system" (uFlags, dwReason: win.UINT) -> win.BOOL
MonitorFromWindow: proc "system" (hwnd: win.HWND, flags: win.DWORD) -> win.HMONITOR
GetMonitorInfoW: proc "system" (hMonitor: win.HMONITOR, lpmi: ^win.MONITORINFO) -> win.BOOL
GetSystemMetrics: proc "system" (nIndex: i32) -> i32
GetWindowRect: proc "system" (hWnd: win.HWND, lpRect: ^win.RECT) -> win.BOOL
IsIconic: proc "system" (hWnd: win.HWND) -> win.BOOL
IsWindowVisible: proc "system" (hWnd: win.HWND) -> win.BOOL
ShowWindow: proc "system" (hWnd: win.HWND, nCmdShow: i32) -> win.BOOL
GetForegroundWindow: proc "system" () -> win.HWND
SetForegroundWindow: proc "system" (hWnd: win.HWND) -> win.BOOL
BringWindowToTop: proc "system" (hWnd: win.HWND) -> win.BOOL
SetFocus: proc "system" (hWnd: win.HWND) -> win.HWND
GetWindowThreadProcessId: proc "system" (hWnd: win.HWND, lpdwProcessId: ^win.DWORD) -> win.DWORD
SetWindowPos: proc "system" (hWnd, hWndInsertAfter: win.HWND, X, Y, cx, cy: i32, uFlags: win.UINT) -> win.BOOL
PeekMessageW: proc "system" (lpMsg: ^win.MSG, hWnd: win.HWND, wMsgFilterMin, wMsgFilterMax, wRemoveMsg: win.UINT) -> win.BOOL
TranslateMessage: proc "system" (lpMsg: ^win.MSG) -> win.BOOL
DispatchMessageW: proc "system" (lpMsg: ^win.MSG) -> win.LRESULT
MsgWaitForMultipleObjects: proc "system" (nCount: win.DWORD, pHandles: [^]win.HANDLE, fWaitAll: win.BOOL, dwMilliseconds, dwWakeMask: win.DWORD) -> win.DWORD
EnumWindows: proc "system" (lpEnumFunc: win.Window_Enum_Proc, lParam: win.LPARAM) -> win.BOOL
GetWindowLongPtrW: proc "system" (hWnd: win.HWND, nIndex: i32) -> win.LONG_PTR
PostMessageW: proc "system" (hWnd: win.HWND, Msg: win.UINT, wParam: win.WPARAM, lParam: win.LPARAM) -> win.BOOL
GetDC: proc "system" (hWnd: win.HWND) -> win.HDC
ReleaseDC: proc "system" (hWnd: win.HWND, hDC: win.HDC) -> i32

@(init)
load_user32 :: proc "contextless" () {
	mod := win.LoadLibraryW(win.L("user32.dll"))
	if mod == nil {
		return
	}
	AttachThreadInput = auto_cast win.GetProcAddress(mod, "AttachThreadInput")
	AllowSetForegroundWindow = auto_cast win.GetProcAddress(mod, "AllowSetForegroundWindow")
	GetShellWindow = auto_cast win.GetProcAddress(mod, "GetShellWindow")
	ExitWindowsEx = auto_cast win.GetProcAddress(mod, "ExitWindowsEx")
	MonitorFromWindow = auto_cast win.GetProcAddress(mod, "MonitorFromWindow")
	GetMonitorInfoW = auto_cast win.GetProcAddress(mod, "GetMonitorInfoW")
	GetSystemMetrics = auto_cast win.GetProcAddress(mod, "GetSystemMetrics")
	GetWindowRect = auto_cast win.GetProcAddress(mod, "GetWindowRect")
	IsIconic = auto_cast win.GetProcAddress(mod, "IsIconic")
	IsWindowVisible = auto_cast win.GetProcAddress(mod, "IsWindowVisible")
	ShowWindow = auto_cast win.GetProcAddress(mod, "ShowWindow")
	GetForegroundWindow = auto_cast win.GetProcAddress(mod, "GetForegroundWindow")
	SetForegroundWindow = auto_cast win.GetProcAddress(mod, "SetForegroundWindow")
	BringWindowToTop = auto_cast win.GetProcAddress(mod, "BringWindowToTop")
	SetFocus = auto_cast win.GetProcAddress(mod, "SetFocus")
	GetWindowThreadProcessId = auto_cast win.GetProcAddress(mod, "GetWindowThreadProcessId")
	SetWindowPos = auto_cast win.GetProcAddress(mod, "SetWindowPos")
	PeekMessageW = auto_cast win.GetProcAddress(mod, "PeekMessageW")
	TranslateMessage = auto_cast win.GetProcAddress(mod, "TranslateMessage")
	DispatchMessageW = auto_cast win.GetProcAddress(mod, "DispatchMessageW")
	MsgWaitForMultipleObjects = auto_cast win.GetProcAddress(mod, "MsgWaitForMultipleObjects")
	EnumWindows = auto_cast win.GetProcAddress(mod, "EnumWindows")
	GetWindowLongPtrW = auto_cast win.GetProcAddress(mod, "GetWindowLongPtrW")
	PostMessageW = auto_cast win.GetProcAddress(mod, "PostMessageW")
	GetDC = auto_cast win.GetProcAddress(mod, "GetDC")
	ReleaseDC = auto_cast win.GetProcAddress(mod, "ReleaseDC")
}

MONITOR_DEFAULTTONEAREST :: 2

ASFW_ANY :: win.DWORD(0xFFFFFFFF)

Window_Handle :: win.HWND

native_hwnd :: proc() -> win.HWND {
	return win.HWND(rl.GetWindowHandle())
}

foreground_window :: proc() -> Window_Handle {
	return GetForegroundWindow()
}

window_pid :: proc(hwnd: Window_Handle) -> u32 {
	pid: win.DWORD
	GetWindowThreadProcessId(hwnd, &pid)
	return pid
}

// Lets a launched program take the foreground from us.
allow_foreground :: proc() {
	if AllowSetForegroundWindow != nil {
		AllowSetForegroundWindow(ASFW_ANY)
	}
}

wide_to_utf8 :: proc(p: [^]u16, n: int) -> string {
	s, _ := win.wstring_to_utf8(win.wstring(p), n)
	return s
}

// Full rect of the monitor the window is on (tracks resolution changes made by games).
monitor_rect :: proc(hwnd: win.HWND) -> win.RECT {
	mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
	mon := MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)
	if mon != nil && GetMonitorInfoW(mon, &mi) {
		return mi.rcMonitor
	}
	return {0, 0, GetSystemMetrics(win.SM_CXSCREEN), GetSystemMetrics(win.SM_CYSCREEN)}
}

window_rect :: proc(hwnd: win.HWND) -> win.RECT {
	r: win.RECT
	GetWindowRect(hwnd, &r)
	return r
}

// SetForegroundWindow is refused unless we share input with the current foreground
// thread; without Explorer (account shell) this is the only reliable way to take focus.
force_foreground :: proc(hwnd: win.HWND) {
	if hwnd == nil {
		return
	}
	if IsIconic(hwnd) {
		ShowWindow(hwnd, win.SW_RESTORE)
	}
	me := win.GetCurrentThreadId()
	fg := GetForegroundWindow()
	fg_thread: win.DWORD
	if fg != nil && fg != hwnd {
		fg_thread = GetWindowThreadProcessId(fg, nil)
	}
	attached := fg_thread != 0 && fg_thread != me && AttachThreadInput != nil && bool(AttachThreadInput(me, fg_thread, true))
	BringWindowToTop(hwnd)
	SetForegroundWindow(hwnd)
	SetFocus(hwnd)
	if attached {
		AttachThreadInput(me, fg_thread, false)
	}
}

// Hide without resizing: shrinking the GL window to a stub (old behaviour) left
// raylib's framebuffer and borderless state out of sync when we came back.
hide_for_child :: proc() {
	hwnd := native_hwnd()
	if hwnd == nil || !IsWindowVisible(hwnd) {
		return
	}
	SetWindowPos(hwnd, win.HWND_NOTOPMOST, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOACTIVATE)
	ShowWindow(hwnd, win.SW_HIDE)
}

// One pixel taller than the monitor on purpose: a GL window that exactly covers the
// screen gets promoted by the driver to DWM-bypassing "fullscreen" presentation,
// which shows stale frames to anything composited on top, breaks screen capture,
// and makes handing the display to a launching game flicker or go black.
fullscreen_rect :: proc(hwnd: win.HWND) -> win.RECT {
	m := monitor_rect(hwnd)
	m.bottom += 1
	return m
}

fit_to_monitor :: proc(hwnd: win.HWND, insert_after: win.HWND, flags: win.UINT) {
	m := fullscreen_rect(hwnd)
	SetWindowPos(hwnd, insert_after, m.left, m.top, m.right - m.left, m.bottom - m.top, flags | win.SWP_FRAMECHANGED)
}

show_window_on_top :: proc(topmost: bool) {
	hwnd := native_hwnd()
	if hwnd == nil {
		return
	}
	if !rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) {
		rl.ToggleBorderlessWindowed()
	}
	fit_to_monitor(hwnd, topmost ? win.HWND_TOPMOST : win.HWND_TOP, win.SWP_SHOWWINDOW)
	if !topmost {
		SetWindowPos(hwnd, win.HWND_NOTOPMOST, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE)
	}
	ShowWindow(hwnd, win.SW_SHOW)
	force_foreground(hwnd)
}

restore_after_child :: proc() {
	show_window_on_top(false)
	app.fit_check_at = 0
}

// Games that switch display modes often restore the desktop resolution a moment
// after they exit; re-fit until the window matches the monitor again.
FIT_INTERVAL :: 0.5

keep_fullscreen :: proc() {
	now := rl.GetTime()
	if now < app.fit_check_at {
		return
	}
	app.fit_check_at = now + FIT_INTERVAL
	hwnd := native_hwnd()
	if hwnd == nil || !rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) || !IsWindowVisible(hwnd) {
		return
	}
	if window_rect(hwnd) != fullscreen_rect(hwnd) {
		fit_to_monitor(hwnd, nil, win.SWP_NOZORDER | win.SWP_NOACTIVATE)
	}
}

pump_messages :: proc() {
	msg: win.MSG
	for PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
		TranslateMessage(&msg)
		DispatchMessageW(&msg)
	}
}

// Sleep up to `ms`, waking early for window messages or when `handle` signals.
msg_wait :: proc(handle: win.HANDLE, ms: u32) {
	h := handle
	if h != nil {
		MsgWaitForMultipleObjects(1, &h, false, ms, win.QS_ALLINPUT)
	} else {
		MsgWaitForMultipleObjects(0, nil, false, ms, win.QS_ALLINPUT)
	}
	pump_messages()
}
