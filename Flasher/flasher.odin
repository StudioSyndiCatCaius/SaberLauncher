package flasher

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode/utf8"
import rl "vendor:raylib"
import win "core:sys/windows"

// Saber Flasher: builds a `_Saber` config for a PC game and installs it to a drive or folder.
// Static raylib exports CloseWindow, so user32/shell32/comdlg32 are loaded at runtime (see Saber's winapi.odin).

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	GetLogicalDrives :: proc() -> u32 ---
	GetDriveTypeW :: proc(lpRootPathName: win.LPCWSTR) -> u32 ---
	GetVolumeInformationW :: proc(root: win.LPCWSTR, name: win.LPWSTR, name_len: u32, serial, max_comp, flags: ^u32, fs: win.LPWSTR, fs_len: u32) -> win.BOOL ---
	GetDiskFreeSpaceExW :: proc(root: win.LPCWSTR, free_avail, total, total_free: ^u64) -> win.BOOL ---
}

DRIVE_REMOVABLE :: 2
DRIVE_FIXED :: 3

BROWSEINFOW :: struct {
	hwndOwner:      win.HWND,
	pidlRoot:       rawptr,
	pszDisplayName: win.LPWSTR,
	lpszTitle:      win.LPCWSTR,
	ulFlags:        u32,
	lpfn:           rawptr,
	lParam:         win.LPARAM,
	iImage:         i32,
}
BIF_RETURNONLYFSDIRS :: 0x1
BIF_NEWDIALOGSTYLE :: 0x40
OFN_FILEMUSTEXIST :: 0x1000
OFN_NOCHANGEDIR :: 0x8

GetOpenFileNameW: proc "system" (ofn: ^win.OPENFILENAMEW) -> win.BOOL
SHBrowseForFolderW: proc "system" (bi: ^BROWSEINFOW) -> rawptr
SHGetPathFromIDListW: proc "system" (pidl: rawptr, path: win.LPWSTR) -> win.BOOL
ShellExecuteW: proc "system" (hwnd: win.HWND, op, file, params, dir: win.LPCWSTR, show: i32) -> win.HINSTANCE

@(init)
load_dialog_libs :: proc "contextless" () {
	if m := win.LoadLibraryW(win.L("comdlg32.dll")); m != nil {
		GetOpenFileNameW = auto_cast win.GetProcAddress(m, "GetOpenFileNameW")
	}
	if m := win.LoadLibraryW(win.L("shell32.dll")); m != nil {
		SHBrowseForFolderW = auto_cast win.GetProcAddress(m, "SHBrowseForFolderW")
		SHGetPathFromIDListW = auto_cast win.GetProcAddress(m, "SHGetPathFromIDListW")
		ShellExecuteW = auto_cast win.GetProcAddress(m, "ShellExecuteW")
	}
}

// ---------------------------------------------------------------- palette (Saber theme)

COL_BG :: rl.Color{11, 13, 20, 255}
COL_SIDEBAR :: rl.Color{15, 18, 28, 255}
COL_CARD :: rl.Color{20, 24, 36, 255}
COL_CARD_HI :: rl.Color{30, 36, 54, 255}
COL_INPUT :: rl.Color{13, 16, 25, 255}
COL_BORDER :: rl.Color{255, 255, 255, 20}
COL_BORDER_HI :: rl.Color{255, 255, 255, 48}
COL_ACCENT :: rl.Color{92, 204, 255, 255}
COL_ACCENT_HI :: rl.Color{140, 220, 255, 255}
COL_ON_ACCENT :: rl.Color{6, 18, 30, 255}
COL_TEXT :: rl.Color{236, 240, 248, 255}
COL_MUTED :: rl.Color{140, 150, 172, 255}
COL_FAINT :: rl.Color{90, 98, 120, 255}
COL_OK :: rl.Color{86, 214, 146, 255}
COL_WARN :: rl.Color{255, 178, 76, 255}
COL_DANGER :: rl.Color{255, 98, 112, 255}

// Segoe MDL2 Assets glyphs
IC_GAME :: rune(0xE7FC)
IC_PICTURE :: rune(0xE8B9)
IC_DRIVE :: rune(0xEDA2)
IC_USB :: rune(0xE88E)
IC_FOLDER :: rune(0xED25)
IC_GLOBE :: rune(0xE774)
IC_CHECK :: rune(0xE73E)
IC_WARN :: rune(0xE7BA)
IC_REFRESH :: rune(0xE72C)
IC_CLOSE :: rune(0xE711)
IC_FLASH :: rune(0xE945)
IC_BACK :: rune(0xE72B)
IC_NEXT :: rune(0xE72A)
IC_OPEN :: rune(0xE8A7)
IC_ERASE :: rune(0xE75C)
IC_SEARCH :: rune(0xE721)
IC_DOWNLOAD :: rune(0xE896)
IC_SETTINGS :: rune(0xE713)
IC_DISC :: rune(0xE958)

ICON_CODEPOINTS := [?]rune{IC_GAME, IC_PICTURE, IC_DRIVE, IC_USB, IC_FOLDER, IC_GLOBE, IC_CHECK, IC_WARN, IC_REFRESH, IC_CLOSE, IC_FLASH, IC_BACK, IC_NEXT, IC_OPEN, IC_ERASE, IC_SEARCH, IC_DOWNLOAD, IC_SETTINGS, IC_DISC}

FONT_REGULAR :: `C:\Windows\Fonts\segoeui.ttf`
FONT_BOLD :: `C:\Windows\Fonts\seguisb.ttf`
FONT_ICONS :: `C:\Windows\Fonts\segmdl2.ttf`

// Fonts are rasterised at the exact pixel size they're drawn at, so text stays crisp.
font_cache: map[i32]rl.Font

get_font :: proc(size: f32, bold := false, icons := false) -> rl.Font {
	px := i32(size + 0.5)
	key := px + (bold ? 1000 : 0) + (icons ? 2000 : 0)
	if f, ok := font_cache[key]; ok do return f
	f: rl.Font
	if icons {
		if os.exists(FONT_ICONS) do f = rl.LoadFontEx(FONT_ICONS, px, &ICON_CODEPOINTS[0], len(ICON_CODEPOINTS))
	} else {
		path := bold ? FONT_BOLD : FONT_REGULAR
		if os.exists(path) {
			cps: [dynamic]rune
			defer delete(cps)
			for r in 32 ..= 126 do append(&cps, rune(r))
			for r in 160 ..= 255 do append(&cps, rune(r))
			append(&cps, '…', '•', '→', '—', '·')
			f = rl.LoadFontEx(strings.clone_to_cstring(path, context.temp_allocator), px, raw_data(cps), i32(len(cps)))
		}
	}
	if f.texture.id == 0 {
		f = rl.GetFontDefault()
	} else {
		rl.SetTextureFilter(f.texture, .BILINEAR)
	}
	font_cache[key] = f
	return f
}

cs :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

text_w :: proc(s: string, size: f32, bold := false) -> f32 {
	return rl.MeasureTextEx(get_font(size, bold), cs(s), size, 0).x
}

draw_text :: proc(s: string, x, y, size: f32, col: rl.Color, bold := false) {
	rl.DrawTextEx(get_font(size, bold), cs(s), {f32(i32(x)), f32(i32(y))}, size, 0, col)
}

// Truncates with an ellipsis so it fits max_w.
draw_text_fit :: proc(s: string, x, y, size: f32, col: rl.Color, max_w: f32, bold := false) {
	if text_w(s, size, bold) <= max_w {
		draw_text(s, x, y, size, col, bold)
		return
	}
	n := len(s)
	for n > 0 && text_w(fmt.tprintf("%s…", s[:n]), size, bold) > max_w {
		n -= 1
		for n > 0 && s[n] & 0xC0 == 0x80 do n -= 1
	}
	draw_text(fmt.tprintf("%s…", s[:n]), x, y, size, col, bold)
}

draw_icon :: proc(ic: rune, cx, cy, size: f32, col: rl.Color) {
	f := get_font(size, icons = true)
	if f.texture.id == rl.GetFontDefault().texture.id do return
	rl.DrawTextCodepoint(f, ic, {f32(i32(cx - size / 2)), f32(i32(cy - size / 2))}, size, col)
}

rounded :: proc(r: rl.Rectangle, radius: f32, col: rl.Color) {
	m := min(r.width, r.height)
	if m <= 0 do return
	rl.DrawRectangleRounded(r, min(1, radius * 2 / m), 16, col)
}

rounded_line :: proc(r: rl.Rectangle, radius: f32, thick: f32, col: rl.Color) {
	m := min(r.width, r.height)
	if m <= 0 do return
	rl.DrawRectangleRoundedLinesEx(r, min(1, radius * 2 / m), 16, thick, col)
}

mix :: proc(a, b: rl.Color, t: f32) -> rl.Color {
	return rl.ColorLerp(a, b, clamp(t, 0, 1))
}

alpha :: proc(c: rl.Color, a: u8) -> rl.Color {
	return {c.r, c.g, c.b, a}
}

inset :: proc(r: rl.Rectangle, d: f32) -> rl.Rectangle {
	return {r.x + d, r.y + d, r.width - 2 * d, r.height - 2 * d}
}

// ---------------------------------------------------------------- immediate-mode widgets

mouse: rl.Vector2
dt: f32
cursor: rl.MouseCursor
modal_active: bool
drawing_modal: bool
anims: map[u64]f32

interactive :: proc() -> bool {
	return !modal_active || drawing_modal
}

hovered :: proc(r: rl.Rectangle) -> bool {
	return interactive() && rl.CheckCollisionPointRec(mouse, r)
}

clicked :: proc(r: rl.Rectangle) -> bool {
	return hovered(r) && rl.IsMouseButtonPressed(.LEFT)
}

rect_id :: proc(r: rl.Rectangle, salt: u64 = 0) -> u64 {
	return (u64(u32(i32(r.x))) << 32 | u64(u32(i32(r.y)))) ~ (salt * 0x9E3779B97F4A7C15)
}

// Smoothly eases towards 0/1 for hover & selection transitions.
anim :: proc(id: u64, on: bool, speed: f32 = 16) -> f32 {
	v := anims[id]
	v += ((on ? 1 : 0) - v) * min(1, speed * dt)
	anims[id] = v
	return v
}

Btn :: enum {
	Primary,
	Secondary,
	Ghost,
	Danger,
}

button :: proc(r: rl.Rectangle, label: string, kind := Btn.Secondary, ic: rune = 0, disabled := false) -> bool {
	h := !disabled && hovered(r)
	a := anim(rect_id(r, 1), h)
	if h do cursor = .POINTING_HAND

	bg, fg, border: rl.Color
	switch kind {
	case .Primary:
		bg, fg = mix(COL_ACCENT, COL_ACCENT_HI, a), COL_ON_ACCENT
	case .Secondary:
		bg, fg, border = mix(COL_CARD_HI, rl.Color{42, 50, 72, 255}, a), COL_TEXT, COL_BORDER
	case .Ghost:
		bg, fg = alpha(COL_TEXT, u8(a * 18)), mix(COL_MUTED, COL_TEXT, a)
	case .Danger:
		bg, fg, border = mix(alpha(COL_DANGER, 26), alpha(COL_DANGER, 60), a), COL_DANGER, alpha(COL_DANGER, 70)
	}
	if disabled {
		bg = alpha(bg, 70)
		fg = alpha(fg, 110)
	}
	rr := r
	if h && rl.IsMouseButtonDown(.LEFT) do rr = inset(r, 1)
	rounded(rr, 9, bg)
	if border.a > 0 do rounded_line(rr, 9, 1, border)

	size := r.height >= 46 ? f32(17) : f32(15)
	tw := text_w(label, size, true)
	isz := size + 1
	total := tw + (ic != 0 ? isz + 10 : 0)
	if label == "" do total = isz
	x := r.x + (r.width - total) / 2
	if ic != 0 {
		draw_icon(ic, x + isz / 2, r.y + r.height / 2, isz, fg)
		x += isz + 10
	}
	if label != "" do draw_text(label, x, r.y + (r.height - size) / 2 - 1, size, fg, true)
	return h && rl.IsMouseButtonPressed(.LEFT)
}

toggle :: proc(x, y: f32, on: ^bool, label: string) {
	track := rl.Rectangle{x, y, 44, 24}
	hit := rl.Rectangle{x, y - 4, 54 + text_w(label, 15), 32}
	if hovered(hit) do cursor = .POINTING_HAND
	if clicked(hit) do on^ = !on^
	a := anim(rect_id(track, 2), on^)
	rounded(track, 12, mix(COL_CARD_HI, COL_ACCENT, a))
	rl.DrawCircleV({x + 12 + a * 20, y + 12}, 9, mix(COL_MUTED, COL_ON_ACCENT, a))
	draw_text(label, x + 56, y + 3, 15, COL_TEXT)
}

segmented :: proc(r: rl.Rectangle, options: []string, active: ^int, icons: []rune = nil, locked := false) {
	rounded(r, 10, COL_INPUT)
	rounded_line(r, 10, 1, COL_BORDER)
	w := (r.width - 8) / f32(len(options))
	pos := anims[rect_id(r, 3)]
	pos += (f32(active^) - pos) * min(1, 18 * dt)
	anims[rect_id(r, 3)] = pos
	rounded({r.x + 4 + pos * w, r.y + 4, w, r.height - 8}, 8, COL_CARD_HI)
	for opt, i in options {
		cell := rl.Rectangle{r.x + 4 + f32(i) * w, r.y + 4, w, r.height - 8}
		if !locked {
			if hovered(cell) do cursor = .POINTING_HAND
			if clicked(cell) do active^ = i
		}
		col := i == active^ ? COL_TEXT : COL_MUTED
		tw := text_w(opt, 15, true)
		has_ic := icons != nil && i < len(icons)
		tx := cell.x + (cell.width - tw - (has_ic ? 26 : 0)) / 2
		if has_ic {
			draw_icon(icons[i], tx + 8, cell.y + cell.height / 2, 16, i == active^ ? COL_ACCENT : COL_MUTED)
			tx += 26
		}
		draw_text(opt, tx, cell.y + (cell.height - 15) / 2 - 1, 15, col, true)
	}
}

card :: proc(r: rl.Rectangle) {
	rounded({r.x, r.y + 3, r.width, r.height}, 14, {0, 0, 0, 70})
	rounded(r, 14, COL_CARD)
	rounded_line(r, 14, 1, COL_BORDER)
}

pill :: proc(x, y: f32, label: string, col: rl.Color, ic: rune = 0) -> f32 {
	tw := text_w(label, 13, true)
	w := tw + 20 + (ic != 0 ? 18 : 0)
	rounded({x, y, w, 22}, 11, alpha(col, 34))
	tx := x + 10
	if ic != 0 {
		draw_icon(ic, tx + 6, y + 11, 12, col)
		tx += 18
	}
	draw_text(label, tx, y + 3, 13, col, true)
	return w
}

field_label :: proc(x, y: f32, label: string, hint: string = "", width: f32 = 0) {
	draw_text(label, x, y, 13, COL_MUTED, true)
	if hint != "" && width > 0 {
		draw_text(hint, x + width - text_w(hint, 13), y, 13, COL_FAINT)
	}
}

// ---------------------------------------------------------------- text input

Field :: struct {
	buf:    [512]u8,
	n:      int,
	caret:  int,
	scroll: f32,
}

focused: ^Field
focus_order: [dynamic]^Field
click_hit_input: bool

field_str :: proc(f: ^Field) -> string {
	return strings.trim_space(string(f.buf[:f.n]))
}

field_set :: proc(f: ^Field, s: string) {
	f.n = min(len(s), len(f.buf) - 1)
	copy(f.buf[:f.n], s[:f.n])
	f.caret = f.n
	f.scroll = 0
}

field_insert :: proc(f: ^Field, b: []u8) {
	if f.n + len(b) >= len(f.buf) do return
	copy(f.buf[f.caret + len(b):f.n + len(b)], f.buf[f.caret:f.n])
	copy(f.buf[f.caret:], b)
	f.n += len(b)
	f.caret += len(b)
}

field_remove :: proc(f: ^Field, a, b: int) {
	copy(f.buf[a:], f.buf[b:f.n])
	f.n -= b - a
}

rune_prev :: proc(f: ^Field, i: int) -> int {
	p := i - 1
	for p > 0 && f.buf[p] & 0xC0 == 0x80 do p -= 1
	return max(p, 0)
}

rune_next :: proc(f: ^Field, i: int) -> int {
	p := i + 1
	for p < f.n && f.buf[p] & 0xC0 == 0x80 do p += 1
	return min(p, f.n)
}

key_rep :: proc(k: rl.KeyboardKey) -> bool {
	return rl.IsKeyPressed(k) || rl.IsKeyPressedRepeat(k)
}

field_edit :: proc(f: ^Field) {
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	for {
		ch := rl.GetCharPressed()
		if ch == 0 do break
		if ch < 32 do continue
		b, w := utf8.encode_rune(ch)
		field_insert(f, b[:w])
	}
	if key_rep(.BACKSPACE) && f.caret > 0 {
		p := ctrl ? 0 : rune_prev(f, f.caret)
		field_remove(f, p, f.caret)
		f.caret = p
	}
	if key_rep(.DELETE) && f.caret < f.n do field_remove(f, f.caret, rune_next(f, f.caret))
	if key_rep(.LEFT) && f.caret > 0 do f.caret = rune_prev(f, f.caret)
	if key_rep(.RIGHT) && f.caret < f.n do f.caret = rune_next(f, f.caret)
	if rl.IsKeyPressed(.HOME) do f.caret = 0
	if rl.IsKeyPressed(.END) do f.caret = f.n
	if ctrl && rl.IsKeyPressed(.V) {
		clip := string(rl.GetClipboardText())
		clip, _ = strings.replace_all(clip, "\r", "", context.temp_allocator)
		clip, _ = strings.replace_all(clip, "\n", " ", context.temp_allocator)
		field_insert(f, transmute([]u8)clip)
	}
	if ctrl && rl.IsKeyPressed(.C) do rl.SetClipboardText(cs(string(f.buf[:f.n])))
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.ESCAPE) do focused = nil
}

text_input :: proc(f: ^Field, r: rl.Rectangle, placeholder: string) {
	append(&focus_order, f)
	size: f32 = 16
	pad: f32 = 14
	inner := r.width - 2 * pad
	h := hovered(r)
	if h do cursor = .IBEAM
	if clicked(r) {
		focused = f
		click_hit_input = true
		// place caret nearest the click
		target := mouse.x - (r.x + pad) + f.scroll
		best, best_d := f.n, f32(1e9)
		i := 0
		for {
			d := abs(text_w(string(f.buf[:i]), size) - target)
			if d < best_d {
				best, best_d = i, d
			}
			if i >= f.n do break
			i = rune_next(f, i)
		}
		f.caret = best
	}
	active := focused == f && interactive()
	if active do field_edit(f)

	a := anim(rect_id(r, 4), active)
	rounded(r, 9, COL_INPUT)
	rounded_line(r, 9, 1 + a, mix(h ? COL_BORDER_HI : COL_BORDER, COL_ACCENT, a))

	text := string(f.buf[:f.n])
	caret_x := text_w(text[:f.caret], size)
	if caret_x - f.scroll > inner do f.scroll = caret_x - inner
	if caret_x < f.scroll do f.scroll = caret_x
	if text_w(text, size) <= inner do f.scroll = 0

	ty := r.y + (r.height - size) / 2 - 1
	rl.BeginScissorMode(i32(r.x + pad - 2), i32(r.y), i32(inner + 4), i32(r.height))
	if f.n == 0 {
		draw_text(placeholder, r.x + pad, ty, size, COL_FAINT)
	} else {
		draw_text(text, r.x + pad - f.scroll, ty, size, COL_TEXT)
	}
	if active && i32(rl.GetTime() * 2) % 2 == 0 {
		cx := r.x + pad + caret_x - f.scroll
		rl.DrawRectangleRec({cx, ty, 2, size + 3}, COL_ACCENT)
	}
	rl.EndScissorMode()
}

// Input with a browse button on the right; returns true when browse is clicked.
path_input :: proc(f: ^Field, r: rl.Rectangle, placeholder: string, ic := IC_FOLDER) -> bool {
	text_input(f, {r.x, r.y, r.width - r.height - 8, r.height}, placeholder)
	return button({r.x + r.width - r.height, r.y, r.height, r.height}, "", .Secondary, ic)
}

// ---------------------------------------------------------------- data

F_NAME :: 0
F_TAGS :: 1
F_SOURCE :: 2
F_EXE :: 3
F_ARGS :: 4
F_BOX :: 5
F_LOGO :: 6
F_CUSTOM :: 7
F_URL :: 8
F_SEARCH :: 9
F_CONFIRM :: 10
F_GOG :: 11
F_SIMPRETRO :: 12
F_BIOS :: 13

fields: [14]Field

Drive :: struct {
	letter:    u8,
	serial:    u32, // volume serial, re-checked before formatting
	label:     string,
	fs:        string,
	removable: bool,
	used:      bool, // has non-Saber files at the root
	games:     int,  // Saber games already on the drive
	free:      u64,
	total:     u64,
}

drives: [dynamic]Drive
drive_active := -1

refresh_drives :: proc() {
	selected: u8 = drive_active >= 0 && drive_active < len(drives) ? drives[drive_active].letter : 0
	for d in drives {
		delete(d.label)
		delete(d.fs)
	}
	clear(&drives)
	drive_active = -1
	sys := os.get_env("SystemDrive", context.temp_allocator)
	sys_drive := len(sys) > 0 ? sys[0] : 'C'
	mask := GetLogicalDrives()
	for i in 0 ..< 26 {
		if mask & (u32(1) << u32(i)) == 0 do continue
		letter := u8('A' + i)
		if letter == sys_drive do continue
		root := [4]u16{u16(letter), ':', '\\', 0}
		kind := GetDriveTypeW(wp(root[:]))
		if kind != DRIVE_REMOVABLE && kind != DRIVE_FIXED do continue
		name, fs: [64]u16
		serial: u32
		if !GetVolumeInformationW(wp(root[:]), win.LPWSTR(raw_data(name[:])), 64, &serial, nil, nil, win.LPWSTR(raw_data(fs[:])), 64) do continue
		d := Drive {
			letter    = letter,
			serial    = serial,
			label     = strings.clone(w2s(name[:])),
			fs        = strings.clone(w2s(fs[:])),
			removable = kind == DRIVE_REMOVABLE,
		}
		scan := scan_drive_root(fmt.tprintf("%c:\\", letter))
		d.used, d.games = scan.other, scan.games
		avail: u64
		GetDiskFreeSpaceExW(wp(root[:]), &avail, &d.total, &d.free)
		if letter == selected do drive_active = len(drives)
		append(&drives, d)
	}
}

fmt_size :: proc(b: u64) -> string {
	gb := f64(b) / (1024 * 1024 * 1024)
	if gb >= 1000 do return fmt.tprintf("%.1f TB", gb / 1024)
	if gb >= 1 do return fmt.tprintf("%.1f GB", gb)
	if b >= 1024 * 1024 do return fmt.tprintf("%.0f MB", f64(b) / (1024 * 1024))
	return fmt.tprintf("%.0f KB", f64(b) / 1024)
}

Drive_Scan :: struct {
	other: bool, // anything besides Saber game folders
	games: int,
}

// Saber game folders (`X:\game\_Saber`) don't count as clutter, so several games can share a drive.
scan_drive_root :: proc(dir: string) -> Drive_Scan {
	res: Drive_Scan
	walk_dir(dir, proc(path: string, is_dir: bool, user: rawptr) -> bool {
		r := (^Drive_Scan)(user)
		base := filepath.base(path)
		if base == "System Volume Information" || base == "$RECYCLE.BIN" do return false
		if is_dir && os.exists(fmt.tprintf("%s\\_Saber\\saber.ini", path)) {
			r.games += 1
		} else {
			r.other = true
		}
		return false
	}, &res, recurse = false)
	return res
}

// ---------------------------------------------------------------- file utils

Walk_Proc :: #type proc(path: string, is_dir: bool, user: rawptr) -> (descend: bool)

walk_dir :: proc(dir: string, fn: Walk_Proc, user: rawptr, recurse := true) {
	fd: win.WIN32_FIND_DATAW
	pattern := win.utf8_to_wstring(fmt.tprintf("%s\\*", strings.trim_right(dir, "\\/")))
	h := win.FindFirstFileW(pattern, &fd)
	if h == win.INVALID_HANDLE_VALUE do return
	defer win.FindClose(h)
	for {
		name := w2s(fd.cFileName[:])
		if name != "." && name != ".." {
			full := strings.concatenate({strings.trim_right(dir, "\\/"), "\\", name})
			is_dir := fd.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0
			if fn(full, is_dir, user) && is_dir && recurse {
				walk_dir(full, fn, user, true)
			}
			delete(full)
		}
		if !win.FindNextFileW(h, &fd) do break
	}
}

make_dirs :: proc(path: string) {
	p := strings.trim_right(path, "\\/")
	if p == "" || os.exists(p) do return
	if i := strings.last_index_any(p, "\\/"); i > 0 do make_dirs(p[:i])
	win.CreateDirectoryW(win.utf8_to_wstring(p), nil)
}

sanitize_name :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for r in s {
		switch r {
		case '<', '>', ':', '"', '/', '\\', '|', '?', '*':
			continue
		}
		strings.write_rune(&sb, r)
	}
	return strings.trim(strings.to_string(sb), " .")
}

is_image :: proc(path: string) -> bool {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	return ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".bmp" || ext == ".tga" || ext == ".gif"
}

wp :: proc(b: []u16) -> win.LPCWSTR {
	return win.LPCWSTR(raw_data(b))
}

// NUL-terminated UTF-16 buffer -> temp UTF-8 string
w2s :: proc(b: []u16) -> string {
	n := 0
	for n < len(b) && b[n] != 0 do n += 1
	s, _ := win.utf16_to_utf8(b[:n], context.temp_allocator)
	return s
}

// ---------------------------------------------------------------- dialogs

IMAGE_FILTER :: "Images|*.png;*.jpg;*.jpeg;*.bmp;*.tga|"

pick_file :: proc(filter: string) -> (string, bool) {
	if GetOpenFileNameW == nil do return "", false
	buf: [1024]u16
	// filter uses '|' separators; Win32 wants NULs and a double NUL at the end
	fw := make([]u16, len(filter) + 2, context.temp_allocator)
	for ch, i in transmute([]u8)filter do fw[i] = ch == '|' ? 0 : u16(ch)
	ofn := win.OPENFILENAMEW {
		lStructSize = size_of(win.OPENFILENAMEW),
		hwndOwner   = win.HWND(rl.GetWindowHandle()),
		lpstrFilter = wp(fw),
		lpstrFile   = cstring16(raw_data(buf[:])),
		nMaxFile    = len(buf),
		Flags       = OFN_FILEMUSTEXIST | OFN_NOCHANGEDIR,
	}
	if !GetOpenFileNameW(&ofn) do return "", false
	return w2s(buf[:]), true
}

pick_folder :: proc(title: string) -> (string, bool) {
	if SHBrowseForFolderW == nil do return "", false
	buf: [1024]u16
	bi := BROWSEINFOW {
		hwndOwner = win.HWND(rl.GetWindowHandle()),
		lpszTitle = win.utf8_to_wstring(title),
		ulFlags   = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE,
	}
	pidl := SHBrowseForFolderW(&bi)
	if pidl == nil do return "", false
	defer win.CoTaskMemFree(pidl)
	if !SHGetPathFromIDListW(pidl, win.LPWSTR(raw_data(buf[:]))) do return "", false
	return w2s(buf[:]), true
}

shell_exec :: proc(op, file, params: string) {
	if ShellExecuteW == nil do return
	ShellExecuteW(nil, win.utf8_to_wstring(op), win.utf8_to_wstring(file), win.utf8_to_wstring(params), nil, 1)
}

// ---------------------------------------------------------------- flashing job (worker thread)

Job :: struct {
	name, tags, source, exe, args, box, logo, dest: string,
	preconfig:                                      string, // _Saber folder of a preconfig to copy from
	script:                                         string, // preconfig's config.lua, if any
	shared:                                         string, // <source>\shared, for Shared(name)
	temp:                                           string, // per-job scratch folder (downloads, extraction)
	gog:                                            string, // GOG games folder from Settings
	simpretro, bios:                                string, // emulator + BIOS folders (disc dumps)
	dump:                                           Disc_Info, // disc to dump on flash (letter 0 = none)
	dump_discs:                                     int,
	files_total, files_done:                        int,
	running, finished, failed, cancel:              bool,
	current:                                        string,
	message:                                        string,
	steps:                                          [dynamic]Step,
	log:                                            [dynamic]string,
	progress:                                       f32, // current step, -1 = indeterminate
	mu:                                             sync.Mutex,
}

job: Job
job_thread: ^thread.Thread
job_overlay: bool // install overlay is up (blocks the rest of the UI until dismissed)

job_set_status :: proc(msg: string, failed := false) {
	sync.guard(&job.mu)
	delete(job.message)
	job.message = strings.clone(msg)
	if failed do job.failed = true
}

job_set_current :: proc(s: string) {
	sync.guard(&job.mu)
	delete(job.current)
	job.current = strings.clone(s)
}

// Ends the job on an error/cancel, marking the running step accordingly.
job_fail :: proc(err: string) {
	if err == CANCELLED_MSG || cancelled() {
		step_end(.Cancelled)
		job_set_status("Cancelled — the install was stopped.", true)
	} else {
		step_end(.Failed, err)
		job_set_status(err, true)
	}
}

job_run :: proc(t: ^thread.Thread) {
	context = runtime.default_context()
	defer {
		if job.temp != "" && os.exists(job.temp) do delete_tree(job.temp)
		sync.atomic_store(&job.running, false)
		sync.atomic_store(&job.finished, true)
	}
	step_begin("Preparing destination")
	make_dirs(job.dest)
	if !os.exists(job.dest) {
		job_fail(fmt.tprintf("Could not create %s", job.dest))
		return
	}

	// 1. copy the game folder (optional)
	if job.source != "" && !strings.equal_fold(strings.trim_right(job.source, "\\/"), strings.trim_right(job.dest, "\\/")) {
		step_begin("Copying game files")
		walk_dir(job.source, proc(path: string, is_dir: bool, user: rawptr) -> bool {
			if !is_dir do sync.atomic_add(&job.files_total, 1)
			return filepath.base(path) != "_Saber"
		}, nil)
		walk_dir(job.source, proc(path: string, is_dir: bool, user: rawptr) -> bool {
			if cancelled() || job.failed do return false
			if filepath.base(path) == "_Saber" && is_dir do return false
			rel := path[len(strings.trim_right(job.source, "\\/")):]
			target := strings.concatenate({strings.trim_right(job.dest, "\\/"), rel}, context.temp_allocator)
			if is_dir {
				make_dirs(target)
			} else {
				job_set_current(rel)
				if !win.CopyFileW(win.utf8_to_wstring(path), win.utf8_to_wstring(target), false) {
					job_set_status(fmt.tprintf("Copy failed: %s", rel), true)
				}
				done := sync.atomic_add(&job.files_done, 1) + 1
				total := sync.atomic_load(&job.files_total)
				step_progress(f32(done) / f32(max(total, 1)), fmt.tprintf("%d / %d files", done, total))
			}
			free_all(context.temp_allocator)
			return true
		}, nil)
		if cancelled() || job.failed {
			job_fail(cancelled() ? CANCELLED_MSG : job.message)
			return
		}
	}

	// 1b. dump a disc straight into the destination (+ SimpRetro, core, BIOS)
	if job.dump.letter != 0 {
		if err := run_dump(); err != "" {
			job_fail(err)
			return
		}
	}

	// 2. game-specific install script
	if job.script != "" {
		step_begin("Running install script")
		if err := run_install_script(job.script); err != "" {
			job_fail(err)
			return
		}
	}

	// 3. write _Saber
	step_begin("Writing _Saber config")
	saber := strings.concatenate({strings.trim_right(job.dest, "\\/"), "\\_Saber"}, context.temp_allocator)
	make_dirs(saber)
	extra_ini := ""
	if job.preconfig != "" {
		// bring along everything else the preconfig ships (screenshots, extra art...)
		walk_dir(job.preconfig, proc(path: string, is_dir: bool, user: rawptr) -> bool {
			base := strings.to_lower(filepath.base(path), context.temp_allocator)
			if is_dir || base == "saber.ini" || base == "records.ini" do return false
			dst := fmt.tprintf("%s\\_Saber\\%s", strings.trim_right(job.dest, "\\/"), filepath.base(path))
			win.CopyFileW(win.utf8_to_wstring(path), win.utf8_to_wstring(dst), false)
			return false
		}, nil, recurse = false)
		extra_ini = preconfig_extra_keys(fmt.tprintf("%s\\saber.ini", job.preconfig))
	}

	has_box := job.box != "" && export_png(job.box, fmt.tprintf("%s\\box.png", saber))
	has_logo := job.logo != "" && export_png(job.logo, fmt.tprintf("%s\\logo.png", saber))

	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "[game]\ntitle=%s\ntags=%s\n", job.name, job.tags)
	if has_logo do strings.write_string(&sb, "logo=logo.png\n")
	if has_box do strings.write_string(&sb, "box=box.png\n")
	fmt.sbprintf(&sb, "exe=%s\nargs=%s\n", job.exe, job.args)
	if job.dump.letter != 0 && job.dump.platform != .Unknown {
		// lets Saber's plugins find covers / info for the dumped game
		fmt.sbprintf(&sb, "serial=%s\nplatform=%s\n", disc_serial(&job.dump), PLATFORM_TAG[job.dump.platform])
	}
	strings.write_string(&sb, extra_ini)
	if err := os.write_entire_file(fmt.tprintf("%s\\saber.ini", saber), transmute([]u8)strings.to_string(sb)); err != nil {
		job_fail("Failed to write saber.ini")
		return
	}
	if job.exe != "" {
		bat := fmt.tprintf("@echo off\r\ncd /d \"%%~dp0..\"\r\nstart \"\" \"%s\" %s\r\n", job.exe, job.args)
		_ = os.write_entire_file(fmt.tprintf("%s\\PLAY.bat", saber), transmute([]u8)bat)
	}
	step_end()
	job.failed = false
	job_set_status(fmt.tprintf("Installed to %s", job.dest))
}

// Keys from a preconfig's saber.ini that the flasher doesn't manage itself (e.g. screenshot=).
preconfig_extra_keys :: proc(ini: string) -> string {
	data, err := os.read_entire_file(ini, context.temp_allocator)
	if err != nil do return ""
	sb := strings.builder_make(context.temp_allocator)
	for line in strings.split_lines(strings.trim_prefix(string(data), "\uFEFF"), context.temp_allocator) {
		k, sep, _ := strings.partition(line, "=")
		k = strings.trim_space(k)
		if sep == "" do continue
		switch k {
		case "title", "tags", "logo", "box", "exe", "args", "date_added", "date_first_played", "date_last_played", "playtime_seconds":
			continue
		}
		fmt.sbprintf(&sb, "%s\n", strings.trim_space(line))
	}
	return strings.to_string(sb)
}

export_png :: proc(src, dst: string) -> bool {
	img := rl.LoadImage(cs(src))
	if img.data == nil {
		job_set_status(fmt.tprintf("Could not load image %s", filepath.base(src)), true)
		return false
	}
	defer rl.UnloadImage(img)
	return rl.ExportImage(img, cs(dst))
}

// ---------------------------------------------------------------- app state

Page :: enum {
	Game,
	Artwork,
	Install,
	Configs,
	Settings,
	Dump,
}

page: Page
target_mode: int // 0 = drive, 1 = custom folder, 2 = Saber's own games library (next to the exe)
confirm: enum {
	None,
	Flash_Used_Drive,
	Format,
}

status_buf: [512]u8
status: string
status_col: rl.Color = COL_MUTED

set_status :: proc(s: string, col := COL_MUTED) {
	status = fmt.bprint(status_buf[:], s)
	status_col = col
}

Art :: struct {
	tex:  rl.Texture2D,
	path: string,
}
box_art, logo_art: Art

dest_path :: proc() -> (string, bool) {
	name := sanitize_name(field_str(&fields[F_NAME]))
	if target_mode == 0 {
		if drive_active < 0 || drive_active >= len(drives) do return "", false
		root := fmt.tprintf("%c:\\", drives[drive_active].letter)
		if name == "" do return "", false
		return fmt.tprintf("%s%s", root, name), true
	}
	if target_mode == 2 {
		if name == "" do return "", false
		return fmt.tprintf("%s\\%s", library_dir(), name), true
	}
	base := field_str(&fields[F_CUSTOM])
	if base == "" do return "", false
	if name == "" do return "", false
	return fmt.tprintf("%s\\%s", strings.trim_right(base, "\\/"), name), true
}

// Saber's local library: APP\games, i.e. `games` next to SaberFlasher.exe / Saber.exe.
library_dir :: proc() -> string {
	return fmt.tprintf("%s\\games", filepath.dir(os.args[0]))
}

library_game_count :: proc() -> int {
	n := 0
	walk_dir(library_dir(), proc(path: string, is_dir: bool, user: rawptr) -> bool {
		if is_dir && os.exists(fmt.tprintf("%s\\_Saber\\saber.ini", path)) do (^int)(user)^ += 1
		return false
	}, &n, recurse = false)
	return n
}

// Exe path stored in saber.ini relative to the game folder when possible.
exe_relative :: proc() -> string {
	exe := field_str(&fields[F_EXE])
	src := strings.trim_right(field_str(&fields[F_SOURCE]), "\\/")
	if src != "" && len(exe) > len(src) && strings.equal_fold(exe[:len(src)], src) && (exe[len(src)] == '\\' || exe[len(src)] == '/') {
		return exe[len(src) + 1:]
	}
	if src != "" && filepath.is_abs(exe) do return filepath.base(exe)
	return exe
}

start_flash :: proc() {
	dest, ok := dest_path()
	if field_str(&fields[F_NAME]) == "" {
		set_status("Give the game a name first.", COL_WARN)
		page = .Game
		return
	}
	if !ok {
		set_status("Pick a drive or folder to install to.", COL_WARN)
		return
	}
	src := field_str(&fields[F_SOURCE])
	if src != "" && !os.is_dir(src) {
		set_status("The game folder doesn't exist.", COL_WARN)
		page = .Game
		return
	}

	clean_job()
	job.name = strings.clone(field_str(&fields[F_NAME]))
	job.tags = strings.clone(field_str(&fields[F_TAGS]))
	job.source = strings.clone(src)
	job.exe = strings.clone(exe_relative())
	job.args = strings.clone(field_str(&fields[F_ARGS]))
	job.box = strings.clone(field_str(&fields[F_BOX]))
	job.logo = strings.clone(field_str(&fields[F_LOGO]))
	job.dest = strings.clone(dest)
	job.preconfig = strings.clone(preconfig_dir)
	job.gog = strings.clone(field_str(&fields[F_GOG]))
	job.simpretro = strings.clone(field_str(&fields[F_SIMPRETRO]))
	job.bios = strings.clone(field_str(&fields[F_BIOS]))
	if dump_active {
		job.dump = dump_disc
		job.dump_discs = dump_discs
	}
	if preconfig_dir != "" {
		game_dir := filepath.dir(preconfig_dir)
		if lua := fmt.tprintf("%s\\config.lua", game_dir); os.exists(lua) do job.script = strings.clone(lua)
		// shared\ sits at the source root: <source>\games\<id>\_Saber or <source>\<id>\_Saber
		d := game_dir
		for _ in 0 ..< 3 {
			d = filepath.dir(d)
			if sh := fmt.tprintf("%s\\shared", d); os.is_dir(sh) {
				job.shared = strings.clone(sh)
				break
			}
		}
	}
	tmp: [260]u16
	n := win.GetTempPathW(len(tmp), cstring16(raw_data(tmp[:])))
	job.temp = strings.clone(fmt.tprintf("%s\\SaberFlasher\\job_%d", strings.trim_right(w2s(tmp[:n]), "\\"), win.GetCurrentProcessId()))
	job.progress = -1
	job.running = true
	job_overlay = true
	set_status("")
	job_thread = thread.create(job_run)
	thread.start(job_thread)
}

clean_job :: proc() {
	if job_thread != nil {
		thread.join(job_thread)
		thread.destroy(job_thread)
		job_thread = nil
	}
	delete(job.name); delete(job.tags); delete(job.source); delete(job.exe)
	delete(job.args); delete(job.box); delete(job.logo); delete(job.dest)
	delete(job.message); delete(job.current); delete(job.preconfig)
	delete(job.script); delete(job.shared); delete(job.temp); delete(job.gog); delete(job.simpretro); delete(job.bios)
	for st in job.steps {
		delete(st.name); delete(st.detail)
	}
	delete(job.steps)
	for l in job.log do delete(l)
	delete(job.log)
	job = {}
}

load_saber_ini :: proc(dir: string) {
	data, err := os.read_entire_file(fmt.tprintf("%s\\_Saber\\saber.ini", dir), context.temp_allocator)
	if err != nil do return
	for line in strings.split_lines(string(data), context.temp_allocator) {
		k, _, v := strings.partition(line, "=")
		k = strings.trim_space(k)
		v = strings.trim(strings.trim_space(v), "\"")
		switch k {
		case "title": field_set(&fields[F_NAME], v)
		case "tags":  field_set(&fields[F_TAGS], v)
		case "exe":   field_set(&fields[F_EXE], v)
		case "args":  field_set(&fields[F_ARGS], v)
		case "box":   field_set(&fields[F_BOX], fmt.tprintf("%s\\_Saber\\%s", dir, v))
		case "logo":  field_set(&fields[F_LOGO], fmt.tprintf("%s\\_Saber\\%s", dir, v))
		}
	}
	set_status("Loaded the game's existing _Saber config.", COL_OK)
}

set_source :: proc(dir: string) {
	field_set(&fields[F_SOURCE], dir)
	if field_str(&fields[F_NAME]) == "" do field_set(&fields[F_NAME], filepath.base(dir))
	load_saber_ini(dir)
}

box_rect, logo_rect: rl.Rectangle // last drawn drop zones, for routing dropped files

handle_drops :: proc() {
	if !rl.IsFileDropped() do return
	list := rl.LoadDroppedFiles()
	defer rl.UnloadDroppedFiles(list)
	for i in 0 ..< int(list.count) {
		p := string(list.paths[i])
		if os.is_dir(p) {
			set_source(p)
		} else if is_image(p) {
			if page == .Artwork && rl.CheckCollisionPointRec(mouse, logo_rect) {
				field_set(&fields[F_LOGO], p)
			} else if page == .Artwork && rl.CheckCollisionPointRec(mouse, box_rect) {
				field_set(&fields[F_BOX], p)
			} else if field_str(&fields[F_BOX]) == "" || field_str(&fields[F_LOGO]) != "" {
				field_set(&fields[F_BOX], p)
			} else {
				field_set(&fields[F_LOGO], p)
			}
		} else if strings.to_lower(filepath.ext(p), context.temp_allocator) == ".exe" {
			field_set(&fields[F_EXE], p)
		}
	}
}

update_art :: proc(a: ^Art, p: string) {
	if p == a.path do return
	if a.tex.id != 0 {
		rl.UnloadTexture(a.tex)
		a.tex = {}
	}
	delete(a.path)
	a.path = strings.clone(p)
	if p != "" && os.exists(p) {
		a.tex = rl.LoadTexture(cs(p))
		if a.tex.id != 0 {
			rl.GenTextureMipmaps(&a.tex)
			rl.SetTextureFilter(a.tex, .TRILINEAR)
		}
	}
}

// ---------------------------------------------------------------- layout

SIDEBAR_W :: 250
FOOTER_H :: 76

W, H: f32

content_x :: proc() -> f32 { return SIDEBAR_W + 40 }
content_w :: proc() -> f32 { return W - SIDEBAR_W - 80 }

page_header :: proc(title, subtitle: string) {
	draw_text(title, content_x(), 34, 28, COL_TEXT, true)
	draw_text(subtitle, content_x(), 74, 15, COL_MUTED)
}

step_done :: proc(p: Page) -> bool {
	switch p {
	case .Game:    return field_str(&fields[F_NAME]) != ""
	case .Artwork: return field_str(&fields[F_BOX]) != "" || field_str(&fields[F_LOGO]) != ""
	case .Install: _, ok := dest_path(); return ok
	case .Configs, .Settings, .Dump: return false
	}
	return false
}

draw_sidebar :: proc() {
	rl.DrawRectangleRec({0, 0, SIDEBAR_W, H}, COL_SIDEBAR)
	rl.DrawRectangleRec({SIDEBAR_W - 1, 0, 1, H}, COL_BORDER)

	rounded({24, 28, 40, 40}, 11, alpha(COL_ACCENT, 36))
	draw_icon(IC_FLASH, 44, 48, 20, COL_ACCENT)
	draw_text("Saber", 76, 26, 22, COL_TEXT, true)
	draw_text("Flasher", 76, 50, 14, COL_MUTED)

	draw_text("CREATE", 28, 106, 12, COL_FAINT, true)
	steps := [3]string{"Game details", "Artwork", "Install"}
	y: f32 = 128
	for label, i in steps {
		nav_item({12, y, SIDEBAR_W - 24, 48}, Page(i), label, i + 1)
		y += 54
	}
	draw_text("MORE", 28, y + 18, 12, COL_FAINT, true)
	nav_item({12, y + 40, SIDEBAR_W - 24, 48}, .Dump, "Dump disc", 0, IC_DISC)
	nav_item({12, y + 94, SIDEBAR_W - 24, 48}, .Configs, "Configs", 0)
	nav_item({12, y + 148, SIDEBAR_W - 24, 48}, .Settings, "Settings", 0, IC_SETTINGS)

	saber := fmt.tprintf("%s\\Saber.exe", filepath.dir(os.args[0]))
	has_saber := os.exists(saber)
	if button({20, H - 128, SIDEBAR_W - 40, 44}, "Launch Saber", .Secondary, IC_FLASH, !has_saber) {
		shell_exec("open", saber, "")
	}
	if !has_saber && hovered({20, H - 128, SIDEBAR_W - 40, 44}) do draw_tooltip("Saber.exe isn't next to SaberFlasher.exe")

	draw_text("Tip: drop a game folder", 28, H - 62, 13, COL_FAINT)
	draw_text("anywhere to get started.", 28, H - 44, 13, COL_FAINT)
}

nav_item :: proc(r: rl.Rectangle, p: Page, label: string, num: int, ic := IC_GLOBE) {
	sel := page == p
	h := hovered(r)
	if h do cursor = .POINTING_HAND
	if clicked(r) do page = p
	a := anim(rect_id(r, 5), sel)
	ha := anim(rect_id(r, 6), h)
	rounded(r, 10, alpha(COL_CARD_HI, u8(clamp(a * 255 + ha * 90 * (1 - a), 0, 255))))
	if a > 0.01 do rounded({r.x, r.y + 12, 3, r.height - 24}, 1.5, alpha(COL_ACCENT, u8(a * 255)))

	c := rl.Vector2{r.x + 30, r.y + r.height / 2}
	if num == 0 {
		draw_icon(ic, c.x, c.y, 18, sel ? COL_ACCENT : COL_MUTED)
	} else if step_done(p) && !sel {
		rl.DrawCircleV(c, 13, alpha(COL_OK, 40))
		draw_icon(IC_CHECK, c.x, c.y, 13, COL_OK)
	} else {
		rl.DrawCircleV(c, 13, sel ? COL_ACCENT : COL_CARD_HI)
		n := fmt.tprint(num)
		draw_text(n, c.x - text_w(n, 14, true) / 2, c.y - 9, 14, sel ? COL_ON_ACCENT : COL_MUTED, true)
	}
	draw_text(label, r.x + 56, r.y + (r.height - 16) / 2 - 1, 16, sel ? COL_TEXT : COL_MUTED, sel)
}

draw_game_page :: proc() {
	page_header("Game details", "Name the game and tell Saber how to start it.")
	x, w := content_x(), content_w()
	if dump_active {
		dd := dump_disc
		label := fmt.tprintf("Disc %c: · %s · %s", dd.letter, PLATFORM_NAME[dd.platform], disc_serial(&dd))
		pw := text_w(label, 13, true) + 38
		pill(x + w - pw - 40, 46, label, COL_OK, IC_DISC)
		if button({x + w - 34, 40, 34, 34}, "", .Ghost, IC_CLOSE) do dump_active = false
	}
	if preconfig_dir != "" {
		label := fmt.tprintf("Preconfig: %s", filepath.base(filepath.dir(preconfig_dir)))
		pw := text_w(label, 13, true) + 38
		pill(x + w - pw - 40, 46, label, COL_OK, IC_CHECK)
		if button({x + w - 34, 40, 34, 34}, "", .Ghost, IC_CLOSE) {
			delete(preconfig_dir)
			preconfig_dir = ""
		}
	}
	card({x, 116, w, H - 116 - FOOTER_H - 20})
	ix, iw := x + 28, w - 56
	y: f32 = 140
	gap: f32 = 80
	ih: f32 = 42

	field_label(ix, y, "NAME", "Shown in Saber's menu", iw)
	text_input(&fields[F_NAME], {ix, y + 24, iw, ih}, "e.g. Rayman 2: The Great Escape")
	y += gap

	tags := field_str(&fields[F_TAGS])
	field_label(ix, y, "TAGS")
	if tags == "" {
		draw_text("Comma separated", ix + iw - text_w("Comma separated", 13), y, 13, COL_FAINT)
	} else {
		// live chip preview, right aligned
		parts := strings.split(tags, ",", context.temp_allocator)
		cx := ix + iw
		#reverse for t in parts {
			t := strings.trim_space(t)
			if t == "" do continue
			cw := text_w(t, 13, true) + 20
			if cx - cw < ix + 80 do break
			cx -= cw
			pill(cx, y - 4, t, COL_ACCENT)
			cx -= 6
		}
	}
	text_input(&fields[F_TAGS], {ix, y + 24, iw, ih}, "platformer, pc, gog")
	y += gap

	field_label(ix, y, "GAME FOLDER", "Optional · the whole folder is copied to the target", iw)
	if path_input(&fields[F_SOURCE], {ix, y + 24, iw, ih}, "Leave empty to only write the _Saber config") {
		if p, ok := pick_folder("Pick the game's folder"); ok do set_source(p)
	}
	y += gap

	field_label(ix, y, "EXECUTABLE", "Relative to the game folder", iw)
	if path_input(&fields[F_EXE], {ix, y + 24, iw, ih}, "Game.exe", IC_GAME) {
		if p, ok := pick_file("Programs (*.exe;*.bat;*.lnk)|*.exe;*.bat;*.lnk|All files|*.*|"); ok do field_set(&fields[F_EXE], p)
	}
	y += gap

	field_label(ix, y, "LAUNCH ARGUMENTS", "Optional", iw)
	text_input(&fields[F_ARGS], {ix, y + 24, iw, ih}, "-fullscreen")
}

drop_zone :: proc(r: rl.Rectangle, title, hint: string, f: ^Field, art: ^Art) {
	h := hovered(r)
	a := anim(rect_id(r, 7), h)
	rounded(r, 14, mix(COL_CARD, rl.Color{24, 30, 46, 255}, a))
	rounded_line(r, 14, 1 + a, mix(COL_BORDER, alpha(COL_ACCENT, 160), a))

	draw_text(title, r.x + 20, r.y + 16, 16, COL_TEXT, true)
	draw_text_fit(hint, r.x + 20, r.y + 38, 13, COL_MUTED, r.width - 80)
	body := rl.Rectangle{r.x + 20, r.y + 66, r.width - 40, r.height - 86}

	clear_btn := rl.Rectangle{r.x + r.width - 48, r.y + 14, 34, 34}
	has_art := art.tex.id != 0
	if has_art {
		s := min(body.width / f32(art.tex.width), body.height / f32(art.tex.height))
		dw, dh := f32(art.tex.width) * s, f32(art.tex.height) * s
		dst := rl.Rectangle{body.x + (body.width - dw) / 2, body.y + (body.height - dh) / 2, dw, dh}
		rl.DrawTexturePro(art.tex, {0, 0, f32(art.tex.width), f32(art.tex.height)}, dst, {}, 0, rl.WHITE)
		if button(clear_btn, "", .Ghost, IC_CLOSE) {
			field_set(f, "")
			return
		}
	} else {
		rounded(body, 10, alpha(COL_INPUT, 200))
		rounded_line(body, 10, 1, mix(COL_BORDER, alpha(COL_ACCENT, 120), a))
		cx := body.x + body.width / 2
		cy := body.y + body.height / 2
		rl.DrawCircleV({cx, cy - 26}, 28, alpha(COL_ACCENT, u8(30 + a * 30)))
		draw_icon(IC_PICTURE, cx, cy - 26, 24, COL_ACCENT)
		t1 := "Drop an image here"
		t2 := "or click to browse"
		draw_text(t1, cx - text_w(t1, 15, true) / 2, cy + 14, 15, COL_TEXT, true)
		draw_text(t2, cx - text_w(t2, 13) / 2, cy + 36, 13, COL_MUTED)
	}
	over_clear := has_art && hovered(clear_btn)
	if h && !over_clear do cursor = .POINTING_HAND
	if clicked(r) && !over_clear {
		if p, ok := pick_file(IMAGE_FILTER); ok do field_set(f, p)
	}
}

draw_artwork_page :: proc() {
	page_header("Artwork", "Box art shows in Saber's grid; the logo is used on the game's page.")
	x, w := content_x(), content_w()
	top: f32 = 116
	ah := H - top - FOOTER_H - 20
	bw := min(ah * 0.72, w * 0.45)
	box_rect = {x, top, bw, ah}
	drop_zone(box_rect, "Box art", "Portrait cover · saved as box.png", &fields[F_BOX], &box_art)

	rx := x + bw + 20
	rw := w - bw - 20
	logo_rect = {rx, top, rw, ah * 0.55}
	drop_zone(logo_rect, "Logo", "Transparent PNG works best · saved as logo.png", &fields[F_LOGO], &logo_art)

	tip := rl.Rectangle{rx, top + ah * 0.55 + 20, rw, ah * 0.45 - 20}
	card(tip)
	draw_icon(IC_PICTURE, tip.x + 34, tip.y + 34, 20, COL_ACCENT)
	draw_text("Tips", tip.x + 56, tip.y + 24, 16, COL_TEXT, true)
	lines := [?]string {
		"• Drag images straight from Explorer or your browser.",
		"• PNG, JPG, BMP and TGA are converted to PNG.",
		"• Existing _Saber art is picked up automatically.",
	}
	for l, i in lines {
		draw_text_fit(l, tip.x + 24, tip.y + 62 + f32(i) * 24, 14, COL_MUTED, tip.width - 48)
	}
}

drive_card :: proc(r: rl.Rectangle, d: Drive, i: int, locked: bool) {
	sel := drive_active == i
	h := !locked && hovered(r)
	if h do cursor = .POINTING_HAND
	if h && rl.IsMouseButtonPressed(.LEFT) do drive_active = i
	a := anim(rect_id(r, 8), sel)
	ha := anim(rect_id(r, 9), h)
	rounded(r, 12, mix(mix(COL_CARD, COL_CARD_HI, ha * 0.6), rl.Color{22, 40, 60, 255}, a))
	rounded_line(r, 12, 1 + a, mix(COL_BORDER, COL_ACCENT, a))

	rounded({r.x + 16, r.y + 18, 44, 44}, 10, alpha(COL_ACCENT, u8(24 + a * 30)))
	draw_icon(d.removable ? IC_USB : IC_DRIVE, r.x + 38, r.y + 40, 22, COL_ACCENT)

	name := fmt.tprintf("%c:  %s", d.letter, d.label == "" ? (d.removable ? "USB drive" : "Local disk") : d.label)
	draw_text_fit(name, r.x + 74, r.y + 16, 16, COL_TEXT, r.width - 90, true)
	draw_text(fmt.tprintf("%s free of %s", fmt_size(d.free), fmt_size(d.total)), r.x + 74, r.y + 40, 13, COL_MUTED)

	px := r.x + 74
	px += pill(px, r.y + 62, d.fs, COL_MUTED) + 6
	if d.games > 0 {
		px += pill(px, r.y + 62, fmt.tprintf("%d game%s", d.games, d.games == 1 ? "" : "s"), COL_ACCENT, IC_GAME) + 6
	}
	if d.used {
		pill(px, r.y + 62, "Other files", COL_WARN)
	} else if d.games == 0 {
		pill(px, r.y + 62, "Empty", COL_OK, IC_CHECK)
	}

	// usage bar
	bar := rl.Rectangle{r.x + 16, r.y + r.height - 14, r.width - 32, 4}
	rounded(bar, 2, COL_INPUT)
	if d.total > 0 {
		used := 1 - f32(d.free) / f32(d.total)
		rounded({bar.x, bar.y, max(bar.width * used, 4), bar.height}, 2, alpha(COL_ACCENT, 180))
	}
}

draw_install_page :: proc() {
	page_header("Install", "Each game gets its own folder, so one drive can hold many games.")
	x, w := content_x(), content_w()
	running := sync.atomic_load(&job.running)
	if target_mode == 0 && button({x + w - 120, 40, 120, 38}, "Refresh", .Secondary, IC_REFRESH, running) {
		refresh_drives()
	}

	y: f32 = 116
	segmented({x, y, 450, 44}, {"Drive", "Folder", "Saber library"}, &target_mode, {IC_USB, IC_FOLDER, IC_GAME}, running)
	y += 68

	summary_h: f32 = 124
	area_bottom := H - FOOTER_H - 20 - summary_h - 20
	if target_mode == 0 {
		if len(drives) == 0 {
			empty := rl.Rectangle{x, y, w, min(170, area_bottom - y)}
			card(empty)
			draw_icon(IC_USB, empty.x + empty.width / 2, empty.y + 50, 30, COL_FAINT)
			t := "No extra drives found"
			draw_text(t, empty.x + (empty.width - text_w(t, 17, true)) / 2, empty.y + 80, 17, COL_TEXT, true)
			t2 := "Plug in a USB stick, SD card or disk and press Refresh."
			draw_text(t2, empty.x + (empty.width - text_w(t2, 14)) / 2, empty.y + 106, 14, COL_MUTED)
		} else {
			cw: f32 = 290
			ch: f32 = 108
			cols := max(1, int((w + 16) / (cw + 16)))
			cw = (w - f32(cols - 1) * 16) / f32(cols)
			for d, i in drives {
				r := rl.Rectangle{x + f32(i % cols) * (cw + 16), y + f32(i / cols) * (ch + 16), cw, ch}
				if r.y + r.height > area_bottom do break
				drive_card(r, d, i, running)
			}
		}
	} else if target_mode == 2 {
		lib := rl.Rectangle{x, y, w, 120}
		card(lib)
		rl.DrawCircleV({lib.x + 48, lib.y + 60}, 26, alpha(COL_ACCENT, 36))
		draw_icon(IC_GAME, lib.x + 48, lib.y + 60, 24, COL_ACCENT)
		draw_text("Install into Saber's games library", lib.x + 92, lib.y + 26, 17, COL_TEXT, true)
		draw_text_fit("Shows up under \"Games\" in Saber on this PC — no drive needed.", lib.x + 92, lib.y + 52, 14, COL_MUTED, lib.width - 300)
		n := library_game_count()
		pill(lib.x + 92, lib.y + 80, fmt.tprintf("%d game%s in library", n, n == 1 ? "" : "s"), COL_ACCENT, IC_GAME)
		if button({lib.x + lib.width - 184, lib.y + 40, 160, 40}, "Open folder", .Secondary, IC_OPEN) {
			make_dirs(library_dir())
			shell_exec("explore", library_dir(), "")
		}
	} else {
		field_label(x, y, "INSTALL LOCATION", "A folder named after the game is created inside", w)
		if path_input(&fields[F_CUSTOM], {x, y + 24, w, 44}, "e.g. D:\\Games") {
			if p, ok := pick_folder("Install location"); ok do field_set(&fields[F_CUSTOM], p)
		}
	}

	// summary / progress
	s := rl.Rectangle{x, H - FOOTER_H - 20 - summary_h, w, summary_h}
	card(s)
	sx := s.x + 24
	if running || sync.atomic_load(&job.finished) {
		total := sync.atomic_load(&job.files_total)
		done := sync.atomic_load(&job.files_done)
		msg, cur: string
		{
			sync.guard(&job.mu)
			msg = fmt.tprint(job.message)
			cur = fmt.tprint(job.current)
		}
		col := running ? COL_ACCENT : (job.failed ? COL_DANGER : COL_OK)
		ic := running ? IC_FLASH : (job.failed ? IC_WARN : IC_CHECK)
		rl.DrawCircleV({sx + 20, s.y + 42}, 20, alpha(col, 40))
		draw_icon(ic, sx + 20, s.y + 42, 18, col)
		title := running ? "Flashing…" : (job.failed ? "Something went wrong" : "All done!")
		draw_text(title, sx + 54, s.y + 22, 17, COL_TEXT, true)
		draw_text_fit(running && cur != "" ? cur : msg, sx + 54, s.y + 46, 13, COL_MUTED, s.width - 280)

		frac: f32 = 1
		if total > 0 do frac = f32(done) / f32(total)
		else if running do frac = 0.15
		bar := rl.Rectangle{sx, s.y + s.height - 30, s.width - 48, 8}
		rounded(bar, 4, COL_INPUT)
		rounded({bar.x, bar.y, max(bar.width * frac, 8), bar.height}, 4, col)
		if total > 0 {
			t := fmt.tprintf("%d / %d files", done, total)
			draw_text(t, s.x + s.width - 24 - text_w(t, 13), s.y + 24, 13, COL_MUTED)
		}
		if !running && !job.failed && button({s.x + s.width - 164, s.y + 44, 140, 36}, "Open folder", .Secondary, IC_OPEN) {
			shell_exec("explore", job.dest, "")
		}
		return
	}

	draw_text("DESTINATION", sx, s.y + 20, 12, COL_FAINT, true)
	has_drive := target_mode == 0 && drive_active >= 0 && drive_active < len(drives)
	right_w: f32 = has_drive ? 220 : 0
	if d, ok := dest_path(); ok {
		draw_text_fit(fmt.tprintf("%s\\_Saber", strings.trim_right(d, "\\")), sx, s.y + 40, 18, COL_TEXT, s.width - 48 - right_w, true)
	} else {
		draw_text(target_mode == 0 ? "Select a drive above" : (target_mode == 2 ? "Give the game a name first" : "Choose a folder above"), sx, s.y + 40, 18, COL_FAINT, true)
	}
	src := field_str(&fields[F_SOURCE])
	what := src != "" ? fmt.tprintf("Copies the game folder from %s", src) : "Config only · no game files are copied"
	if dump_active {
		dd := dump_disc
		what = fmt.tprintf("Dumps %s disc %s from %c:%s + SimpRetro", PLATFORM_NAME[dd.platform], disc_serial(&dd), dd.letter, dump_discs > 1 ? fmt.tprintf(" (%d discs)", dump_discs) : "")
	}
	draw_text_fit(what, sx, s.y + 70, 14, COL_MUTED, s.width - 48 - right_w)
	if has_drive {
		if d, ok := dest_path(); ok && os.exists(fmt.tprintf("%s\\_Saber", d)) {
			draw_text_fit("This game is already on the drive — it will be updated.", sx, s.y + 92, 13, COL_ACCENT, s.width - 48 - right_w)
		} else if drives[drive_active].used {
			draw_text_fit("This drive has non-Saber files — a dedicated drive is recommended.", sx, s.y + 92, 13, COL_WARN, s.width - 48 - right_w)
		}
		d := drives[drive_active]
		if block := format_check(d.letter, d.serial); block == .None {
			if button({s.x + s.width - 204, s.y + (s.height - 40) / 2, 180, 40}, "Format drive…", .Danger, IC_ERASE) {
				field_set(&fields[F_CONFIRM], "")
				focused = &fields[F_CONFIRM]
				confirm = .Format
			}
		} else {
			pr := rl.Rectangle{s.x + s.width - 204, s.y + (s.height - 40) / 2, 180, 40}
			pill(pr.x + 40, pr.y + 9, "Protected", COL_MUTED, IC_WARN)
			if hovered(pr) do draw_tooltip(format_block_text(block))
		}
	}
}

draw_footer :: proc() {
	x: f32 = SIDEBAR_W
	y := H - FOOTER_H
	rl.DrawRectangleRec({x, y, W - x, FOOTER_H}, COL_SIDEBAR)
	rl.DrawRectangleRec({x, y, W - x, 1}, COL_BORDER)

	bx := W - 40
	by := y + (FOOTER_H - 46) / 2
	running := sync.atomic_load(&job.running)
	switch page {
	case .Game, .Artwork:
		bx -= 150
		if button({bx, by, 150, 46}, "Next", .Primary, IC_NEXT) do page = Page(int(page) + 1)
		if page == .Artwork {
			bx -= 120 + 12
			if button({bx, by, 120, 46}, "Back", .Ghost, IC_BACK) do page = .Game
		}
	case .Install:
		bx -= 190
		_, ok := dest_path()
		if button({bx, by, 190, 46}, running ? "Flashing…" : "Flash", .Primary, IC_FLASH, running || !ok) {
			if target_mode == 0 && drives[drive_active].used {
				confirm = .Flash_Used_Drive
			} else {
				start_flash()
			}
		}
		bx -= 120 + 12
		if button({bx, by, 120, 46}, "Back", .Ghost, IC_BACK) do page = .Artwork
	case .Configs, .Settings, .Dump:
	}
	if status != "" do draw_text_fit(status, content_x(), y + (FOOTER_H - 15) / 2 - 1, 15, status_col, bx - content_x() - 20)
}

draw_modal :: proc() {
	if confirm == .None do return
	drawing_modal = true
	defer drawing_modal = false
	if drive_active < 0 || drive_active >= len(drives) {
		confirm = .None
		return
	}
	d := drives[drive_active]
	rl.DrawRectangleRec({0, 0, W, H}, {0, 0, 0, 150})
	danger := confirm == .Format
	r := rl.Rectangle{W / 2 - 250, H / 2 - 115, 500, danger ? 300 : 230}
	rounded({r.x, r.y + 8, r.width, r.height}, 16, {0, 0, 0, 120})
	rounded(r, 16, COL_CARD)
	rounded_line(r, 16, 1, COL_BORDER_HI)

	col := danger ? COL_DANGER : COL_WARN
	rl.DrawCircleV({r.x + 52, r.y + 56}, 24, alpha(col, 40))
	draw_icon(IC_WARN, r.x + 52, r.y + 56, 22, col)

	title, l1, l2, ok_label: string
	if danger {
		title = fmt.tprintf("Format %c:?", d.letter)
		l1 = fmt.tprintf("Everything on %c: (%s) will be erased.", d.letter, d.label == "" ? "no label" : d.label)
		l2 = fmt.tprintf("Type %c: below to confirm. Windows asks once more.", d.letter)
		ok_label = "Format"
	} else {
		title = "Drive has other files"
		l1 = fmt.tprintf("%c: has files that aren't Saber games. Saber works", d.letter)
		l2 = "best with a dedicated drive. Flash anyway?"
		ok_label = "Flash anyway"
	}
	draw_text(title, r.x + 92, r.y + 40, 20, COL_TEXT, true)
	draw_text(l1, r.x + 92, r.y + 76, 14, COL_MUTED)
	draw_text(l2, r.x + 92, r.y + 98, 14, COL_MUTED)

	typed_ok := true
	if danger {
		text_input(&fields[F_CONFIRM], {r.x + 92, r.y + 130, r.width - 92 - 24, 42}, fmt.tprintf("%c:", d.letter))
		t := strings.to_upper(field_str(&fields[F_CONFIRM]), context.temp_allocator)
		typed_ok = t == fmt.tprintf("%c:", d.letter) || t == fmt.tprintf("%c", d.letter)
	}

	by := r.y + r.height - 68
	cancel := button({r.x + r.width - 24 - 160 - 12 - 120, by, 120, 44}, "Cancel", .Ghost) || rl.IsKeyPressed(.ESCAPE)
	if button({r.x + r.width - 24 - 160, by, 160, 44}, ok_label, danger ? .Danger : .Primary, 0, !typed_ok) {
		if danger {
			if block := start_format(d.letter, d.serial); block != .None {
				set_status(format_block_text(block), COL_DANGER)
			} else {
				set_status(fmt.tprintf("Formatting %c: in a console window — press Refresh when it finishes.", d.letter), COL_WARN)
			}
		} else {
			start_flash()
		}
		confirm = .None
	}
	if cancel do confirm = .None
}

main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT, .VSYNC_HINT})
	rl.SetTraceLogLevel(.WARNING)
	rl.InitWindow(1180, 760, "Saber Flasher")
	defer rl.CloseWindow()
	rl.SetWindowMinSize(1000, 680)
	rl.SetExitKey(.KEY_NULL)
	rl.SetTargetFPS(120)
	refresh_drives()
	load_settings()
	refresh_preconfigs()

	for !rl.WindowShouldClose() {
		free_all(context.temp_allocator)
		W, H = f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
		mouse = rl.GetMousePosition()
		dt = rl.GetFrameTime()
		cursor = .DEFAULT
		modal_active = confirm != .None || job_overlay
		click_hit_input = false
		clear(&focus_order)

		handle_drops()
		update_art(&box_art, field_str(&fields[F_BOX]))
		update_art(&logo_art, field_str(&fields[F_LOGO]))
		if sync.atomic_load(&job.finished) && job_thread != nil {
			thread.join(job_thread)
			thread.destroy(job_thread)
			job_thread = nil
			refresh_drives()
		}

		rl.BeginDrawing()
		rl.ClearBackground(COL_BG)
		prev_page := page
		switch page {
		case .Game:    draw_game_page()
		case .Artwork: draw_artwork_page()
		case .Install: draw_install_page()
		case .Configs: draw_configs_page()
		case .Settings: draw_settings_page()
		case .Dump:     draw_dump_page()
		}
		draw_footer()
		draw_sidebar()
		flush_tooltip()
		draw_modal()
		draw_install_overlay()
		rl.EndDrawing()

		if page != prev_page do focused = nil
		if rl.IsMouseButtonPressed(.LEFT) && !click_hit_input do focused = nil
		if focused != nil && rl.IsKeyPressed(.TAB) && len(focus_order) > 0 {
			idx := 0
			for f, i in focus_order do if f == focused do idx = i
			step := rl.IsKeyDown(.LEFT_SHIFT) ? len(focus_order) - 1 : 1
			focused = focus_order[(idx + step) % len(focus_order)]
			focused.caret = focused.n
		}
		rl.SetMouseCursor(cursor)
	}
	clean_job()
}

utf8_encode :: proc(r: rune) -> ([4]u8, int) {
	return utf8.encode_rune(r)
}
