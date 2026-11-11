package saber

// Emulated controller bindings. Every libretro joypad button takes up to EMU_BINDS_PER inputs:
// keyboard keys (player 1), pad buttons and pad axes (sticks / analog triggers, every pad).
// The global set lives in emulation.ini; a game can carry its own copy in
// APP/libretro/controls/<platform>-<save key>.ini, used whenever that game runs.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

EMU_BINDS_PER :: 4
EMU_AXIS_ON :: 0.5      // a stick pushed this far counts as pressed
EMU_TRIGGER_ON :: -0.5 // triggers rest at -1
EMU_CAPTURE_SEC :: 8.0

Emu_Bind_Kind :: enum u8 {
	None,
	Key,  // code = rl.KeyboardKey
	Pad,  // code = rl.GamepadButton
	Axis, // code = axis * 2 + (1 = positive direction)
}

Emu_Bind :: struct {
	kind: Emu_Bind_Kind,
	code: i32,
}

Emu_Controls :: struct {
	deadzone: int,  // percent
	swap_ab:  bool, // Nintendo layout: A/B and X/Y trade places
	binds:    [16][EMU_BINDS_PER]Emu_Bind, // by libretro joypad id
}

// The running game's own controls, when it has any.
Emu_Game_Controls :: struct {
	active: bool, // a game is running: the in-game menu may edit its profile
	has:    bool, // it has its own controls file
	key:    string,
	title:  string,
	ctl:    Emu_Controls,
}

emu_game: Emu_Game_Controls

// The controls in effect now.
emu_controls :: proc() -> ^Emu_Controls {
	return emu_game.active && emu_game.has ? &emu_game.ctl : &emu.ctl
}

emu_default_controls :: proc() -> Emu_Controls {
	c := Emu_Controls{deadzone = 15}
	for b in RETRO_PAD_BINDS do emu_bind_add(&c, int(b.id), {.Pad, i32(b.button)})
	emu_bind_add(&c, RETRO_DEVICE_ID_JOYPAD_L2, {.Pad, i32(rl.GamepadButton.LEFT_TRIGGER_2)})
	emu_bind_add(&c, RETRO_DEVICE_ID_JOYPAD_L2, {.Axis, i32(rl.GamepadAxis.LEFT_TRIGGER) * 2 + 1})
	emu_bind_add(&c, RETRO_DEVICE_ID_JOYPAD_R2, {.Pad, i32(rl.GamepadButton.RIGHT_TRIGGER_2)})
	emu_bind_add(&c, RETRO_DEVICE_ID_JOYPAD_R2, {.Axis, i32(rl.GamepadAxis.RIGHT_TRIGGER) * 2 + 1})
	for k in RETRO_KEY_BINDS do emu_bind_add(&c, int(k.id), {.Key, i32(k.key)})
	return c
}

// Adds `b` to `id` unless it is already there; a full row drops its oldest binding.
emu_bind_add :: proc(c: ^Emu_Controls, id: int, b: Emu_Bind) {
	row := &c.binds[id]
	for o in row do if o == b do return
	for &o in row do if o.kind == .None {
		o = b
		return
	}
	for i in 0 ..< EMU_BINDS_PER - 1 do row[i] = row[i + 1]
	row[EMU_BINDS_PER - 1] = b
}

emu_bind_name :: proc(b: Emu_Bind) -> string {
	switch b.kind {
	case .None: return ""
	case .Key:  return fmt.tprintf("Key %s", emu_key_name(rl.KeyboardKey(b.code)))
	case .Pad:  return emu_pad_name(rl.GamepadButton(b.code))
	case .Axis:
		pos := b.code & 1 == 1
		switch rl.GamepadAxis(b.code / 2) {
		case .LEFT_X:        return pos ? "L Stick Right" : "L Stick Left"
		case .LEFT_Y:        return pos ? "L Stick Down" : "L Stick Up"
		case .RIGHT_X:       return pos ? "R Stick Right" : "R Stick Left"
		case .RIGHT_Y:       return pos ? "R Stick Down" : "R Stick Up"
		case .LEFT_TRIGGER:  return "LT (analog)"
		case .RIGHT_TRIGGER: return "RT (analog)"
		}
	}
	return "?"
}

emu_binds_label :: proc(c: ^Emu_Controls, id: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for o in c.binds[id] {
		if o.kind == .None do continue
		if strings.builder_len(b) > 0 do strings.write_string(&b, "  ·  ")
		strings.write_string(&b, emu_bind_name(o))
	}
	return strings.builder_len(b) > 0 ? strings.to_string(b) : "Unbound"
}

// --- reading the bindings ------------------------------------------------------------------

emu_axis_down :: proc(pad: i32, code: i32) -> bool {
	axis := rl.GamepadAxis(code / 2)
	v := rl.GetGamepadAxisMovement(pad, axis)
	if axis == .LEFT_TRIGGER || axis == .RIGHT_TRIGGER do return v > EMU_TRIGGER_ON
	return code & 1 == 1 ? v > EMU_AXIS_ON : v < -EMU_AXIS_ON
}

// Joypad bits from one pad's buttons / axes (keys are added for port 0 separately).
emu_pad_bits :: proc(c: ^Emu_Controls, pad: i32) -> (bits: u16) {
	for row, id in c.binds {
		for b in row {
			down := false
			#partial switch b.kind {
			case .Pad:
				down = rl.IsGamepadButtonDown(pad, rl.GamepadButton(b.code))
				for cb, i in COMBO_BUTTONS do if rl.GamepadButton(b.code) == cb && combo_override[i] != 0 {
					down = combo_override[i] > 0
				}
			case .Axis: down = emu_axis_down(pad, b.code)
			}
			if down {
				bits |= 1 << emu_joy_id(u8(id))
				break
			}
		}
	}
	return
}

emu_key_bits :: proc(c: ^Emu_Controls) -> (bits: u16) {
	for row, id in c.binds {
		for b in row do if b.kind == .Key && rl.IsKeyDown(rl.KeyboardKey(b.code)) {
			bits |= 1 << emu_joy_id(u8(id))
			break
		}
	}
	return
}

// Anything bound is held right now (any pad).
emu_any_bound_down :: proc(c: ^Emu_Controls) -> bool {
	if emu_key_bits(c) != 0 do return true
	for p in 0 ..< i32(MAX_PADS) do if rl.IsGamepadAvailable(p) && emu_pad_bits(c, p) != 0 do return true
	return false
}

// --- capture (rebinding in the menu) -------------------------------------------------------
// The capture waits until every key and button is released (the A / Enter / click that started
// it included), then takes the first new press. raylib's GetGamepadButtonPressed can't be used:
// it keeps reporting the last button, so A used to bind to itself at once.

Emu_Capture :: struct {
	on:      bool,
	armed:   bool, // everything was released since it started
	id:      int,
	started: f64,
}

emu_capture: Emu_Capture

emu_capture_start :: proc(id: int) {
	emu_capture = {on = true, id = id, started = rl.GetTime()}
}

emu_capture_left :: proc() -> int {
	return max(0, int(EMU_CAPTURE_SEC - (rl.GetTime() - emu_capture.started) + 0.999))
}

// The input held right now, if any (keys, then pad buttons, then axes).
emu_input_held :: proc() -> (Emu_Bind, bool) {
	for k in i32(32) ..= i32(348) {
		if rl.IsKeyDown(rl.KeyboardKey(k)) do return {.Key, k}, true
	}
	for p in 0 ..< i32(MAX_PADS) {
		if !rl.IsGamepadAvailable(p) do continue
		for b in i32(rl.GamepadButton.LEFT_FACE_UP) ..= i32(rl.GamepadButton.RIGHT_THUMB) {
			if rl.IsGamepadButtonDown(p, rl.GamepadButton(b)) do return {.Pad, b}, true
		}
		for a in i32(0) ..< 6 {
			v := rl.GetGamepadAxisMovement(p, rl.GamepadAxis(a))
			if a >= 4 {
				if v > 0.3 do return {.Axis, a * 2 + 1}, true
			} else if abs(v) > 0.7 {
				return {.Axis, a * 2 + (v > 0 ? 1 : 0)}, true
			}
		}
	}
	return {}, false
}

// One frame of capture; returns true when it ended this frame.
emu_capture_step :: proc(c: ^Emu_Controls) -> bool {
	if rl.GetTime() - emu_capture.started > EMU_CAPTURE_SEC {
		emu_capture.on = false
		sfx_back()
		return true
	}
	held, any := emu_input_held()
	if !emu_capture.armed {
		emu_capture.armed = !any
		return false
	}
	if !any do return false
	emu_capture.on = false
	if held.kind == .Key && rl.KeyboardKey(held.code) == .ESCAPE {
		sfx_back()
		return true
	}
	emu_bind_add(c, emu_capture.id, held)
	sfx_click()
	return true
}

// --- saving --------------------------------------------------------------------------------

// "bind.<id>=K65,P7,A9"
emu_controls_write :: proc(b: ^strings.Builder, c: ^Emu_Controls) {
	fmt.sbprintf(b, "deadzone=%d\nswap_ab=%d\n", c.deadzone, int(c.swap_ab))
	for row, id in c.binds {
		fmt.sbprintf(b, "bind.%d=", id)
		n := 0
		for o in row {
			if o.kind == .None do continue
			tags := "-KPA"
			fmt.sbprintf(b, "%s%c%d", n > 0 ? "," : "", tags[int(o.kind)], o.code)
			n += 1
		}
		strings.write_byte(b, '\n')
	}
}

// Reads the controls in `text` over `c`. found = it had any bindings.
emu_controls_read :: proc(text: string, c: ^Emu_Controls) -> (found: bool) {
	if v, ok := ini_get(text, "deadzone"); ok do c.deadzone = clamp(strconv.parse_int(v) or_else 15, 0, 50)
	if v, ok := ini_get(text, "swap_ab"); ok do c.swap_ab = v == "1"
	for id in 0 ..< 16 {
		v, ok := ini_get(text, fmt.tprintf("bind.%d", id))
		if !ok do continue
		found = true
		c.binds[id] = {}
		it := v
		for part in strings.split_iterator(&it, ",") {
			p := strings.trim_space(part)
			if len(p) < 2 do continue
			code, cok := strconv.parse_int(p[1:])
			if !cok do continue
			kind: Emu_Bind_Kind
			switch p[0] {
			case 'K': kind = .Key
			case 'P': kind = .Pad
			case 'A': kind = .Axis
			case: continue
			}
			emu_bind_add(c, id, {kind, i32(code)})
		}
	}
	if found do return
	// Saber 1.x: pad.<id>=button, key.<id>.<slot>=key
	for id in 0 ..< 16 {
		if v, ok := ini_get(text, fmt.tprintf("pad.%d", id)); ok {
			found = true
			c.binds[id] = {}
			if n, nok := strconv.parse_int(v); nok && n > 0 && n <= int(rl.GamepadButton.RIGHT_THUMB) do emu_bind_add(c, id, {.Pad, i32(n)})
		}
		for slot in 0 ..< 2 {
			if v, ok := ini_get(text, fmt.tprintf("key.%d.%d", id, slot)); ok {
				if n, nok := strconv.parse_int(v); nok && n > 0 && n < 512 do emu_bind_add(c, id, {.Key, i32(n)})
			}
		}
	}
	if found {
		// 1.x always read the analog triggers as L2 / R2
		emu_bind_add(c, RETRO_DEVICE_ID_JOYPAD_L2, {.Axis, i32(rl.GamepadAxis.LEFT_TRIGGER) * 2 + 1})
		emu_bind_add(c, RETRO_DEVICE_ID_JOYPAD_R2, {.Axis, i32(rl.GamepadAxis.RIGHT_TRIGGER) * 2 + 1})
	}
	return
}

emu_game_path :: proc() -> string {
	return retro_dir("controls", fmt.tprintf("%s.ini", emu_game.key))
}

// retro_play: picks up the game's own controls, if it has a file.
emu_game_begin :: proc(g: ^Game, save_key: string) {
	emu_game_end()
	emu_game.active = true
	emu_game.key = strings.clone(safe_file_name(fmt.tprintf("%s-%s", RETRO_PLATFORM_DIR[g.platform], save_key)))
	emu_game.title = strings.clone(g.title)
	if data, err := os.read_entire_file(emu_game_path(), context.temp_allocator); err == nil {
		emu_game.ctl = emu.ctl
		emu_game.has = emu_controls_read(string(data), &emu_game.ctl)
	}
}

emu_game_end :: proc() {
	delete(emu_game.key)
	delete(emu_game.title)
	emu_game = {}
}

emu_game_save :: proc() {
	if !emu_game.active || !emu_game.has do return
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "; controls for %s\n[controls]\n", emu_game.title)
	emu_controls_write(&b, &emu_game.ctl)
	os.make_directory(retro_dir())
	os.make_directory(retro_dir("controls"))
	_ = os.write_entire_file(emu_game_path(), strings.to_string(b))
}

// Switches the running game between its own controls (starting from the global ones) and the global set.
emu_game_set_own :: proc(own: bool) {
	if !emu_game.active || own == emu_game.has do return
	emu_game.has = own
	if own {
		emu_game.ctl = emu.ctl
		emu_game_save()
	} else {
		_ = os.remove(emu_game_path())
	}
}
