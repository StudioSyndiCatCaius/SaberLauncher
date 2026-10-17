package saber

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"
import win "core:sys/windows"

// A running game / app / movie that Saber is hidden behind.

Launch_Kind :: enum {
	Game,
	App,
	Movie,
}

MAX_TRACKED :: 64

Session :: struct {
	kind:          Launch_Kind,
	title:         string,
	handle:        win.HANDLE,
	pid:           win.DWORD,
	exe_name:      string, // also track stray processes with this name (launchers that re-spawn)
	pids:          [MAX_TRACKED]win.DWORD,
	pid_count:     int,
	started:       f64,
	main_hwnd:     win.HWND,
	seen_window:   bool,
	windowless_at: f64,
	gone_at:       f64,
	focus_tries:   int,
	detached:      bool, // user chose "Return to Saber" while it keeps running
}

POLL_MS :: 33
TRACK_INTERVAL :: 0.25
EXIT_GRACE :: 0.7
// Apps like Steam/Discord drop to the tray instead of exiting; treat "no windows" as closed.
APP_WINDOWLESS_SEC :: 4.0
APP_NEVER_SHOWN_SEC :: 15.0
FOCUS_WINDOW_SEC :: 10.0

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

// Blocks until the launched program (and anything it spawned) is gone, or the
// user leaves it from the Home-button overlay. Returns seconds spent, and whether
// it was left running.
run_session :: proc(pi: win.PROCESS_INFORMATION, kind: Launch_Kind, title, exe_name: string) -> (seconds: int, detached: bool) {
	s := Session{
		kind     = kind,
		title    = title,
		handle   = pi.hProcess,
		pid      = pi.dwProcessId,
		exe_name = exe_name,
		started  = rl.GetTime(),
	}
	s.pids[0] = s.pid
	s.pid_count = 1
	defer {
		win.CloseHandle(pi.hProcess)
		win.CloseHandle(pi.hThread)
	}

	sfx_start()
	theme_pause_for_game()
	if AllowSetForegroundWindow != nil {
		AllowSetForegroundWindow(ASFW_ANY)
	}
	hide_for_child()
	guide_reset()

	next_track: f64 = 0
	for {
		now := rl.GetTime()
		if now >= next_track {
			next_track = now + TRACK_INTERVAL
			if session_tick(&s, now) {
				break
			}
		}
		if guide_pressed() {
			if pause_menu(&s) {
				break
			}
			next_track = 0
		}
		hide_for_child()
		msg_wait(s.handle, POLL_MS)
		free_all(context.temp_allocator)
	}

	restore_after_child()
	theme_resume_after_game()
	eat_input()
	return int(rl.GetTime() - s.started), s.detached
}

// Returns true when the session is over.
session_tick :: proc(s: ^Session, now: f64) -> bool {
	session_refresh_pids(s)
	if s.pid_count == 0 {
		if s.gone_at == 0 {
			s.gone_at = now
		}
		return now - s.gone_at >= EXIT_GRACE
	}
	s.gone_at = 0

	hwnd := session_find_window(s)
	if hwnd != nil {
		s.main_hwnd = hwnd
		s.seen_window = true
		s.windowless_at = 0
		// Without Explorer nobody hands focus to a new window; exclusive-fullscreen
		// games render black or flicker if they start in the background.
		fg := GetForegroundWindow()
		if now - s.started < FOCUS_WINDOW_SEC && !session_owns_window(s, fg) && s.focus_tries < 20 {
			s.focus_tries += 1
			force_foreground(hwnd)
		}
	} else if s.kind == .App {
		if s.seen_window {
			if s.windowless_at == 0 {
				s.windowless_at = now
			}
			return now - s.windowless_at >= APP_WINDOWLESS_SEC
		}
		root_done := win.WaitForSingleObject(s.handle, 0) != win.WAIT_TIMEOUT
		return root_done && now - s.started >= APP_NEVER_SHOWN_SEC
	}
	return false
}

generic_wait_exe :: proc(name: string) -> bool {
	for n in ([]string{"cmd.exe", "powershell.exe", "pwsh.exe", "conhost.exe", "explorer.exe", "Saber.exe"}) {
		if strings.equal_fold(name, n) {
			return true
		}
	}
	return false
}

// Track the root, its live descendants (including orphans whose parent we already
// knew) and same-named processes, using one snapshot per tick.
session_refresh_pids :: proc(s: ^Session) {
	Row :: struct {
		pid, ppid: win.DWORD,
		named:     bool,
	}
	rows: [1024]Row
	count := 0
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0)
	if snap == nil || snap == win.INVALID_HANDLE_VALUE {
		return
	}
	match_name := s.exe_name != "" && !generic_wait_exe(s.exe_name)
	pe := win.PROCESSENTRY32W{dwSize = size_of(win.PROCESSENTRY32W)}
	if win.Process32FirstW(snap, &pe) {
		for count < len(rows) {
			named := false
			if match_name {
				name, _ := win.wstring_to_utf8(win.wstring(&pe.szExeFile[0]), -1, context.temp_allocator)
				named = strings.equal_fold(name, s.exe_name)
			}
			rows[count] = {pe.th32ProcessID, pe.th32ParentProcessID, named}
			count += 1
			if !win.Process32NextW(snap, &pe) {
				break
			}
		}
	}
	win.CloseHandle(snap)

	known := s.pids
	known_n := s.pid_count
	in_known :: proc(list: []win.DWORD, pid: win.DWORD) -> bool {
		for p in list {
			if p == pid {
				return true
			}
		}
		return false
	}
	next: [MAX_TRACKED]win.DWORD
	n := 0
	self := win.GetCurrentProcessId()
	root_alive := win.WaitForSingleObject(s.handle, 0) == win.WAIT_TIMEOUT
	if root_alive {
		next[0] = s.pid
		n = 1
	}
	changed := true
	for changed && n < MAX_TRACKED {
		changed = false
		for r in rows[:count] {
			if r.pid == 0 || r.pid == self || r.pid == s.pid || in_known(next[:n], r.pid) {
				continue
			}
			if r.named || in_known(known[:known_n], r.pid) || in_known(known[:known_n], r.ppid) || in_known(next[:n], r.ppid) {
				next[n] = r.pid
				n += 1
				changed = true
				if n == MAX_TRACKED {
					break
				}
			}
		}
	}
	s.pids = next
	s.pid_count = n
}

session_owns_pid :: proc(s: ^Session, pid: win.DWORD) -> bool {
	for p in s.pids[:s.pid_count] {
		if p == pid {
			return true
		}
	}
	return false
}

session_owns_window :: proc(s: ^Session, hwnd: win.HWND) -> bool {
	if hwnd == nil {
		return false
	}
	pid: win.DWORD
	GetWindowThreadProcessId(hwnd, &pid)
	return session_owns_pid(s, pid)
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
// Home / Guide button. The Xbox button is only exposed by the undocumented
// XInputGetStateEx (ordinal 100); other pads come through raylib's MIDDLE button.

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
guide_was_down: bool

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

guide_down :: proc() -> bool {
	xinput_init()
	down := false
	if xinput_get_state_ex != nil {
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
	}
	for i in 0 ..< MAX_PADS {
		if rl.IsGamepadAvailable(i32(i)) && rl.IsGamepadButtonDown(i32(i), .MIDDLE) {
			down = true
		}
	}
	return down
}

guide_reset :: proc() {
	guide_was_down = guide_down()
}

// `poll` refreshes raylib's pad state; only needed while no frames are being drawn.
guide_pressed :: proc(poll := true) -> bool {
	if poll {
		rl.PollInputEvents()
	}
	down := guide_down()
	pressed := down && !guide_was_down
	guide_was_down = down
	return pressed
}

// ---------------------------------------------------------------------------
// In-game overlay

Pause_Choice :: enum {
	Resume,
	Home,
	Quit,
}

pause_labels :: proc(s: ^Session) -> [3]string {
	quit := "Quit Game"
	if s.kind == .App {
		quit = "Close App"
	} else if s.kind == .Movie {
		quit = "Stop Movie"
	}
	return {"Resume", "Return to Saber", quit}
}

// Shows Saber on top of the running program. Returns true when the session should end.
pause_menu :: proc(s: ^Session) -> bool {
	target := GetForegroundWindow()
	if !session_owns_window(s, target) {
		target = s.main_hwnd
	}
	shot, has_shot := capture_screen(native_hwnd())
	defer if has_shot {
		rl.UnloadTexture(shot)
	}

	show_window_on_top(true)
	sfx_click()
	app.pause_sel = 0
	app.pause_t = 0
	closing_at: f64 = 0
	done := false
	end_session := false

	for !done {
		input_poll()
		now := rl.GetTime()

		if closing_at != 0 {
			session_refresh_pids(s)
			if s.pid_count == 0 {
				done, end_session = true, true
			} else if now - closing_at > 3 {
				session_kill(s)
				done, end_session = true, true
			}
		} else {
			if win.WaitForSingleObject(s.handle, 0) != win.WAIT_TIMEOUT {
				session_refresh_pids(s)
				if s.pid_count == 0 {
					done, end_session = true, true
				}
			}
			if input.up {
				app.pause_sel = (app.pause_sel + 2) % 3
				sfx_click()
			}
			if input.down {
				app.pause_sel = (app.pause_sel + 1) % 3
				sfx_click()
			}
			if guide_pressed(false) || input.cancel || input.power {
				app.pause_sel = int(Pause_Choice.Resume)
				input.confirm = true
			}
			if input.confirm {
				switch Pause_Choice(app.pause_sel) {
				case .Resume:
					done = true
				case .Home:
					s.detached = true
					done, end_session = true, true
				case .Quit:
					sfx_back()
					session_refresh_pids(s)
					session_close(s)
					closing_at = now
				}
			}
		}

		w := f32(rl.GetScreenWidth())
		h := f32(rl.GetScreenHeight())
		rl.BeginDrawing()
		draw_pause_overlay(s, shot, has_shot, w, h, closing_at != 0)
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}

	if !end_session {
		hide_for_child()
		force_foreground(target)
	}
	return end_session
}

draw_pause_overlay :: proc(s: ^Session, shot: rl.Texture2D, has_shot: bool, w, h: f32, closing: bool) {
	app.pause_t = smooth_to(app.pause_t, 1, 12)
	rl.ClearBackground(COL_BG)
	if has_shot {
		draw_texture_cover(shot, {0, 0, w, h})
	}
	rl.DrawRectangle(0, 0, i32(w), i32(h), with_alpha(COL_SHADE, u8(150 * app.pause_t)))

	labels := pause_labels(s)
	sub := fmt.tprintf("%s  ·  %s", format_playtime(int(rl.GetTime() - s.started)), clock_label())
	if closing {
		sub = "Closing…"
	}
	if clicked := draw_modal_menu(s.title, sub, labels[:], app.pause_sel, app.pause_t, w, h, !closing); clicked >= 0 {
		app.pause_sel = clicked
		input.confirm = true // handled next frame through the same path as the pad
	}
	draw_hints(w, h, []Hint{{"A", "Select"}, {"B", "Resume"}})
}

// Screen grab of the running game used as the overlay backdrop. Downscaled so the
// bilinear upscale reads as a soft blur.
capture_screen :: proc(hwnd: win.HWND) -> (rl.Texture2D, bool) {
	m := monitor_rect(hwnd)
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
