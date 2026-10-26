package saber

// Built-in libretro frontend (ported from SimpRetro): runs a core inside Saber's own
// window, so console games play without leaving the launcher. Video is software-rendered
// frames uploaded to a raylib texture; audio goes through a raylib AudioStream (raylib
// already owns miniaudio). Disc games read the physical drive through retro_disc.odin.
//
//   APP/libretro/cores/   *_libretro.dll
//   APP/libretro/system/  BIOS files (e.g. scph1001.bin)
//   APP/libretro/saves/<platform>/   memory card (shared, like a real console) + save states
//   APP/libretro/options.ini         optional core option overrides (key=value)
//   APP/libretro/retro.log           core log of the last session

import "base:runtime"
import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import rl "vendor:raylib"
import win "core:sys/windows"

Retro_Platform :: enum {
	None,
	PS1,
	PS2,
	PSP,
	DC, // burned self-boot CD-Rs (retro_dreamcast.odin)
	// cartridge systems: one ROM file on a drive (roms.odin)
	GB,
	GBC,
	GBA,
	NES,
	SNES,
	N64,
	MD,
	SMS,
	GG,
	NDS,
	PCE,
	A2600,
}

RETRO_PLATFORM_NAME := [Retro_Platform]string {
	.None  = "",
	.PS1   = "PlayStation",
	.PS2   = "PlayStation 2",
	.PSP   = "PlayStation Portable",
	.DC    = "Dreamcast",
	.GB    = "Game Boy",
	.GBC   = "Game Boy Color",
	.GBA   = "Game Boy Advance",
	.NES   = "NES",
	.SNES  = "Super Nintendo",
	.N64   = "Nintendo 64",
	.MD    = "Mega Drive / Genesis",
	.SMS   = "Master System",
	.GG    = "Game Gear",
	.NDS   = "Nintendo DS",
	.PCE   = "PC Engine / TurboGrafx-16",
	.A2600 = "Atari 2600",
}
RETRO_PLATFORM_DIR := [Retro_Platform]string {
	.None  = "",
	.PS1   = "ps1",
	.PS2   = "ps2",
	.PSP   = "psp",
	.DC    = "dc",
	.GB    = "gb",
	.GBC   = "gbc",
	.GBA   = "gba",
	.NES   = "nes",
	.SNES  = "snes",
	.N64   = "n64",
	.MD    = "md",
	.SMS   = "sms",
	.GG    = "gg",
	.NDS   = "nds",
	.PCE   = "pce",
	.A2600 = "a2600",
}

// First core found wins.
RETRO_CORES := [Retro_Platform][]string {
	.None  = {},
	.PS1   = {"swanstation_libretro.dll", "mednafen_psx_hw_libretro.dll", "mednafen_psx_libretro.dll", "pcsx_rearmed_libretro.dll"},
	.PS2   = {"pcsx2_libretro.dll"},
	.PSP   = {"ppsspp_libretro.dll"},
	.DC    = {"flycast_libretro.dll"},
	.GB    = {"gambatte_libretro.dll", "sameboy_libretro.dll", "mgba_libretro.dll"},
	.GBC   = {"gambatte_libretro.dll", "sameboy_libretro.dll", "mgba_libretro.dll"},
	.GBA   = {"mgba_libretro.dll", "vbam_libretro.dll", "vba_next_libretro.dll"},
	.NES   = {"mesen_libretro.dll", "nestopia_libretro.dll", "fceumm_libretro.dll", "quicknes_libretro.dll"},
	.SNES  = {"snes9x_libretro.dll", "bsnes_libretro.dll", "snes9x2010_libretro.dll"},
	.N64   = {"mupen64plus_next_libretro.dll", "parallel_n64_libretro.dll"},
	.MD    = {"genesis_plus_gx_libretro.dll", "picodrive_libretro.dll"},
	.SMS   = {"genesis_plus_gx_libretro.dll", "picodrive_libretro.dll"},
	.GG    = {"genesis_plus_gx_libretro.dll"},
	.NDS   = {"melondsds_libretro.dll", "melonds_libretro.dll", "desmume_libretro.dll"},
	.PCE   = {"mednafen_pce_fast_libretro.dll", "mednafen_pce_libretro.dll"},
	.A2600 = {"stella_libretro.dll", "stella2014_libretro.dll"},
}

// Saber only presents software frames, so make cores pick their software renderer.
RETRO_OPTION_DEFAULTS := [?][2]string {
	{"swanstation_GPU_Renderer", "Software"},
}

Retro_Option :: struct {
	key:     cstring,
	desc:    string, // shown in the emulation menu
	values:  [dynamic]cstring,
	current: int,
}

Retro :: struct {
	core:            Core_API,
	av:              System_AV_Info,
	pixel_format:    Pixel_Format,
	ctx:             runtime.Context,
	quit:            bool,

	frame:           [dynamic]u8, // RGBA8 copy of the last frame
	frame_w:         i32,
	frame_h:         i32,
	frame_dirty:     bool,
	tex:             rl.Texture2D,
	has_tex:         bool,

	options:         [dynamic]Retro_Option,
	options_dirty:   bool,
	overrides:       map[string]string,

	disk:            Disk_Control,
	has_disk:        bool,
	disc_letter:     u8,
	disc_present:    bool,
	disc_serial:     u32,
	disc_path_c:     cstring,
	disc_iso:        bool, // the disc is served as .iso (cd_open_iso), not .cue/.bin
	disc_check_at:   f64,
	rom_data:        []byte, // ROM games whose core wants the file in memory (need_fullpath = false)

	frame_time_cb:   Frame_Time_Callback,
	last_run:        time.Tick,
	has_run:         bool,

	joy:             [4]u16,
	analog:          [4][2][2]i16, // port, stick, axis
	trigger:         [4][2]i16,
	block_input:     bool, // after the overlay closes, until every button is released
	single_samples:  [dynamic]i16,
	controller_ports: int,
	controller_dev:  u32,

	system_dir_c:    cstring,
	saves_dir_c:     cstring,
	core_path_c:     cstring,
	assets_dir_c:    cstring,
	game_path_c:     cstring,
	sram_path:       string,
	state_path:      string,
	sram_snapshot:   []byte,
	sram_check:      f64,

	osd_buf:         [128]u8,
	osd:             string,
	osd_until:       f64,

	log_lock:        sync.Mutex,
	log_file:        ^os.File,
}

retro: Retro

// ---------------------------------------------------------------------------
// Audio: the core's samples go into a lock-free ring that raylib's audio thread drains.

RING_FRAMES :: 1 << 15 // power of two

Retro_Audio :: struct {
	stream:    rl.AudioStream,
	ok:        bool,
	rate:      f64,
	ring:      [RING_FRAMES * 2]i16,
	read_pos:  u64, // written by the audio thread
	write_pos: u64, // written by the main thread
	produced:  bool,
}

raudio: Retro_Audio

retro_audio_callback :: proc "c" (buffer: rawptr, frames: c.uint) {
	out := ([^]i16)(buffer)
	r := sync.atomic_load_explicit(&raudio.read_pos, .Relaxed)
	w := sync.atomic_load_explicit(&raudio.write_pos, .Acquire)
	n := min(u64(frames), w - r)
	for i in 0 ..< n {
		idx := ((r + i) & (RING_FRAMES - 1)) * 2
		out[i * 2 + 0] = raudio.ring[idx + 0]
		out[i * 2 + 1] = raudio.ring[idx + 1]
	}
	for i in n ..< u64(frames) {
		out[i * 2 + 0] = 0
		out[i * 2 + 1] = 0
	}
	sync.atomic_store_explicit(&raudio.read_pos, r + n, .Release)
}

retro_audio_open :: proc(rate: f64) {
	retro_audio_close()
	raudio.rate = rate > 0 ? rate : 44100
	rl.SetAudioStreamBufferSizeDefault(1024)
	raudio.stream = rl.LoadAudioStream(c.uint(raudio.rate + 0.5), 16, 2)
	if !rl.IsAudioStreamValid(raudio.stream) do return
	rl.SetAudioStreamCallback(raudio.stream, retro_audio_callback)
	rl.SetAudioStreamVolume(raudio.stream, emu_volume())
	rl.PlayAudioStream(raudio.stream)
	raudio.ok = true
}

retro_audio_close :: proc() {
	if raudio.ok {
		rl.StopAudioStream(raudio.stream)
		rl.UnloadAudioStream(raudio.stream)
		raudio.ok = false
	}
	sync.atomic_store(&raudio.read_pos, 0)
	sync.atomic_store(&raudio.write_pos, 0)
}

retro_audio_buffered :: proc() -> u64 {
	return sync.atomic_load(&raudio.write_pos) - sync.atomic_load(&raudio.read_pos)
}

retro_audio_push :: proc(data: [^]i16, frames: int) {
	if !raudio.ok || frames <= 0 do return
	if emu.speed != EMU_SPEED_DEFAULT do return // slow motion / fast forward: silent, paced by the clock
	raudio.produced = true
	w := sync.atomic_load_explicit(&raudio.write_pos, .Relaxed)
	r := sync.atomic_load_explicit(&raudio.read_pos, .Acquire)
	for i in 0 ..< frames {
		if w - r >= RING_FRAMES do break // overflow: drop
		idx := (w & (RING_FRAMES - 1)) * 2
		raudio.ring[idx + 0] = data[i * 2 + 0]
		raudio.ring[idx + 1] = data[i * 2 + 1]
		w += 1
	}
	sync.atomic_store_explicit(&raudio.write_pos, w, .Release)
}

// ---------------------------------------------------------------------------
// Discs

// A PlayStation disc in an optical drive (SYSTEM.CNF with BOOT=, or a PSP disc's
// UMD_DATA.BIN) becomes a Main-screen game.
disc_game :: proc(letter: rune, label: string) -> (Game, bool) {
	if g, ok := psp_disc_game(letter, label); ok do return g, true
	label := label
	data, err := os.read_entire_file(fmt.tprintf("%c:\\SYSTEM.CNF", letter), context.temp_allocator)
	if err != nil {
		// burned discs whose mounted UDF side hides the game; its volume label is bogus too
		ok: bool
		data, ok = iso_read_root_file(u8(letter), "SYSTEM.CNF", allocator = context.temp_allocator)
		if !ok do return dc_disc_game(letter, label)
		label = ""
	}
	serial := ""
	platform := Retro_Platform.None
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		k, _, v := strings.partition(line, "=")
		k = strings.trim_space(k)
		if k == "BOOT2" {
			serial, platform = serial_from_boot(v), .PS2
		} else if k == "BOOT" && platform == .None {
			serial, platform = serial_from_boot(v), .PS1
		}
	}
	if serial == "" do return {}, false

	g := new_disc_game(letter, label, platform, serial)
	plugins_apply(&g)
	return g, true
}

new_disc_game :: proc(letter: rune, label: string, platform: Retro_Platform, serial: string, title := "") -> Game {
	g: Game
	g.root = fmt.aprintf("%c:\\", letter)
	g.drive_label = strings.clone(label)
	g.from_drive = true
	g.platform = platform
	g.meta_platform = platform
	g.disc_letter = u8(letter)
	g.disc_serial = strings.clone(serial)
	has_label := label != "" && !strings.has_suffix(label, ":")
	switch {
	case title != "": g.title = strings.clone(title)
	case has_label:   g.title = strings.clone(label)
	case:             g.title = fmt.aprintf("%s Disc", RETRO_PLATFORM_NAME[platform])
	}
	if disc_is_recordable(u8(letter)) {
		// named after the disc's own label, else the drive
		g.mod_name = has_label ? strings.clone(label) : fmt.aprintf("Drive %c", letter)
	}
	return g
}

// PSP: UMD_DATA.BIN starts with "ULUS-10540|..."; PSP_GAME/PARAM.SFO has the title,
// PSP_GAME/ICON0.PNG is the disc's own icon (shown until a plugin supplies a cover).
psp_disc_game :: proc(letter: rune, label: string) -> (Game, bool) {
	umd, err := os.read_entire_file(fmt.tprintf("%c:\\UMD_DATA.BIN", letter), context.temp_allocator)
	if err != nil do return {}, false
	serial, _, _ := strings.partition(string(umd), "|")
	serial = strings.to_upper(strings.trim_space(serial), context.temp_allocator)
	if len(serial) < 9 do return {}, false
	title := ""
	if sfo, e := os.read_entire_file(fmt.tprintf("%c:\\PSP_GAME\\PARAM.SFO", letter), context.temp_allocator); e == nil {
		title = sfo_string(sfo, "TITLE")
	}
	g := new_disc_game(letter, label, .PSP, serial, title)
	icon := fmt.tprintf("%c:\\PSP_GAME\\ICON0.PNG", letter)
	if os.exists(icon) do game_set_box(&g, icon)
	plugins_apply(&g)
	return g, true
}

// A string entry of a PSP PARAM.SFO.
sfo_string :: proc(d: []byte, key: string) -> string {
	le :: proc(b: []byte, n: int) -> int {
		v := 0
		for i in 0 ..< n do v |= int(b[i]) << uint(8 * i)
		return v
	}
	if len(d) < 20 || string(d[:4]) != "\x00PSF" do return ""
	keys, data, n := le(d[8:], 4), le(d[12:], 4), le(d[16:], 4)
	for i in 0 ..< n {
		e := 20 + i * 16
		if e + 16 > len(d) do break
		ko, ln, off := keys + le(d[e:], 2), le(d[e + 4:], 4), data + le(d[e + 12:], 4)
		if ko >= len(d) || off + ln > len(d) do break
		end := strings.index_byte(string(d[ko:]), 0)
		if end < 0 || string(d[ko:][:end]) != key do continue
		return strings.trim_right(string(d[off:][:ln]), "\x00")
	}
	return ""
}

// Replaces characters Windows doesn't allow in file names.
safe_file_name :: proc(s: string) -> string {
	b := transmute([]byte)strings.clone(strings.trim_space(s), context.temp_allocator)
	for &c in b do if strings.index_byte(`<>:"/\|?*`, c) >= 0 || c < 32 do c = '_'
	return string(b)
}

// "cdrom:\SLUS_008.92;1" -> "SLUS-00892"
serial_from_boot :: proc(v: string) -> string {
	s := v
	if i := strings.last_index_any(s, "\\:"); i >= 0 do s = s[i + 1:]
	if i := strings.index_byte(s, ';'); i >= 0 do s = s[:i]
	s, _ = strings.replace_all(strings.trim_space(s), "_", "-", context.temp_allocator)
	s, _ = strings.replace_all(s, ".", "", context.temp_allocator)
	return strings.to_upper(s, context.temp_allocator)
}

volume_serial :: proc(letter: u8) -> (serial: u32, present: bool) {
	root := [4]u16{u16(letter), ':', '\\', 0}
	ok := GetVolumeInformationW(win.LPCWSTR(raw_data(root[:])), nil, 0, &serial, nil, nil, nil, 0)
	return serial, bool(ok)
}

// Optical drives are polled on a background thread: while a freshly inserted disc spins
// up, GetVolumeInformationW blocks for seconds, which froze the UI (and stuttered games
// during disc swaps). The main thread only reads the results.

MEDIA_POLL_MS :: 1000

Media_Watch :: struct {
	slots:   [26]u64, // atomic: bit 32 = disc present, low 32 bits = volume serial
	sig:     u64,     // atomic: changes whenever a disc is inserted, removed or swapped
	ready:   bool,    // atomic: first full pass done
	started: bool,
}

media: Media_Watch

media_watch_start :: proc() {
	if media.started do return
	media.started = true
	thread.run(media_watch_loop)
}

media_watch_loop :: proc() {
	for {
		sig: u64
		mask := current_drive_mask()
		for i in 0 ..< 26 {
			slot: u64
			if mask & (u32(1) << u32(i)) != 0 {
				root := [4]u16{u16('A' + i), ':', '\\', 0}
				if GetDriveTypeW(win.LPCWSTR(raw_data(root[:]))) == DRIVE_CDROM {
					if serial, ok := volume_serial(u8('A' + i)); ok {
						slot = 1 << 32 | u64(serial)
						sig = sig * 31 + u64(serial) + u64(i + 1)
					}
				}
			}
			sync.atomic_store(&media.slots[i], slot)
		}
		sync.atomic_store(&media.sig, sig)
		sync.atomic_store(&media.ready, true)
		free_all(context.temp_allocator)
		win.Sleep(MEDIA_POLL_MS)
	}
}

optical_media_signature :: proc() -> u64 {
	return sync.atomic_load(&media.sig)
}

// Last polled state of the disc in `letter`; never blocks. ok = false until the first poll finished.
media_volume :: proc(letter: u8) -> (serial: u32, present: bool, ok: bool) {
	if !sync.atomic_load(&media.ready) do return
	slot := sync.atomic_load(&media.slots[(letter | 0x20) - 'a'])
	return u32(slot), slot >> 32 != 0, true
}

// ---------------------------------------------------------------------------
// Session

retro_dir :: proc(parts: ..string) -> string {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, app.exe_dir, "libretro")
	append(&all, ..parts)
	return path_join(all[:])
}

// The core picked in the emulation menu wins; otherwise the first installed candidate.
find_retro_core :: proc(p: Retro_Platform) -> (string, bool) {
	emu_init()
	if pref, ok := emu.cores[RETRO_PLATFORM_DIR[p]]; ok {
		if path, found := emu_core_installed(pref); found do return path, true
	}
	for name in RETRO_CORES[p] {
		if path, found := emu_core_installed(name); found do return path, true
	}
	return "", false
}

// Plays a disc game in Saber's window. Blocks until the player quits.
retro_play :: proc(g: ^Game) -> (ok: bool, err: string) {
	if g.gdrom {
		_, _, why := dc_prepare(g) // only explains why it can't play
		return false, why
	}
	core_path, has_core := find_retro_core(g.platform)
	if !has_core {
		return false, fmt.tprintf("No %s core: put %s in APP\\libretro\\cores", RETRO_PLATFORM_NAME[g.platform], RETRO_CORES[g.platform][0])
	}
	is_rom := g.rom_path != ""
	// PS1 gets raw sectors behind a generated .cue; PSP and PS2 (DVD and CD alike) a plain .iso
	retro_iso := g.platform == .PSP || g.platform == .PS2
	cue: string
	if is_rom {
		if !os.exists(g.rom_path) do return false, fmt.tprintf("Couldn't find %s", g.rom_path)
		cue = strings.clone(g.rom_path)
	} else if g.platform == .DC {
		// Flycast can't use the live VFS disc: boot a copy on disk (made on first play)
		dc_ok: bool
		dc_err: string
		if cue, dc_ok, dc_err = dc_prepare(g); !dc_ok do return false, dc_err
	} else {
		disc_ok: bool
		cue, disc_ok = retro_open_disc(g.disc_letter, retro_iso)
		if !disc_ok do return false, fmt.tprintf("Couldn't read the disc in %c:", g.disc_letter)
	}

	emu_init()
	retro = {}
	retro.ctx = context
	emu_filter_tex = 0
	retro.disc_letter = g.platform == .DC ? 0 : g.disc_letter // no live disc swaps for a copied disc
	retro.disc_iso = retro_iso
	if !is_rom && g.platform != .DC do retro.disc_serial, retro.disc_present = volume_serial(g.disc_letter)
	plat := RETRO_PLATFORM_DIR[g.platform]
	saves := retro_dir("saves", plat)
	os.make_directory(retro_dir())
	os.make_directory(retro_dir("saves"))
	os.make_directory(saves)
	os.make_directory(retro_dir("system"))
	retro.system_dir_c = strings.clone_to_cstring(retro_dir("system"))
	retro.saves_dir_c = strings.clone_to_cstring(saves)
	retro.assets_dir_c = strings.clone_to_cstring(retro_dir())
	retro.core_path_c = strings.clone_to_cstring(core_path)
	// a modded (burned) disc gets its own memory card and states: "<serial>-<disc name>"
	save_key := g.disc_serial
	if g.mod_name != "" do save_key = fmt.tprintf("%s-%s", g.disc_serial, safe_file_name(g.mod_name))
	retro.sram_path = path_join({saves, g.mod_name != "" ? fmt.tprintf("Memory Card-%s.srm", save_key) : "Memory Card.srm"})
	if is_rom {
		// cartridges keep their save with the game, named after the ROM file
		save_key = safe_file_name(g.rom_name)
		delete(retro.sram_path)
		retro.sram_path = path_join({saves, fmt.tprintf("%s.srm", save_key)})
	}
	retro.state_path = path_join({saves, fmt.tprintf("%s.state", save_key)})
	retro_log_open()
	retro_load_overrides()
	defer retro_free()

	if _, loaded := dynlib.initialize_symbols(&retro.core, core_path, "retro_", "__handle"); !loaded {
		cd_close()
		return false, fmt.tprintf("Couldn't load %s", core_path)
	}
	defer dynlib.unload_library(retro.core.__handle)

	// RetroArch's order: environment, init, then the other callbacks. Some cores (Mesen)
	// only create the objects those setters write to in retro_init.
	retro.core.set_environment(retro_environment)
	retro.core.init()
	retro.core.set_video_refresh(retro_video_refresh)
	retro.core.set_audio_sample(retro_audio_sample)
	retro.core.set_audio_sample_batch(retro_audio_sample_batch)
	retro.core.set_input_poll(retro_input_poll)
	retro.core.set_input_state(retro_input_state)

	retro.game_path_c = strings.clone_to_cstring(cue)
	delete(cue)
	info := Game_Info{path = retro.game_path_c}
	if is_rom {
		sys: System_Info
		retro.core.get_system_info(&sys)
		if !sys.need_fullpath {
			data, err := os.read_entire_file(g.rom_path, context.allocator)
			if err != nil {
				retro.core.deinit()
				return false, fmt.tprintf("Couldn't read %s", g.rom_path)
			}
			retro.rom_data = data
			info.data, info.size = raw_data(data), c.size_t(len(data))
		}
	}
	if !retro.core.load_game(&info) {
		retro.core.deinit()
		cd_close()
		if is_rom do return false, "The emulator couldn't load this game (missing BIOS in APP\\libretro\\system?)"
		bios_dir := g.platform == .PS2 ? "system\\pcsx2\\bios" : "system"
		return false, fmt.tprintf("The emulator couldn't boot this disc (missing BIOS in APP\\libretro\\%s?)", bios_dir)
	}
	retro.core.get_system_av_info(&retro.av)
	if !retro_hw_start(i32(retro.av.geometry.max_width), i32(retro.av.geometry.max_height)) {
		retro_hw_stop()
		retro.core.unload_game()
		retro.core.deinit()
		cd_close()
		return false, "Couldn't create the OpenGL context this emulator needs"
	}
	retro_sram_load()
	retro_apply_controller()

	theme_pause_for_game()
	sfx_start()
	retro_audio_open(retro.av.timing.sample_rate)
	rl.SetTargetFPS(0) // paced by audio + vsync instead
	guide_reset()
	started := rl.GetTime()
	retro_run_loop(g)
	g.playtime_seconds += int(rl.GetTime() - started)

	retro_sram_save()
	retro_audio_close()
	retro_hw_begin()
	if rhw.ready && rhw.cb.context_destroy != nil do rhw.cb.context_destroy()
	rhw.cb.context_destroy = nil
	retro.core.unload_game()
	retro.core.deinit()
	retro_hw_end()
	retro_hw_stop()
	cd_close()
	rl.SetTargetFPS(TARGET_FPS)
	theme_resume_after_game()
	eat_input()
	return true, ""
}

retro_open_disc :: proc(letter: u8, iso: bool) -> (string, bool) {
	if iso do return cd_open_iso(letter)
	return cd_open(letter)
}

retro_free :: proc() {
	if retro.has_tex do rl.UnloadTexture(retro.tex)
	for &o in retro.options {
		delete(o.key)
		delete(o.desc)
		for v in o.values do delete(v)
		delete(o.values)
	}
	delete(retro.options)
	for k, v in retro.overrides {
		delete(k)
		delete(v)
	}
	delete(retro.overrides)
	delete(retro.frame)
	delete(retro.single_samples)
	delete(retro.sram_snapshot)
	delete(retro.system_dir_c)
	delete(retro.saves_dir_c)
	delete(retro.assets_dir_c)
	delete(retro.core_path_c)
	delete(retro.game_path_c)
	delete(retro.disc_path_c)
	delete(retro.rom_data)
	delete(retro.sram_path)
	delete(retro.state_path)
	if retro.log_file != nil do os.close(retro.log_file)
	retro.log_file = nil
}

retro_run_loop :: proc(g: ^Game) {
	next_frame := time.tick_now()
	for !retro.quit {
		if rl.WindowShouldClose() && !app.in_shell do break
		keep_fullscreen()

		if retro_pause_pressed() {
			rl.PauseAudioStream(raudio.stream)
			retro_pause_menu(g)
			rl.ResumeAudioStream(raudio.stream)
			retro.block_input = true
			retro.has_run = false
			next_frame = time.tick_now()
			if retro.quit do break
		}

		if retro.disc_letter != 0 do retro_watch_disc()
		retro_update_input()
		retro_run_frame()
		retro_upload_frame()

		w := f32(rl.GetScreenWidth())
		h := f32(rl.GetScreenHeight())
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		retro_draw_frame(w, h, rl.WHITE)
		retro_draw_osd(w, h)
		rl.EndDrawing()

		retro_sram_autosave()
		retro_pace(&next_frame)
		free_all(context.temp_allocator)
	}
}

retro_run_frame :: proc() {
	if retro.frame_time_cb.callback != nil {
		now := time.tick_now()
		usec := retro.frame_time_cb.reference
		if retro.has_run do usec = i64(time.tick_diff(retro.last_run, now) / time.Microsecond)
		retro.last_run = now
		retro.frame_time_cb.callback(usec)
	}
	retro.has_run = true
	raudio.produced = false
	retro_hw_begin()
	retro.core.run()
	retro_hw_end()
	retro_flush_single_samples()
}

retro_pace :: proc(next_frame: ^time.Tick) {
	if raudio.ok && raudio.produced {
		// Audio-driven: wait until the device has drained down to the target latency.
		target := u64(raudio.rate * emu_audio_target_sec())
		start := time.tick_now()
		for retro_audio_buffered() > target && time.tick_since(start) < 100 * time.Millisecond {
			win.Sleep(1)
		}
		next_frame^ = time.tick_now()
		return
	}
	fps := retro.av.timing.fps > 0 ? retro.av.timing.fps : 60
	fps *= emu_speed()
	next_frame^ = time.tick_add(next_frame^, time.Duration(f64(time.Second) / fps))
	ahead := time.tick_diff(time.tick_now(), next_frame^)
	if ahead < -100 * time.Millisecond || ahead > 100 * time.Millisecond {
		next_frame^ = time.tick_now()
		return
	}
	for time.tick_diff(time.tick_now(), next_frame^) > 2 * time.Millisecond {
		win.Sleep(1)
	}
}

// ---------------------------------------------------------------------------
// Disc swapping: open the tray, put the next disc in, and the core sees a disc change.

DISC_CHECK_SEC :: 0.5

retro_watch_disc :: proc() {
	now := rl.GetTime()
	if now < retro.disc_check_at do return
	retro.disc_check_at = now + DISC_CHECK_SEC
	serial, present, polled := media_volume(retro.disc_letter)
	if !polled do return
	if present == retro.disc_present && serial == retro.disc_serial do return

	d := retro.disk
	if retro.disc_present {
		if retro.has_disk && d.set_eject_state != nil do d.set_eject_state(true)
		cd_close()
		retro.disc_present = false
		retro_osd("Disc ejected")
	}
	if !present do return
	cue, ok := retro_open_disc(retro.disc_letter, retro.disc_iso)
	if !ok do return
	defer delete(cue)
	retro.disc_present = true
	retro.disc_serial = serial
	if !retro.has_disk || d.add_image_index == nil || d.replace_image_index == nil || d.set_image_index == nil || d.get_num_images == nil {
		retro_osd("This core can't change discs")
		return
	}
	delete(retro.disc_path_c)
	retro.disc_path_c = strings.clone_to_cstring(cue)
	info := Game_Info{path = retro.disc_path_c}
	if d.add_image_index() {
		idx := d.get_num_images() - 1
		if d.replace_image_index(idx, &info) && d.set_image_index(idx) {
			if d.set_eject_state != nil do d.set_eject_state(false)
			retro_osd("Disc inserted")
			return
		}
	}
	retro_osd("Couldn't insert the new disc")
}

// ---------------------------------------------------------------------------
// Video

retro_video_refresh :: proc "c" (data: rawptr, width, height: c.uint, pitch: c.size_t) {
	context = retro.ctx
	if data == RETRO_HW_FRAME_BUFFER_VALID {
		rhw.frame = true
		retro.frame_w, retro.frame_h = i32(width), i32(height)
		return
	}
	if data == nil do return // dupe: keep the previous frame
	w, h := int(width), int(height)
	resize(&retro.frame, w * h * 4)
	src := ([^]u8)(data)
	dst := retro.frame[:]
	for y in 0 ..< h {
		row := src[y * int(pitch):]
		o := dst[y * w * 4:]
		switch retro.pixel_format {
		case .XRGB8888:
			for x in 0 ..< w {
				o[x * 4 + 0] = row[x * 4 + 2]
				o[x * 4 + 1] = row[x * 4 + 1]
				o[x * 4 + 2] = row[x * 4 + 0]
				o[x * 4 + 3] = 255
			}
		case .RGB565:
			px := ([^]u16)(row)
			for x in 0 ..< w {
				v := px[x]
				r, g, b := u8(v >> 11), u8(v >> 5) & 63, u8(v) & 31
				o[x * 4 + 0] = r << 3 | r >> 2
				o[x * 4 + 1] = g << 2 | g >> 4
				o[x * 4 + 2] = b << 3 | b >> 2
				o[x * 4 + 3] = 255
			}
		case .RGB1555:
			px := ([^]u16)(row)
			for x in 0 ..< w {
				v := px[x]
				r, g, b := u8(v >> 10) & 31, u8(v >> 5) & 31, u8(v) & 31
				o[x * 4 + 0] = r << 3 | r >> 2
				o[x * 4 + 1] = g << 3 | g >> 2
				o[x * 4 + 2] = b << 3 | b >> 2
				o[x * 4 + 3] = 255
			}
		}
	}
	retro.frame_w, retro.frame_h = i32(w), i32(h)
	retro.frame_dirty = true
}

retro_upload_frame :: proc() {
	if !retro.frame_dirty || retro.frame_w <= 0 || retro.frame_h <= 0 do return
	retro.frame_dirty = false
	if !retro.has_tex || retro.tex.width != retro.frame_w || retro.tex.height != retro.frame_h {
		if retro.has_tex do rl.UnloadTexture(retro.tex)
		img := rl.Image{data = raw_data(retro.frame), width = retro.frame_w, height = retro.frame_h, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
		retro.tex = rl.LoadTextureFromImage(img)
		retro.has_tex = retro.tex.id != 0
		emu_filter_tex = 0
		emu_apply_filter(retro.tex)
		return
	}
	rl.UpdateTexture(retro.tex, raw_data(retro.frame))
}

emu_filter_tex: u32 // texture the current smoothing mode was applied to
emu_filter_smooth: bool

emu_apply_filter :: proc(tex: rl.Texture2D) {
	if emu_filter_tex == tex.id && emu_filter_smooth == emu.smooth do return
	rl.SetTextureFilter(tex, emu.smooth ? .BILINEAR : .POINT)
	emu_filter_tex, emu_filter_smooth = tex.id, emu.smooth
}

retro_draw_frame :: proc(w, h: f32, tint: rl.Color) {
	tex, src := retro.tex, rl.Rectangle{0, 0, f32(retro.tex.width), f32(retro.tex.height)}
	if hw_tex, hw_src, ok := retro_hw_texture(); ok {
		tex, src = hw_tex, hw_src
	} else if !retro.has_tex {
		return
	}
	emu_apply_filter(tex)
	aspect := retro.av.geometry.aspect_ratio
	if aspect <= 0 do aspect = f32(retro.frame_w) / f32(retro.frame_h)
	switch emu.aspect {
	case .Four_Three: aspect = 4.0 / 3
	case .Sixteen_Nine: aspect = 16.0 / 9
	case .Stretch: aspect = w / h
	case .Core:
	}
	dh := h
	dw := dh * aspect
	if dw > w {
		dw = w
		dh = dw / aspect
	}
	if emu.integer_scale && emu.aspect != .Stretch {
		// largest whole multiple of the source height that still fits
		if sh := abs(src.height); sh > 0 {
			if k := f32(int(min(dh / sh, dw / (sh * aspect)))); k >= 1 {
				dh = sh * k
				dw = dh * aspect
			}
		}
	}
	dst := rl.Rectangle{(w - dw) / 2, (h - dh) / 2, dw, dh}
	rl.DrawTexturePro(tex, src, dst, {}, 0, tint)
	if emu.scanlines > 0 {
		lines := int(abs(src.height))
		if pitch := dst.height / f32(max(lines, 1)); pitch >= 2 {
			col := rl.Color{0, 0, 0, emu.scanlines == 1 ? 55 : 120}
			for i in 0 ..< lines {
				rl.DrawRectangleRec({dst.x, dst.y + f32(i) * pitch + pitch * 0.5, dst.width, pitch * 0.5}, col)
			}
		}
	}
}

retro_osd :: proc(format: string, args: ..any) {
	retro.osd = fmt.bprintf(retro.osd_buf[:], format, ..args)
	retro.osd_until = rl.GetTime() + 3
}

retro_draw_osd :: proc(w, h: f32) {
	if emu.show_fps {
		label := fmt.tprintf("%d FPS", rl.GetFPS())
		tw := measure_t(label, 18)
		rl.DrawRectangleRounded({w - tw - 40, 16, tw + 24, 34}, 0.4, 8, {0, 0, 0, 170})
		draw_t(label, w - tw - 28, 24, 18, rl.WHITE)
	}
	if retro.osd == "" || rl.GetTime() > retro.osd_until do return
	size: f32 = 22
	tw := measure_t(retro.osd, size)
	r := rl.Rectangle{24, h - 24 - size - 20, tw + 28, size + 20}
	rl.DrawRectangleRounded(r, 0.3, 8, {0, 0, 0, 190})
	draw_t(retro.osd, r.x + 14, r.y + 10, size, rl.WHITE)
}

// ---------------------------------------------------------------------------
// In-game overlay (Home / Esc)

RETRO_PAUSE_LABELS := [?]string{"Resume", "Save State", "Load State", "Emulation Settings", "Quit Game"}

retro_pause_pressed :: proc() -> bool {
	if guide_pressed(false) do return true
	if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.F1) do return true
	for p in 0 ..< i32(MAX_PADS) {
		if !rl.IsGamepadAvailable(p) do continue
		// Back + Start for pads without a usable guide button
		if rl.IsGamepadButtonDown(p, .MIDDLE_LEFT) && rl.IsGamepadButtonDown(p, .MIDDLE_RIGHT) &&
		   (rl.IsGamepadButtonPressed(p, .MIDDLE_LEFT) || rl.IsGamepadButtonPressed(p, .MIDDLE_RIGHT)) {
			return true
		}
	}
	return false
}

retro_pause_menu :: proc(g: ^Game) {
	sfx_click()
	app.pause_sel = 0
	app.pause_t = 0
	sub_buf: [128]u8
	sub := g.tags
	n := len(RETRO_PAUSE_LABELS)
	// The key/button that opened the overlay still reads as "pressed" until the next
	// EndDrawing polls events, so ignore input on the first pass or it closes instantly.
	first := true
	for {
		if rl.WindowShouldClose() && !app.in_shell {
			retro.quit = true
			return
		}
		input_poll()
		if first {
			eat_input()
			guide_pressed(false)
		}
		if input.up {
			app.pause_sel = (app.pause_sel + n - 1) % n
			sfx_click()
		}
		if input.down {
			app.pause_sel = (app.pause_sel + 1) % n
			sfx_click()
		}
		if !first && (guide_pressed(false) || input.cancel || rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.F1)) {
			sfx_back()
			return
		}
		if !first && input.extra {
			app.pause_sel = 3 // Y: straight to Emulation Settings
			input.confirm = true
		}
		if input.confirm {
			switch app.pause_sel {
			case 0:
				return
			case 1:
				sub = retro_save_state() ? "State saved" : "Couldn't save state"
				sfx_click()
			case 2:
				if retro_load_state() {
					sfx_click()
					retro_osd("State loaded")
					return
				}
				sub = fmt.bprintf(sub_buf[:], "No save state for %s yet", g.rom_path != "" ? g.title : g.disc_serial)
				sfx_back()
			case 3:
				emu_menu_run_in_game()
				if retro.quit do return
				app.pause_t = 1
				first = true
			case 4:
				sfx_back()
				retro.quit = true
				return
			}
		}

		w := f32(rl.GetScreenWidth())
		h := f32(rl.GetScreenHeight())
		app.pause_t = smooth_to(app.pause_t, 1, 12)
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		retro_draw_frame(w, h, rl.WHITE)
		rl.DrawRectangle(0, 0, i32(w), i32(h), with_alpha(COL_SHADE, u8(150 * app.pause_t)))
		if clicked := draw_modal_menu(g.title, sub, RETRO_PAUSE_LABELS[:], app.pause_sel, app.pause_t, w, h, true); clicked >= 0 {
			app.pause_sel = clicked
			input.confirm = true
		}
		draw_hints(w, h, []Hint{{"A", "Select"}, {"Y", "Settings"}, {"B", "Resume"}})
		rl.EndDrawing()
		free_all(context.temp_allocator)
		first = false
	}
}

// ---------------------------------------------------------------------------
// Input

Retro_Pad_Bind :: struct {
	button: rl.GamepadButton,
	id:     u8,
}

// Positional, like RetroArch: the bottom face button is libretro B (PlayStation Cross).
RETRO_PAD_BINDS := [?]Retro_Pad_Bind {
	{.LEFT_FACE_UP, RETRO_DEVICE_ID_JOYPAD_UP},
	{.LEFT_FACE_DOWN, RETRO_DEVICE_ID_JOYPAD_DOWN},
	{.LEFT_FACE_LEFT, RETRO_DEVICE_ID_JOYPAD_LEFT},
	{.LEFT_FACE_RIGHT, RETRO_DEVICE_ID_JOYPAD_RIGHT},
	{.RIGHT_FACE_DOWN, RETRO_DEVICE_ID_JOYPAD_B},
	{.RIGHT_FACE_RIGHT, RETRO_DEVICE_ID_JOYPAD_A},
	{.RIGHT_FACE_LEFT, RETRO_DEVICE_ID_JOYPAD_Y},
	{.RIGHT_FACE_UP, RETRO_DEVICE_ID_JOYPAD_X},
	{.LEFT_TRIGGER_1, RETRO_DEVICE_ID_JOYPAD_L},
	{.RIGHT_TRIGGER_1, RETRO_DEVICE_ID_JOYPAD_R},
	{.LEFT_THUMB, RETRO_DEVICE_ID_JOYPAD_L3},
	{.RIGHT_THUMB, RETRO_DEVICE_ID_JOYPAD_R3},
	{.MIDDLE_LEFT, RETRO_DEVICE_ID_JOYPAD_SELECT},
	{.MIDDLE_RIGHT, RETRO_DEVICE_ID_JOYPAD_START},
}

Retro_Key_Bind :: struct {
	key: rl.KeyboardKey,
	id:  u8,
}

RETRO_KEY_BINDS := [?]Retro_Key_Bind {
	{.UP, RETRO_DEVICE_ID_JOYPAD_UP},
	{.DOWN, RETRO_DEVICE_ID_JOYPAD_DOWN},
	{.LEFT, RETRO_DEVICE_ID_JOYPAD_LEFT},
	{.RIGHT, RETRO_DEVICE_ID_JOYPAD_RIGHT},
	{.X, RETRO_DEVICE_ID_JOYPAD_A},
	{.Z, RETRO_DEVICE_ID_JOYPAD_B},
	{.S, RETRO_DEVICE_ID_JOYPAD_X},
	{.A, RETRO_DEVICE_ID_JOYPAD_Y},
	{.Q, RETRO_DEVICE_ID_JOYPAD_L},
	{.W, RETRO_DEVICE_ID_JOYPAD_R},
	{.E, RETRO_DEVICE_ID_JOYPAD_L2},
	{.R, RETRO_DEVICE_ID_JOYPAD_R2},
	{.C, RETRO_DEVICE_ID_JOYPAD_L3},
	{.V, RETRO_DEVICE_ID_JOYPAD_R3},
	{.ENTER, RETRO_DEVICE_ID_JOYPAD_START},
	{.RIGHT_SHIFT, RETRO_DEVICE_ID_JOYPAD_SELECT},
	{.BACKSPACE, RETRO_DEVICE_ID_JOYPAD_SELECT},
}

stick_axis :: proc(v: f32) -> i16 {
	if abs(v) < f32(emu.deadzone) / 100 do return 0
	return i16(clamp(v, -1, 1) * 32767)
}

trigger_axis :: proc(v: f32) -> i16 {
	return i16(clamp((v + 1) / 2, 0, 1) * 32767) // raylib reports triggers as -1 (released) .. 1
}

retro_update_input :: proc() {
	retro.joy = {}
	retro.analog = {}
	retro.trigger = {}

	if retro.block_input {
		any_down := rl.GetKeyPressed() != .KEY_NULL
		for keys in emu.keys do for k in keys do if k != .KEY_NULL && rl.IsKeyDown(k) do any_down = true
		for p in 0 ..< i32(MAX_PADS) {
			if !rl.IsGamepadAvailable(p) do continue
			for b in emu.pad do if b != .UNKNOWN && rl.IsGamepadButtonDown(p, b) do any_down = true
		}
		if any_down do return
		retro.block_input = false
	}

	// Connected pads fill ports in order, whatever index raylib gave them.
	port := 0
	for p in 0 ..< i32(MAX_PADS) {
		if !rl.IsGamepadAvailable(p) do continue
		bits: u16
		for button, id in emu.pad {
			if button != .UNKNOWN && rl.IsGamepadButtonDown(p, button) do bits |= 1 << emu_joy_id(u8(id))
		}
		lt := trigger_axis(rl.GetGamepadAxisMovement(p, .LEFT_TRIGGER))
		rt := trigger_axis(rl.GetGamepadAxisMovement(p, .RIGHT_TRIGGER))
		if lt > 4000 do bits |= 1 << RETRO_DEVICE_ID_JOYPAD_L2
		if rt > 4000 do bits |= 1 << RETRO_DEVICE_ID_JOYPAD_R2
		retro.joy[port] = bits
		retro.trigger[port] = {lt, rt}
		retro.analog[port] = {
			{stick_axis(rl.GetGamepadAxisMovement(p, .LEFT_X)), stick_axis(rl.GetGamepadAxisMovement(p, .LEFT_Y))},
			{stick_axis(rl.GetGamepadAxisMovement(p, .RIGHT_X)), stick_axis(rl.GetGamepadAxisMovement(p, .RIGHT_Y))},
		}
		port += 1
		if port >= 4 do break
	}
	for keys, id in emu.keys {
		for k in keys do if k != .KEY_NULL && rl.IsKeyDown(k) do retro.joy[0] |= 1 << emu_joy_id(u8(id))
	}
}

retro_input_poll :: proc "c" () {}

retro_input_state :: proc "c" (port, device, index, id: c.uint) -> i16 {
	if port >= 4 do return 0
	switch device & RETRO_DEVICE_MASK {
	case RETRO_DEVICE_JOYPAD:
		bits := retro.joy[port]
		if id == RETRO_DEVICE_ID_JOYPAD_MASK do return i16(bits)
		if id < 16 do return i16((bits >> id) & 1)
	case RETRO_DEVICE_ANALOG:
		if index == RETRO_DEVICE_INDEX_ANALOG_BUTTON {
			if id == RETRO_DEVICE_ID_JOYPAD_L2 do return retro.trigger[port][0]
			if id == RETRO_DEVICE_ID_JOYPAD_R2 do return retro.trigger[port][1]
			if id < 16 && ((retro.joy[port] >> id) & 1) != 0 do return 0x7fff
			return 0
		}
		if index <= 1 && id <= 1 do return retro.analog[port][index][id]
	}
	return 0
}

// Some cores ignore input until a device is plugged in, like RetroArch does at start.
retro_apply_controller :: proc() {
	ports := retro.controller_ports > 0 ? min(retro.controller_ports, 4) : 2
	dev := retro.controller_dev != 0 ? retro.controller_dev : RETRO_DEVICE_JOYPAD
	for port in 0 ..< ports do retro.core.set_controller_port_device(c.uint(port), c.uint(dev))
}

// ---------------------------------------------------------------------------
// Audio callbacks

retro_audio_sample :: proc "c" (left, right: i16) {
	context = retro.ctx
	append(&retro.single_samples, left, right)
}

retro_audio_sample_batch :: proc "c" (data: [^]i16, frames: c.size_t) -> c.size_t {
	context = retro.ctx
	retro_flush_single_samples()
	retro_audio_push(data, int(frames))
	return frames
}

retro_flush_single_samples :: proc() {
	if len(retro.single_samples) == 0 do return
	retro_audio_push(raw_data(retro.single_samples), len(retro.single_samples) / 2)
	clear(&retro.single_samples)
}

// ---------------------------------------------------------------------------
// Saves

retro_save_state :: proc() -> bool {
	size := int(retro.core.serialize_size())
	if size <= 0 do return false
	buf := make([]byte, size)
	defer delete(buf)
	retro_hw_begin()
	defer retro_hw_end()
	if !retro.core.serialize(raw_data(buf), c.size_t(size)) do return false
	return os.write_entire_file(retro.state_path, buf) == nil
}

retro_load_state :: proc() -> bool {
	data, err := os.read_entire_file(retro.state_path, context.allocator)
	if err != nil do return false
	defer delete(data)
	retro_hw_begin()
	defer retro_hw_end()
	return retro.core.unserialize(raw_data(data), c.size_t(len(data)))
}

retro_sram :: proc() -> []byte {
	ptr := retro.core.get_memory_data(RETRO_MEMORY_SAVE_RAM)
	size := int(retro.core.get_memory_size(RETRO_MEMORY_SAVE_RAM))
	if ptr == nil || size <= 0 do return nil
	return ([^]byte)(ptr)[:size]
}

retro_sram_load :: proc() {
	sram := retro_sram()
	if sram == nil do return
	if data, err := os.read_entire_file(retro.sram_path, context.allocator); err == nil {
		copy(sram, data)
		delete(data)
	}
	retro.sram_snapshot = slice.clone(sram)
	retro.sram_check = rl.GetTime()
}

retro_sram_save :: proc() {
	if sram := retro_sram(); sram != nil {
		_ = os.write_entire_file(retro.sram_path, sram)
	}
}

// Writes the memory card shortly after the game changes it, so a crash never eats a save.
retro_sram_autosave :: proc() {
	now := rl.GetTime()
	if now - retro.sram_check < 5 do return
	retro.sram_check = now
	sram := retro_sram()
	if sram == nil do return
	if len(retro.sram_snapshot) == len(sram) && mem.compare(retro.sram_snapshot, sram) == 0 do return
	delete(retro.sram_snapshot)
	retro.sram_snapshot = slice.clone(sram)
	retro_sram_save()
}

// ---------------------------------------------------------------------------
// Core options

retro_set_override :: proc(k, v: string) {
	if old_k, old_v := delete_key(&retro.overrides, k); old_k != "" {
		delete(old_k)
		delete(old_v)
	}
	retro.overrides[strings.clone(k)] = strings.clone(v)
}

retro_clear_overrides :: proc() {
	for k, v in retro.overrides {
		delete(k)
		delete(v)
	}
	clear(&retro.overrides)
}

// Defaults, then options.ini, then whatever was chosen in the emulation menu.
retro_load_overrides :: proc() {
	emu_init()
	for d in RETRO_OPTION_DEFAULTS do retro_set_override(d[0], d[1])
	if data, err := os.read_entire_file(retro_dir("options.ini"), context.temp_allocator); err == nil {
		it := string(data)
		for line in strings.split_lines_iterator(&it) {
			l := strings.trim_space(line)
			if l == "" || l[0] == ';' || l[0] == '#' || l[0] == '[' do continue
			k, _, v := strings.partition(l, "=")
			k = strings.trim_space(k)
			if k == "" do continue
			retro_set_override(k, strings.trim(strings.trim_space(v), "\""))
		}
	}
	for k, v in emu.core_opts do retro_set_override(k, v)
}

// Selects the value an override asks for, else the core's default (the first one).
retro_pick_override :: proc(opt: ^Retro_Option) {
	opt.current = 0
	if want, ok := retro.overrides[string(opt.key)]; ok {
		for v, idx in opt.values do if string(v) == want do opt.current = idx
	}
}

// RETRO_ENVIRONMENT_SET_VARIABLES entries: "Description; default|b|c".
retro_set_variables :: proc(vars: [^]Retro_Variable) {
	for i := 0; vars[i].key != nil; i += 1 {
		key := string(vars[i].key)
		spec := string(vars[i].value)
		opt := Retro_Option{key = strings.clone_to_cstring(key)}
		if semi := strings.index(spec, "; "); semi >= 0 {
			opt.desc = strings.clone(spec[:semi])
			spec = spec[semi + 2:]
		}
		for v in strings.split_iterator(&spec, "|") do append(&opt.values, strings.clone_to_cstring(v))
		if len(opt.values) == 0 do append(&opt.values, strings.clone_to_cstring(""))
		retro_pick_override(&opt)
		append(&retro.options, opt)
	}
}

retro_option :: proc(key: cstring) -> ^Retro_Option {
	for &o in retro.options do if o.key == key do return &o
	return nil
}

// ---------------------------------------------------------------------------
// Environment

retro_environment :: proc "c" (cmd: c.uint, data: rawptr) -> bool {
	context = retro.ctx
	switch cmd {
	case ENV_GET_CAN_DUPE:
		(^bool)(data)^ = true
	case ENV_GET_OVERSCAN:
		(^bool)(data)^ = false
	case ENV_SET_MESSAGE:
		m := (^Retro_Message)(data)
		retro_osd("%s", string(m.msg))
	case ENV_SET_MESSAGE_EXT:
		m := (^Retro_Message_Ext)(data)
		if m.target != 2 do retro_osd("%s", string(m.msg)) // 2 = log only
	case ENV_GET_MESSAGE_INTERFACE_VERSION:
		(^c.uint)(data)^ = 1
	case ENV_SHUTDOWN:
		retro.quit = true
	case ENV_GET_SYSTEM_DIRECTORY:
		(^cstring)(data)^ = retro.system_dir_c
	case ENV_GET_SAVE_DIRECTORY:
		(^cstring)(data)^ = retro.saves_dir_c
	case ENV_GET_CORE_ASSETS_DIRECTORY:
		(^cstring)(data)^ = retro.assets_dir_c
	case ENV_GET_LIBRETRO_PATH:
		(^cstring)(data)^ = retro.core_path_c
	case ENV_SET_PIXEL_FORMAT:
		f := (^Pixel_Format)(data)^
		if f < .RGB1555 || f > .RGB565 do return false
		retro.pixel_format = f
	case ENV_SET_HW_RENDER:
		return retro_hw_request((^HW_Render_Callback)(data))
	case ENV_GET_PREFERRED_HW_RENDER:
		(^c.uint)(data)^ = c.uint(HW_Context_Type.OPENGL)
	case ENV_GET_CURRENT_SOFTWARE_FRAMEBUFFER, ENV_GET_RUMBLE_INTERFACE:
		return false
	case ENV_GET_VFS_INTERFACE:
		info := (^Vfs_Interface_Info)(data)
		if info.required_interface_version > 3 do return false
		info.required_interface_version = 3
		info.iface = &vfs_iface
	case ENV_GET_VARIABLE:
		v := (^Retro_Variable)(data)
		v.value = nil
		if v.key == nil do return false
		opt := retro_option(v.key)
		if opt == nil do return false
		v.value = opt.values[opt.current]
	case ENV_SET_VARIABLES:
		if data != nil do retro_set_variables((^Retro_Variable)(data))
	case ENV_SET_VARIABLE:
		if data == nil do return true
		v := (^Retro_Variable)(data)
		if v.key == nil || v.value == nil do return false
		opt := retro_option(v.key)
		if opt == nil do return false
		for val, i in opt.values do if val == v.value do opt.current = i
	case ENV_GET_VARIABLE_UPDATE:
		(^bool)(data)^ = retro.options_dirty
		retro.options_dirty = false
	case ENV_GET_CORE_OPTIONS_VERSION:
		(^c.uint)(data)^ = 0 // makes cores fall back to SET_VARIABLES
	case ENV_SET_CORE_OPTIONS_DISPLAY, ENV_SET_CORE_OPTIONS_UPDATE_DISPLAY_CB:
	case ENV_SET_DISK_CONTROL_INTERFACE:
		retro.disk = {}
		mem.copy(&retro.disk, data, 7 * size_of(rawptr))
		retro.has_disk = true
	case ENV_SET_DISK_CONTROL_EXT_INTERFACE:
		retro.disk = (^Disk_Control)(data)^
		retro.has_disk = true
	case ENV_GET_DISK_CONTROL_INTERFACE_VERSION:
		(^c.uint)(data)^ = 1
	case ENV_GET_INPUT_DEVICE_CAPABILITIES:
		(^u64)(data)^ = (1 << RETRO_DEVICE_JOYPAD) | (1 << RETRO_DEVICE_ANALOG)
	case ENV_GET_INPUT_BITMASKS:
	case ENV_GET_INPUT_MAX_USERS:
		(^c.uint)(data)^ = 4
	case ENV_GET_LOG_INTERFACE:
		(^rawptr)(data)^ = rawptr(retro_log)
	case ENV_GET_PERF_INTERFACE:
		(^Perf_Callback)(data)^ = {
			get_time_usec    = retro_perf_time_usec,
			get_cpu_features = retro_perf_cpu_features,
			get_perf_counter = retro_perf_counter,
			perf_register    = retro_perf_noop,
			perf_start       = retro_perf_noop,
			perf_stop        = retro_perf_noop,
			perf_log         = retro_perf_log_noop,
		}
	case ENV_SET_SYSTEM_AV_INFO:
		old_rate := retro.av.timing.sample_rate
		retro.av = (^System_AV_Info)(data)^
		if rhw.ready {
			retro_hw_begin()
			retro_hw_resize(max(rhw.w, i32(retro.av.geometry.max_width)), max(rhw.h, i32(retro.av.geometry.max_height)))
			retro_hw_end()
		}
		if raudio.ok && retro.av.timing.sample_rate != old_rate do retro_audio_open(retro.av.timing.sample_rate)
	case ENV_SET_GEOMETRY:
		g := (^Game_Geometry)(data)
		retro.av.geometry.base_width = g.base_width
		retro.av.geometry.base_height = g.base_height
		retro.av.geometry.aspect_ratio = g.aspect_ratio
	case ENV_GET_USERNAME:
		(^cstring)(data)^ = "Player"
	case ENV_GET_LANGUAGE:
		(^c.uint)(data)^ = 0
	case ENV_GET_AUDIO_VIDEO_ENABLE:
		if data != nil do (^c.int)(data)^ = 3
	case ENV_GET_FASTFORWARDING:
		(^bool)(data)^ = false
	case ENV_GET_TARGET_REFRESH_RATE:
		(^f32)(data)^ = f32(retro.av.timing.fps)
	case ENV_GET_THROTTLE_STATE:
		(^Throttle_State)(data)^ = {mode = 0, rate = f32(retro.av.timing.fps)}
	case ENV_GET_SAVESTATE_CONTEXT:
		if data != nil do (^c.int)(data)^ = 0
	case ENV_GET_JIT_CAPABLE:
		if data != nil do (^bool)(data)^ = true
	case ENV_SET_FRAME_TIME_CALLBACK:
		retro.frame_time_cb = (^Frame_Time_Callback)(data)^
	case ENV_SET_CONTROLLER_INFO:
		infos := ([^]Controller_Info)(data)
		n := 0
		for infos[n].types != nil {
			if n == 0 {
				descs := ([^]Controller_Description)(infos[n].types)
				for t in 0 ..< int(infos[n].num_types) {
					// PlayStation cores: plug in a DualShock rather than the digital pad
					if descs[t].desc != nil && strings.contains(string(descs[t].desc), "DualShock") do retro.controller_dev = u32(descs[t].id)
				}
			}
			n += 1
		}
		retro.controller_ports = n
	case ENV_SET_PERFORMANCE_LEVEL, ENV_SET_INPUT_DESCRIPTORS, ENV_SET_SUBSYSTEM_INFO, ENV_SET_MEMORY_MAPS,
	     ENV_SET_SUPPORT_ACHIEVEMENTS, ENV_SET_SERIALIZATION_QUIRKS, ENV_SET_SUPPORT_NO_GAME,
	     ENV_SET_PROC_ADDRESS_CALLBACK, ENV_SET_CONTENT_INFO_OVERRIDE, ENV_SET_HW_SHARED_CONTEXT:
	case:
		retro_log_line("[env] unhandled %d%s", cmd & 0xffff, cmd & RETRO_ENVIRONMENT_EXPERIMENTAL != 0 ? " (exp)" : "")
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Log (APP/libretro/retro.log)

retro_log_open :: proc() {
	f, err := os.open(retro_dir("retro.log"), {.Write, .Create, .Trunc})
	if err == nil do retro.log_file = f
	if nt_snprintf == nil {
		if nt := win.GetModuleHandleW(win.L("ntdll.dll")); nt != nil {
			nt_snprintf = auto_cast win.GetProcAddress(nt, "_snprintf")
		}
	}
}

retro_log_line :: proc(format: string, args: ..any) {
	if retro.log_file == nil do return
	sync.mutex_lock(&retro.log_lock)
	defer sync.mutex_unlock(&retro.log_lock)
	fmt.fprintfln(retro.log_file, format, ..args)
}

// ntdll's _snprintf, loaded at runtime: linking a CRT printf clashes with static raylib's CRT.
Snprintf_Proc :: #type proc "c" (buf: [^]u8, n: c.size_t, format: cstring, #c_vararg args: ..any) -> c.int
nt_snprintf: Snprintf_Proc

// The real signature is variadic (level, fmt, ...). On Win64 variadic args travel like
// fixed integer ones (doubles are mirrored in integer registers), so taking six spare
// slots and handing them back to snprintf formats the common cases correctly.
retro_log :: proc "c" (level: c.int, format: cstring, a0, a1, a2, a3, a4, a5: uintptr) {
	context = runtime.default_context() // may be called from core threads
	if retro.log_file == nil || format == nil || nt_snprintf == nil do return
	buf: [1024]u8
	nt_snprintf(&buf[0], len(buf) - 1, format, a0, a1, a2, a3, a4, a5)
	line := strings.trim_right(string(cstring(&buf[0])), "\r\n")
	LEVELS := [4]string{"debug", "info", "warn", "error"}
	sync.mutex_lock(&retro.log_lock)
	defer sync.mutex_unlock(&retro.log_lock)
	fmt.fprintfln(retro.log_file, "[%s] %s", LEVELS[clamp(level, 0, 3)], line)
}

retro_perf_time_usec :: proc "c" () -> i64 {
	return time.tick_now()._nsec / 1000
}
retro_perf_cpu_features :: proc "c" () -> u64 {
	return 0
}
retro_perf_counter :: proc "c" () -> u64 {
	return u64(time.tick_now()._nsec)
}
retro_perf_noop :: proc "c" (counter: ^Perf_Counter) {}
retro_perf_log_noop :: proc "c" () {}
