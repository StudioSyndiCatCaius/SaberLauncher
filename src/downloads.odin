package saber

// Big downloads (game installers): streamed to disk, resumable, one at a time, owned by Saber
// (not by the Lua state that asked), so they keep going after a channel / plugin view closes.
// Keyed by destination path. Everything goes to `<path>.part` and is renamed when complete; a
// later Download() of the same path resumes the .part with an HTTP Range request.
//
//   Download(url, path [, headers]) -> true | nil, err     queue it (relative path = plugin / channel folder)
//   Download_Status(path) -> { state, got, total, error } | nil
//       state: "queued" | "downloading" | "done" | "failed" | "partial" (a .part left from before) ; nil = nothing
//   Download_Cancel(path)                                   stops it, keeping the .part for a resume
//
// Online Mode off stops them like any other transfer. A card bottom-right shows the progress.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

Download_State :: enum {
	Queued,
	Running,
	Done,
	Failed,
}

DOWNLOAD_STATE_NAMES := [Download_State]string {
	.Queued  = "queued",
	.Running = "downloading",
	.Done    = "done",
	.Failed  = "failed",
}

Download_Job :: struct {
	url:      string,
	path:     string,
	headers:  string,
	name:     string, // file name, for the card
	state:    Download_State,
	err:      string,
	gen:      u64,
	worker:   ^thread.Thread,
	ended_at: f64,
	// shared with the worker
	got:      i64, // atomic: bytes on disk so far (including a resumed .part)
	total:    i64, // atomic: whole file size, 0 = unknown
	cancel:   bool, // atomic
	finished: bool, // atomic
	ok:       bool,
	w_err:    string, // worker's error (heap)
}

downloads: [dynamic]^Download_Job

dl_card: struct {
	t:        f32,
	speed:    f64,
	last_got: i64,
	last_at:  f64,
}

DOWNLOAD_CARD_SEC :: 5.0

download_find :: proc(path: string) -> ^Download_Job {
	for d in downloads do if paths_equal(d.path, path) do return d
	return nil
}

download_start :: proc(url, path, headers: string) -> (ok: bool, err: string) {
	if !online_enabled() do return false, "Online Mode is off (Settings)"
	if d := download_find(path); d != nil {
		if d.state == .Queued || d.state == .Running do return true, ""
		// finished / failed before: start over (resumes from the .part)
		download_remove(d)
	}
	d := new(Download_Job)
	d.url = strings.clone(url)
	d.path = strings.clone(path)
	d.headers = strings.clone(headers)
	d.name = strings.clone(filepath.base(path))
	append(&downloads, d)
	return true, ""
}

download_remove :: proc(d: ^Download_Job) {
	for x, i in downloads do if x == d {
		ordered_remove(&downloads, i)
		break
	}
	thread_end(&d.worker)
	delete(d.url)
	delete(d.path)
	delete(d.headers)
	delete(d.name)
	delete(d.err)
	delete(d.w_err)
	free(d)
}

download_running :: proc() -> ^Download_Job {
	for d in downloads do if d.state == .Running do return d
	return nil
}

// Main loop, every scene: finishes jobs and starts the next queued one.
downloads_update :: proc() {
	for d in downloads {
		if d.state != .Running || !sync.atomic_load(&d.finished) do continue
		thread_end(&d.worker)
		d.state = d.ok ? .Done : .Failed
		delete(d.err)
		d.err = strings.clone(d.w_err)
		d.ended_at = rl.GetTime()
		if d.ok {
			set_status("Downloaded %s", d.name)
		} else if !sync.atomic_load(&d.cancel) {
			set_status("Download failed: %s (%s)", d.name, d.err)
		}
	}
	// cancelled jobs vanish once their worker is done
	for i := len(downloads) - 1; i >= 0; i -= 1 {
		d := downloads[i]
		if d.state != .Running && sync.atomic_load(&d.cancel) do download_remove(d)
	}
	if download_running() != nil do return
	for d in downloads {
		if d.state != .Queued do continue
		d.state = .Running
		d.gen = sync.atomic_load(&online_gen)
		dl_card.last_got, dl_card.last_at, dl_card.speed = 0, rl.GetTime(), 0
		d.worker = thread.create_and_start_with_data(d, download_worker)
		break
	}
}

download_killed :: proc(d: ^Download_Job) -> bool {
	return sync.atomic_load(&d.cancel) || sync.atomic_load(&online_gen) != d.gen
}

download_worker :: proc(data: rawptr) {
	d := (^Download_Job)(data)
	context = runtime.default_context()
	defer sync.atomic_store(&d.finished, true)
	defer free_all(context.temp_allocator)
	fail :: proc(d: ^Download_Job, msg: string) {
		d.w_err = strings.clone(msg)
	}
	if !online_enabled() {
		fail(d, "Online Mode is off")
		return
	}
	part := strings.concatenate({d.path, ".part"}, context.temp_allocator)
	os.make_directory_all(filepath.dir(d.path)) // dir() is a view into the path: nothing to free
	offset: i64 = 0
	if fi, err := os.stat(part, context.temp_allocator); err == nil do offset = fi.size
	if err := download_fetch(d, part, offset); err != "" {
		fail(d, err)
		return
	}
	os.remove(d.path)
	if os.rename(part, d.path) != nil {
		fail(d, "Couldn't rename the finished download")
		return
	}
	d.ok = true
}

// Main loop, before the session ends.
downloads_shutdown :: proc() {
	for d in downloads do sync.atomic_store(&d.cancel, true)
	for len(downloads) > 0 do download_remove(downloads[len(downloads) - 1])
}

// ---------------------------------------------------------------------------
// Card

download_card_visible :: proc() -> bool {
	return dl_card.t >= 0.02
}

draw_download_card :: proc(w, h: f32) {
	now := rl.GetTime()
	d := download_running()
	queued := 0
	for x in downloads do if x.state == .Queued do queued += 1
	last: ^Download_Job
	if d == nil {
		for x in downloads do if (x.state == .Done || x.state == .Failed) && now - x.ended_at < DOWNLOAD_CARD_SEC do last = x
	}
	show := d != nil || last != nil
	if !modal_fade(&dl_card.t, show, 14) do return
	t := dl_card.t
	lift := drive_scan.card_t * (92 + 12) + install.card_t * (104 + 12)
	r := toast_card(w, h, 440, 104, t, lift, last != nil && last.state == .Failed)
	if t < 0.5 do return

	// arrow into a tray
	icon := rl.Vector2{r.x + 52, r.y + r.height * 0.5}
	bob: f32 = d != nil ? 3 * math.sin(f32(rl.GetTime()) * 5) : 0
	col := COL_ACCENT
	rl.DrawRectangleRounded({icon.x - 4, icon.y - 22 + bob, 8, 22}, 0.5, 4, col)
	rl.DrawTriangle({icon.x - 12, icon.y - 2 + bob}, {icon.x, icon.y + 12 + bob}, {icon.x + 12, icon.y - 2 + bob}, col)
	rl.DrawRectangleRounded({icon.x - 20, icon.y + 16, 40, 5}, 1, 4, col)
	tx := r.x + 100
	tw := r.width - (tx - r.x) - 22

	if d == nil {
		if last == nil do return // fading out: the job is gone
		ok := last.state == .Done
		draw_t(ok ? "Download complete" : "Download failed", tx, r.y + 24, 21, COL_TEXT)
		draw_t_fit(ok ? last.name : last.err, tx, r.y + 56, tw, 15, COL_MUTED, false)
		return
	}
	got := sync.atomic_load(&d.got)
	total := sync.atomic_load(&d.total)
	frac := total > 0 ? clamp(f32(f64(got) / f64(total)), 0, 1) : 0
	// speed over ~1 s windows
	if now - dl_card.last_at >= 1 {
		if dl_card.last_got > 0 && got >= dl_card.last_got {
			s := f64(got - dl_card.last_got) / (now - dl_card.last_at)
			dl_card.speed = dl_card.speed == 0 ? s : dl_card.speed * 0.6 + s * 0.4
		}
		dl_card.last_got, dl_card.last_at = got, now
	}
	title := queued > 0 ? fmt.tprintf("Downloading  ·  %d more queued", queued) : "Downloading"
	draw_t_fit(title, tx, r.y + 14, tw, 15, COL_MUTED, false)
	draw_t_fit(d.name, tx, r.y + 34, tw, 18, COL_TEXT, false)
	line := total > 0 ? fmt.tprintf("%d%%  ·  %s of %s", int(frac * 100), fmt_bytes(got), fmt_bytes(total)) : fmt_bytes(got)
	if dl_card.speed > 0 {
		line = fmt.tprintf("%s  ·  %s/s", line, fmt_bytes(i64(dl_card.speed)))
		if total > got {
			left := int(f64(total - got) / dl_card.speed)
			line = fmt.tprintf("%s  ·  %d:%02d left", line, left / 60, left % 60)
		}
	}
	draw_t_fit(line, tx, r.y + 58, tw, 14, COL_MUTED, false)
	bar := rl.Rectangle{tx, r.y + r.height - 22, tw, 8}
	rl.DrawRectangleRounded(bar, 1, 8, COL_FAINT)
	if frac > 0 do rl.DrawRectangleRounded({bar.x, bar.y, max(bar.height, bar.width * frac), bar.height}, 1, 8, COL_ACCENT)
}

// ---------------------------------------------------------------------------
// Lua

// Download(url, path [, headers]) -> true | nil, err
lua_download :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	url := lua_string(L, 1)
	path := lua_plugin_path(L, lua_string(L, 2))
	if !strings.has_prefix(url, "https://") && !strings.has_prefix(url, "http://") || path == "" {
		lua_pushnil(L)
		lua_pushstring(L, "Download: needs an http(s) url and a path")
		return 2
	}
	ok, err := download_start(url, path, lua_headers_arg(L, 3))
	if !ok {
		lua_pushnil(L)
		lua_pushstring(L, strings.clone_to_cstring(err, context.temp_allocator))
		return 2
	}
	lua_pushboolean(L, 1)
	return 1
}

// Download_Status(path) -> { state, got, total, error } | nil
lua_download_status :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	path := lua_plugin_path(L, lua_string(L, 1))
	state, err: string
	got, total: i64
	if d := download_find(path); d != nil && !sync.atomic_load(&d.cancel) {
		state = DOWNLOAD_STATE_NAMES[d.state]
		err = d.err
		got, total = sync.atomic_load(&d.got), sync.atomic_load(&d.total)
		if d.state == .Done do got = total
	} else if fi, e := os.stat(path, context.temp_allocator); e == nil && fi.type != .Directory {
		state = "done"
		got, total = fi.size, fi.size
	} else if fi, e := os.stat(strings.concatenate({path, ".part"}, context.temp_allocator), context.temp_allocator); e == nil {
		state = "partial"
		got = fi.size
	} else {
		lua_pushnil(L)
		return 1
	}
	lua_createtable(L, 0, 4)
	push_field(L, "state", state)
	lua_pushnumber(L, f64(got))
	lua_setfield(L, -2, "got")
	lua_pushnumber(L, f64(total))
	lua_setfield(L, -2, "total")
	if err != "" do push_field(L, "error", err)
	return 1
}

lua_download_cancel :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if d := download_find(lua_plugin_path(L, lua_string(L, 1))); d != nil {
		sync.atomic_store(&d.cancel, true)
		if d.state != .Running do d.state = .Failed // the update loop drops it
	}
	return 0
}
