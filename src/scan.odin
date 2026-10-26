package saber

import "core:os"
import "core:path/filepath"
import "core:strings"

// Drives are addressed by letter on every platform; drives_<os>.odin maps letters to
// volumes (on Linux, to mount points) and provides current_drive_mask, drive_type,
// drive_root, drive_path, volume_label and volume_serial.

DRIVE_REMOVABLE :: 2
DRIVE_FIXED :: 3
DRIVE_CDROM :: 5

scan_library :: proc(out: ^[dynamic]Game, games_dir: string) {
	if !os.exists(games_dir) {
		return
	}
	scan_children(out, games_dir, "Library", false)
}

is_insertable_drive :: proc(letter: rune) -> bool {
	if is_system_drive(letter) {
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

		label := volume_label(letter)
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
		if base == "." || base == ".." || base == "_Saber" {
			continue
		}
		if g, ok := game_from_folder(fi.fullpath, label, from_drive); ok {
			append(out, g)
		}
	}
}
