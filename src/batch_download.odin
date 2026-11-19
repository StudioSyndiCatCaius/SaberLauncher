package saber

// Batch downloads: many pieces fetched in parallel and written into files at given offsets, each
// optionally zlib-inflated and md5-checked. A generic engine for content-delivery systems that
// split files into chunks (the Lua side knows the service; Saber only moves bytes).
//
//   Batch_Download(id, tasks, opts) -> true | nil, err
//       tasks: { { url =, path =, offset = 0, size =, md5 = <hex of the written data>, zlib = false, optional = false }, ... }
//              optional: a piece that can't be fetched is skipped (counted in status.skipped) instead of failing the batch.
//              size = bytes written (progress); parent folders are created.
//       opts:  { title = "shown on the card", workers = 6, headers = {...},
//                journal = <path>, resume_key = "...",
//                mirrors = { { from_prefix =, from_suffix = "", to_prefix =, to_suffix = "" }, ... } }
//              A piece that fails on its url is retried on each mirror whose from_prefix / from_suffix
//              frame the url (the middle part is kept): other servers of the same content.
//              With a journal, finished pieces are recorded; a later batch with the same journal and
//              resume_key skips them (if their file still exists): stopped batches resume.
//   Batch_Status(id) -> { state = "queued" | "running" | "done" | "failed", got, total, skipped, error, url } | nil
//       url = the address of the piece that failed
//   Batch_Cancel(id)
//
// One batch runs at a time (queued); Online Mode off stops it. Batches belong to Saber, not to the
// Lua state, so they keep going when a channel closes. A card shows the running one.

import "base:runtime"
import "core:bytes"
import "core:c"
import "core:compress/zlib"
import "core:crypto/legacy/md5"
import "core:encoding/hex"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

Batch_State :: enum i32 {
	Queued,
	Running,
	Done,
	Failed,
}

BATCH_STATE_NAMES := [Batch_State]string {
	.Queued  = "queued",
	.Running = "running",
	.Done    = "done",
	.Failed  = "failed",
}

Batch_Task :: struct {
	url:    string,
	path:   string,
	offset: i64,
	size:   i64,
	md5:    string,
	zlib:   bool,
	optional: bool,
}

Batch_Job :: struct {
	id:         string,
	title:      string,
	headers:    string,
	journal:    string,
	resume_key: string,
	workers:    int,
	mirrors:    [dynamic][4]string, // from_prefix, from_suffix, to_prefix, to_suffix (arena)
	arena:      virtual.Arena, // tasks and their strings
	tasks:      []Batch_Task,
	done:       []bool,
	controller: ^thread.Thread,
	ended_at:   f64,
	gen:        u64,
	// shared
	state:      Batch_State, // atomic
	got:        i64, // atomic
	skipped:    int, // atomic: optional pieces that failed
	total:      i64, // atomic
	next:       int, // atomic
	cancel:     bool, // atomic: Batch_Cancel / shutdown
	stop:       bool, // atomic: a piece failed, the other workers stop
	finished:   bool, // atomic
	lock:       sync.Mutex,
	journal_f:  ^os.File,
	err:        string, // first error (under lock)
	err_url:    string, // the piece that failed (logged by batches_update)
}

batches: [dynamic]^Batch_Job

batch_card: struct {
	t:        f32,
	speed:    f64,
	last_got: i64,
	last_at:  f64,
}

batch_find :: proc(id: string) -> ^Batch_Job {
	for b in batches do if b.id == id do return b
	return nil
}

batch_state :: proc(b: ^Batch_Job) -> Batch_State {
	return Batch_State(sync.atomic_load(cast(^i32)&b.state))
}

batch_running :: proc() -> ^Batch_Job {
	for b in batches do if batch_state(b) == .Running do return b
	return nil
}

batch_free :: proc(b: ^Batch_Job) {
	for x, i in batches do if x == b {
		ordered_remove(&batches, i)
		break
	}
	thread_end(&b.controller)
	virtual.arena_destroy(&b.arena)
	delete(b.id)
	delete(b.title)
	delete(b.headers)
	delete(b.journal)
	delete(b.resume_key)
	delete(b.err)
	delete(b.err_url)
	free(b)
}

batch_killed :: proc(b: ^Batch_Job) -> bool {
	return sync.atomic_load(&b.cancel) || sync.atomic_load(&b.stop) || sync.atomic_load(&online_gen) != b.gen
}

batch_fail :: proc(b: ^Batch_Job, msg: string, url := "") {
	sync.mutex_lock(&b.lock)
	if b.err == "" {
		b.err = strings.clone(msg, runtime.default_allocator())
		b.err_url = strings.clone(url, runtime.default_allocator())
	}
	sync.mutex_unlock(&b.lock)
	sync.atomic_store(&b.stop, true)
}

// Main loop, every scene.
batches_update :: proc() {
	for b in batches {
		if b.controller == nil || !sync.atomic_load(&b.finished) do continue
		thread_end(&b.controller)
		b.ended_at = rl.GetTime()
		if batch_state(b) == .Failed && !sync.atomic_load(&b.cancel) {
			set_status("%s: %s", b.title, b.err)
			plugin_logf("batch %s failed: %s  (%s)", b.id, b.err, b.err_url)
		}
	}
	for i := len(batches) - 1; i >= 0; i -= 1 {
		b := batches[i]
		if b.controller == nil && sync.atomic_load(&b.cancel) do batch_free(b)
	}
	if batch_running() != nil do return
	for b in batches {
		if batch_state(b) != .Queued do continue
		sync.atomic_store(cast(^i32)&b.state, i32(Batch_State.Running))
		b.gen = sync.atomic_load(&online_gen)
		batch_card.last_got, batch_card.last_at, batch_card.speed = 0, rl.GetTime(), 0
		b.controller = thread.create_and_start_with_data(b, batch_controller)
		break
	}
}

batches_shutdown :: proc() {
	for b in batches do sync.atomic_store(&b.cancel, true)
	for len(batches) > 0 do batch_free(batches[len(batches) - 1])
}

batch_controller :: proc(data: rawptr) {
	b := (^Batch_Job)(data)
	context = runtime.default_context()
	defer sync.atomic_store(&b.finished, true)
	defer free_all(context.temp_allocator)
	defer {
		s: Batch_State = b.err == "" && !batch_killed(b) ? .Done : .Failed
		if s == .Failed && b.err == "" do b.err = strings.clone(sync.atomic_load(&b.cancel) ? "Stopped" : "Online Mode was turned off")
		sync.atomic_store(cast(^i32)&b.state, i32(s))
	}

	b.done = make([]bool, len(b.tasks))
	// resume from the journal
	if b.journal != "" {
		if old, err := os.read_entire_file(b.journal, context.allocator); err == nil {
			defer delete(old)
			lines := strings.split_lines(string(old), context.temp_allocator)
			if len(lines) > 0 && lines[0] == b.resume_key {
				for l in lines[1:] {
					if n, ok := strconv.parse_int(l); ok && n >= 0 && n < len(b.tasks) && os.exists(b.tasks[n].path) do b.done[n] = true
				}
			}
		}
		os.make_directory_all(filepath.dir(b.journal)) // dir() is a view into the path: nothing to free
		f, err := os.open(b.journal, {.Write, .Create, .Trunc})
		if err != nil {
			batch_fail(b, fmt.tprintf("Can't write %s", b.journal))
			return
		}
		b.journal_f = f
		fmt.fprintln(f, b.resume_key)
	}
	total, got: i64
	{
		context.allocator = context.temp_allocator // this thread's own temp arena: dir strings
		made := make(map[string]bool)
		for t, i in b.tasks {
			total += t.size
			if b.done[i] {
				got += t.size
				if b.journal_f != nil do fmt.fprintln(b.journal_f, i)
			}
			dir := filepath.dir(t.path)
			if !made[dir] {
				made[dir] = true
				os.make_directory_all(dir)
			}
		}
	}
	sync.atomic_store(&b.total, total)
	sync.atomic_store(&b.got, got)

	workers := make([]^thread.Thread, clamp(b.workers, 1, 16), context.temp_allocator)
	for &w in workers do w = thread.create_and_start_with_data(b, batch_worker)
	for &w in workers do thread_end(&w)
	if b.journal_f != nil {
		os.close(b.journal_f)
		b.journal_f = nil
	}
}

batch_md5_is :: proc(data: []u8, want: string) -> bool {
	ctx: md5.Context
	md5.init(&ctx)
	md5.update(&ctx, data)
	sum: [md5.DIGEST_SIZE]u8
	md5.final(&ctx, sum[:])
	return eq_fold(string(hex.encode(sum[:], context.temp_allocator)), want)
}

batch_worker :: proc(data: rawptr) {
	b := (^Batch_Job)(data)
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	open_path := ""
	fh: ^os.File
	defer if fh != nil do os.close(fh)
	for {
		if batch_killed(b) do return
		i := sync.atomic_add(&b.next, 1)
		if i >= len(b.tasks) do return
		if b.done[i] do continue
		t := b.tasks[i]
		piece: []u8
		err := ""
		// the piece's url, then the same middle part on each mirror
		urls := make([dynamic]string, context.temp_allocator)
		append(&urls, t.url)
		for m in b.mirrors {
			if strings.has_prefix(t.url, m[0]) && strings.has_suffix(t.url, m[1]) && len(t.url) >= len(m[0]) + len(m[1]) {
				append(&urls, strings.concatenate({m[2], t.url[len(m[0]):len(t.url) - len(m[1])], m[3]}, context.temp_allocator))
			}
		}
		for attempt in 0 ..< max(3, len(urls) * 2) {
			if batch_killed(b) do return
			r: Http_Request
			r.url = urls[min(attempt / 2, len(urls) - 1)] // two tries per server
			r.headers = b.headers
			r.gen = b.gen
			buf := make([dynamic]u8)
			fetched := http_fetch(&r, &buf)
			status := r.status
			if !fetched || status != 200 {
				err = !fetched && r.err != "" ? fmt.tprintf("%s", r.err) : fmt.tprintf("HTTP %d", status)
				delete(r.err)
				delete(buf)
				if (status == 401 || status == 403 || status == 404) && attempt / 2 >= len(urls) - 1 do break // no server has it
				continue
			}
			delete(r.err)
			if t.zlib {
				out: bytes.Buffer
				if zlib.inflate_from_byte_array(buf[:], &out, expected_output_size = int(t.size)) != nil {
					delete(buf)
					bytes.buffer_destroy(&out)
					err = "a piece didn't unpack"
					continue
				}
				delete(buf)
				piece = bytes.buffer_to_bytes(&out)
			} else {
				piece = buf[:]
			}
			if t.md5 != "" && !batch_md5_is(piece, t.md5) {
				delete(piece)
				piece = nil
				err = "a piece failed its checksum"
				continue
			}
			err = ""
			break
		}
		if (err != "" || piece == nil) && t.optional {
			sync.atomic_add(&b.skipped, 1)
			sync.atomic_add(&b.got, t.size)
			free_all(context.temp_allocator)
			continue
		}
		if err != "" || piece == nil {
			batch_fail(b, err != "" ? err : "download failed", urls[len(urls) - 1])
			return
		}
		if open_path != t.path {
			if fh != nil do os.close(fh)
			fh = nil
			f, oerr := os.open(t.path, {.Write, .Create})
			if oerr != nil {
				delete(piece)
				batch_fail(b, fmt.tprintf("Couldn't write %s", t.path))
				return
			}
			fh, open_path = f, t.path
		}
		_, werr := os.write_at(fh, piece, t.offset)
		delete(piece)
		if werr != nil {
			batch_fail(b, "Couldn't write to disk (full?)")
			return
		}
		sync.mutex_lock(&b.lock)
		if b.journal_f != nil do fmt.fprintln(b.journal_f, i)
		sync.mutex_unlock(&b.lock)
		sync.atomic_add(&b.got, t.size)
		free_all(context.temp_allocator)
	}
}

// ---------------------------------------------------------------------------
// Card (stacked above the download card)

batch_card_visible :: proc() -> bool {
	return batch_card.t >= 0.02 || batch_running() != nil
}

draw_batch_card :: proc(w, h: f32) {
	now := rl.GetTime()
	b := batch_running()
	queued := 0
	for x in batches do if batch_state(x) == .Queued do queued += 1
	last: ^Batch_Job
	if b == nil {
		for x in batches {
			s := batch_state(x)
			if (s == .Done || s == .Failed) && x.controller == nil && now - x.ended_at < DOWNLOAD_CARD_SEC && !sync.atomic_load(&x.cancel) do last = x
		}
	}
	if !modal_fade(&batch_card.t, b != nil || last != nil, 14) do return
	t := batch_card.t
	lift := drive_scan.card_t * (92 + 12) + install.card_t * (104 + 12) + dl_card.t * (104 + 12)
	r := toast_card(w, h, 460, 104, t, lift, last != nil && batch_state(last) == .Failed)
	if t < 0.5 do return
	tx := r.x + 24
	tw := r.width - 48
	if b == nil {
		if last == nil do return // fading out: the job is gone
		ok := batch_state(last) == .Done
		draw_t_fit(last.title, tx, r.y + 22, tw, 20, COL_TEXT, false)
		draw_t_fit(ok ? "Download complete" : last.err, tx, r.y + 54, tw, 15, COL_MUTED, false)
		return
	}
	got := sync.atomic_load(&b.got)
	total := sync.atomic_load(&b.total)
	frac := total > 0 ? clamp(f32(f64(got) / f64(total)), 0, 1) : 0
	if now - batch_card.last_at >= 1 {
		if batch_card.last_got > 0 && got >= batch_card.last_got {
			s := f64(got - batch_card.last_got) / (now - batch_card.last_at)
			batch_card.speed = batch_card.speed == 0 ? s : batch_card.speed * 0.6 + s * 0.4
		}
		batch_card.last_got, batch_card.last_at = got, now
	}
	draw_t_fit(queued > 0 ? fmt.tprintf("Downloading  ·  %d more queued", queued) : "Downloading", tx, r.y + 14, tw, 15, COL_MUTED, false)
	draw_t_fit(b.title, tx, r.y + 34, tw, 18, COL_TEXT, false)
	line := total > 0 ? fmt.tprintf("%d%%  ·  %s of %s", int(frac * 100), fmt_bytes(got), fmt_bytes(total)) : "Starting…"
	if batch_card.speed > 0 {
		line = fmt.tprintf("%s  ·  %s/s", line, fmt_bytes(i64(batch_card.speed)))
		if total > got {
			left := int(f64(total - got) / batch_card.speed)
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

// Batch_Download(id, tasks, opts) -> true | nil, err
lua_batch_download :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	fail :: proc(L: ^lua_State, msg: string) -> c.int {
		lua_pushnil(L)
		lua_pushstring(L, strings.clone_to_cstring(msg, context.temp_allocator))
		return 2
	}
	id := strings.clone(lua_string(L, 1), context.temp_allocator)
	if id == "" || lua_type(L, 2) != LUA_TTABLE do return fail(L, "Batch_Download(id, tasks, opts)")
	if !online_enabled() do return fail(L, "Online Mode is off (Settings)")
	if old := batch_find(id); old != nil {
		s := batch_state(old)
		if s == .Queued || s == .Running do return fail(L, "That batch is already running")
		batch_free(old)
	}
	b := new(Batch_Job)
	b.id = strings.clone(id)
	b.workers = 6
	_ = virtual.arena_init_growing(&b.arena)
	{
		context.allocator = virtual.arena_allocator(&b.arena)
		n := int(lua_rawlen(L, 2))
		tasks := make([]Batch_Task, n)
		for i in 0 ..< n {
			if lua_rawgeti(L, 2, i64(i + 1)) != LUA_TTABLE {
				lua_pop(L, 1)
				continue
			}
			t := &tasks[i]
			t.url = strings.clone(lua_field_string(L, -1, "url"))
			t.path = strings.clone(lua_plugin_path(L, lua_field_string(L, -1, "path")))
			t.md5 = strings.clone(lua_field_string(L, -1, "md5"))
			if lua_getfield(L, -1, "offset") == LUA_TNUMBER do t.offset = i64(lua_tonumberx(L, -1, nil))
			lua_pop(L, 1)
			if lua_getfield(L, -1, "size") == LUA_TNUMBER do t.size = i64(lua_tonumberx(L, -1, nil))
			lua_pop(L, 1)
			lua_getfield(L, -1, "zlib")
			t.zlib = lua_toboolean(L, -1) != 0
			lua_pop(L, 1)
			lua_getfield(L, -1, "optional")
			t.optional = lua_toboolean(L, -1) != 0
			lua_pop(L, 2)
		}
		b.tasks = tasks
	}
	if lua_type(L, 3) == LUA_TTABLE {
		b.title = strings.clone(lua_field_string(L, 3, "title"))
		if j := lua_field_string(L, 3, "journal"); j != "" do b.journal = strings.clone(lua_plugin_path(L, j))
		b.resume_key = strings.clone(lua_field_string(L, 3, "resume_key"))
		if lua_getfield(L, 3, "workers") == LUA_TNUMBER do b.workers = int(lua_tonumberx(L, -1, nil))
		lua_pop(L, 1)
		if lua_getfield(L, 3, "headers") == LUA_TTABLE do b.headers = strings.clone(lua_headers_arg(L, lua_gettop(L)))
		lua_pop(L, 1)
		if lua_getfield(L, 3, "mirrors") == LUA_TTABLE {
			context.allocator = virtual.arena_allocator(&b.arena)
			mt := lua_gettop(L)
			for i in 1 ..= int(lua_rawlen(L, mt)) {
				if lua_rawgeti(L, mt, i64(i)) == LUA_TTABLE {
					m: [4]string
					for key, k in ([4]cstring{"from_prefix", "from_suffix", "to_prefix", "to_suffix"}) do m[k] = strings.clone(lua_field_string(L, -1, key))
					if m[0] != "" && m[2] != "" do append(&b.mirrors, m)
				}
				lua_pop(L, 1)
			}
		}
		lua_pop(L, 1)
	}
	if b.title == "" do b.title = strings.clone(id)
	append(&batches, b)
	lua_pushboolean(L, 1)
	return 1
}

lua_batch_status :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	b := batch_find(lua_string(L, 1))
	if b == nil || sync.atomic_load(&b.cancel) {
		lua_pushnil(L)
		return 1
	}
	s := batch_state(b)
	if s != .Queued && s != .Running && b.controller != nil do s = .Running // finishing up
	lua_createtable(L, 0, 4)
	push_field(L, "state", BATCH_STATE_NAMES[s])
	lua_pushnumber(L, f64(sync.atomic_load(&b.got)))
	lua_setfield(L, -2, "got")
	lua_pushnumber(L, f64(sync.atomic_load(&b.total)))
	lua_setfield(L, -2, "total")
	lua_pushinteger(L, i64(sync.atomic_load(&b.skipped)))
	lua_setfield(L, -2, "skipped")
	if s == .Failed && b.err != "" do push_field(L, "error", b.err)
	if s == .Failed && b.err_url != "" do push_field(L, "url", b.err_url)
	return 1
}

lua_batch_cancel :: proc "c" (L: ^lua_State) -> c.int {
	context = runtime.default_context()
	if b := batch_find(lua_string(L, 1)); b != nil do sync.atomic_store(&b.cancel, true)
	return 0
}
