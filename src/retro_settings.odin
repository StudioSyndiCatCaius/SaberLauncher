package saber

// Emulation settings: one menu for the built-in libretro frontend, reachable from the
// launcher's Settings screen and from the in-game overlay (Settings). Pages:
//   Core Options  the running core's own options (in-game only)
//   Video         aspect ratio, integer scaling, filter, scanlines, FPS counter, speed
//   Audio         game volume, audio latency
//   Controls      deadzone, A/B layout, rebinding of every pad button and key
//   Cores         which core each console uses
//
//   APP/libretro/emulation.ini     everything above except core options
//   APP/libretro/options.menu.ini  core options changed in the menu (options.ini still loads first)

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

Emu_Aspect :: enum {
	Core,
	Four_Three,
	Sixteen_Nine,
	Stretch,
}

EMU_ASPECT_NAMES := [Emu_Aspect]string {
	.Core         = "Core default",
	.Four_Three   = "4:3",
	.Sixteen_Nine = "16:9",
	.Stretch      = "Stretch to screen",
}

EMU_SCANLINE_NAMES := [?]string{"Off", "Light", "Strong"}
EMU_SPEEDS := [?]int{50, 75, 100, 150, 200, 300} // percent
EMU_SPEED_DEFAULT :: 2
EMU_LATENCIES := [?]int{30, 50, 80, 120, 200} // ms of audio kept buffered
EMU_LATENCY_DEFAULT :: 1

Emu_Settings :: struct {
	loaded:        bool,
	aspect:        Emu_Aspect,
	integer_scale: bool,
	smooth:        bool, // bilinear instead of sharp pixels
	scanlines:     int,
	show_fps:      bool,
	speed:         int, // index into EMU_SPEEDS
	volume:        int, // percent
	latency:       int, // index into EMU_LATENCIES
	deadzone:      int, // percent
	swap_ab:       bool, // Nintendo layout: A/B and X/Y trade places
	pad:           [16]rl.GamepadButton, // by libretro joypad id; .UNKNOWN = unbound
	keys:          [16][2]rl.KeyboardKey, // player 1 keyboard, two slots per id
	cores:         map[string]string, // platform dir -> preferred core dll
	core_opts:     map[string]string, // core option key -> value chosen in the menu
}

emu: Emu_Settings

emu_set_default_controls :: proc() {
	emu.pad = {}
	emu.keys = {}
	for b in RETRO_PAD_BINDS do emu.pad[b.id] = b.button
	emu.pad[RETRO_DEVICE_ID_JOYPAD_L2] = .LEFT_TRIGGER_2
	emu.pad[RETRO_DEVICE_ID_JOYPAD_R2] = .RIGHT_TRIGGER_2
	for k in RETRO_KEY_BINDS {
		slot := emu.keys[k.id][0] == .KEY_NULL ? 0 : 1
		emu.keys[k.id][slot] = k.key
	}
}

emu_init :: proc() {
	if emu.loaded do return
	emu.loaded = true
	emu.volume = 70
	emu.speed = EMU_SPEED_DEFAULT
	emu.latency = EMU_LATENCY_DEFAULT
	emu.deadzone = 15
	emu_set_default_controls()

	if data, err := os.read_entire_file(retro_dir("emulation.ini"), context.temp_allocator); err == nil {
		text := string(data)
		geti :: proc(text, key: string, fallback: int) -> int {
			if v, found := ini_get(text, key); found {
				if n, ok := strconv.parse_int(v); ok do return n
			}
			return fallback
		}
		emu.aspect = Emu_Aspect(clamp(geti(text, "aspect", 0), 0, len(Emu_Aspect) - 1))
		emu.integer_scale = geti(text, "integer", 0) != 0
		emu.smooth = geti(text, "smooth", 0) != 0
		emu.scanlines = clamp(geti(text, "scanlines", 0), 0, len(EMU_SCANLINE_NAMES) - 1)
		emu.show_fps = geti(text, "fps", 0) != 0
		emu.speed = clamp(geti(text, "speed", EMU_SPEED_DEFAULT), 0, len(EMU_SPEEDS) - 1)
		emu.volume = clamp(geti(text, "volume", 70), 0, 100)
		emu.latency = clamp(geti(text, "latency", EMU_LATENCY_DEFAULT), 0, len(EMU_LATENCIES) - 1)
		emu.deadzone = clamp(geti(text, "deadzone", 15), 0, 50)
		emu.swap_ab = geti(text, "swap_ab", 0) != 0
		for id in 0 ..< 16 {
			if n := geti(text, fmt.tprintf("pad.%d", id), -1); n >= 0 && n <= int(rl.GamepadButton.RIGHT_THUMB) {
				emu.pad[id] = rl.GamepadButton(n)
			}
			for slot in 0 ..< 2 {
				if n := geti(text, fmt.tprintf("key.%d.%d", id, slot), -1); n >= 0 && n < 512 {
					emu.keys[id][slot] = rl.KeyboardKey(n)
				}
			}
		}
		for p in Retro_Platform {
			if p == .None do continue
			if v, found := ini_get(text, fmt.tprintf("core.%s", RETRO_PLATFORM_DIR[p])); found && v != "" {
				emu.cores[strings.clone(RETRO_PLATFORM_DIR[p])] = strings.clone(v)
			}
		}
	}
	emu_load_core_opts()
}

emu_save :: proc() {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "[emulation]\naspect=%d\ninteger=%d\nsmooth=%d\nscanlines=%d\nfps=%d\nspeed=%d\nvolume=%d\nlatency=%d\ndeadzone=%d\nswap_ab=%d\n",
		int(emu.aspect), int(emu.integer_scale), int(emu.smooth), emu.scanlines, int(emu.show_fps),
		emu.speed, emu.volume, emu.latency, emu.deadzone, int(emu.swap_ab))
	for id in 0 ..< 16 {
		fmt.sbprintf(&b, "pad.%d=%d\n", id, int(emu.pad[id]))
		for slot in 0 ..< 2 do fmt.sbprintf(&b, "key.%d.%d=%d\n", id, slot, int(emu.keys[id][slot]))
	}
	for dir, core in emu.cores do fmt.sbprintf(&b, "core.%s=%s\n", dir, core)
	os.make_directory(retro_dir())
	_ = os.write_entire_file(retro_dir("emulation.ini"), strings.to_string(b))
}

// --- core options chosen in the menu -----------------------------------------------------

emu_set_core_opt :: proc(key, value: string) {
	if old_k, old_v := delete_key(&emu.core_opts, key); old_k != "" {
		delete(old_k)
		delete(old_v)
	}
	emu.core_opts[strings.clone(key)] = strings.clone(value)
}

emu_load_core_opts :: proc() {
	data, err := os.read_entire_file(retro_dir("options.menu.ini"), context.temp_allocator)
	if err != nil do return
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		l := strings.trim_space(line)
		if l == "" || l[0] == ';' || l[0] == '#' || l[0] == '[' do continue
		k, _, v := strings.partition(l, "=")
		if k = strings.trim_space(k); k != "" do emu_set_core_opt(k, strings.trim_space(v))
	}
}

emu_save_core_opts :: proc() {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[menu]\n")
	for k, v in emu.core_opts do fmt.sbprintf(&b, "%s=%s\n", k, v)
	os.make_directory(retro_dir())
	_ = os.write_entire_file(retro_dir("options.menu.ini"), strings.to_string(b))
}

emu_reset_core_options :: proc() {
	for k, v in emu.core_opts {
		delete(k)
		delete(v)
	}
	clear(&emu.core_opts)
	emu_save_core_opts()
	retro_clear_overrides()
	retro_load_overrides()
	for &o in retro.options do retro_pick_override(&o)
	retro.options_dirty = true
}

// --- helpers the frontend calls -----------------------------------------------------------

// Nintendo layout swaps the south/east and west/north buttons.
emu_joy_id :: proc(id: u8) -> u8 {
	if !emu.swap_ab do return id
	switch id {
	case RETRO_DEVICE_ID_JOYPAD_B: return RETRO_DEVICE_ID_JOYPAD_A
	case RETRO_DEVICE_ID_JOYPAD_A: return RETRO_DEVICE_ID_JOYPAD_B
	case RETRO_DEVICE_ID_JOYPAD_Y: return RETRO_DEVICE_ID_JOYPAD_X
	case RETRO_DEVICE_ID_JOYPAD_X: return RETRO_DEVICE_ID_JOYPAD_Y
	}
	return id
}

emu_speed :: proc() -> f64 {
	return f64(EMU_SPEEDS[emu.speed]) / 100
}

emu_audio_target_sec :: proc() -> f64 {
	return f64(EMU_LATENCIES[emu.latency]) / 1000
}

emu_volume :: proc() -> f32 {
	return f32(emu.volume) / 100
}

emu_core_installed :: proc(name: string) -> (string, bool) {
	file := core_file_name(name)
	for dir in ([]string{retro_dir("cores"), retro_dir()}) {
		path := path_join({dir, file})
		if os.exists(path) do return path, true
	}
	for dir in SYSTEM_CORE_DIRS {
		path := path_join({dir, file})
		if os.exists(path) do return path, true
	}
	return "", false
}

emu_core_label :: proc(name: string) -> string {
	return strings.trim_suffix(name, "_libretro.dll")
}

// --- the menu ----------------------------------------------------------------------------

Emu_Page :: enum {
	Core_Options,
	Video,
	Audio,
	Controls,
	Cores,
}

EMU_PAGE_NAMES := [Emu_Page]string {
	.Core_Options = "Core Options",
	.Video        = "Video",
	.Audio        = "Audio",
	.Controls     = "Controls",
	.Cores        = "Cores",
}

Emu_Row :: struct {
	label:  string,
	value:  string,
	help:   string,
	action: bool, // activated with A instead of stepped
}

Emu_Menu :: struct {
	open:     bool,
	in_game:  bool,
	page:     Emu_Page,
	sel:      int,
	first:    int, // first visible row
	t:        f32,
	capture:  bool, // waiting for a button/key to bind to `sel`
	wait:     bool, // skip the frame that started the capture
}

emu_menu: Emu_Menu

EMU_BUTTON_NAMES := [16]string {
	"B (bottom)", "Y (left)", "Select", "Start", "D-Pad Up", "D-Pad Down", "D-Pad Left", "D-Pad Right",
	"A (right)", "X (top)", "L", "R", "L2", "R2", "L3", "R3",
}

emu_pad_name :: proc(b: rl.GamepadButton) -> string {
	#partial switch b {
	case .UNKNOWN: return "—"
	case .LEFT_FACE_UP: return "D-Pad Up"
	case .LEFT_FACE_DOWN: return "D-Pad Down"
	case .LEFT_FACE_LEFT: return "D-Pad Left"
	case .LEFT_FACE_RIGHT: return "D-Pad Right"
	case .RIGHT_FACE_DOWN: return "South"
	case .RIGHT_FACE_RIGHT: return "East"
	case .RIGHT_FACE_LEFT: return "West"
	case .RIGHT_FACE_UP: return "North"
	case .LEFT_TRIGGER_1: return "LB"
	case .LEFT_TRIGGER_2: return "LT"
	case .RIGHT_TRIGGER_1: return "RB"
	case .RIGHT_TRIGGER_2: return "RT"
	case .MIDDLE_LEFT: return "Back"
	case .MIDDLE_RIGHT: return "Start"
	case .MIDDLE: return "Guide"
	case .LEFT_THUMB: return "L Stick"
	case .RIGHT_THUMB: return "R Stick"
	}
	return "?"
}

emu_key_name :: proc(k: rl.KeyboardKey) -> string {
	if k == .KEY_NULL do return "—"
	return strings.to_lower(fmt.tprintf("%v", k), context.temp_allocator)
}

emu_pages :: proc() -> []Emu_Page {
	@(static) all := [?]Emu_Page{.Core_Options, .Video, .Audio, .Controls, .Cores}
	return emu_menu.in_game ? all[:] : all[1:]
}

emu_open :: proc(in_game: bool) {
	emu_init()
	emu_scan_cores()
	emu_menu = {open = true, in_game = in_game, page = in_game && len(retro.options) > 0 ? .Core_Options : .Video}
	sfx_click()
}

emu_close :: proc() {
	emu_menu.open = false
	emu_menu.capture = false
	emu_save()
	sfx_back()
}

emu_percent :: proc(v: int) -> string {
	return fmt.tprintf("%d%%", v)
}

emu_on_off :: proc(v: bool) -> string {
	return v ? "On" : "Off"
}

// Choices of the preferred-core row for one platform: "Auto" then every installed candidate.
emu_core_choices :: proc(p: Retro_Platform) -> [dynamic]string {
	list := make([dynamic]string, context.temp_allocator)
	append(&list, "")
	for name, i in RETRO_CORES[p] do if emu_installed[p] & (1 << uint(i)) != 0 do append(&list, name)
	return list
}

// Which RETRO_CORES candidates exist on disk; refreshed when the menu opens.
emu_installed: [Retro_Platform]u32

emu_scan_cores :: proc() {
	for p in Retro_Platform {
		emu_installed[p] = 0
		for name, i in RETRO_CORES[p] do if _, ok := emu_core_installed(name); ok do emu_installed[p] |= 1 << uint(i)
	}
}

emu_platforms :: proc() -> []Retro_Platform {
	@(static) list: [len(Retro_Platform)]Retro_Platform
	@(static) n: int
	if n == 0 {
		for p in Retro_Platform do if p != .None {
			list[n] = p
			n += 1
		}
	}
	return list[:n]
}

emu_rows :: proc(page: Emu_Page) -> [dynamic]Emu_Row {
	rows := make([dynamic]Emu_Row, context.temp_allocator)
	switch page {
	case .Core_Options:
		append(&rows, Emu_Row{label = "Reset to defaults", value = "", action = true, help = "Puts every option of this core back to its default."})
		for &o in retro.options {
			label := o.desc != "" ? o.desc : string(o.key)
			append(&rows, Emu_Row{label = label, value = string(o.values[o.current]), help = "Some options only take effect after restarting the game."})
		}
	case .Video:
		append(&rows, Emu_Row{label = "Aspect ratio", value = EMU_ASPECT_NAMES[emu.aspect], help = "Shape of the picture. Core default uses what the console outputs."})
		append(&rows, Emu_Row{label = "Integer scaling", value = emu_on_off(emu.integer_scale), help = "Only whole-number zoom levels keep every pixel the same size."})
		append(&rows, Emu_Row{label = "Smoothing", value = emu.smooth ? "Smooth" : "Sharp pixels", help = "Smooth blurs pixels slightly; sharp keeps hard edges."})
		append(&rows, Emu_Row{label = "Scanlines", value = EMU_SCANLINE_NAMES[emu.scanlines], help = "A CRT-style line pattern over the picture."})
		append(&rows, Emu_Row{label = "Show FPS", value = emu_on_off(emu.show_fps), help = "Frames per second in the corner."})
		append(&rows, Emu_Row{label = "Emulation speed", value = emu_percent(EMU_SPEEDS[emu.speed]), help = "Slow motion or fast forward. Audio is muted when not at 100%."})
	case .Audio:
		append(&rows, Emu_Row{label = "Game volume", value = emu_percent(emu.volume), help = "Loudness of emulated games."})
		append(&rows, Emu_Row{label = "Audio latency", value = fmt.tprintf("%d ms", EMU_LATENCIES[emu.latency]), help = "Lower reacts faster; raise it if the sound crackles."})
	case .Controls:
		append(&rows, Emu_Row{label = "Stick deadzone", value = emu_percent(emu.deadzone), help = "How far a stick must move before it counts."})
		append(&rows, Emu_Row{label = "Nintendo button layout", value = emu_on_off(emu.swap_ab), help = "Swaps A/B and X/Y so the face buttons match Nintendo pads."})
		append(&rows, Emu_Row{label = "Reset controls", value = "", action = true, help = "Restores the default pad and keyboard bindings."})
		for id in 0 ..< 16 {
			slot0, slot1 := emu_key_name(emu.keys[id][0]), emu_key_name(emu.keys[id][1])
			keys := emu.keys[id][1] == .KEY_NULL ? slot0 : fmt.tprintf("%s / %s", slot0, slot1)
			value := fmt.tprintf("Pad %s   Key %s", emu_pad_name(emu.pad[id]), keys)
			if emu_menu.capture && emu_menu.sel == 3 + id do value = "Press a button or key…"
			append(&rows, Emu_Row{label = EMU_BUTTON_NAMES[id], value = value, action = true, help = "A to rebind (player 1 keyboard, all pads). Esc cancels."})
		}
	case .Cores:
		for p in emu_platforms() {
			pref := emu.cores[RETRO_PLATFORM_DIR[p]]
			choices := emu_core_choices(p)
			value := "No core installed"
			if len(choices) > 1 {
				value = pref == "" ? fmt.tprintf("Auto (%s)", emu_core_label(choices[1])) : emu_core_label(pref)
			}
			append(&rows, Emu_Row{label = RETRO_PLATFORM_NAME[p], value = value, help = "Takes effect the next time a game starts. Cores go in APP\\libretro\\cores."})
		}
	}
	return rows
}

cycle :: proc(v, delta, n: int) -> int {
	return ((v + delta) % n + n) % n
}

// delta: -1 / +1 steps a value, 0 activates the row (steps forward for plain values).
emu_change :: proc(row: int, delta: int) {
	step := delta == 0 ? 1 : delta
	switch emu_menu.page {
	case .Core_Options:
		if row == 0 {
			if delta == 0 {
				emu_reset_core_options()
				retro_osd("Core options reset")
				sfx_click()
			}
			return
		}
		o := &retro.options[row - 1]
		o.current = cycle(o.current, step, len(o.values))
		emu_set_core_opt(string(o.key), string(o.values[o.current]))
		emu_save_core_opts()
		retro.options_dirty = true
		sfx_click()
	case .Video:
		switch row {
		case 0: emu.aspect = Emu_Aspect(cycle(int(emu.aspect), step, len(Emu_Aspect)))
		case 1: emu.integer_scale = !emu.integer_scale
		case 2: emu.smooth = !emu.smooth
		case 3: emu.scanlines = cycle(emu.scanlines, step, len(EMU_SCANLINE_NAMES))
		case 4: emu.show_fps = !emu.show_fps
		case 5:
			emu.speed = cycle(emu.speed, step, len(EMU_SPEEDS))
			retro.has_run = false
		}
		sfx_click()
	case .Audio:
		switch row {
		case 0:
			if delta == 0 {
				emu.volume = emu.volume >= 100 ? 0 : min(100, emu.volume + 10) // A wraps around
			} else {
				emu.volume = clamp(emu.volume + delta * 5, 0, 100)
			}
			if raudio.ok do rl.SetAudioStreamVolume(raudio.stream, emu_volume())
		case 1: emu.latency = cycle(emu.latency, step, len(EMU_LATENCIES))
		}
		sfx_click()
	case .Controls:
		switch row {
		case 0: emu.deadzone = clamp(emu.deadzone + (delta == 0 ? 5 : delta * 5), 0, 50)
		case 1: emu.swap_ab = !emu.swap_ab
		case 2:
			if delta == 0 {
				emu_set_default_controls()
				emu.deadzone = 15
				emu.swap_ab = false
			}
		case:
			if delta == 0 {
				emu_menu.capture = true
				emu_menu.wait = true
			}
		}
		sfx_click()
	case .Cores:
		p := emu_platforms()[row]
		choices := emu_core_choices(p)
		if len(choices) <= 1 do return
		cur := 0
		for c, i in choices do if c == emu.cores[RETRO_PLATFORM_DIR[p]] do cur = i
		next := choices[cycle(cur, step, len(choices))]
		dir := RETRO_PLATFORM_DIR[p]
		if old_k, old_v := delete_key(&emu.cores, dir); old_k != "" {
			delete(old_k)
			delete(old_v)
		}
		if next != "" do emu.cores[strings.clone(dir)] = strings.clone(next)
		sfx_click()
	}
}

emu_capture_step :: proc() {
	if emu_menu.wait {
		emu_menu.wait = false
		return
	}
	id := emu_menu.sel - 3
	if rl.IsKeyPressed(.ESCAPE) {
		emu_menu.capture = false
		sfx_back()
		return
	}
	if b := rl.GetGamepadButtonPressed(); b != .UNKNOWN {
		emu.pad[id] = b
		emu_menu.capture = false
		sfx_click()
		return
	}
	if k := rl.GetKeyPressed(); k != .KEY_NULL {
		emu.keys[id] = {k, .KEY_NULL}
		emu_menu.capture = false
		sfx_click()
	}
}

emu_menu_input :: proc() {
	if emu_menu.capture {
		emu_capture_step()
		return
	}
	pages := emu_pages()
	pi := 0
	for p, i in pages do if p == emu_menu.page do pi = i
	if input.menu_l || input.menu_r {
		emu_menu.page = pages[cycle(pi, input.menu_l ? -1 : 1, len(pages))]
		emu_menu.sel, emu_menu.first = 0, 0
		sfx_click()
		return
	}
	if input.cancel || input.power {
		emu_close()
		return
	}
	rows := emu_rows(emu_menu.page)
	n := len(rows)
	if n == 0 do return
	emu_menu.sel = clamp(emu_menu.sel, 0, n - 1)
	if input.up {
		emu_menu.sel = (emu_menu.sel + n - 1) % n
		sfx_click()
	}
	if input.down {
		emu_menu.sel = (emu_menu.sel + 1) % n
		sfx_click()
	}
	if wheel := rl.GetMouseWheelMove(); wheel != 0 && !input.using_pad {
		emu_menu.sel = clamp(emu_menu.sel - int(wheel), 0, n - 1)
	}
	row := rows[emu_menu.sel]
	if input.left && !row.action do emu_change(emu_menu.sel, -1)
	if input.right && !row.action do emu_change(emu_menu.sel, 1)
	if input.confirm do emu_change(emu_menu.sel, 0)
}

EMU_ROW_H :: 50
EMU_ROW_GAP :: 6

emu_menu_draw :: proc(w, h: f32) {
	emu_menu.t = smooth_to(emu_menu.t, emu_menu.open ? 1 : 0, 16)
	if !emu_menu.open && emu_menu.t < 0.02 do return
	t := emu_menu.t
	rl.DrawRectangle(0, 0, i32(w), i32(h), with_alpha(COL_SHADE, u8(190 * t)))
	if t < 0.5 do return

	pw := min(w - PAD * 2, 940)
	ph := h - 2 * PAD - FOOTER_H
	pr := rl.Rectangle{(w - pw) * 0.5, PAD, pw, ph}
	draw_panel(pr, false, with_alpha(COL_PANEL_SOLID, 248))
	draw_t("EMULATION", pr.x + 28, pr.y + 22, 26, COL_TEXT)

	// page tabs
	pages := emu_pages()
	tx := pr.x + 28
	ty := pr.y + 66
	for p in pages {
		label := EMU_PAGE_NAMES[p]
		tw := measure_t(label, 18) + 28
		tr := rl.Rectangle{tx, ty, tw, 34}
		active := p == emu_menu.page
		hovered := !emu_menu.capture && mouse_over(tr, true)
		if active || hovered {
			rl.DrawRectangleRounded(tr, 1, 8, with_alpha(COL_ACCENT, active ? 60 : 30))
		}
		draw_t_center(label, tr.x + tw * 0.5, tr.y + 7, 18, active ? COL_TEXT : COL_MUTED)
		if hovered && !active && rl.IsMouseButtonPressed(.LEFT) {
			emu_menu.page = p
			emu_menu.sel, emu_menu.first = 0, 0
			sfx_click()
		}
		tx += tw + 8
	}

	rows := emu_rows(emu_menu.page)
	list := rl.Rectangle{pr.x + 20, pr.y + 116, pr.width - 40, pr.height - 116 - 54}
	if len(rows) == 0 {
		draw_t_center("Nothing to configure here", pr.x + pr.width * 0.5, list.y + 40, 20, COL_MUTED)
		draw_hints(w, h, []Hint{{"B", "Back"}, {"LB/RB", "Page"}})
		return
	}
	emu_menu.sel = clamp(emu_menu.sel, 0, len(rows) - 1)
	vis := max(1, int(list.height) / (EMU_ROW_H + EMU_ROW_GAP))
	if emu_menu.sel < emu_menu.first do emu_menu.first = emu_menu.sel
	if emu_menu.sel >= emu_menu.first + vis do emu_menu.first = emu_menu.sel - vis + 1
	emu_menu.first = clamp(emu_menu.first, 0, max(0, len(rows) - vis))

	for i in emu_menu.first ..< min(len(rows), emu_menu.first + vis) {
		row := rows[i]
		r := rl.Rectangle{list.x, list.y + f32(i - emu_menu.first) * (EMU_ROW_H + EMU_ROW_GAP), list.width, EMU_ROW_H}
		if !emu_menu.capture && !input.using_pad && mouse_over(r, true) && rl.GetMouseDelta() != {} && emu_menu.sel != i {
			emu_menu.sel = i
			hover_enter(fmt.tprintf("emu-%d", i))
		}
		focused := emu_menu.sel == i
		rl.DrawRectangleRounded(r, roundness(r, 10), 8, focused ? with_alpha(COL_ACCENT, 38) : with_alpha(COL_TINT, 10))
		if focused do rl.DrawRectangleRoundedLinesEx(r, roundness(r, 10), 8, 1.5, COL_ACCENT_SOFT)
		draw_t_fit(row.label, r.x + 20, r.y + 14, r.width * 0.4 - 24, 20, focused ? COL_TEXT : COL_MUTED, focused)
		val := rl.Rectangle{r.x + r.width * 0.42, r.y + 4, r.width * 0.58 - 12, r.height - 8}
		if row.action {
			draw_t_fit(row.value, val.x + 8, r.y + 15, val.width - 50, 18, focused ? COL_TEXT : COL_MUTED, false)
			draw_glyph("A", val.x + val.width - 30, r.y + r.height * 0.5)
			if focused && mouse_over(r, true) && rl.IsMouseButtonPressed(.LEFT) do emu_change(i, 0)
		} else if d := emu_stepper(val, row.value, focused); d != 0 {
			emu_menu.sel = i
			emu_change(i, d)
		}
		if !row.action && focused && mouse_over(rl.Rectangle{r.x, r.y, r.width * 0.42, r.height}, true) && rl.IsMouseButtonPressed(.LEFT) {
			emu_change(i, 0)
		}
	}
	if len(rows) > vis {
		track := rl.Rectangle{list.x + list.width + 4, list.y, 4, list.height}
		rl.DrawRectangleRounded(track, 1, 4, with_alpha(COL_TINT, 20))
		th := track.height * f32(vis) / f32(len(rows))
		ty := track.y + (track.height - th) * f32(emu_menu.first) / f32(len(rows) - vis)
		rl.DrawRectangleRounded({track.x, ty, track.width, th}, 1, 4, COL_ACCENT_SOFT)
	}
	draw_t_fit(rows[emu_menu.sel].help, pr.x + 28, pr.y + pr.height - 38, pr.width - 56, 16, COL_MUTED, false)

	hints := [?]Hint{{"B", "Back"}, {"LB/RB", "Page"}, {"A", "Select"}}
	draw_hints(w, h, hints[:])
}

// "<  value  >" with clickable arrows; returns -1 / +1 for a click.
emu_stepper :: proc(r: rl.Rectangle, value: string, focused: bool) -> int {
	arrow := focused ? COL_ACCENT : COL_MUTED
	left := rl.Rectangle{r.x, r.y, 36, r.height}
	right := rl.Rectangle{r.x + r.width - 36, r.y, 36, r.height}
	draw_triangle_dir(left.x + 18, r.y + r.height * 0.5, 14, .Left, arrow)
	draw_triangle_dir(right.x + 18, r.y + r.height * 0.5, 14, .Right, arrow)
	draw_t_fit(value, left.x + 44, r.y + 11, r.width - 88, 18, focused ? COL_TEXT : COL_MUTED, focused)
	if mouse_over(left, true) && rl.IsMouseButtonPressed(.LEFT) do return -1
	if mouse_over(right, true) && rl.IsMouseButtonPressed(.LEFT) do return 1
	return 0
}

// In-game: runs the menu over the paused picture until it closes.
emu_menu_run_in_game :: proc() {
	emu_open(true)
	emu_menu.t = 1
	first := true
	for emu_menu.open {
		if rl.WindowShouldClose() && !app.in_shell {
			retro.quit = true
			emu_close()
			return
		}
		input_poll()
		if first {
			eat_input()
			first = false
		}
		emu_menu_input()
		w := f32(rl.GetScreenWidth())
		h := f32(rl.GetScreenHeight())
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		retro_draw_frame(w, h, rl.WHITE)
		emu_menu_draw(w, h)
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
}
