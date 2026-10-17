package flasher

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import win "core:sys/windows"

// Install scripting: a preconfig's `config.lua` returns a table; `OnInstall(self, install_path)`
// runs on the flash worker thread. The API is plain globals that block until done, then call
// an optional callback with the result (and also return it), e.g.
//
//     File_Download(self.link, function(file)
//         File_Unzip(file, function(folder) Dir_Copy(folder, install_path) end)
//     end)
//
// Each long call is a "step" with live progress in the install overlay; Cancel aborts the
// running step and unwinds the script. Writes/deletes are only allowed inside the install
// folder or the job's temp folder.

// ---------------------------------------------------------------- steps & progress (shared with UI)

Step_State :: enum {
	Running,
	Done,
	Failed,
	Cancelled,
}

Step :: struct {
	name:   string,
	detail: string,
	state:  Step_State,
}

CANCELLED_MSG :: "Cancelled"

cancelled :: proc() -> bool {
	return sync.atomic_load(&job.cancel)
}

step_begin :: proc(name: string) {
	sync.guard(&job.mu)
	if n := len(job.steps); n > 0 && job.steps[n - 1].state == .Running do job.steps[n - 1].state = .Done
	append(&job.steps, Step{name = strings.clone(name), state = .Running})
	job.progress = -1
}

step_progress :: proc(frac: f32, detail: string = "") {
	sync.guard(&job.mu)
	job.progress = frac
	if n := len(job.steps); n > 0 {
		delete(job.steps[n - 1].detail)
		job.steps[n - 1].detail = strings.clone(detail)
	}
}

step_end :: proc(state: Step_State = .Done, detail: string = "") {
	sync.guard(&job.mu)
	if n := len(job.steps); n > 0 && job.steps[n - 1].state == .Running {
		job.steps[n - 1].state = state
		if detail != "" {
			delete(job.steps[n - 1].detail)
			job.steps[n - 1].detail = strings.clone(detail)
		}
	}
}

job_log :: proc(msg: string) {
	sync.guard(&job.mu)
	append(&job.log, strings.clone(msg))
}

// ---------------------------------------------------------------- path safety

full_path :: proc(p: string) -> string {
	buf: [1024]u16
	n := win.GetFullPathNameW(win.utf8_to_wstring(p), len(buf), cstring16(raw_data(buf[:])), nil)
	if n == 0 || n >= len(buf) do return p
	return strings.trim_right(w2s(buf[:n]), "\\")
}

path_inside :: proc(p, root: string) -> bool {
	if root == "" do return false
	fp := strings.to_lower(full_path(p), context.temp_allocator)
	r := strings.to_lower(full_path(root), context.temp_allocator)
	return fp == r || strings.has_prefix(fp, strings.concatenate({r, "\\"}, context.temp_allocator))
}

writable :: proc(p: string) -> bool {
	return path_inside(p, job.dest) || path_inside(p, job.temp)
}

// Relative paths in scripts resolve against the install folder.
resolve :: proc(p: string) -> string {
	if p == "" do return job.dest
	if filepath.is_abs(p) || (len(p) >= 2 && p[1] == ':') do return p
	return fmt.tprintf("%s\\%s", strings.trim_right(job.dest, "\\/"), p)
}

// ---------------------------------------------------------------- file ops

delete_tree :: proc(root: string) -> bool {
	if !os.is_dir(root) {
		return !os.exists(root) || bool(win.DeleteFileW(win.utf8_to_wstring(root)))
	}
	entries: [dynamic]string
	defer {
		for e in entries do delete(e)
		delete(entries)
	}
	walk_dir(root, proc(path: string, is_dir: bool, user: rawptr) -> bool {
		append((^[dynamic]string)(user), strings.clone(fmt.tprintf("%s%s", is_dir ? "D" : "F", path)))
		return true
	}, &entries)
	#reverse for e in entries { // children come after parents, so reverse deletes bottom-up
		w := win.utf8_to_wstring(e[1:])
		if e[0] == 'F' {
			win.SetFileAttributesW(w, win.FILE_ATTRIBUTE_NORMAL)
			win.DeleteFileW(w)
		} else {
			win.RemoveDirectoryW(w)
		}
	}
	return bool(win.RemoveDirectoryW(win.utf8_to_wstring(root)))
}

Copy_Ctx :: struct {
	src, dst:    string,
	total, done: int,
	err:         string,
}

// Copies the *contents* of src into dst (merging), with progress. Returns "" or an error.
copy_tree :: proc(src, dst: string) -> string {
	ctx := Copy_Ctx{src = strings.trim_right(src, "\\/"), dst = strings.trim_right(dst, "\\/")}
	if !os.is_dir(src) do return fmt.tprintf("Not a folder: %s", src)
	walk_dir(ctx.src, proc(path: string, is_dir: bool, user: rawptr) -> bool {
		if !is_dir do (^Copy_Ctx)(user).total += 1
		return true
	}, &ctx)
	make_dirs(ctx.dst)
	walk_dir(ctx.src, proc(path: string, is_dir: bool, user: rawptr) -> bool {
		x := (^Copy_Ctx)(user)
		if cancelled() || x.err != "" do return false
		rel := path[len(x.src):]
		target := strings.concatenate({x.dst, rel}, context.temp_allocator)
		if is_dir {
			make_dirs(target)
			return true
		}
		if !win.CopyFileW(win.utf8_to_wstring(path), win.utf8_to_wstring(target), false) {
			x.err = strings.clone(fmt.tprintf("Copy failed: %s", rel))
			return false
		}
		x.done += 1
		step_progress(f32(x.done) / f32(max(x.total, 1)), fmt.tprintf("%d / %d files", x.done, x.total))
		return true
	}, &ctx)
	if cancelled() do return CANCELLED_MSG
	return ctx.err
}

// ---------------------------------------------------------------- download (WinINet, loaded at runtime)

HINTERNET :: rawptr
InternetOpenW: proc "system" (agent: win.LPCWSTR, access: u32, proxy, bypass: win.LPCWSTR, flags: u32) -> HINTERNET
InternetOpenUrlW: proc "system" (h: HINTERNET, url, headers: win.LPCWSTR, headers_len: u32, flags: u32, ctx: uintptr) -> HINTERNET
InternetReadFile: proc "system" (h: HINTERNET, buf: rawptr, to_read: u32, read: ^u32) -> win.BOOL
InternetCloseHandle: proc "system" (h: HINTERNET) -> win.BOOL
HttpQueryInfoW: proc "system" (h: HINTERNET, level: u32, buf: rawptr, len: ^u32, index: ^u32) -> win.BOOL
InternetQueryOptionW: proc "system" (h: HINTERNET, option: u32, buf: rawptr, len: ^u32) -> win.BOOL

HTTP_QUERY_CONTENT_TYPE :: 1
HTTP_QUERY_CONTENT_LENGTH :: 5
HTTP_QUERY_STATUS_CODE :: 19
HTTP_QUERY_CONTENT_DISPOSITION :: 47
HTTP_QUERY_FLAG_NUMBER :: 0x20000000
HTTP_QUERY_FLAG_NUMBER64 :: 0x08000000
INTERNET_OPTION_URL :: 34
INTERNET_FLAG_RELOAD :: 0x80000000
INTERNET_FLAG_NO_CACHE_WRITE :: 0x04000000
INTERNET_FLAG_NO_UI :: 0x00000200

load_wininet :: proc() -> bool {
	if InternetOpenW != nil do return true
	m := win.LoadLibraryW(win.L("wininet.dll"))
	if m == nil do return false
	InternetOpenW = auto_cast win.GetProcAddress(m, "InternetOpenW")
	InternetOpenUrlW = auto_cast win.GetProcAddress(m, "InternetOpenUrlW")
	InternetReadFile = auto_cast win.GetProcAddress(m, "InternetReadFile")
	InternetCloseHandle = auto_cast win.GetProcAddress(m, "InternetCloseHandle")
	HttpQueryInfoW = auto_cast win.GetProcAddress(m, "HttpQueryInfoW")
	InternetQueryOptionW = auto_cast win.GetProcAddress(m, "InternetQueryOptionW")
	return InternetOpenW != nil
}

http_header :: proc(h: HINTERNET, level: u32) -> string {
	buf: [1024]u16
	n := u32(size_of(buf))
	if !HttpQueryInfoW(h, level, &buf[0], &n, nil) do return ""
	return w2s(buf[:])
}

url_file_name :: proc(url: string) -> string {
	u := url
	if i := strings.index_any(u, "?#"); i >= 0 do u = u[:i]
	name := sanitize_name(u[strings.last_index_byte(u, '/') + 1:])
	return name == "" ? "download.bin" : name
}

short_name :: proc(s: string, n := 48) -> string {
	return len(s) <= n ? s : fmt.tprintf("%s…%s", s[:n / 2], s[len(s) - n / 2:])
}

// Downloads url into the job temp folder; returns the file path.
download :: proc(url: string) -> (path: string, err: string) {
	step_begin(fmt.tprintf("Downloading %s", short_name(url_file_name(url))))
	if !load_wininet() do return "", "wininet.dll unavailable"
	hnet := InternetOpenW(win.L("SaberFlasher/1.0"), 0, nil, nil, 0)
	if hnet == nil do return "", "Could not start an internet session"
	defer InternetCloseHandle(hnet)
	h := InternetOpenUrlW(hnet, win.utf8_to_wstring(url), nil, 0, INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE | INTERNET_FLAG_NO_UI, 0)
	if h == nil do return "", fmt.tprintf("Could not connect to %s (error %d)", short_name(url), win.GetLastError())
	defer InternetCloseHandle(h)

	status: u32
	sz := u32(size_of(status))
	HttpQueryInfoW(h, HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER, &status, &sz, nil)
	if status >= 400 do return "", fmt.tprintf("Server returned HTTP %d", status)
	if strings.has_prefix(strings.to_lower(http_header(h, HTTP_QUERY_CONTENT_TYPE), context.temp_allocator), "text/html") {
		return "", "The link opened a web page, not a file — the script needs a direct download link"
	}

	total: u64
	sz = size_of(total)
	HttpQueryInfoW(h, HTTP_QUERY_CONTENT_LENGTH | HTTP_QUERY_FLAG_NUMBER64, &total, &sz, nil)

	// file name: Content-Disposition, else the final (post-redirect) URL
	name := ""
	if cd := http_header(h, HTTP_QUERY_CONTENT_DISPOSITION); cd != "" {
		if i := strings.index(cd, "filename="); i >= 0 {
			v := cd[i + 9:]
			if j := strings.index_byte(v, ';'); j >= 0 do v = v[:j]
			name = sanitize_name(strings.trim(v, "\" "))
		}
	}
	if name == "" {
		ubuf: [2048]u16
		ul := u32(size_of(ubuf))
		final := url
		if InternetQueryOptionW(h, INTERNET_OPTION_URL, &ubuf[0], &ul) do final = w2s(ubuf[:])
		name = url_file_name(final)
	}
	path = fmt.tprintf("%s\\%s", job.temp, name)
	make_dirs(job.temp)

	f := win.CreateFileW(win.utf8_to_wstring(path), win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if f == win.INVALID_HANDLE_VALUE do return "", fmt.tprintf("Could not create %s", path)
	buf := make([]u8, 256 * 1024)
	defer delete(buf)
	done: u64
	ok := true
	for {
		if cancelled() {
			ok = false
			err = CANCELLED_MSG
			break
		}
		got: u32
		if !InternetReadFile(h, raw_data(buf), u32(len(buf)), &got) {
			ok = false
			err = "Download interrupted"
			break
		}
		if got == 0 do break
		written: u32
		if !win.WriteFile(f, raw_data(buf), got, &written, nil) || written != got {
			ok = false
			err = "Disk write failed (drive full?)"
			break
		}
		done += u64(got)
		if total > 0 {
			step_progress(f32(f64(done) / f64(total)), fmt.tprintf("%s / %s", fmt_size(done), fmt_size(total)))
		} else {
			step_progress(-1, fmt_size(done))
		}
	}
	win.CloseHandle(f)
	if !ok {
		win.DeleteFileW(win.utf8_to_wstring(path))
		return "", err
	}
	return strings.clone(path, context.temp_allocator), ""
}

// ---------------------------------------------------------------- processes

Line_Proc :: #type proc(line: string, user: rawptr)

// Runs a command line, optionally hidden with stdout+stderr captured line by line.
// Cancel terminates the process.
run_process :: proc(cmdline, cwd: string, hidden: bool, on_line: Line_Proc = nil, user: rawptr = nil) -> (code: u32, err: string) {
	sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
	rd, wr: win.HANDLE
	capture := on_line != nil
	if capture {
		if !win.CreatePipe(&rd, &wr, &sa, 0) do return 0, "CreatePipe failed"
		win.SetHandleInformation(rd, win.HANDLE_FLAG_INHERIT, 0)
	}
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW)}
	if hidden {
		si.dwFlags |= win.STARTF_USESHOWWINDOW
		si.wShowWindow = u16(win.SW_HIDE)
	}
	if capture {
		si.dwFlags |= win.STARTF_USESTDHANDLES
		si.hStdOutput = wr
		si.hStdError = wr
	}
	pi: win.PROCESS_INFORMATION
	cmd_w := win.utf8_to_wstring(cmdline) // CreateProcessW may modify this buffer; it's a fresh temp copy
	flags: u32 = hidden ? win.CREATE_NO_WINDOW : 0
	cwd_w: win.LPCWSTR = cwd != "" ? win.utf8_to_wstring(cwd) : nil
	if !win.CreateProcessW(nil, cmd_w, nil, nil, win.BOOL(capture), flags, nil, cwd_w, &si, &pi) {
		if capture {
			win.CloseHandle(rd)
			win.CloseHandle(wr)
		}
		return 0, fmt.tprintf("Could not start: %s (error %d)", short_name(cmdline, 80), win.GetLastError())
	}
	if capture do win.CloseHandle(wr)
	defer {
		win.CloseHandle(pi.hProcess)
		win.CloseHandle(pi.hThread)
		if capture do win.CloseHandle(rd)
	}

	pending: [dynamic]u8
	defer delete(pending)
	buf: [4096]u8
	drain :: proc(rd: win.HANDLE, buf: []u8, pending: ^[dynamic]u8, on_line: Line_Proc, user: rawptr) {
		for {
			avail: u32
			if !win.PeekNamedPipe(rd, nil, 0, nil, &avail, nil) || avail == 0 do return
			got: u32
			if !win.ReadFile(rd, raw_data(buf), u32(min(len(buf), int(avail))), &got, nil) || got == 0 do return
			append(pending, ..buf[:got])
			for {
				i := -1
				for b, j in pending^ do if b == '\n' { i = j; break }
				if i < 0 do break
				line := strings.trim_right(string(pending[:i]), "\r")
				on_line(line, user)
				remove_range(pending, 0, i + 1)
			}
		}
	}
	for {
		if cancelled() {
			win.TerminateProcess(pi.hProcess, 1)
			return 1, CANCELLED_MSG
		}
		if capture do drain(rd, buf[:], &pending, on_line, user)
		if win.WaitForSingleObject(pi.hProcess, 30) == win.WAIT_OBJECT_0 do break
	}
	if capture {
		drain(rd, buf[:], &pending, on_line, user)
		if len(pending) > 0 do on_line(string(pending[:]), user)
	}
	win.GetExitCodeProcess(pi.hProcess, &code)
	return code, ""
}

// ---------------------------------------------------------------- extraction (Windows' bsdtar: zip, 7z, rar, tar.*)

Extract_Ctx :: struct {
	total, done: int,
	roots:       map[string]bool,
}

tar_exe :: proc() -> string {
	buf: [260]u16
	n := GetWindowsDirectoryW(win.LPWSTR(raw_data(buf[:])), len(buf))
	windir := n > 0 && n < len(buf) ? w2s(buf[:n]) : `C:\Windows`
	return fmt.tprintf(`%s\System32\tar.exe`, windir)
}

// Extracts into a fresh temp folder. If the archive has a single top-level folder, that
// folder is returned, so Dir_Copy(folder, install_path) lands the files directly in place.
extract :: proc(archive: string) -> (folder: string, root: string, err: string) {
	base := filepath.stem(archive)
	step_begin(fmt.tprintf("Extracting %s", short_name(filepath.base(archive))))
	if !os.exists(archive) do return "", "", fmt.tprintf("Archive not found: %s", archive)
	out := fmt.tprintf("%s\\%s_files", job.temp, base)
	for i := 2; os.exists(out); i += 1 do out = fmt.tprintf("%s\\%s_files%d", job.temp, base, i)
	make_dirs(out)
	tar := tar_exe()

	ctx: Extract_Ctx
	defer {
		for k in ctx.roots do delete(k)
		delete(ctx.roots)
	}
	_, lerr := run_process(fmt.tprintf(`"%s" -tf "%s"`, tar, archive), "", true, proc(line: string, user: rawptr) {
		x := (^Extract_Ctx)(user)
		l := strings.trim_space(line)
		if l == "" do return
		x.total += 1
		root := l
		if i := strings.index_any(l, "/\\"); i >= 0 do root = l[:i]
		if root != "" && root not_in x.roots do x.roots[strings.clone(root)] = true
	}, &ctx)
	if lerr != "" do return "", "", lerr
	if ctx.total == 0 do return "", "", fmt.tprintf("Could not read archive %s", filepath.base(archive))

	code, xerr := run_process(fmt.tprintf(`"%s" -xvf "%s" -C "%s"`, tar, archive, out), "", true, proc(line: string, user: rawptr) {
		x := (^Extract_Ctx)(user)
		if strings.trim_space(line) == "" do return
		x.done += 1
		step_progress(f32(x.done) / f32(max(x.total, 1)), fmt.tprintf("%d / %d files", min(x.done, x.total), x.total))
	}, &ctx)
	if xerr != "" do return "", "", xerr
	if code != 0 do return "", "", fmt.tprintf("Extraction failed (tar exit code %d)", code)

	folder = out
	if len(ctx.roots) == 1 {
		for k in ctx.roots {
			if inner := fmt.tprintf("%s\\%s", out, k); os.is_dir(inner) do folder = inner
		}
	}
	return folder, out, ""
}

// ---------------------------------------------------------------- Lua API

script_context: runtime.Context

raise :: proc(L: ^lua_State, msg: string) -> c.int {
	lua_pushstring(L, cs(msg))
	lua_error(L) // longjmps out; nothing with pending defers may sit between here and the C boundary
	return 0
}

arg_str :: proc(L: ^lua_State, i: c.int) -> string {
	return string(luaL_checklstring(L, i, nil))
}

opt_str :: proc(L: ^lua_State, i: c.int) -> string {
	if lua_type(L, i) == LUA_TSTRING || lua_type(L, i) == LUA_TNUMBER do return lua_string(L, i)
	return ""
}

// Pushes `value` as the return, then calls the callback at stack index `cb` (if a function) with it.
finish_str :: proc(L: ^lua_State, cb: c.int, value: string) -> c.int {
	lua_pushstring(L, cs(value))
	if lua_type(L, cb) == LUA_TFUNCTION {
		lua_pushvalue(L, cb)
		lua_pushstring(L, cs(value))
		lua_call(L, 1, 0)
	}
	return 1
}

check_cancel :: proc(L: ^lua_State) {
	if cancelled() do raise(L, CANCELLED_MSG)
}

// File_Download(url, [cb(file)]) -> file
lua_File_Download :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	check_cancel(L)
	path, err := download(arg_str(L, 1))
	if err != "" do return raise(L, err)
	step_end(.Done, fmt.tprintf("%s · %s", filepath.base(path), fmt_size(u64(file_size(path)))))
	return finish_str(L, 2, path)
}

// File_Unzip(archive, [cb(folder, root)]) -> folder, root   (zip, 7z, rar, tar.gz…)
//   folder: the archive's single top folder if it has exactly one, else same as root
//   root:   the extraction folder exactly as the archive laid it out
lua_File_Unzip :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	check_cancel(L)
	folder, root, err := extract(resolve(arg_str(L, 1)))
	if err != "" do return raise(L, err)
	step_end()
	lua_pushstring(L, cs(folder))
	lua_pushstring(L, cs(root))
	if lua_type(L, 2) == LUA_TFUNCTION {
		lua_pushvalue(L, 2)
		lua_pushstring(L, cs(folder))
		lua_pushstring(L, cs(root))
		lua_call(L, 2, 0)
	}
	return 2
}

// Dir_Copy(src, dst, [cb(dst)]) -> dst   copies the contents of src into dst
lua_Dir_Copy :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	check_cancel(L)
	src, dst := resolve(arg_str(L, 1)), resolve(arg_str(L, 2))
	if !writable(dst) do return raise(L, fmt.tprintf("Dir_Copy: not allowed to write to %s", dst))
	step_begin(fmt.tprintf("Copying %s", short_name(filepath.base(src))))
	if err := copy_tree(src, dst); err != "" do return raise(L, err)
	step_end()
	return finish_str(L, 3, dst)
}

// File_Copy(src, dst) -> dst
lua_File_Copy :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	src, dst := resolve(arg_str(L, 1)), resolve(arg_str(L, 2))
	if !writable(dst) do return raise(L, fmt.tprintf("File_Copy: not allowed to write to %s", dst))
	if os.is_dir(dst) do dst = fmt.tprintf("%s\\%s", dst, filepath.base(src))
	make_dirs(filepath.dir(dst))
	if !win.CopyFileW(win.utf8_to_wstring(src), win.utf8_to_wstring(dst), false) {
		return raise(L, fmt.tprintf("File_Copy failed: %s", src))
	}
	return finish_str(L, 3, dst)
}

// File_Move(src, dst) -> dst   (src must also be inside the install/temp folder)
lua_File_Move :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	src, dst := resolve(arg_str(L, 1)), resolve(arg_str(L, 2))
	if !writable(src) || !writable(dst) do return raise(L, "File_Move: both paths must be inside the install or temp folder")
	make_dirs(filepath.dir(dst))
	if !win.MoveFileExW(win.utf8_to_wstring(src), win.utf8_to_wstring(dst), win.MOVEFILE_REPLACE_EXISTING | win.MOVEFILE_COPY_ALLOWED) {
		return raise(L, fmt.tprintf("File_Move failed: %s", src))
	}
	return finish_str(L, 3, dst)
}

// File_Delete(path) / Dir_Delete(path)  — only inside the install or temp folder
lua_Delete :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	p := resolve(arg_str(L, 1))
	if !writable(p) || path_inside(job.dest, p) do return raise(L, fmt.tprintf("Delete: not allowed for %s", p))
	lua_pushboolean(L, c.int(delete_tree(p)))
	return 1
}

// Dir_Create(path) -> path
lua_Dir_Create :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	p := resolve(arg_str(L, 1))
	if !writable(p) do return raise(L, fmt.tprintf("Dir_Create: not allowed for %s", p))
	make_dirs(p)
	lua_pushstring(L, cs(p))
	return 1
}

// File_Exists(path) -> bool, Dir_Exists(path) -> bool
lua_File_Exists :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	p := resolve(arg_str(L, 1))
	lua_pushboolean(L, c.int(os.exists(p) && !os.is_dir(p)))
	return 1
}

lua_Dir_Exists :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	lua_pushboolean(L, c.int(os.is_dir(resolve(arg_str(L, 1)))))
	return 1
}

// File_Read(path) -> string|nil
lua_File_Read :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	data, err := os.read_entire_file(resolve(arg_str(L, 1)), context.temp_allocator)
	if err != nil {
		lua_pushnil(L)
	} else {
		lua_pushstring(L, cs(string(data)))
	}
	return 1
}

// File_Write(path, text)
lua_File_Write :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	p := resolve(arg_str(L, 1))
	text := arg_str(L, 2)
	if !writable(p) do return raise(L, fmt.tprintf("File_Write: not allowed for %s", p))
	make_dirs(filepath.dir(p))
	if os.write_entire_file(p, transmute([]u8)text) != nil do return raise(L, fmt.tprintf("File_Write failed: %s", p))
	return 0
}

// Run(exe, [args], [cb(exit_code)], [hidden]) -> exit_code   waits for the program to exit
lua_Run :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	check_cancel(L)
	exe := resolve(arg_str(L, 1))
	args := opt_str(L, 2)
	hidden := lua_toboolean(L, 4) != 0
	step_begin(fmt.tprintf("Running %s", filepath.base(exe)))
	step_progress(-1, "Waiting for it to finish…")
	cmd := args != "" ? fmt.tprintf(`"%s" %s`, exe, args) : fmt.tprintf(`"%s"`, exe)
	code, err := run_process(cmd, filepath.dir(exe), hidden)
	if err != "" do return raise(L, err)
	step_end(.Done, fmt.tprintf("Exit code %d", code))
	lua_pushinteger(L, i64(code))
	if lua_type(L, 3) == LUA_TFUNCTION {
		lua_pushvalue(L, 3)
		lua_pushinteger(L, i64(code))
		lua_call(L, 1, 0)
	}
	return 1
}

// Step(name) starts a custom step; Progress(0..1, [detail]); Log(msg)
lua_Step :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	check_cancel(L)
	step_begin(arg_str(L, 1))
	return 0
}

lua_Progress :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	check_cancel(L)
	step_progress(f32(lua_tonumberx(L, 1, nil)), opt_str(L, 2))
	return 0
}

lua_Log :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	msg := lua_string(L, 1)
	job_log(msg)
	return 0
}

// Path_Join(a, b, ...) -> string
lua_Path_Join :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	n := lua_gettop(L)
	parts := make([dynamic]string, context.temp_allocator)
	for i in 1 ..= n do append(&parts, strings.trim(lua_string(L, i), "\\/"))
	joined := strings.join(parts[:], "\\", context.temp_allocator)
	if n > 0 && strings.has_prefix(lua_string(L, 1), "\\\\") do joined = fmt.tprintf("\\\\%s", joined)
	lua_pushstring(L, cs(joined))
	return 1
}

// Shared(name) -> <source>\shared\<name>   files shared between preconfigs (emulators etc.)
lua_Shared :: proc "c" (L: ^lua_State) -> c.int {
	context = script_context
	lua_pushstring(L, cs(fmt.tprintf("%s\\%s", job.shared, arg_str(L, 1))))
	return 1
}

file_size :: proc(p: string) -> i64 {
	fd: win.WIN32_FILE_ATTRIBUTE_DATA
	if !win.GetFileAttributesExW(win.utf8_to_wstring(p), win.GetFileExInfoStandard, &fd) do return 0
	return i64(fd.nFileSizeHigh) << 32 | i64(fd.nFileSizeLow)
}

set_global_str :: proc(L: ^lua_State, name: cstring, v: string) {
	lua_pushstring(L, cs(v))
	lua_setglobal(L, name)
}

// Runs config.lua's OnInstall(self, install_path). Returns "" on success.
run_install_script :: proc(script: string) -> string {
	script_context = context
	L := luaL_newstate()
	if L == nil do return "Could not start Lua"
	defer lua_close(L)
	luaL_openlibs(L)

	lua_register(L, "File_Download", lua_File_Download)
	lua_register(L, "File_Unzip", lua_File_Unzip)
	lua_register(L, "File_Extract", lua_File_Unzip)
	lua_register(L, "Dir_Copy", lua_Dir_Copy)
	lua_register(L, "File_Copy", lua_File_Copy)
	lua_register(L, "File_Move", lua_File_Move)
	lua_register(L, "File_Delete", lua_Delete)
	lua_register(L, "Dir_Delete", lua_Delete)
	lua_register(L, "Dir_Create", lua_Dir_Create)
	lua_register(L, "File_Exists", lua_File_Exists)
	lua_register(L, "Dir_Exists", lua_Dir_Exists)
	lua_register(L, "File_Read", lua_File_Read)
	lua_register(L, "File_Write", lua_File_Write)
	lua_register(L, "Run", lua_Run)
	lua_register(L, "Step", lua_Step)
	lua_register(L, "Progress", lua_Progress)
	lua_register(L, "Log", lua_Log)
	lua_register(L, "Path_Join", lua_Path_Join)
	lua_register(L, "Shared", lua_Shared)
	lua_register(L, "GetDir_GogGames", lua_GetDir_GogGames)
	lua_register(L, "print", lua_Log)
	set_global_str(L, "INSTALL_PATH", job.dest)
	set_global_str(L, "TEMP_PATH", job.temp)
	set_global_str(L, "CONFIG_PATH", filepath.dir(script))
	set_global_str(L, "SHARED_PATH", job.shared)
	set_global_str(L, "GOG_PATH", job.gog)

	err_of :: proc(L: ^lua_State) -> string {
		if cancelled() do return CANCELLED_MSG
		msg := lua_string(L, -1)
		if strings.contains(msg, CANCELLED_MSG) do return CANCELLED_MSG
		return strings.clone(msg == "" ? "Script error" : msg, context.temp_allocator)
	}

	if luaL_loadfilex(L, cs(script), nil) != LUA_OK || lua_pcall(L, 0, 1, 0) != LUA_OK {
		return err_of(L)
	}
	if lua_type(L, -1) != LUA_TTABLE do return "" // plain script: top-level code already ran

	// gog_name = "<GOG game>": the install starts as a copy of that GOG game (mods build on top of it)
	lua_getfield(L, -1, "gog_name")
	if lua_type(L, -1) == LUA_TSTRING {
		name := strings.clone(lua_string(L, -1), context.temp_allocator)
		step_begin(fmt.tprintf("Copying %s from GOG", name))
		src, ok := find_gog_game(job.gog, name)
		if !ok do return fmt.tprintf("GOG game \"%s\" isn't installed (or set the GOG folder in Settings)", name)
		if err := copy_tree(src, job.dest); err != "" do return err
		step_end()
	}
	lua_pop(L, 1)

	lua_getfield(L, -1, "OnInstall")
	if lua_type(L, -1) != LUA_TFUNCTION do return ""
	lua_pushvalue(L, -2) // self
	lua_pushstring(L, cs(job.dest))
	if lua_pcall(L, 2, 0, 0) != LUA_OK do return err_of(L)
	return ""
}
