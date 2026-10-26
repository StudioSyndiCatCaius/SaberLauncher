package saber

import "core:strings"
import rl "vendor:raylib"
import win "core:sys/windows"

// Windows side of session.odin: process launch/tracking, window search, XInput guide button.

Proc_Info :: win.PROCESS_INFORMATION
Proc_Handle :: win.HANDLE

spawn_process :: proc(exe, cmd, work_dir: string) -> (win.PROCESS_INFORMATION, bool) {
	cmd_w := win.utf8_to_wstring(cmd) // CreateProcessW may write to the command line buffer
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW), dwFlags = win.STARTF_USESHOWWINDOW, wShowWindow = u16(win.SW_SHOWNORMAL)}
	pi: win.PROCESS_INFORMATION
	ok := win.CreateProcessW(
		exe != "" ? win.utf8_to_wstring(exe) : nil,
		cmd_w,
		nil,
		nil,
		false,
		win.CREATE_UNICODE_ENVIRONMENT,
		nil,
		work_dir != "" ? win.utf8_to_wstring(work_dir) : nil,
		&si,
		&pi,
	)
	return pi, bool(ok)
}

proc_handle :: proc(pi: Proc_Info) -> Proc_Handle {
	return pi.hProcess
}

proc_pid :: proc(pi: Proc_Info) -> u32 {
	return pi.dwProcessId
}

proc_release :: proc(pi: Proc_Info) {
	win.CloseHandle(pi.hProcess)
	win.CloseHandle(pi.hThread)
}

proc_alive :: proc(h: Proc_Handle) -> bool {
	return win.WaitForSingleObject(h, 0) == win.WAIT_TIMEOUT
}

Proc_Row :: struct {
	pid, ppid: u32,
	named:     bool, // exe name matched `match_name`
}

// Every running process, from one Toolhelp snapshot. -1 when the snapshot fails.
snapshot_processes :: proc(rows: []Proc_Row, match_name: string) -> int {
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0)
	if snap == nil || snap == win.INVALID_HANDLE_VALUE {
		return -1
	}
	defer win.CloseHandle(snap)
	count := 0
	pe := win.PROCESSENTRY32W{dwSize = size_of(win.PROCESSENTRY32W)}
	if win.Process32FirstW(snap, &pe) {
		for count < len(rows) {
			named := false
			if match_name != "" {
				name, _ := win.wstring_to_utf8(win.wstring(&pe.szExeFile[0]), -1, context.temp_allocator)
				named = strings.equal_fold(name, match_name)
			}
			rows[count] = {pe.th32ProcessID, pe.th32ParentProcessID, named}
			count += 1
			if !win.Process32NextW(snap, &pe) {
				break
			}
		}
	}
	return count
}

Window_Search :: struct {
	s:     ^Session,
	best:  win.HWND,
	area:  i32,
}

// Largest visible, non-minimized top-level window owned by the session.
session_find_window :: proc(s: ^Session) -> win.HWND {
	search := Window_Search{s = s}
	EnumWindows(proc "system" (hwnd: win.HWND, lp: win.LPARAM) -> win.BOOL {
		ws := (^Window_Search)(rawptr(uintptr(lp)))
		if !IsWindowVisible(hwnd) || IsIconic(hwnd) {
			return true
		}
		if u32(GetWindowLongPtrW(hwnd, win.GWL_EXSTYLE)) & win.WS_EX_TOOLWINDOW != 0 {
			return true
		}
		pid: win.DWORD
		GetWindowThreadProcessId(hwnd, &pid)
		found := false
		for p in ws.s.pids[:ws.s.pid_count] {
			if p == pid {
				found = true
				break
			}
		}
		if !found {
			return true
		}
		r: win.RECT
		GetWindowRect(hwnd, &r)
		area := (r.right - r.left) * (r.bottom - r.top)
		if area > 64 * 64 && area > ws.area {
			ws.area = area
			ws.best = hwnd
		}
		return true
	}, win.LPARAM(uintptr(&search)))
	return search.best
}

session_close :: proc(s: ^Session) {
	// Ask nicely first: post WM_CLOSE to every window of every tracked process.
	EnumWindows(proc "system" (hwnd: win.HWND, lp: win.LPARAM) -> win.BOOL {
		ss := (^Session)(rawptr(uintptr(lp)))
		pid: win.DWORD
		GetWindowThreadProcessId(hwnd, &pid)
		for p in ss.pids[:ss.pid_count] {
			if p == pid && IsWindowVisible(hwnd) {
				PostMessageW(hwnd, win.WM_CLOSE, 0, 0)
				break
			}
		}
		return true
	}, win.LPARAM(uintptr(s)))
}

session_kill :: proc(s: ^Session) {
	for p in s.pids[:s.pid_count] {
		h := win.OpenProcess(win.PROCESS_TERMINATE, false, p)
		if h != nil {
			win.TerminateProcess(h, 1)
			win.CloseHandle(h)
		}
	}
	win.TerminateProcess(s.handle, 1)
}

// ---------------------------------------------------------------------------
// The Xbox button is only exposed by the undocumented XInputGetStateEx (ordinal 100).

XInput_State :: struct {
	packet:   u32,
	buttons:  u16,
	lt, rt:   u8,
	lx, ly:   i16,
	rx, ry:   i16,
	reserved: u32,
}

XINPUT_GUIDE :: 0x0400

xinput_get_state_ex: proc "system" (user: u32, state: ^XInput_State) -> u32
xinput_loaded: bool
xinput_connected: [4]bool
xinput_probe_at: f64

xinput_init :: proc() {
	if xinput_loaded {
		return
	}
	xinput_loaded = true
	for dll in ([]string{"xinput1_4.dll", "xinput1_3.dll"}) {
		mod := win.LoadLibraryW(win.utf8_to_wstring(dll))
		if mod == nil {
			continue
		}
		if p := win.GetProcAddress(mod, transmute(cstring)uintptr(100)); p != nil {
			xinput_get_state_ex = auto_cast p
			xinput_connected = {true, true, true, true}
			return
		}
	}
}

xinput_guide_down :: proc() -> bool {
	xinput_init()
	if xinput_get_state_ex == nil {
		return false
	}
	down := false
	// Querying empty slots is slow, so only re-probe them every couple of seconds.
	now := rl.GetTime()
	probe := now >= xinput_probe_at
	if probe {
		xinput_probe_at = now + 2
	}
	for i in 0 ..< 4 {
		if !xinput_connected[i] && !probe {
			continue
		}
		st: XInput_State
		xinput_connected[i] = xinput_get_state_ex(u32(i), &st) == 0
		if xinput_connected[i] && st.buttons & XINPUT_GUIDE != 0 {
			down = true
		}
	}
	return down
}

// ---------------------------------------------------------------------------

// Screen grab of the running game used as the overlay backdrop. Downscaled so the
// bilinear upscale reads as a soft blur.
capture_screen :: proc() -> (rl.Texture2D, bool) {
	m := monitor_rect(native_hwnd())
	w := m.right - m.left
	h := m.bottom - m.top
	if w <= 0 || h <= 0 {
		return {}, false
	}
	sdc := GetDC(nil)
	if sdc == nil {
		return {}, false
	}
	defer ReleaseDC(nil, sdc)
	mdc := win.CreateCompatibleDC(sdc)
	if mdc == nil {
		return {}, false
	}
	bmp := win.CreateCompatibleBitmap(sdc, w, h)
	if bmp == nil {
		win.DeleteDC(mdc)
		return {}, false
	}
	defer win.DeleteObject(win.HGDIOBJ(bmp))
	old := win.SelectObject(mdc, win.HGDIOBJ(bmp))
	win.BitBlt(mdc, 0, 0, w, h, sdc, m.left, m.top, win.SRCCOPY)
	win.SelectObject(mdc, old)
	win.DeleteDC(mdc)

	img, ok := hbitmap_to_image(bmp)
	if !ok {
		return {}, false
	}
	defer rl.UnloadImage(img)
	rl.ImageResize(&img, max(1, img.width / 6), max(1, img.height / 6))
	tex := rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(tex, .BILINEAR)
	return tex, tex.id != 0
}
