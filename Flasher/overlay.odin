package flasher

import "core:fmt"
import "core:math"
import "core:sync"
import rl "vendor:raylib"

// Blocking install overlay: lists every step with its state, live progress for the running
// one, the latest script log lines, and Cancel (while running) / Close (when finished).

MAX_STEP_ROWS :: 8

draw_install_overlay :: proc() {
	if !job_overlay do return
	drawing_modal = true
	defer drawing_modal = false

	running := sync.atomic_load(&job.running)
	Row :: struct {
		name, detail: string,
		state:        Step_State,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	logs := make([dynamic]string, context.temp_allocator)
	progress: f32
	msg: string
	failed: bool
	{
		sync.guard(&job.mu)
		first := max(0, len(job.steps) - MAX_STEP_ROWS)
		for st in job.steps[first:] {
			append(&rows, Row{fmt.tprint(st.name), fmt.tprint(st.detail), st.state})
		}
		for l in job.log[max(0, len(job.log) - 3):] do append(&logs, fmt.tprint(l))
		progress = job.progress
		msg = fmt.tprint(job.message)
		failed = job.failed
	}

	rl.DrawRectangleRec({0, 0, W, H}, {0, 0, 0, 170})
	ch := 150 + f32(len(rows)) * 44 + (len(logs) > 0 ? 24 + f32(len(logs)) * 20 : 0) + 96
	r := rl.Rectangle{W / 2 - 320, H / 2 - ch / 2, 640, ch}
	rounded({r.x, r.y + 10, r.width, r.height}, 18, {0, 0, 0, 120})
	rounded(r, 18, COL_CARD)
	rounded_line(r, 18, 1, COL_BORDER_HI)

	// header
	col := running ? COL_ACCENT : (failed ? COL_DANGER : COL_OK)
	ic := running ? IC_FLASH : (failed ? IC_WARN : IC_CHECK)
	rl.DrawCircleV({r.x + 52, r.y + 54}, 24, alpha(col, 40))
	draw_icon(ic, r.x + 52, r.y + 54, 22, col)
	title := running ? (cancelled() ? "Cancelling…" : fmt.tprintf("Installing %s", job.name)) : (failed ? "Install stopped" : "All done!")
	draw_text_fit(title, r.x + 92, r.y + 34, 21, COL_TEXT, r.width - 120, true)
	sub := running ? job.dest : msg
	draw_text_fit(sub, r.x + 92, r.y + 64, 14, failed && !running ? COL_DANGER : COL_MUTED, r.width - 120)

	// steps
	y := r.y + 112
	for row in rows {
		cx := r.x + 44
		cy := y + 14
		switch row.state {
		case .Running:
			t := f32(rl.GetTime())
			rl.DrawRing({cx, cy}, 7, 10, t * 360, t * 360 + 260, 24, COL_ACCENT)
		case .Done:
			rl.DrawCircleV({cx, cy}, 11, alpha(COL_OK, 40))
			draw_icon(IC_CHECK, cx, cy, 11, COL_OK)
		case .Failed:
			rl.DrawCircleV({cx, cy}, 11, alpha(COL_DANGER, 40))
			draw_icon(IC_CLOSE, cx, cy, 10, COL_DANGER)
		case .Cancelled:
			rl.DrawCircleV({cx, cy}, 11, alpha(COL_MUTED, 40))
			draw_icon(IC_CLOSE, cx, cy, 10, COL_MUTED)
		}
		active := row.state == .Running
		name_col := active ? COL_TEXT : (row.state == .Failed ? COL_DANGER : COL_MUTED)
		dw := text_w(row.detail, 13)
		draw_text_fit(row.name, cx + 26, cy - 10, 15, name_col, r.width - 140 - min(dw, 220), active)
		if row.detail != "" {
			dcol := row.state == .Failed ? COL_DANGER : COL_FAINT
			if row.state == .Failed {
				// errors get their own line, they're usually long
				draw_text_fit(row.detail, cx + 26, cy + 10, 13, dcol, r.width - 110)
			} else {
				draw_text_fit(row.detail, r.x + r.width - 28 - min(dw, 220), cy - 8, 13, dcol, 220)
			}
		}
		if active {
			bar := rl.Rectangle{cx + 26, cy + 14, r.width - 110, 6}
			rounded(bar, 3, COL_INPUT)
			if progress >= 0 {
				rounded({bar.x, bar.y, max(bar.width * clamp(progress, 0, 1), 6), bar.height}, 3, COL_ACCENT)
			} else {
				// indeterminate: a segment sweeping back and forth
				t := f32(rl.GetTime())
				seg := bar.width * 0.25
				pos := (math.sin(t * 2.4) * 0.5 + 0.5) * (bar.width - seg)
				rounded({bar.x + pos, bar.y, seg, bar.height}, 3, COL_ACCENT)
			}
		}
		y += 44
	}

	// script log
	if len(logs) > 0 {
		y += 8
		draw_text("LOG", r.x + 44, y, 11, COL_FAINT, true)
		y += 16
		for l in logs {
			draw_text_fit(l, r.x + 44, y, 13, COL_MUTED, r.width - 88)
			y += 20
		}
	}

	// buttons
	by := r.y + r.height - 70
	if running {
		if button({r.x + r.width - 24 - 150, by, 150, 46}, cancelled() ? "Cancelling…" : "Cancel", .Danger, IC_CLOSE, cancelled()) || (rl.IsKeyPressed(.ESCAPE) && !cancelled()) {
			sync.atomic_store(&job.cancel, true)
		}
	} else {
		if button({r.x + r.width - 24 - 140, by, 140, 46}, "Close", .Primary) || rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.ENTER) {
			job_overlay = false
		}
		if !failed && button({r.x + r.width - 24 - 140 - 12 - 160, by, 160, 46}, "Open folder", .Secondary, IC_OPEN) {
			shell_exec("explore", job.dest, "")
		}
	}
}
