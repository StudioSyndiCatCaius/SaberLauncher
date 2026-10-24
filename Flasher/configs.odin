package flasher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

// Preconfig browser: lists premade `_Saber` folders from local folders (and, later, online repos).
// A source is scanned at its root and in `games\`; any subfolder with `_Saber\saber.ini` is a preconfig.

DEFAULT_SOURCE :: `D:\Github\SaberLauncherPreconfigs`

Preconfig :: struct {
	id:       string, // folder name, e.g. SwKotor1_PC_Vanilla
	dir:      string,
	source:   string,
	title:    string,
	tags:     string,
	exe:      string,
	args:     string,
	box:      string,
	logo:     string,
	lua:      string, // path to config.lua, if any
	lua_vars: [dynamic][2]string, // simple `key = "value"` fields from config.lua
	downloads: bool, // script fetches the game itself (File_Download / a link field)
	gog_name: string, // config.lua `gog_name`: install starts as a copy of this GOG game
	thumb:    rl.Texture2D,
	tried:    bool, // thumbnail load attempted
}

sources: [dynamic]string
preconfigs: [dynamic]Preconfig
pc_selected := -1
pc_scroll: f32
preconfig_dir: string // _Saber folder of the preconfig in use, copied on flash

settings_path :: proc() -> string {
	return fmt.tprintf("%s\\SaberFlasher.ini", filepath.dir(os.args[0]))
}

load_settings :: proc() {
	data, err := os.read_entire_file(settings_path(), context.temp_allocator)
	if err != nil {
		append(&sources, strings.clone(DEFAULT_SOURCE))
		if g, ok := detect_gog(); ok do field_set(&fields[F_GOG], g)
		if sp, ok := detect_simpretro(); ok do field_set(&fields[F_SIMPRETRO], sp)
		return
	}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		k, _, v := strings.partition(line, "=")
		k, v = strings.trim_space(k), strings.trim_space(v)
		if k == "source" && v != "" do append(&sources, strings.clone(v))
		if k == "gog_dir" do field_set(&fields[F_GOG], v)
		if k == "simpretro_dir" do field_set(&fields[F_SIMPRETRO], v)
		if k == "bios_dir" do field_set(&fields[F_BIOS], v)
	}
	if field_str(&fields[F_SIMPRETRO]) == "" {
		if sp, ok := detect_simpretro(); ok do field_set(&fields[F_SIMPRETRO], sp)
	}
	saved_gog = strings.clone(settings_snapshot())
}

save_settings :: proc() {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "[flasher]\n")
	for s in sources do fmt.sbprintf(&sb, "source=%s\n", s)
	fmt.sbprintf(&sb, "gog_dir=%s\n", field_str(&fields[F_GOG]))
	fmt.sbprintf(&sb, "simpretro_dir=%s\n", field_str(&fields[F_SIMPRETRO]))
	fmt.sbprintf(&sb, "bios_dir=%s\n", field_str(&fields[F_BIOS]))
	delete(saved_gog)
	saved_gog = strings.clone(settings_snapshot())
	_ = os.write_entire_file(settings_path(), transmute([]u8)strings.to_string(sb))
}

is_url :: proc(s: string) -> bool {
	return strings.has_prefix(s, "http://") || strings.has_prefix(s, "https://")
}

add_source :: proc(s: string) {
	s := strings.trim_right(strings.trim_space(s), "\\/")
	if s == "" do return
	for o in sources do if strings.equal_fold(o, s) do return
	append(&sources, strings.clone(s))
	save_settings()
	refresh_preconfigs()
}

remove_source :: proc(i: int) {
	delete(sources[i])
	ordered_remove(&sources, i)
	save_settings()
	refresh_preconfigs()
}

free_preconfig :: proc(p: ^Preconfig) {
	if p.thumb.id != 0 do rl.UnloadTexture(p.thumb)
	delete(p.id); delete(p.dir); delete(p.source); delete(p.title); delete(p.tags)
	delete(p.exe); delete(p.args); delete(p.box); delete(p.logo); delete(p.lua)
	for kv in p.lua_vars {
		delete(kv[0]); delete(kv[1])
	}
	delete(p.lua_vars)
	delete(p.gog_name)
}

refresh_preconfigs :: proc() {
	for &p in preconfigs do free_preconfig(&p)
	clear(&preconfigs)
	pc_selected = -1
	pc_scroll = 0
	for src in sources {
		if is_url(src) do continue // remote repos: coming later
		scan_preconfig_dir(src, src)
		scan_preconfig_dir(fmt.tprintf("%s\\games", src), src)
	}
}

scan_preconfig_dir :: proc(dir, source: string) {
	Ctx :: struct {
		source: string,
	}
	ctx := Ctx{source}
	walk_dir(dir, proc(path: string, is_dir: bool, user: rawptr) -> bool {
		if !is_dir do return false
		ini := fmt.tprintf("%s\\_Saber\\saber.ini", path)
		if !os.exists(ini) do return false
		data, err := os.read_entire_file(ini, context.temp_allocator)
		if err != nil do return false
		saber := fmt.tprintf("%s\\_Saber", path)
		p := Preconfig {
			id     = strings.clone(filepath.base(path)),
			dir    = strings.clone(path),
			source = strings.clone((^Ctx)(user).source),
		}
		box, logo := "box.png", "logo.png"
		for line in strings.split_lines(strings.trim_prefix(string(data), "\uFEFF"), context.temp_allocator) {
			k, _, v := strings.partition(line, "=")
			k = strings.trim_space(k)
			v = strings.trim(strings.trim_space(v), "\"")
			switch k {
			case "title": p.title = strings.clone(v)
			case "tags":  p.tags = strings.clone(strings.trim_right(v, ", "))
			case "exe":   p.exe = strings.clone(v)
			case "args":  p.args = strings.clone(v)
			case "box":   if v != "" do box = v
			case "logo":  if v != "" do logo = v
			}
		}
		if p.title == "" do p.title = strings.clone(p.id)
		if b := fmt.tprintf("%s\\%s", saber, box); os.exists(b) do p.box = strings.clone(b)
		if l := fmt.tprintf("%s\\%s", saber, logo); os.exists(l) do p.logo = strings.clone(l)
		if lua := fmt.tprintf("%s\\config.lua", path); os.exists(lua) {
			p.lua = strings.clone(lua)
			read_lua_vars(&p)
		}
		append(&preconfigs, p)
		return false
	}, &ctx, recurse = false)
}

// Lua isn't executed yet; this just surfaces top-level `key = "string"` fields (e.g. link) for display.
is_link_key :: proc(k: string) -> bool {
	k := strings.to_lower(k, context.temp_allocator)
	return k == "link" || k == "url" || k == "download" || strings.has_suffix(k, "_url") || strings.has_suffix(k, "_link")
}

read_lua_vars :: proc(p: ^Preconfig) {
	data, err := os.read_entire_file(p.lua, context.temp_allocator)
	if err != nil do return
	if strings.contains(string(data), "File_Download") do p.downloads = true
	for line in strings.split_lines(string(data), context.temp_allocator) {
		k, sep, v := strings.partition(strings.trim_space(line), "=")
		if sep == "" do continue
		k = strings.trim_space(k)
		v = strings.trim_right(strings.trim_space(v), ",")
		if len(v) < 2 || !(v[0] == '"' || v[0] == '\'') || v[len(v) - 1] != v[0] do continue
		if strings.contains_any(k, " ()[].") do continue
		append(&p.lua_vars, [2]string{strings.clone(k), strings.clone(v[1:len(v) - 1])})
		if is_link_key(k) do p.downloads = true
		if k == "gog_name" && p.gog_name == "" do p.gog_name = strings.clone(v[1:len(v) - 1])
	}
}

load_thumb :: proc(p: ^Preconfig) {
	if p.tried do return
	p.tried = true
	if p.box == "" do return
	img := rl.LoadImage(cs(p.box))
	if img.data == nil do return
	defer rl.UnloadImage(img)
	if img.height > 480 {
		rl.ImageResize(&img, i32(f32(img.width) * 480 / f32(img.height)), 480)
	}
	p.thumb = rl.LoadTextureFromImage(img)
	rl.GenTextureMipmaps(&p.thumb)
	rl.SetTextureFilter(p.thumb, .TRILINEAR)
}

matches_search :: proc(p: ^Preconfig, q: string) -> bool {
	if q == "" do return true
	for word in strings.fields(q, context.temp_allocator) {
		w := strings.to_lower(word, context.temp_allocator)
		hay := strings.to_lower(fmt.tprintf("%s %s %s", p.title, p.tags, p.id), context.temp_allocator)
		if !strings.contains(hay, w) do return false
	}
	return true
}

use_preconfig :: proc(p: ^Preconfig) {
	field_set(&fields[F_NAME], p.title)
	field_set(&fields[F_TAGS], p.tags)
	field_set(&fields[F_EXE], p.exe)
	field_set(&fields[F_ARGS], p.args)
	field_set(&fields[F_BOX], p.box)
	field_set(&fields[F_LOGO], p.logo)
	delete(preconfig_dir)
	preconfig_dir = strings.clone(fmt.tprintf("%s\\_Saber", p.dir))
	page = .Game
	set_status(fmt.tprintf("Loaded preconfig \"%s\" — pick the game folder, then flash.", p.title), COL_OK)
}

// Draws an image fitted (cover) inside r with rounded-looking crop.
draw_cover :: proc(tex: rl.Texture2D, r: rl.Rectangle) {
	tw, th := f32(tex.width), f32(tex.height)
	s := max(r.width / tw, r.height / th)
	sw, sh := r.width / s, r.height / s
	src := rl.Rectangle{(tw - sw) / 2, (th - sh) / 2, sw, sh}
	rl.DrawTexturePro(tex, src, r, {}, 0, rl.WHITE)
}

draw_configs_page :: proc() {
	page_header("Configs", "Premade _Saber configs from local folders or online repositories.")
	x, w := content_x(), content_w()

	// sources row
	y: f32 = 112
	sx := x
	for src, i in sources {
		label := is_url(src) ? src : filepath.base(src)
		tw := min(text_w(label, 14, true), 220)
		r := rl.Rectangle{sx, y, tw + 70, 34}
		if r.x + r.width > x + w - 560 do break
		rounded(r, 17, COL_CARD_HI)
		rounded_line(r, 17, 1, COL_BORDER)
		draw_icon(is_url(src) ? IC_GLOBE : IC_FOLDER, r.x + 20, r.y + 17, 14, COL_ACCENT)
		draw_text_fit(label, r.x + 36, r.y + 8, 14, COL_TEXT, 220, true)
		if hovered({r.x, r.y, r.width - 34, r.height}) {
			draw_tooltip(is_url(src) ? fmt.tprintf("%s (online listing coming soon)", src) : src)
		}
		if button({r.x + r.width - 32, r.y + 3, 28, 28}, "", .Ghost, IC_CLOSE) {
			remove_source(i)
			return
		}
		sx += r.width + 8
	}
	if button({x + w - 550, y - 2, 140, 38}, "Add folder", .Secondary, IC_FOLDER) {
		if p, ok := pick_folder("Folder with preconfigs"); ok do add_source(p)
	}
	text_input(&fields[F_URL], {x + w - 400, y - 2, 270, 38}, "https://… repository URL")
	if button({x + w - 120, y - 2, 120, 38}, "Add URL", .Secondary, IC_GLOBE, !is_url(field_str(&fields[F_URL]))) {
		add_source(field_str(&fields[F_URL]))
		field_set(&fields[F_URL], "")
	}

	// search row
	y += 52
	detail_w: f32 = pc_selected >= 0 ? 400 : 0
	list_w := w - (detail_w > 0 ? detail_w + 20 : 0)
	text_input(&fields[F_SEARCH], {x, y, list_w, 42}, "Search by title, tag or id…")
	n_label := fmt.tprintf("%d configs", len(preconfigs))
	if field_str(&fields[F_SEARCH]) == "" do draw_text(n_label, x + list_w - 16 - text_w(n_label, 13), y + 13, 13, COL_FAINT)

	// grid
	q := field_str(&fields[F_SEARCH])
	gy := y + 58
	area := rl.Rectangle{x, gy, list_w, H - FOOTER_H - 20 - gy}
	cw: f32 = 168
	gap: f32 = 16
	cols := max(1, int((area.width + gap) / (cw + gap)))
	cw = (area.width - f32(cols - 1) * gap) / f32(cols)
	ch := cw * 1.4 + 58

	visible := make([dynamic]int, context.temp_allocator)
	for &p, i in preconfigs do if matches_search(&p, q) do append(&visible, i)

	rows := (len(visible) + cols - 1) / cols
	content_h := f32(rows) * (ch + gap)
	if hovered(area) do pc_scroll -= rl.GetMouseWheelMove() * 60
	pc_scroll = clamp(pc_scroll, 0, max(0, content_h - area.height))

	if len(visible) == 0 {
		msg := len(preconfigs) == 0 ? "No preconfigs found in your sources." : "No configs match your search."
		draw_icon(IC_SEARCH, area.x + area.width / 2, area.y + 60, 30, COL_FAINT)
		draw_text(msg, area.x + (area.width - text_w(msg, 16, true)) / 2, area.y + 92, 16, COL_MUTED, true)
	}

	rl.BeginScissorMode(i32(area.x - 4), i32(area.y), i32(area.width + 8), i32(area.height))
	for idx, n in visible {
		r := rl.Rectangle{area.x + f32(n % cols) * (cw + gap), area.y + f32(n / cols) * (ch + gap) - pc_scroll, cw, ch}
		if r.y > area.y + area.height || r.y + r.height < area.y do continue
		p := &preconfigs[idx]
		h := hovered(r) && rl.CheckCollisionPointRec(mouse, area)
		if h do cursor = .POINTING_HAND
		if h && rl.IsMouseButtonPressed(.LEFT) do pc_selected = pc_selected == idx ? -1 : idx
		sel := pc_selected == idx
		a := anim(rect_id({f32(idx) * 7919, 1, 0, 0}, 10), h || sel)
		rounded(r, 12, mix(COL_CARD, COL_CARD_HI, a))
		rounded_line(r, 12, 1 + (sel ? 1 : 0), sel ? COL_ACCENT : mix(COL_BORDER, COL_BORDER_HI, a))

		img := rl.Rectangle{r.x + 8, r.y + 8, r.width - 16, r.height - 66}
		load_thumb(p)
		if p.thumb.id != 0 {
			draw_cover(p.thumb, img)
		} else {
			rounded(img, 8, COL_INPUT)
			draw_icon(IC_GAME, img.x + img.width / 2, img.y + img.height / 2, 30, COL_FAINT)
		}
		badge_y := img.y
		if p.gog_name != "" {
			gog_badge({img.x, badge_y, img.width, img.height})
			badge_y += 26
		}
		if p.downloads {
			download_stamp({img.x, badge_y, img.width, img.height})
		} else if p.lua != "" && p.gog_name == "" {
			pill(img.x + 6, img.y + 6, "Script", COL_WARN)
		}
		draw_text_fit(p.title, r.x + 12, r.y + r.height - 52, 14, COL_TEXT, r.width - 24, true)
		if p.tags != "" {
			tag_row(p.tags, r.x + 12, r.y + r.height - 31, r.width - 24, false)
		} else {
			draw_text_fit(p.id, r.x + 12, r.y + r.height - 30, 12, COL_FAINT, r.width - 24)
		}
	}
	rl.EndScissorMode()

	// scrollbar
	if content_h > area.height {
		frac := area.height / content_h
		th := max(area.height * frac, 30)
		ty := area.y + (area.height - th) * (pc_scroll / (content_h - area.height))
		rounded({area.x + area.width + 6, ty, 4, th}, 2, COL_BORDER_HI)
	}

	if pc_selected >= 0 && pc_selected < len(preconfigs) {
		draw_preconfig_detail(&preconfigs[pc_selected], {x + w - detail_w, y, detail_w, H - FOOTER_H - 20 - y})
	}
}

draw_preconfig_detail :: proc(p: ^Preconfig, r: rl.Rectangle) {
	card(r)
	if button({r.x + r.width - 46, r.y + 12, 34, 34}, "", .Ghost, IC_CLOSE) {
		pc_selected = -1
		return
	}
	ix := r.x + 22
	iw := r.width - 44
	y := r.y + 20

	// art
	art_h := min(r.height * 0.42, 300)
	if p.thumb.id != 0 {
		s := min(iw / f32(p.thumb.width), art_h / f32(p.thumb.height))
		dw, dh := f32(p.thumb.width) * s, f32(p.thumb.height) * s
		art := rl.Rectangle{ix + (iw - dw) / 2, y, dw, dh}
		rl.DrawTexturePro(p.thumb, {0, 0, f32(p.thumb.width), f32(p.thumb.height)}, art, {}, 0, rl.WHITE)
		if p.downloads do download_stamp(art)
	} else {
		rounded({ix, y, iw, art_h}, 10, COL_INPUT)
		draw_icon(IC_GAME, ix + iw / 2, y + art_h / 2, 36, COL_FAINT)
		if p.downloads do download_stamp({ix, y, iw, art_h})
	}
	y += art_h + 18

	// title (wrapped to two lines max)
	lines := wrap_text(p.title, 19, iw, 2)
	for l in lines {
		draw_text(l, ix, y, 19, COL_TEXT, true)
		y += 25
	}
	y += 4
	if p.tags != "" {
		y += tag_row(p.tags, ix, y, iw, true) + 12
	}

	info_row :: proc(x, y, w: f32, label, value: string) {
		draw_text(label, x, y, 12, COL_FAINT, true)
		draw_text_fit(value == "" ? "—" : value, x + 90, y - 1, 14, COL_TEXT, w - 90)
	}
	info_row(ix, y, iw, "EXE", p.exe); y += 24
	if p.args != "" { info_row(ix, y, iw, "ARGS", p.args); y += 24 }
	info_row(ix, y, iw, "ID", p.id); y += 24
	info_row(ix, y, iw, "SOURCE", p.source); y += 24
	if p.lua != "" {
		info_row(ix, y, iw, "SCRIPT", p.downloads ? "Downloads the game on install" : "config.lua · runs on install"); y += 24
		if p.gog_name != "" {
			src, found := find_gog_game(field_str(&fields[F_GOG]), p.gog_name)
			draw_text("NEEDS", ix, y, 12, COL_FAINT, true)
			gx := ix + 90
			gx += pill(gx, y - 4, "GOG", COL_ACCENT) + 8
			draw_text_fit(p.gog_name, gx, y - 1, 14, COL_TEXT, iw - (gx - ix) - 110)
			if found {
				pill(ix + iw - 92, y - 4, "Installed", COL_OK, IC_CHECK)
				if hovered({ix + iw - 92, y - 4, 92, 22}) do draw_tooltip(src)
			} else {
				pill(ix + iw - 100, y - 4, "Not found", COL_DANGER, IC_WARN)
			}
			y += 24
		}
		for kv in p.lua_vars {
			if is_link_key(kv[0]) || kv[0] == "gog_name" do continue
			info_row(ix, y, iw, strings.to_upper(kv[0], context.temp_allocator), kv[1]); y += 24
		}
	}

	by := r.y + r.height - 64
	if button({ix, by, iw - 140 - 10, 44}, "Use this config", .Primary, IC_NEXT) do use_preconfig(p)
	if button({ix + iw - 140, by, 140, 44}, "Open folder", .Secondary, IC_OPEN) do shell_exec("explore", p.dir, "")
}

wrap_text :: proc(s: string, size: f32, max_w: f32, max_lines: int) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	line := ""
	for word in strings.fields(s, context.temp_allocator) {
		try := line == "" ? word : fmt.tprintf("%s %s", line, word)
		if text_w(try, size, true) > max_w && line != "" {
			append(&out, line)
			line = word
		} else {
			line = try
		}
	}
	if line != "" do append(&out, line)
	if len(out) > max_lines {
		out[max_lines - 1] = fmt.tprintf("%s…", out[max_lines - 1])
		resize(&out, max_lines)
	}
	return out[:]
}

tooltip_text: string

draw_tooltip :: proc(s: string) {
	tooltip_text = s
}

flush_tooltip :: proc() {
	if tooltip_text == "" do return
	defer tooltip_text = ""
	tw := text_w(tooltip_text, 13)
	r := rl.Rectangle{min(mouse.x + 14, W - tw - 30), mouse.y + 20, tw + 20, 28}
	rounded(r, 6, {36, 42, 60, 250})
	rounded_line(r, 6, 1, COL_BORDER_HI)
	draw_text(tooltip_text, r.x + 10, r.y + 6, 13, COL_TEXT)
}

// ---------------------------------------------------------------- tags & stamps

TAG_COLORS := [?]rl.Color {
	{92, 204, 255, 255},  // sky
	{150, 140, 255, 255}, // violet
	{255, 128, 170, 255}, // pink
	{255, 178, 76, 255},  // amber
	{86, 214, 146, 255},  // green
	{90, 220, 220, 255},  // teal
	{255, 120, 100, 255}, // coral
	{200, 210, 120, 255}, // lime
}

// Stable colour per tag, so "rpg" looks the same everywhere.
tag_color :: proc(tag: string) -> rl.Color {
	h: u32 = 2166136261
	for b in transmute([]u8)strings.to_lower(tag, context.temp_allocator) do h = (h ~ u32(b)) * 16777619
	return TAG_COLORS[h % len(TAG_COLORS)]
}

split_tags :: proc(tags: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for t in strings.split(tags, ",", context.temp_allocator) {
		t := strings.trim_space(t)
		if t != "" do append(&out, t)
	}
	return out[:]
}

tag_metrics :: proc(big: bool) -> (size, h, pad: f32) {
	return big ? 13 : 11, big ? 24 : 18, big ? 10 : 7
}

tag_width :: proc(tag: string, big: bool) -> f32 {
	size, h, pad := tag_metrics(big)
	return text_w(tag, size, true) + pad * 2 + h * 0.35
}

tag_chip :: proc(x, y: f32, tag: string, big: bool) -> (w: f32, hit: bool) {
	size, h, pad := tag_metrics(big)
	col := tag_color(tag)
	w = tag_width(tag, big)
	r := rl.Rectangle{x, y, w, h}
	hov := big && hovered(r)
	rounded(r, h / 2, alpha(col, hov ? 60 : 30))
	rounded_line(r, h / 2, 1, alpha(col, hov ? 150 : 80))
	rl.DrawCircleV({x + pad, y + h / 2}, h * 0.14, col)
	draw_text(tag, x + pad + h * 0.35, y + (h - size) / 2 - 1, size, mix(col, COL_TEXT, 0.35), true)
	if hov {
		cursor = .POINTING_HAND
		draw_tooltip(fmt.tprintf("Show all \"%s\" configs", tag))
	}
	return w, hov && rl.IsMouseButtonPressed(.LEFT)
}

// Small = one line with a "+N" overflow chip; big = wraps to 2 lines and chips are clickable
// (clicking searches for that tag). Returns the height used.
tag_row :: proc(tags: string, x, y, w: f32, big: bool) -> f32 {
	list := split_tags(tags)
	size, h, pad := tag_metrics(big)
	gap: f32 = 6
	max_lines := big ? 2 : 1
	cx, line := x, 0
	for t, i in list {
		cw := tag_width(t, big)
		more := fmt.tprintf("+%d", len(list) - i)
		mw := text_w(more, size, true) + pad * 2
		last_line := line == max_lines - 1
		reserve: f32 = (last_line && i < len(list) - 1) ? mw + gap : 0
		if cx + cw + reserve > x + w && cx > x {
			if last_line {
				r := rl.Rectangle{cx, y + f32(line) * (h + gap), mw, h}
				rounded(r, h / 2, alpha(COL_MUTED, 30))
				draw_text(more, r.x + pad, r.y + (h - size) / 2 - 1, size, COL_MUTED, true)
				break
			}
			line += 1
			cx = x
		}
		cw2, hit := tag_chip(cx, y + f32(line) * (h + gap), t, big)
		if hit {
			field_set(&fields[F_SEARCH], t)
			pc_scroll = 0
		}
		cx += cw2 + gap
	}
	return f32(line + 1) * h + f32(line) * gap
}

// "GOG" blip: the config builds on an installed GOG game.
gog_badge :: proc(cover: rl.Rectangle) {
	w := text_w("GOG", 12, true) + 34
	r := rl.Rectangle{cover.x + 6, cover.y + 6, w, 22}
	rounded(r, 11, {10, 14, 24, 220})
	rounded(r, 11, alpha({170, 120, 255, 255}, 50))
	draw_icon(IC_GAME, r.x + 14, r.y + 11, 12, {190, 150, 255, 255})
	draw_text("GOG", r.x + 24, r.y + 4, 12, COL_TEXT, true)
}

// Small "Download" blip in the top-left corner of a cover.
download_stamp :: proc(cover: rl.Rectangle) {
	label := "Download"
	w := text_w(label, 12, true) + 34
	r := rl.Rectangle{cover.x + 6, cover.y + 6, w, 22}
	rounded(r, 11, {10, 14, 24, 220})
	rounded(r, 11, alpha(COL_ACCENT, 40))
	draw_icon(IC_DOWNLOAD, r.x + 14, r.y + 11, 12, COL_ACCENT)
	draw_text(label, r.x + 24, r.y + 4, 12, COL_TEXT, true)
}
