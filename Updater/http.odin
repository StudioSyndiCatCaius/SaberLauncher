package updater

import win "core:sys/windows"

// Minimal WinHTTP binding: HTTPS GET with redirects (GitHub's /releases/latest/download/
// redirects to its asset CDN). Fine to link here; the updater doesn't use raylib.
foreign import winhttp "system:winhttp.lib"

HINTERNET :: rawptr

WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY :: 4
WINHTTP_FLAG_SECURE :: 0x00800000
WINHTTP_QUERY_STATUS_CODE :: 19
WINHTTP_QUERY_FLAG_NUMBER :: 0x20000000

@(default_calling_convention = "system")
foreign winhttp {
	WinHttpOpen :: proc(agent: win.LPCWSTR, access: win.DWORD, proxy, bypass: win.LPCWSTR, flags: win.DWORD) -> HINTERNET ---
	WinHttpConnect :: proc(session: HINTERNET, server: win.LPCWSTR, port: u16, reserved: win.DWORD) -> HINTERNET ---
	WinHttpOpenRequest :: proc(connect: HINTERNET, verb, object, version, referrer: win.LPCWSTR, accept: ^win.LPCWSTR, flags: win.DWORD) -> HINTERNET ---
	WinHttpSendRequest :: proc(request: HINTERNET, headers: win.LPCWSTR, headers_len: win.DWORD, optional: rawptr, optional_len, total_len: win.DWORD, ctx: uintptr) -> win.BOOL ---
	WinHttpReceiveResponse :: proc(request: HINTERNET, reserved: rawptr) -> win.BOOL ---
	WinHttpQueryHeaders :: proc(request: HINTERNET, info: win.DWORD, name: win.LPCWSTR, buffer: rawptr, buffer_len: ^win.DWORD, index: ^win.DWORD) -> win.BOOL ---
	WinHttpReadData :: proc(request: HINTERNET, buffer: rawptr, to_read: win.DWORD, read: ^win.DWORD) -> win.BOOL ---
	WinHttpCloseHandle :: proc(h: HINTERNET) -> win.BOOL ---
}

http_get :: proc(host, path: string) -> (data: []byte, ok: bool) {
	session := WinHttpOpen(win.L("SaberUpdater"), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, 0)
	if session == nil do return
	defer WinHttpCloseHandle(session)
	connect := WinHttpConnect(session, win.utf8_to_wstring(host), 443, 0)
	if connect == nil do return
	defer WinHttpCloseHandle(connect)
	request := WinHttpOpenRequest(connect, win.L("GET"), win.utf8_to_wstring(path), nil, nil, nil, WINHTTP_FLAG_SECURE)
	if request == nil do return
	defer WinHttpCloseHandle(request)

	if !WinHttpSendRequest(request, nil, 0, nil, 0, 0, 0) do return
	if !WinHttpReceiveResponse(request, nil) do return
	status: win.DWORD
	size := win.DWORD(size_of(status))
	if !WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nil, &status, &size, nil) || status != 200 {
		return
	}

	buf := make([dynamic]byte)
	chunk: [64 * 1024]byte
	for {
		n: win.DWORD
		if !WinHttpReadData(request, &chunk[0], len(chunk), &n) {
			delete(buf)
			return
		}
		if n == 0 do break
		append(&buf, ..chunk[:n])
	}
	return buf[:], true
}
