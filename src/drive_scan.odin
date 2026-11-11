package saber

// Drive scans run on a worker thread: spinning up a disc, listing folders, hashing ROMs
// and decoding cover art used to freeze the UI for a moment on every insert. The worker
// builds a fresh game list (scan_deferred skips GL and Lua); the main thread then uploads
// the art, runs the plugins and swaps the list in. A small glass card shows meanwhile.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

Drive_Scan_Kind :: enum {
	Drive,
	Disc,
}

Drive_Scan :: struct {
	worker:     ^thread.Thread,
	games:      [dynamic]Game, // owned by the worker until done
	done:       bool,          // atomic
	running:    bool,
	pending:    bool,          // a change arrived mid-scan: scan again afterwards
	kind:       Drive_Scan_Kind,
	started:    f64,
	label_lock: sync.Mutex,
	label_buf:  [64]u8,
	label:      string, // drive being read; view into label_buf, under label_lock
	// card
	card_t:     f32,
	shown_at:   f64,
	card_kind:  Drive_Scan_Kind,
}

drive_scan: Drive_Scan

DRIVE_CARD_DELAY :: 0.2 // quick scans never show the card
DRIVE_CARD_MIN :: 0.6   // once shown, stays at least this long

drive_scan_start :: proc(kind: Drive_Scan_Kind) {
	if drive_scan.running {
		drive_scan.pending = true
		if kind == .Disc do drive_scan.kind = .Disc
		return
	}
	drive_scan.running = true
	drive_scan.pending = false
	drive_scan.kind = kind
	drive_scan.started = rl.GetTime()
	drive_scan_note("")
	sync.atomic_store(&drive_scan.done, false)
	drive_scan.games = make([dynamic]Game)
	drive_scan.worker = thread.create_and_start_with_data(&drive_scan, drive_scan_worker)
}

drive_scan_worker :: proc(data: rawptr) {
	s := (^Drive_Scan)(data)
	context = runtime.default_context()
	defer sync.atomic_store(&s.done, true)
	defer free_all(context.temp_allocator)
	scan_deferred = true
	scan_portable_drives(&s.games)
}

// Called by scan_portable_drives as it reaches each drive (any thread).
drive_scan_note :: proc(label: string) {
	sync.mutex_lock(&drive_scan.label_lock)
	defer sync.mutex_unlock(&drive_scan.label_lock)
	drive_scan.label = fmt.bprint(drive_scan.label_buf[:], label)
}

drive_scan_label :: proc() -> string {
	sync.mutex_lock(&drive_scan.label_lock)
	defer sync.mutex_unlock(&drive_scan.label_lock)
	return fmt.tprint(drive_scan.label)
}

// Main loop: picks up a finished scan.
drive_scan_update :: proc() {
	if !bios_art_ok do for g in app.drive_games do if g.bios_dir != "" {
		bios_art_ensure() // outside the frame's drawing; the startup scan doesn't come through here
		break
	}
	if !drive_scan.running || !sync.atomic_load(&drive_scan.done) do return
	thread.join(drive_scan.worker)
	thread.destroy(drive_scan.worker)
	drive_scan.worker = nil
	drive_scan.running = false

	// keep the focus on the same game if it is still there
	keep := ""
	if sel := app.selected_drive; sel >= 0 && sel < len(app.drive_games) {
		keep = fmt.tprint(app.drive_games[sel].root)
	}
	old := app.drive_games
	app.drive_games = drive_scan.games
	drive_scan.games = nil
	for &g in app.drive_games do game_finish_scan(&g)

	// games still present keep their animation state; gone ones fade out as ghosts
	for &o in old {
		found := false
		for &g in app.drive_games {
			if g.root != o.root do continue
			g.anim_t, g.slot_x, g.has_slot = o.anim_t, o.slot_x, o.has_slot
			found = true
			break
		}
		if !found && app.screen == .Main && o.anim_t > 0.05 {
			append(&drive_ghosts, o) // keeps its textures until the fade ends
		} else {
			game_unload_art(&o)
		}
	}
	delete(old)

	app.selected_drive = clamp(app.selected_drive, 0, max(0, len(app.drive_games) - 1))
	for g, i in app.drive_games {
		if keep != "" && g.root == keep {
			app.selected_drive = i
			break
		}
	}
	// a freshly inserted device: focus its first game
	if app.jump_mask != 0 {
		jumped := false
		for g, i in app.drive_games {
			if g.drive_letter >= 'A' && g.drive_letter <= 'Z' && app.jump_mask & (u32(1) << (g.drive_letter - 'A')) != 0 {
				app.selected_drive = i
				jumped = true
				break
			}
		}
		if jumped && app.screen != .Main && !dialog_visible() do go_screen(.Main)
		if jumped || !drive_scan.pending do app.jump_mask = 0
	}
	update_scan_message()
	plugins_discs_changed()
	set_status("Drives updated  ·  %d inserted", len(app.drive_games))

	if drive_scan.pending do drive_scan_start(drive_scan.kind)
}

drive_scan_shutdown :: proc() {
	if drive_scan.worker == nil do return
	thread.join(drive_scan.worker)
	thread.destroy(drive_scan.worker)
	drive_scan.worker = nil
	for &g in drive_scan.games do game_unload_art(&g)
	delete(drive_scan.games)
}

// Insertable drives in `mask` (USB sticks, SD cards, optical, external disks).
portable_drive_mask :: proc(mask: u32) -> u32 {
	out: u32
	for i in 0 ..< u32(26) {
		if mask & (1 << i) != 0 && is_insertable_drive(rune('A' + i)) do out |= 1 << i
	}
	return out
}

// Optical drives holding a disc, from the media watcher (never blocks).
disc_presence_mask :: proc() -> u32 {
	out: u32
	for i in 0 ..< u32(26) {
		if _, present, ok := media_volume(u8('A' + i)); ok && present do out |= 1 << i
	}
	return out
}

// ---------------------------------------------------------------------------
// Cards that vanish from the Home carousel after their device left

drive_ghosts: [dynamic]Game

drive_ghosts_clear :: proc() {
	for &g in drive_ghosts do game_unload_art(&g)
	clear(&drive_ghosts)
}

// Drawn by draw_main where the cards were; each shrinks, sinks and fades.
draw_drive_ghosts :: proc() {
	for i := len(drive_ghosts) - 1; i >= 0; i -= 1 {
		g := &drive_ghosts[i]
		g.anim_t -= rl.GetFrameTime() * 3
		if g.anim_t <= 0 {
			game_unload_art(g)
			ordered_remove(&drive_ghosts, i)
			continue
		}
		t := g.anim_t
		s := 0.75 + 0.25 * t
		r := g.last_rect
		cx, cy := r.x + r.width * 0.5, r.y + r.height * 0.5 + (1 - t) * 50
		draw_card(game_card(g), {cx - r.width * s * 0.5, cy - r.height * s * 0.5, r.width * s, r.height * s}, false, 18, t * t)
	}
}

// ---------------------------------------------------------------------------
// Drive card: "Reading Disc…" while scanning, "Disc Ejected" / "Drive Removed" on removal

DRIVE_NOTICE_SEC :: 2.0

Drive_Notice :: struct {
	at:        f64,
	kind:      Drive_Scan_Kind,
	label_buf: [64]u8,
	label:     string,
}

drive_notice: Drive_Notice

drive_notice_removed :: proc(kind: Drive_Scan_Kind, letters: u32) {
	letter: u8
	for i in 0 ..< u8(26) {
		if letters & (1 << i) != 0 {
			letter = 'A' + i
			break
		}
	}
	label := fmt.tprintf("%c:", letter)
	for g in app.drive_games {
		if g.drive_letter == letter && g.drive_label != "" {
			label = g.drive_label
			break
		}
	}
	drive_notice.at = rl.GetTime()
	drive_notice.kind = kind
	drive_notice.label = fmt.bprint(drive_notice.label_buf[:], label)
	sfx_back()
}

draw_drive_scan_card :: proc(w, h: f32) {
	now := rl.GetTime()
	notice := drive_notice.at > 0 && now - drive_notice.at < DRIVE_NOTICE_SEC
	reading := drive_scan.running && now - drive_scan.started >= DRIVE_CARD_DELAY
	if reading && drive_scan.card_t < 0.02 do drive_scan.shown_at = now
	if drive_scan.card_t > 0.02 && now - drive_scan.shown_at < DRIVE_CARD_MIN do reading = true
	if reading do drive_scan.card_kind = drive_scan.kind
	drive_scan.card_t = smooth_to(drive_scan.card_t, notice || reading ? 1 : 0, 14)
	t := drive_scan.card_t
	if t < 0.02 do return

	cw: f32 = 380
	ch: f32 = 92
	s := 0.92 + 0.08 * t
	// bottom-right, clear of the Home title and the hint bar; slides in from the edge
	r := rl.Rectangle{w - PAD - cw * s + (1 - t) * 60, h - FOOTER_H - 20 - ch * s, cw * s, ch * s}
	draw_soft_shadow(r, RADIUS, t * 1.4)
	draw_glass(r, RADIUS, COL_PANEL_SOLID, 0.5, notice ? COL_WARN : COL_ACCENT, 0.25, t)
	if t < 0.5 do return

	icon := rl.Vector2{r.x + 52, r.y + r.height * 0.5}
	time := f32(now)
	tx := r.x + 100
	if notice {
		// a removal wins over a scan running behind it
		k := clamp(f32(now - drive_notice.at) / 0.7, 0, 1)
		e := 1 - (1 - k) * (1 - k) * (1 - k)
		disc := drive_notice.kind == .Disc
		if disc {
			draw_ejected_disc(icon, 30, time, e)
		} else {
			draw_unplugged_stick(icon, 30, e)
		}
		draw_t(disc ? "Disc Ejected" : "Drive Removed", tx, r.y + 22, 21, COL_TEXT)
		draw_t_fit(drive_notice.label, tx, r.y + 52, r.width - (tx - r.x) - 20, 15, COL_MUTED, false)
		return
	}

	disc := drive_scan.card_kind == .Disc
	if disc {
		draw_spinning_disc(icon, 30, time)
	} else {
		draw_usb_stick(icon, 30, time)
	}
	dots := "..."
	title := disc ? "Reading Disc" : "Reading Drive"
	draw_t(fmt.tprintf("%s%s", title, dots[:int(time * 3) % 4]), tx, r.y + 22, 21, COL_TEXT)
	label := drive_scan_label()
	if label == "" do label = disc ? "Spinning up…" : "Looking for games…"
	draw_t_fit(label, tx, r.y + 52, r.width - (tx - r.x) - 20, 15, COL_MUTED, false)
}

// The disc rises out of the tray (e: 0 -> 1) under an eject symbol.
draw_ejected_disc :: proc(c: rl.Vector2, radius, time, e: f32) {
	draw_spinning_disc({c.x - 4, c.y + 8 - e * 14}, radius * (1 - 0.15 * e), time * 0.08)
	// tray slot the disc came out of
	rl.DrawRectangleRounded({c.x - radius - 6, c.y + radius - 2, radius * 2 + 4, 6}, 1, 6, rl.Color{0, 0, 0, 110})
	// eject badge
	b := rl.Vector2{c.x + radius * 0.75, c.y + radius * 0.55}
	rl.DrawCircleV(b, 11, COL_WARN)
	rl.DrawTriangle({b.x - 6, b.y + 1}, {b.x + 6, b.y + 1}, {b.x, b.y - 6}, rl.WHITE)
	rl.DrawRectangle(i32(b.x - 6), i32(b.y + 3), 12, 3, rl.WHITE)
}

// The stick slides out of its port (e: 0 -> 1).
draw_unplugged_stick :: proc(c: rl.Vector2, size, e: f32) {
	port := rl.Rectangle{c.x + size * 0.75, c.y - size * 0.45, size * 0.3, size * 0.9}
	rl.DrawRectangleRounded(port, 0.3, 6, rl.Color{0, 0, 0, 90})
	rl.DrawRectangleRoundedLinesEx(port, 0.3, 6, 1.5, with_alpha(COL_TEXT, 90))
	sx := c.x - e * size * 0.35
	body := rl.Rectangle{sx - size * 0.7, c.y - size * 0.38, size * 1.0, size * 0.76}
	plug := rl.Rectangle{body.x + body.width, c.y - size * 0.27, size * 0.42, size * 0.54}
	rl.DrawRectangleRounded(plug, 0.15, 4, rl.Color{200, 206, 218, 255})
	rl.DrawRectangleRounded(body, 0.4, 8, COL_ACCENT)
	rl.DrawRectangleRounded({body.x + 3, body.y + 3, body.width - 6, body.height * 0.4}, 0.5, 8, rl.Color{255, 255, 255, 60})
	rl.DrawCircleV({body.x + size * 0.22, c.y}, 3, rl.Color{0, 0, 0, 90}) // LED off
	// a little spark where it came loose
	if e < 0.9 {
		a := u8(220 * (1 - e))
		px := port.x - 2
		rl.DrawLineEx({px, c.y - 10}, {px - 6, c.y - 16}, 2, with_alpha(COL_WARN, a))
		rl.DrawLineEx({px, c.y + 10}, {px - 6, c.y + 16}, 2, with_alpha(COL_WARN, a))
	}
}

// A CD: silver face, a rainbow sheen that turns with the disc, the hub and a laser glint.
draw_spinning_disc :: proc(c: rl.Vector2, radius, time: f32) {
	spin := time * 420
	rl.DrawCircleV({c.x, c.y + 3}, radius, rl.Color{0, 0, 0, 60})
	rl.DrawCircleV(c, radius, rl.Color{206, 212, 224, 255})
	// two opposing rainbow fans of thin sectors
	steps :: 14
	for side in 0 ..< 2 {
		base := spin + f32(side) * 180
		for i in 0 ..< steps {
			hue := f32(i) / f32(steps) * 300 + time * 40
			col := rl.ColorFromHSV(math.mod(hue, 360), 0.55, 1)
			a0 := base + f32(i) * 5
			rl.DrawCircleSector(c, radius - 1, a0, a0 + 5.5, 4, with_alpha(col, 120))
		}
	}
	// soft white highlight that stays put while the disc turns under it
	rl.DrawCircleSector(c, radius - 1, -130, -100, 8, rl.Color{255, 255, 255, 90})
	rl.DrawRing(c, radius - 1.5, radius, 0, 360, 48, rl.Color{255, 255, 255, 140})
	// printed label arc, so the spin reads clearly
	rl.DrawRing(c, radius * 0.48, radius * 0.56, spin, spin + 70, 12, with_alpha(COL_ACCENT, 200))
	// hub
	rl.DrawCircleV(c, radius * 0.34, rl.Color{232, 236, 244, 255})
	rl.DrawRing(c, radius * 0.30, radius * 0.34, 0, 360, 32, rl.Color{160, 168, 184, 255})
	rl.DrawCircleV(c, radius * 0.14, COL_BG)
	// laser glint sweeping across the tracks
	lr := radius * (0.45 + 0.45 * (0.5 + 0.5 * math.sin(time * 2.3)))
	gp := rl.Vector2{c.x + lr * 0.7, c.y + lr * 0.7}
	rl.DrawCircleV(gp, 5, with_alpha(COL_WARN, 60))
	rl.DrawCircleV(gp, 2.2, rl.Color{255, 240, 245, 255})
}

// A USB stick with a blinking LED and data dots streaming out of its plug.
draw_usb_stick :: proc(c: rl.Vector2, size, time: f32) {
	body := rl.Rectangle{c.x - size * 1.1, c.y - size * 0.42, size * 1.3, size * 0.84}
	plug := rl.Rectangle{body.x + body.width, c.y - size * 0.3, size * 0.5, size * 0.6}
	rl.DrawRectangleRounded({body.x, body.y + 3, body.width, body.height}, 0.4, 8, rl.Color{0, 0, 0, 60})
	rl.DrawRectangleRounded(plug, 0.15, 4, rl.Color{200, 206, 218, 255})
	rl.DrawRectangle(i32(plug.x + plug.width * 0.25), i32(c.y - size * 0.14), i32(size * 0.1), i32(size * 0.1), rl.Color{120, 128, 144, 255})
	rl.DrawRectangle(i32(plug.x + plug.width * 0.6), i32(c.y - size * 0.14), i32(size * 0.1), i32(size * 0.1), rl.Color{120, 128, 144, 255})
	rl.DrawRectangleRounded(body, 0.4, 8, with_alpha(COL_ACCENT, 255))
	rl.DrawRectangleRounded({body.x + 3, body.y + 3, body.width - 6, body.height * 0.4}, 0.5, 8, rl.Color{255, 255, 255, 60})
	// LED: blinks irregularly, like real activity
	on := math.sin(time * 17) + math.sin(time * 7.3) > 0.2
	led := rl.Vector2{body.x + size * 0.22, c.y}
	if on {
		rl.DrawCircleV(led, 6, with_alpha(COL_WARN, 70))
		rl.DrawCircleV(led, 3, rl.Color{255, 236, 240, 255})
	} else {
		rl.DrawCircleV(led, 3, rl.Color{0, 0, 0, 90})
	}
	// data dots leaving the plug
	for i in 0 ..< 3 {
		k := math.mod(time * 1.4 + f32(i) / 3, 1)
		x := plug.x + plug.width + 4 + k * size * 0.5
		rl.DrawCircleV({x, c.y}, 2.6, with_alpha(COL_TEXT, u8(230 * (1 - k))))
	}
}
