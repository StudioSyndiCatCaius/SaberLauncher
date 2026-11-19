package saber

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import win "core:sys/windows"

// wininet transport for online.odin.

HINTERNET :: distinct rawptr

InternetOpenW: proc "system" (agent: win.LPCWSTR, access: u32, proxy, bypass: win.LPCWSTR, flags: u32) -> HINTERNET
InternetOpenUrlW: proc "system" (h: HINTERNET, url, headers: win.LPCWSTR, headers_len: u32, flags: u32, ctx: uintptr) -> HINTERNET
InternetReadFile: proc "system" (h: HINTERNET, buf: rawptr, to_read: u32, read: ^u32) -> win.BOOL
InternetCloseHandle: proc "system" (h: HINTERNET) -> win.BOOL
HttpQueryInfoW: proc "system" (h: HINTERNET, level: u32, buf: rawptr, len: ^u32, index: ^u32) -> win.BOOL

HTTP_QUERY_STATUS_CODE :: 19
HTTP_QUERY_CONTENT_LENGTH :: 5
HTTP_QUERY_FLAG_NUMBER :: 0x20000000
INTERNET_FLAG_RELOAD :: 0x80000000
INTERNET_FLAG_NO_UI :: 0x00000200

wininet_lock: sync.Mutex

load_wininet :: proc() -> bool {
	sync.mutex_lock(&wininet_lock)
	defer sync.mutex_unlock(&wininet_lock)
	if InternetOpenW != nil do return true
	m := win.LoadLibraryW(win.L("wininet.dll"))
	if m == nil do return false
	InternetOpenW = auto_cast win.GetProcAddress(m, "InternetOpenW")
	InternetOpenUrlW = auto_cast win.GetProcAddress(m, "InternetOpenUrlW")
	InternetReadFile = auto_cast win.GetProcAddress(m, "InternetReadFile")
	InternetCloseHandle = auto_cast win.GetProcAddress(m, "InternetCloseHandle")
	HttpQueryInfoW = auto_cast win.GetProcAddress(m, "HttpQueryInfoW")
	return InternetOpenW != nil && InternetOpenUrlW != nil && InternetReadFile != nil && InternetCloseHandle != nil && HttpQueryInfoW != nil
}

// Downloads r.url into body and sets r.status. On failure sets r.err and returns false.
http_fetch :: proc(r: ^Http_Request, body: ^[dynamic]u8) -> bool {
	if !load_wininet() {
		r.err = strings.clone("wininet.dll unavailable")
		return false
	}
	hnet := InternetOpenW(win.L("Saber/1.0"), 0, nil, nil, 0)
	if hnet == nil {
		r.err = strings.clone("Couldn't start an internet session")
		return false
	}
	defer InternetCloseHandle(hnet)
	headers: win.LPCWSTR = r.headers != "" ? win.utf8_to_wstring(r.headers) : nil
	h := InternetOpenUrlW(hnet, win.utf8_to_wstring(r.url), headers, headers != nil ? 0xFFFFFFFF : 0, INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_UI, 0)
	if h == nil {
		r.err = fmt.aprintf("Couldn't connect (error %d)", win.GetLastError())
		return false
	}
	defer InternetCloseHandle(h)
	status: u32
	sz := u32(size_of(status))
	HttpQueryInfoW(h, HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER, &status, &sz, nil)
	r.status = int(status)
	length: u32
	sz = u32(size_of(length))
	if HttpQueryInfoW(h, HTTP_QUERY_CONTENT_LENGTH | HTTP_QUERY_FLAG_NUMBER, &length, &sz, nil) do sync.atomic_store(&r.total, i64(length))

	buf: [16 * 1024]u8
	for {
		if http_killed(r) {
			r.err = strings.clone("Online Mode was turned off")
			return false
		}
		got: u32
		if !InternetReadFile(h, &buf[0], len(buf), &got) {
			r.err = strings.clone("Connection dropped")
			return false
		}
		if got == 0 do break
		append(body, ..buf[:got])
		sync.atomic_store(&r.got, i64(len(body)))
		if len(body) > HTTP_MAX_BYTES {
			r.err = strings.clone("Response too large")
			return false
		}
	}
	return true
}

// Streams d.url into `part` for downloads.odin, resuming at `offset` (a Range request; a server
// that answers 200 instead restarts the file). Returns "" on success, else the error.
download_fetch :: proc(d: ^Download_Job, part: string, offset: i64) -> string {
	if !load_wininet() do return "wininet.dll unavailable"
	hnet := InternetOpenW(win.L("Saber/1.0"), 0, nil, nil, 0)
	if hnet == nil do return "Couldn't start an internet session"
	defer InternetCloseHandle(hnet)
	headers := d.headers
	if offset > 0 do headers = fmt.tprintf("%sRange: bytes=%d-\r\n", headers, offset)
	wh: win.LPCWSTR = headers != "" ? win.utf8_to_wstring(headers) : nil
	h := InternetOpenUrlW(hnet, win.utf8_to_wstring(d.url), wh, wh != nil ? 0xFFFFFFFF : 0, INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_UI, 0)
	if h == nil do return fmt.tprintf("Couldn't connect (error %d)", win.GetLastError())
	defer InternetCloseHandle(h)
	status: u32
	sz := u32(size_of(status))
	HttpQueryInfoW(h, HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER, &status, &sz, nil)
	offset := offset
	switch status {
	case 206:
	case 200: offset = 0 // no resume: start over
	case 416:
		if offset > 0 { // the .part is already whole
			sync.atomic_store(&d.got, offset)
			sync.atomic_store(&d.total, offset)
			return ""
		}
		return "HTTP 416"
	case: return fmt.tprintf("HTTP %d", status)
	}
	length: u64
	lbuf: [32]u16
	lsz := u32(size_of(lbuf))
	// Content-Length as text: files can be over 4 GB
	if HttpQueryInfoW(h, HTTP_QUERY_CONTENT_LENGTH, &lbuf[0], &lsz, nil) {
		for ch in lbuf[:lsz / 2] {
			if ch < '0' || ch > '9' do break
			length = length * 10 + u64(ch - '0')
		}
	}
	if length > 0 do sync.atomic_store(&d.total, offset + i64(length))
	sync.atomic_store(&d.got, offset)

	flags: os.File_Flags = {.Write, .Create}
	flags += offset > 0 ? {.Append} : {.Trunc}
	f, ferr := os.open(part, flags)
	if ferr != nil do return fmt.tprintf("Couldn't write %s", part)
	defer os.close(f)
	buf := make([]u8, 256 * 1024, context.temp_allocator)
	got := offset
	for {
		if download_killed(d) do return sync.atomic_load(&d.cancel) ? "Cancelled" : "Online Mode was turned off"
		n: u32
		if !InternetReadFile(h, raw_data(buf), u32(len(buf)), &n) do return "Connection dropped (it resumes next time)"
		if n == 0 do break
		if _, werr := os.write(f, buf[:n]); werr != nil do return "Couldn't write to disk (full?)"
		got += i64(n)
		sync.atomic_store(&d.got, got)
	}
	if t := sync.atomic_load(&d.total); t > 0 && got < t do return "Connection dropped (it resumes next time)"
	return ""
}
