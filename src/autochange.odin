package saber

import "core:fmt"
import "core:math/rand"
import "core:strings"
import win "core:sys/windows"
import rl "vendor:raylib"

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	GetLocalTime :: proc(st: ^win.SYSTEMTIME) ---
}

// Wallpaper / music autochange: when the local day / week (Sunday) / month (the 1st) rolls over,
// a random file is picked, never repeating until every file was shown once (shuffle bag).
// Saber.ini: bkg_auto= / bgm_auto= (never|day|week|month), *_auto_period= (last period key),
// *_auto_seen= (';'-separated names used this cycle).

Auto_Change :: enum {
	Never,
	Day,
	Week,
	Month,
}

AUTO_CHANGE_NAMES := [Auto_Change]string {
	.Never = "Never",
	.Day   = "Every Day (at midnight)",
	.Week  = "Every Week (on Sunday)",
	.Month = "Every Month (on the 1st)",
}

AUTO_CHANGE_KEYS := [Auto_Change]string {
	.Never = "never",
	.Day   = "day",
	.Week  = "week",
	.Month = "month",
}

Auto_State :: struct {
	mode:   Auto_Change,
	period: string, // heap
	seen:   string, // heap, ';'-separated
}

auto_next_check: f64

auto_parse :: proc(v: string) -> Auto_Change {
	for key, m in AUTO_CHANGE_KEYS do if eq_fold(v, key) do return m
	return .Never
}

// Key of the current local period ("" for Never); a change of key = time to switch.
auto_period_key :: proc(mode: Auto_Change) -> string {
	st: win.SYSTEMTIME
	GetLocalTime(&st)
	y, m, d := int(st.year), int(st.month), int(st.day)
	switch mode {
	case .Never: return ""
	case .Day:   return fmt.tprintf("%04d-%02d-%02d", y, m, d)
	case .Month: return fmt.tprintf("%04d-%02d", y, m)
	case .Week:
		// step back to Sunday (wDayOfWeek 0 = Sunday)
		back := int(st.day_of_week)
		for _ in 0 ..< back {
			d -= 1
			if d == 0 {
				m -= 1
				if m == 0 { m = 12; y -= 1 }
				d = days_in_month(y, m)
			}
		}
		return fmt.tprintf("%04d-%02d-%02d", y, m, d)
	}
	return ""
}

days_in_month :: proc(y, m: int) -> int {
	switch m {
	case 4, 6, 9, 11: return 30
	case 2: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
	}
	return 31
}

auto_set_str :: proc(dst: ^string, v: string) {
	delete(dst^)
	dst^ = strings.clone(v)
}

// Changing the mode starts counting from now (no immediate switch).
auto_set_mode :: proc(st: ^Auto_State, mode: Auto_Change) {
	st.mode = mode
	auto_set_str(&st.period, auto_period_key(mode))
	save_settings()
}

// Random file not shown yet this cycle (bag refills when all were used); "" when there's nothing.
auto_pick :: proc(st: ^Auto_State, files: []string, current: string) -> string {
	if len(files) == 0 do return ""
	in_seen :: proc(seen, name: string) -> bool {
		s := seen
		for part in strings.split_iterator(&s, ";") do if eq_fold(part, name) do return true
		return false
	}
	pool := make([dynamic]string, context.temp_allocator)
	for f in files do if !in_seen(st.seen, f) && !eq_fold(f, current) do append(&pool, f)
	if len(pool) == 0 {
		// full cycle done: start over, still avoiding an immediate repeat
		auto_set_str(&st.seen, current)
		for f in files do if !eq_fold(f, current) do append(&pool, f)
		if len(pool) == 0 do return ""
	}
	pick := pool[rand.int_max(len(pool))]
	auto_set_str(&st.seen, st.seen == "" ? pick : fmt.tprintf("%s;%s", st.seen, pick))
	return pick
}

// One stream: switch if the period rolled over. True when settings changed.
auto_tick_one :: proc(st: ^Auto_State, files: []string, current: string, apply: proc(name: string)) -> bool {
	if st.mode == .Never do return false
	key := auto_period_key(st.mode)
	if key == st.period do return false
	first := st.period == ""
	auto_set_str(&st.period, key)
	if !first {
		if pick := auto_pick(st, files, current); pick != "" do apply(pick)
	}
	return true
}

// Called every frame from the main loop; checks the clock every 30 s (and right away at startup).
autochange_update :: proc() {
	now := rl.GetTime()
	if now < auto_next_check do return
	auto_next_check = now + 30
	changed := auto_tick_one(&app.settings.bkg_auto, theme.bkg_files[:], app.settings.bkg, theme_apply_bkg)
	// music stays put while the explorer or a game holds the audio
	if !explorer.has_music do changed |= auto_tick_one(&app.settings.bgm_auto, theme.bgm_files[:], app.settings.bgm, theme_apply_bgm)
	if changed do save_settings()
}
