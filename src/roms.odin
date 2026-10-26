package saber

// Cartridge games: a single ROM file (.gba, .nes, .sfc...) in the root of an inserted drive,
// or one folder down (e.g. F:\GBA\Pokemon Emerald (USA).gba), becomes a Main-screen game
// played by the built-in libretro host. Its CRC32 identifies it for plugins (covers / info),
// with the file name as fallback, so No-Intro-named ROMs are found either way.

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"

// ext is lowercase, with the dot
rom_platform :: proc(ext: string) -> (Retro_Platform, bool) {
	switch ext {
	case ".gb":                  return .GB, true
	case ".gbc":                 return .GBC, true
	case ".gba":                 return .GBA, true
	case ".nes":                 return .NES, true
	case ".sfc", ".smc":         return .SNES, true
	case ".n64", ".z64", ".v64": return .N64, true
	case ".md", ".gen", ".smd":  return .MD, true
	case ".sms":                 return .SMS, true
	case ".gg":                  return .GG, true
	case ".nds":                 return .NDS, true
	case ".pce":                 return .PCE, true
	case ".a26":                 return .A2600, true
	}
	return .None, false
}

ROM_MAX_PER_DRIVE :: 1000
ROM_MAX_HASH_SIZE :: 32 * 1024 * 1024 // bigger ROMs (N64, DS) are identified by file name only

// "path|size|mtime" -> CRC32 hex, so rescans (every drive change) never re-read a ROM
rom_crc_cache: map[string]string

scan_roms :: proc(out: ^[dynamic]Game, root, label: string) {
	found := 0
	scan_rom_dir(out, root, label, &found)
	fis, err := os.read_all_directory_by_path(root, context.allocator)
	if err != nil do return
	defer os.file_info_slice_delete(fis, context.allocator)
	for fi in fis {
		if fi.type != .Directory || fi.name == "_Saber" || strings.has_prefix(fi.name, "$") do continue
		if fi.name == "System Volume Information" do continue
		if os.exists(path_join({fi.fullpath, "_Saber"})) do continue // a _Saber game's own files
		scan_rom_dir(out, fi.fullpath, label, &found)
	}
}

scan_rom_dir :: proc(out: ^[dynamic]Game, dir, label: string, found: ^int) {
	fis, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil do return
	defer os.file_info_slice_delete(fis, context.allocator)
	for fi in fis {
		if found^ >= ROM_MAX_PER_DRIVE do return
		if fi.type != .Regular do continue
		ext := strings.to_lower(filepath.ext(fi.name), context.temp_allocator)
		platform, ok := rom_platform(ext)
		if !ok do continue
		append(out, rom_game(fi, label, platform))
		found^ += 1
	}
}

rom_game :: proc(fi: os.File_Info, label: string, platform: Retro_Platform) -> Game {
	g: Game
	g.rom_path = strings.clone(fi.fullpath)
	g.rom_name = strings.clone(filepath.stem(fi.name))
	g.rom_crc = strings.clone(rom_crc(fi))
	g.root = strings.clone(g.rom_path)
	g.drive_label = strings.clone(label)
	g.from_drive = true
	g.platform = platform
	g.meta_platform = platform
	g.disc_serial = strings.clone(g.rom_crc != "" ? g.rom_crc : g.rom_name)
	g.title = strings.clone(rom_display_title(g.rom_name))
	plugins_apply(&g)
	return g
}

rom_crc :: proc(fi: os.File_Info) -> string {
	if fi.size <= 0 || fi.size > ROM_MAX_HASH_SIZE do return ""
	key := fmt.tprintf("%s|%d|%v", fi.fullpath, fi.size, fi.modification_time)
	if v, ok := rom_crc_cache[key]; ok do return v
	data, err := os.read_entire_file(fi.fullpath, context.allocator)
	if err != nil do return ""
	defer delete(data)
	body := data
	// SNES copier header: No-Intro hashes the ROM without it
	ext := strings.to_lower(filepath.ext(fi.name), context.temp_allocator)
	if (ext == ".sfc" || ext == ".smc") && len(body) % 1024 == 512 do body = body[512:]
	v := fmt.aprintf("%08X", hash.crc32(body))
	rom_crc_cache[strings.clone(key)] = v
	return v
}

// "Legend of Zelda, The - A Link to the Past (USA) [!]" -> "The Legend of Zelda - A Link to the Past"
rom_display_title :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	depth := 0
	for r in name {
		switch r {
		case '(', '[': depth += 1
		case ')', ']': depth = max(depth - 1, 0)
		case:          if depth == 0 do strings.write_rune(&b, r == '_' ? ' ' : r)
		}
	}
	t := strings.trim_space(strings.to_string(b))
	for article in ([]string{"The", "A", "An"}) {
		suffix := fmt.tprintf(", %s", article)
		// "Zelda, The - Subtitle" or "Zelda, The"
		if i := strings.index(t, fmt.tprintf("%s - ", suffix)); i >= 0 {
			t = fmt.tprintf("%s %s%s", article, t[:i], t[i + len(suffix):])
			break
		}
		if strings.has_suffix(t, suffix) {
			t = fmt.tprintf("%s %s", article, t[:len(t) - len(suffix)])
			break
		}
	}
	return t != "" ? t : name
}
