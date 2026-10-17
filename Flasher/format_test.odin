package flasher

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// `odin test Flasher` — exercises the format guards against the real drives on this machine.
// Nothing here launches format.com.

live_serial :: proc(l: u8) -> (u32, bool) {
	root := [4]u16{u16(l), ':', '\\', 0}
	s: u32
	ok := GetVolumeInformationW(wp(root[:]), nil, 0, &s, nil, nil, nil, 0)
	return s, bool(ok)
}

@(test)
test_c_is_forbidden :: proc(t: ^testing.T) {
	s, _ := live_serial('C')
	testing.expect_value(t, format_check('C', s), Format_Block.Drive_C)
	testing.expect_value(t, format_check('c', s), Format_Block.Drive_C)
	testing.expect_value(t, format_check('C', 0), Format_Block.Drive_C)
}

@(test)
test_invalid_letters :: proc(t: ^testing.T) {
	for l in ([]u8{0, '1', ':', '\\', ' ', '&', '|', '"'}) {
		testing.expect_value(t, format_check(l, 0), Format_Block.Invalid_Letter)
	}
}

@(test)
test_system_and_own_drive :: proc(t: ^testing.T) {
	w := windows_drive()
	s, _ := live_serial(w)
	b := format_check(w, s)
	testing.expectf(t, b == .Drive_C || b == .System_Drive, "windows drive %c: got %v", w, b)

	// the drive the running exe lives on is protected
	exe := os.args[0]
	if len(exe) >= 2 && exe[1] == ':' {
		l := upper_letter(exe[0])
		es, _ := live_serial(l)
		b2 := format_check(l, es)
		testing.expectf(t, b2 == .Own_Drive || b2 == .Drive_C || b2 == .System_Drive, "exe drive %c: got %v", l, b2)
	}
}

@(test)
test_missing_drive :: proc(t: ^testing.T) {
	mask := GetLogicalDrives()
	for i in u32(3) ..< 26 { // skip A/B
		if mask & (1 << i) == 0 {
			l := u8('A' + i)
			testing.expect_value(t, format_check(l, 0x1234), Format_Block.Not_Present)
			return
		}
	}
}

@(test)
test_live_drives :: proc(t: ^testing.T) {
	mask := GetLogicalDrives()
	for i in u32(0) ..< 26 {
		if mask & (1 << i) == 0 do continue
		l := u8('A' + i)
		s, ok := live_serial(l)
		b := format_check(l, s)
		fmt.printfln("  %c:  serial=%08X  -> %v", l, s, b)
		if !ok do continue
		if l == 'C' do testing.expect_value(t, b, Format_Block.Drive_C)
		if b == .None {
			// a volume swapped in under the same letter must be refused
			testing.expect_value(t, format_check(l, s ~ 0xFFFF_FFFF), Format_Block.Changed)
		}
	}
}

@(test)
test_command_line :: proc(t: ^testing.T) {
	exe, params := format_command('e')
	testing.expect(t, strings.has_suffix(exe, `\System32\cmd.exe`), exe)
	testing.expect(t, strings.has_suffix(params, `\System32\format.com E: /FS:exFAT /Q /V:SABER /X`), params)
	testing.expect(t, strings.count(params, " E: ") == 1 && strings.count(params, ":\\") == 1, params) // only the target drive letter is passed
	fmt.printfln("  %s %s", exe, params)
}
