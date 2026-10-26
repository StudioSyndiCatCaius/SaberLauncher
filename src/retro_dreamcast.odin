package saber

// Dreamcast discs. PC drives can't read GD-ROMs (pressed Dreamcast discs), but they read
// burned self-boot CD-Rs: an audio track in session 1, the game's data track in session 2,
// whose first sectors hold IP.BIN ("SEGA SEGAKATANA", product number, title).
//
// Flycast opens images with plain fopen (not the libretro VFS that serves PlayStation discs
// live), so the disc is copied once into APP/libretro/cache/dc/<volume serial>/ as a
// .cue + one .bin per track, then booted from there. Only the newest copy is kept.

import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"
import win "core:sys/windows"

DC_SESSION_GAP :: 11400 // session 1 lead-out (6750) + session 2 lead-in (4500) + pregap (150)
DC_RIP_CHUNK :: 32      // sectors per read while copying

// IP.BIN's user data, from a raw sector of the disc's last data track.
dc_read_ip :: proc(h: win.HANDLE, toc: ^Cd_Toc) -> (ip: [256]u8, ok: bool) {
	lba := -1
	for ti in 0 ..< toc.count do if !toc.tracks[ti].audio do lba = toc.tracks[ti].lba
	if lba < 0 do return
	raw: [RAW_SECTOR]u8
	if !dc_raw_read(h, lba, raw[:]) do return
	// mode 1: user data after the 16-byte header; mode 2 (XA): after the 8-byte subheader too
	off := raw[15] == 1 ? 16 : 24
	copy(ip[:], raw[off:])
	return ip, string(ip[:15]) == "SEGA SEGAKATANA"
}

dc_raw_read :: proc(h: win.HANDLE, lba: int, out: []u8) -> bool {
	for mode in ([]u32{TRACK_MODE_YELLOW_MODE2, TRACK_MODE_XA_FORM2}) {
		info := RAW_READ_INFO{disk_offset = i64(lba) * ISO_SECTOR, sector_count = 1, track_mode = mode}
		got: u32
		if win.DeviceIoControl(h, IOCTL_CDROM_RAW_READ, &info, size_of(info), &out[0], RAW_SECTOR, &got, nil) && got == RAW_SECTOR do return true
	}
	return false
}

// A burned Dreamcast CD-R in `letter` becomes a Main-screen game.
dc_disc_game :: proc(letter: rune, label: string) -> (Game, bool) {
	h := open_cd_volume(u8(letter))
	if h == win.INVALID_HANDLE_VALUE do return {}, false
	defer win.CloseHandle(h)
	toc, toc_ok := cd_read_toc(h)
	if !toc_ok do return {}, false
	ip, ok := dc_read_ip(h, &toc)
	if !ok {
		if !dc_is_gdrom(letter) do return {}, false
		// shown, so the player learns why it won't boot instead of the disc being ignored
		g := new_disc_game(letter, label, .DC, "", "Dreamcast GD-ROM")
		g.gdrom = true
		g.tags = strings.clone("Dreamcast  ·  GD-ROM: can't be read by PC drives")
		return g, true
	}
	serial := strings.trim_space(string(ip[0x40:0x4A]))
	title := strings.trim_space(string(ip[0x80:0x100]))
	if serial == "" do serial = "DREAMCAST"
	g := new_disc_game(letter, label, .DC, strings.to_upper(serial, context.temp_allocator), title)
	plugins_apply(&g)
	return g, true
}

// A pressed GD-ROM: a PC drive only sees its low-density area, Sega's three text files
// (the game is in the high-density area, beyond what PC drives can read).
dc_is_gdrom :: proc(letter: rune) -> bool {
	for name in ([]string{"ABSTRACT.TXT", "BIBLIOGR.TXT"}) {
		if !os.exists(fmt.tprintf("%c:\\%s", letter, name)) do return false
	}
	data, err := os.read_entire_file(fmt.tprintf("%c:\\COPYRIGH.TXT", letter), context.temp_allocator)
	return err == nil && strings.contains(string(data), "SEGA")
}

Dc_Track :: struct {
	number:  int,
	audio:   bool,
	mode:    int, // data tracks: 1 or 2
	lba:     int,
	length:  int,
	session: int,
}

IOCTL_CDROM_READ_TOC_EX :: 0x00024054
CDROM_READ_TOC_EX_FORMAT_FULL_TOC :: 2

// track number -> session number, from the drive's full TOC
dc_read_sessions :: proc(h: win.HANDLE) -> (of_track: [100]u8, ok: bool) {
	input: [4]u8
	input[0] = CDROM_READ_TOC_EX_FORMAT_FULL_TOC | 0x80 // Format (low 4 bits), Msf (top bit)
	input[1] = 1 // first session
	raw: [4 + 300 * 11]u8
	got: u32
	if !win.DeviceIoControl(h, IOCTL_CDROM_READ_TOC_EX, &input[0], len(input), &raw[0], len(raw), &got, nil) || got < 4 do return
	n := ((int(raw[0]) << 8 | int(raw[1])) + 2 - 4) / 11 // length field excludes itself
	for i in 0 ..< n {
		if 4 + i * 11 + 11 > int(got) do break
		e := raw[4 + i * 11:]
		session, point := int(e[0]), int(e[3]) // descriptor: session, ctrl/adr, tno, point, ...
		if point >= 1 && point <= 99 && session < 256 do of_track[point] = u8(session)
	}
	return of_track, true
}

// Track lengths and sessions. A track ends where the next one starts; the last track of a
// session ends DC_SESSION_GAP sectors before the next session, which is exactly where Flycast's
// cue parser puts that session, so every sector keeps its real address. Caller deletes.
dc_layout :: proc(h: win.HANDLE, toc: ^Cd_Toc) -> []Dc_Track {
	sessions, has_sessions := dc_read_sessions(h)
	session_of :: proc(s: ^[100]u8, has: bool, track: int) -> int {
		return has && track < 100 ? max(int(s[track]), 1) : 1
	}
	tracks := make([]Dc_Track, toc.count)
	for ti in 0 ..< toc.count {
		t := toc.tracks[ti]
		session := session_of(&sessions, has_sessions, t.number)
		end := toc.leadout
		if ti + 1 < toc.count {
			next := toc.tracks[ti + 1]
			end = next.lba
			if session_of(&sessions, has_sessions, next.number) != session do end = next.lba - DC_SESSION_GAP
		}
		tracks[ti] = Dc_Track{number = t.number, audio = t.audio, mode = 2, lba = t.lba, length = max(end - t.lba, 1), session = session}
	}
	return tracks
}

dc_cache_root :: proc() -> string {
	return retro_dir("cache", "dc")
}

// Copies the disc in `letter` (unless already cached) and returns the .cue path to boot.
dc_prepare :: proc(g: ^Game) -> (cue_path: string, ok: bool, err: string) {
	if g.gdrom do return "", false, "Pressed Dreamcast GD-ROMs can't be read by PC drives; only burned self-boot CD-Rs play"
	letter := g.disc_letter
	vol, present := volume_serial(letter)
	if !present do return "", false, fmt.tprintf("No disc in %c:", letter)
	dir := path_join({dc_cache_root(), fmt.tprintf("%08X", vol)})
	cue := path_join({dir, "disc.cue"})
	if os.exists(path_join({dir, "complete"})) && os.exists(cue) do return cue, true, ""

	// keep only one copy: Dreamcast CD-Rs are up to 700 MB each
	os.make_directory_all(dc_cache_root())
	if fis, e := os.read_all_directory_by_path(dc_cache_root(), context.allocator); e == nil {
		for fi in fis do if fi.type == .Directory do os.remove_all(fi.fullpath)
		os.file_info_slice_delete(fis, context.allocator)
	}
	os.make_directory_all(dir)

	if _, opened := cd_open(letter); !opened do return "", false, fmt.tprintf("Couldn't read the disc in %c:", letter)
	defer cd_close()
	tracks := dc_layout(cd.handle, &cd.toc)
	defer delete(tracks)
	total := 0
	for t in tracks do total += t.length

	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	multi := tracks[len(tracks) - 1].session > 1
	session := 0
	done := 0
	buf := make([]u8, DC_RIP_CHUNK * RAW_SECTOR)
	defer delete(buf)
	last_draw := -1.0
	for &t in tracks {
		name := fmt.tprintf("track%02d.bin", t.number)
		f, ferr := os.open(path_join({dir, name}), {.Write, .Create, .Trunc})
		if ferr != nil do return "", false, "Couldn't write the disc copy (disk full?)"
		for s := 0; s < t.length; {
			n := min(DC_RIP_CHUNK, t.length - s)
			got := cd_read_bin(cd.gen, i64(t.lba + s) * RAW_SECTOR, buf[:n * RAW_SECTOR])
			if got != i64(n * RAW_SECTOR) {
				os.close(f)
				return "", false, "The disc was removed while copying"
			}
			if s == 0 && !t.audio do t.mode = buf[15] == 1 ? 1 : 2
			if _, werr := os.write(f, buf[:n * RAW_SECTOR]); werr != nil {
				os.close(f)
				return "", false, "Couldn't write the disc copy (disk full?)"
			}
			s += n
			done += n
			if now := rl.GetTime(); now - last_draw > 0.05 {
				last_draw = now
				if !dc_draw_progress(g, f32(done) / f32(max(total, 1))) {
					os.close(f)
					return "", false, "Cancelled"
				}
			}
		}
		os.close(f)
		if multi && t.session != session {
			session = t.session
			fmt.sbprintf(&sb, "REM SESSION %02d\r\n", session)
		}
		fmt.sbprintf(&sb, "FILE \"%s\" BINARY\r\n", name)
		fmt.sbprintf(&sb, "  TRACK %02d %s\r\n", t.number, t.audio ? "AUDIO" : t.mode == 1 ? "MODE1/2352" : "MODE2/2352")
		fmt.sbprintf(&sb, "    INDEX 01 00:00:00\r\n")
	}
	if os.write_entire_file(cue, strings.to_string(sb)) != nil do return "", false, "Couldn't write the disc copy"
	_ = os.write_entire_file(path_join({dir, "complete"}), "")
	retro_log_line("[dc] copied %d sectors of %c: to %s", total, letter, dir)
	return cue, true, ""
}

// One frame of the copy screen. false = the player cancelled.
dc_draw_progress :: proc(g: ^Game, t: f32) -> bool {
	input_poll()
	if input.cancel || rl.IsKeyPressed(.ESCAPE) || (rl.WindowShouldClose() && !app.in_shell) do return false
	keep_fullscreen()
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())
	rl.BeginDrawing()
	rl.ClearBackground(COL_BG)
	pw: f32 = 600
	r := rl.Rectangle{(w - pw) * 0.5, h * 0.5 - 100, pw, 200}
	draw_panel(r, false, COL_PANEL_SOLID)
	draw_t_fit(g.title, r.x + 28, r.y + 26, r.width - 56, 22, COL_ACCENT, false)
	draw_t_fit("Copying the disc so the Dreamcast emulator can read it (first play only)", r.x + 28, r.y + 66, r.width - 56 - 64, 17, COL_TEXT, false)
	draw_t_right(fmt.tprintf("%d%%", int(t * 100)), r.x + r.width - 28, r.y + 66, 17, COL_TEXT)
	bar := rl.Rectangle{r.x + 28, r.y + 110, r.width - 56, 10}
	rl.DrawRectangleRounded(bar, 1, 8, COL_FAINT)
	rl.DrawRectangleRounded({bar.x, bar.y, max(bar.height, bar.width * t), bar.height}, 1, 8, COL_ACCENT)
	draw_hints(w, h, []Hint{{"B", "Cancel"}})
	rl.EndDrawing()
	return true
}
