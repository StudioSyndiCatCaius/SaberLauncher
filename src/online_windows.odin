package saber

import "core:fmt"
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
	h := InternetOpenUrlW(hnet, win.utf8_to_wstring(r.url), nil, 0, INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_UI, 0)
	if h == nil {
		r.err = fmt.aprintf("Couldn't connect (error %d)", win.GetLastError())
		return false
	}
	defer InternetCloseHandle(h)
	status: u32
	sz := u32(size_of(status))
	HttpQueryInfoW(h, HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER, &status, &sz, nil)
	r.status = int(status)

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
		if len(body) > HTTP_MAX_BYTES {
			r.err = strings.clone("Response too large")
			return false
		}
	}
	return true
}
