package saber

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Drives are addressed by letter on every platform; drives_<os>.odin maps letters to
// volumes (on Linux, to mount points) and provides current_drive_mask, drive_type,
// drive_root, drive_path, volume_label and volume_serial.

// Set on the drive-scan worker (drive_scan.odin): texture uploads and plugin (Lua)
// calls are recorded on each Game and finished on the main thread instead.
@(thread_local) scan_deferred: bool

DRIVE_REMOVABLE :: 2
DRIVE_FIXED :: 3
DRIVE_CDROM :: 5

scan_library :: proc(out: ^[dynamic]Game, games_dir: string) {
	if !os.exists(games_dir) {
		return
	}
	scan_children(out, games_dir, "Library", false)
}

// APP/games_roms/: one folder per platform holding installed discs (<game>/_Saber/saber.ini
// with rom=, see install.odin) and loose ROMs / disc images copied as-is.
scan_library_roms :: proc(out: ^[dynamic]Game, roms_dir: string) {
	fis, err := os.read_all_directory_by_path(roms_dir, context.allocator)
	if err != nil do return
	defer os.file_info_slice_delete(fis, context.allocator)
	first := len(out)
	found := 0
	scan_rom_dir(out, roms_dir, "Library", &found)
	for fi in fis {
		if fi.type != .Directory || strings.has_suffix(fi.name, INSTALL_PART) do continue
		scan_children(out, fi.fullpath, "Library", false)
		scan_rom_dir(out, fi.fullpath, "Library", &found)
	}
	for k in first ..< len(out) do out[k].from_drive = false
}

is_insertable_drive :: proc(letter: rune) -> bool {
	if is_system_drive(letter) || drive_ignored(letter) {
		return false
	}
	kind := drive_type(letter)
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

		first := len(out)
		defer for k in first ..< len(out) do out[k].drive_letter = u8(letter)
		if scan_deferred do drive_scan_note(fmt.tprintf("%c:", letter))
		label := volume_label(letter)
		if scan_deferred do drive_scan_note(label)
		root_str := strings.clone(drive_root(letter))
		has_files := root_str != "" // "" = an optical drive whose disc isn't mounted (audio / raw data)
		if has_files {
			if g, ok := game_from_folder(root_str, label, true); ok {
				base := filepath.base(strings.trim_right(root_str, "\\/"))
				if base == "" || base == "." || strings.has_suffix(base, ":") {
					delete(g.title)
					g.title = strings.clone(label)
				}
				append(out, g)
			}
		}
		before := len(out)
		if has_files {
			scan_children(out, root_str, label, true)
		}
		if len(out) == before && drive_type(letter) == DRIVE_CDROM {
			if g, ok := disc_game(letter, label); ok {
				append(out, g)
			}
		}
		if has_files {
			scan_roms(out, root_str, label)
		}
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
		if base == "." || base == ".." || base == "_Saber" || strings.has_suffix(base, INSTALL_PART) {
			continue
		}
		if g, ok := game_from_folder(fi.fullpath, label, from_drive); ok {
			append(out, g)
		}
	}
}
