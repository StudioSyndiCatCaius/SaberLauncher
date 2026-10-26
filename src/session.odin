package saber

import "core:fmt"
import "core:strings"
import "core:os"
import rl "vendor:raylib"

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
	handle:        Proc_Handle,
	pid:           u32,
	exe_name:      string, // also track stray processes with this name (launchers that re-spawn)
	pids:          [MAX_TRACKED]u32,
	pid_count:     int,
	started:       f64,
	main_hwnd:     Window_Handle,
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

// Blocks until the launched program (and anything it spawned) is gone, or the
// user leaves it from the Home-button overlay. Returns seconds spent, and whether
// it was left running.
run_session :: proc(pi: Proc_Info, kind: Launch_Kind, title, exe_name: string) -> (seconds: int, detached: bool) {
	s := Session{
		kind     = kind,
		title    = title,
		handle   = proc_handle(pi),
		pid      = proc_pid(pi),
		exe_name = exe_name,
		started  = rl.GetTime(),
	}
	s.pids[0] = s.pid
	s.pid_count = 1
	defer proc_release(pi)

	defer splash_end()
	if !splash.active {
		sfx_start()
		theme_pause_for_game()
	}
	allow_foreground()
	if !splash.active {
		hide_for_child()
	}
	guide_reset()

	next_track: f64 = 0
	for {
		now := rl.GetTime()
		if now >= next_track {
			next_track = now + TRACK_INTERVAL
			if session_tick(&s, now) {
				break
			}
			// keep the splash up until the game has a window to cover the desktop
			if splash.active && splash_intro_done() && (s.seen_window || now - s.started >= SPLASH_MAX_SEC) {
				hide_for_child()
				splash_end()
			}
		}
		if guide_pressed() {
			if pause_menu(&s) {
				break
			}
			splash_end()
			next_track = 0
		}
		if splash.active {
			splash_frame() // paced by vsync; pumps messages
			continue
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
		fg := foreground_window()
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
		root_done := !proc_alive(s.handle)
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
	rows: [1024]Proc_Row
	match_name := s.exe_name != "" && !generic_wait_exe(s.exe_name) ? s.exe_name : ""
	count := snapshot_processes(rows[:], match_name)
	if count < 0 {
		return
	}

	known := s.pids
	known_n := s.pid_count
	in_known :: proc(list: []u32, pid: u32) -> bool {
		for p in list {
			if p == pid {
				return true
			}
		}
		return false
	}
	next: [MAX_TRACKED]u32
	n := 0
	self := u32(os.get_pid())
	root_alive := proc_alive(s.handle)
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

session_owns_pid :: proc(s: ^Session, pid: u32) -> bool {
	for p in s.pids[:s.pid_count] {
		if p == pid {
			return true
		}
	}
	return false
}

session_owns_window :: proc(s: ^Session, hwnd: Window_Handle) -> bool {
	if hwnd == nil {
		return false
	}
	return session_owns_pid(s, window_pid(hwnd))
}

// ---------------------------------------------------------------------------
// Home / Guide button. The Xbox button is only exposed by the undocumented
// XInputGetStateEx (ordinal 100); other pads come through raylib's MIDDLE button.

guide_was_down: bool

guide_down :: proc() -> bool {
	down := xinput_guide_down()
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
	target := foreground_window()
	if !session_owns_window(s, target) {
		target = s.main_hwnd
	}
	shot, has_shot := capture_screen()
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
			if !proc_alive(s.handle) {
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
