package flasher

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

// Drive formatting. Every check runs again right before format.com is launched, against the
// live drive, so a stale list (drive pulled, letter reassigned) can never format the wrong disk.

foreign import kernel32_fmt "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32_fmt {
	GetWindowsDirectoryW :: proc(buf: win.LPWSTR, size: u32) -> u32 ---
}

Format_Block :: enum {
	None,
	Invalid_Letter,
	Drive_C,         // C: is never formatted, whatever it is
	System_Drive,    // %SystemDrive% / the Windows directory's drive
	Windows_Install, // has \Windows, pagefile/hiberfil or Program Files
	Own_Drive,       // the drive SaberFlasher.exe runs from
	Not_Present,
	Wrong_Type,      // not a removable / fixed disk (network, CD, RAM disk...)
	Changed,         // volume serial differs from what the user picked
}

format_block_text :: proc(b: Format_Block) -> string {
	switch b {
	case .None:            return ""
	case .Invalid_Letter:  return "Invalid drive letter."
	case .Drive_C:         return "C: can never be formatted."
	case .System_Drive:    return "This is the Windows system drive — it can't be formatted."
	case .Windows_Install: return "This drive holds a Windows install or system files — it can't be formatted."
	case .Own_Drive:       return "Saber Flasher is running from this drive — it can't be formatted."
	case .Not_Present:     return "The drive is no longer connected."
	case .Wrong_Type:      return "Only USB drives, SD cards and disks can be formatted."
	case .Changed:         return "The drive changed since it was selected — press Refresh and try again."
	}
	return "Blocked."
}

upper_letter :: proc(c: u8) -> u8 {
	return c >= 'a' && c <= 'z' ? c - 32 : c
}

windows_drive :: proc() -> u8 {
	buf: [260]u16
	if GetWindowsDirectoryW(win.LPWSTR(raw_data(buf[:])), len(buf)) >= 2 && buf[1] == ':' {
		return upper_letter(u8(buf[0]))
	}
	return 'C'
}

// Checks `letter` against every protection rule. `serial` is the volume serial captured when
// the drive was listed; pass it so a different volume that took over the letter is refused.
format_check :: proc(letter: u8, serial: u32) -> Format_Block {
	l := upper_letter(letter)
	if l < 'A' || l > 'Z' do return .Invalid_Letter
	if l == 'C' do return .Drive_C

	sys := os.get_env("SystemDrive", context.temp_allocator)
	if len(sys) > 0 && upper_letter(sys[0]) == l do return .System_Drive
	if windows_drive() == l do return .System_Drive

	exe := os.args[0]
	if len(exe) >= 2 && exe[1] == ':' && upper_letter(exe[0]) == l do return .Own_Drive
	if cwd, err := os.get_working_directory(context.temp_allocator); err == nil && len(cwd) >= 2 && cwd[1] == ':' && upper_letter(cwd[0]) == l {
		return .Own_Drive
	}

	root := [4]u16{u16(l), ':', '\\', 0}
	if GetLogicalDrives() & (u32(1) << u32(l - 'A')) == 0 do return .Not_Present
	kind := GetDriveTypeW(wp(root[:]))
	if kind != DRIVE_REMOVABLE && kind != DRIVE_FIXED do return .Wrong_Type

	live_serial: u32
	if !GetVolumeInformationW(wp(root[:]), nil, 0, &live_serial, nil, nil, nil, 0) do return .Not_Present
	if live_serial != serial do return .Changed

	for p in ([]string{"Windows\\System32", "pagefile.sys", "hiberfil.sys", "swapfile.sys", "Program Files", "Users"}) {
		if os.exists(fmt.tprintf("%c:\\%s", l, p)) do return .Windows_Install
	}
	return .None
}

// The exact command launched (elevated). The letter is a validated A-Z, so nothing else can
// end up on the command line; format.com is addressed by full path so PATH can't redirect it.
format_command :: proc(letter: u8) -> (exe: string, params: string) {
	l := upper_letter(letter)
	buf: [260]u16
	n := GetWindowsDirectoryW(win.LPWSTR(raw_data(buf[:])), len(buf))
	windir := n > 0 && n < len(buf) ? w2s(buf[:n]) : `C:\Windows`
	if strings.contains(windir, " ") do windir = `C:\Windows`
	exe = fmt.tprintf(`%s\System32\cmd.exe`, windir)
	// /X dismounts the volume first; format.com still asks for the volume label / Y-N itself.
	params = fmt.tprintf(`/k %s\System32\format.com %c: /FS:exFAT /Q /V:SABER /X`, windir, l)
	return
}

// Re-validates and launches. Returns the block reason if refused.
start_format :: proc(letter: u8, serial: u32) -> Format_Block {
	if b := format_check(letter, serial); b != .None do return b
	exe, params := format_command(letter)
	shell_exec("runas", exe, params)
	return .None
}
