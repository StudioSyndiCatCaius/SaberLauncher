package saber

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

DRIVE_REMOVABLE :: 2
DRIVE_FIXED :: 3
DRIVE_CDROM :: 5

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "stdcall")
foreign kernel32 {
	GetLogicalDrives :: proc() -> u32 ---
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

scan_library :: proc(out: ^[dynamic]Game, games_dir: string) {
	if !os.exists(games_dir) {
		return
	}
	scan_children(out, games_dir, "Library", false)
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

is_insertable_drive :: proc(letter: rune) -> bool {
	if is_system_drive(letter) {
		return false
	}
	root_w := [4]u16{u16(letter), ':', '\\', 0}
	kind := GetDriveTypeW(win.LPCWSTR(raw_data(root_w[:])))
	return kind == DRIVE_REMOVABLE || kind == DRIVE_CDROM || kind == DRIVE_FIXED
}

scan_portable_drives :: proc(out: ^[dynamic]Game) {
	mask := current_drive_mask()
	for i in 0 ..< 26 {
		if mask & (u32(1) << u32(i)) == 0 {
			continue
		}
		letter := rune('A' + i)
		if !is_insertable_drive(letter) {
			continue
		}

		root_w := [4]u16{u16(letter), ':', '\\', 0}
		label := volume_label(win.LPCWSTR(raw_data(root_w[:])), letter)
		root_str := fmt.aprintf("%c:\\", letter)
		if g, ok := game_from_folder(root_str, label, true); ok {
			base := filepath.base(strings.trim_right(root_str, "\\/"))
			if base == "" || base == "." || strings.has_suffix(base, ":") {
				delete(g.title)
				g.title = strings.clone(label)
			}
			append(out, g)
		}
		scan_children(out, root_str, label, true)
	}
}

scan_children :: proc(out: ^[dynamic]Game, parent, label: string, from_drive: bool) {
	fis, err := os.read_all_directory_by_path(parent, context.allocator)
	if err != nil {
		return
	}
	defer os.file_info_slice_delete(fis, context.allocator)

	for fi in fis {
		if fi.type != .Directory {
			continue
		}
		base := fi.name if fi.name != "" else filepath.base(fi.fullpath)
		if base == "." || base == ".." || base == "_Saber" {
			continue
		}
		if g, ok := game_from_folder(fi.fullpath, label, from_drive); ok {
			append(out, g)
		}
	}
}

volume_label :: proc(root: win.LPCWSTR, letter: rune) -> string {
	name: [261]u16
	ok := GetVolumeInformationW(root, raw_data(name[:]), u32(len(name)), nil, nil, nil, nil, 0)
	if ok && name[0] != 0 {
		return strings.clone(wide_to_utf8(raw_data(name[:]), -1))
	}
	return fmt.aprintf("%c:", letter)
}
