package saber

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "stdcall")
foreign kernel32 {
	GetLogicalDrives :: proc() -> u32 ---
	CreateMutexW :: proc(lpMutexAttributes: rawptr, bInitialOwner: win.BOOL, lpName: win.LPCWSTR) -> win.HANDLE ---
	GetDriveTypeW :: proc(lpRootPathName: win.LPCWSTR) -> u32 ---
	GetVolumeInformationW :: proc(
		lpRootPathName: win.LPCWSTR,
		lpVolumeNameBuffer: win.LPWSTR,
		nVolumeNameSize: u32,
		lpVolumeSerialNumber: ^u32,
		lpMaximumComponentLength: ^u32,
		lpFileSystemFlags: ^u32,
		lpFileSystemNameBuffer: win.LPWSTR,
		nFileSystemNameSize: u32,
	) -> win.BOOL ---
}

current_drive_mask :: proc() -> u32 {
	return GetLogicalDrives()
}

is_system_drive :: proc(letter: rune) -> bool {
	sys := os.get_env("SystemDrive", context.temp_allocator)
	if sys == "" {
		return letter == 'C'
	}
	sys = strings.to_upper(sys)
	id := fmt.tprintf("%c:", letter)
	return strings.equal_fold(id, sys)
}

drive_type :: proc(letter: rune) -> u32 {
	root_w := [4]u16{u16(letter), ':', '\\', 0}
	return GetDriveTypeW(win.LPCWSTR(raw_data(root_w[:])))
}

// "F:\" (temp)
drive_root :: proc(letter: rune) -> string {
	return fmt.tprintf("%c:\\", letter)
}

// "F:\PSP_GAME\PARAM.SFO" (temp)
drive_path :: proc(letter: rune, parts: ..string) -> string {
	return fmt.tprintf("%c:\\%s", letter, strings.join(parts, "\\", context.temp_allocator))
}

volume_label :: proc(letter: rune) -> string {
	root_w := [4]u16{u16(letter), ':', '\\', 0}
	name: [261]u16
	ok := GetVolumeInformationW(win.LPCWSTR(raw_data(root_w[:])), raw_data(name[:]), u32(len(name)), nil, nil, nil, nil, 0)
	if ok && name[0] != 0 {
		return strings.clone(wide_to_utf8(raw_data(name[:]), -1))
	}
	return fmt.aprintf("%c:", letter)
}

volume_serial :: proc(letter: u8) -> (serial: u32, present: bool) {
	root := [4]u16{u16(letter), ':', '\\', 0}
	ok := GetVolumeInformationW(win.LPCWSTR(raw_data(root[:])), nil, 0, &serial, nil, nil, nil, 0)
	return serial, bool(ok)
}
