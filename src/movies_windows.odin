package saber

import "core:c"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"
import win "core:sys/windows"

// Windows side of movies.odin: Explorer thumbnails, hidden helper processes, players.

MOVIE_PLAYER_HINT :: "Install VLC (preferred) or Windows Media Player"

movie_com_ready: bool

// {bcc18b79-ba16-442f-80c4-8a59c30c463b}
IID_IShellItemImageFactory := &win.GUID{0xbcc18b79, 0xba16, 0x442f, {0x80, 0xc4, 0x8a, 0x59, 0xc3, 0x0c, 0x46, 0x3b}}

SIIGBF_RESIZETOFIT    :: 0x00
SIIGBF_BIGGERSIZEOK   :: 0x01
SIIGBF_THUMBNAILONLY  :: 0x08
SIIGBF_WIDETHUMBNAILS :: 0x40
SIIGBF_SCALEUP        :: 0x100

IShellItemImageFactory :: struct #raw_union {
	#subtype IUnknown: win.IUnknown,
	using Vtbl:        ^IShellItemImageFactoryVtbl,
}
IShellItemImageFactoryVtbl :: struct {
	using IUnknownVtbl: win.IUnknownVtbl,
	GetImage: proc "system" (this: ^IShellItemImageFactory, size: win.SIZE, flags: win.DWORD, phbm: ^win.HBITMAP) -> win.HRESULT,
}

ensure_movie_com :: proc() {
	if movie_com_ready {
		return
	}
	hr := win.CoInitializeEx(nil, .APARTMENTTHREADED)
	movie_com_ready = win.SUCCEEDED(int(hr)) || i32(hr) == -2147417850 // already inited / RPC_E_CHANGED_MODE
}

extract_thumb_shell :: proc(video_path, dest_png: string) -> bool {
	img, ok := shell_image(video_path, 640, 360)
	if !ok {
		return false
	}
	defer rl.UnloadImage(img)
	if img.width < 64 || img.height < 64 {
		return false
	}
	return rl.ExportImage(img, strings.clone_to_cstring(dest_png, context.temp_allocator))
}

// Decodes anything Explorer can thumbnail (video frames, and JPG/WebP images that
// this raylib build can't load) into an RGBA image no larger than ~w x h.
// still = a picture file: keep its exact aspect (no wide thumbnail frame).
shell_image :: proc(path: string, w, h: i32, still := false) -> (rl.Image, bool) {
	ensure_movie_com()
	win_path, _ := strings.replace_all(path, "/", "\\", context.temp_allocator) // the shell needs backslashes
	item_ptr: rawptr
	hr := win.SHCreateItemFromParsingName(win.utf8_to_wstring(win_path), nil, win.IID_IShellItem, &item_ptr)
	if !win.SUCCEEDED(int(hr)) || item_ptr == nil {
		return {}, false
	}
	item := (^win.IShellItem)(item_ptr)
	defer item.Release((^win.IUnknown)(item))

	fac_ptr: rawptr
	hr = item.QueryInterface((^win.IUnknown)(item), IID_IShellItemImageFactory, &fac_ptr)
	if !win.SUCCEEDED(int(hr)) || fac_ptr == nil {
		return {}, false
	}
	fac := (^IShellItemImageFactory)(fac_ptr)
	defer fac.Release((^win.IUnknown)(fac))

	hbm: win.HBITMAP
	sz := win.SIZE{cx = w, cy = h}
	flags := still ? win.DWORD(SIIGBF_RESIZETOFIT) : win.DWORD(SIIGBF_BIGGERSIZEOK | SIIGBF_WIDETHUMBNAILS | SIIGBF_SCALEUP)
	hr = fac.GetImage(fac, sz, flags, &hbm)
	if !win.SUCCEEDED(int(hr)) || hbm == nil {
		hr = fac.GetImage(fac, sz, win.DWORD(SIIGBF_THUMBNAILONLY | SIIGBF_BIGGERSIZEOK), &hbm)
	}
	if !win.SUCCEEDED(int(hr)) || hbm == nil {
		return {}, false
	}
	defer win.DeleteObject(win.HGDIOBJ(hbm))
	return hbitmap_to_image(hbm)
}

hbitmap_to_image :: proc(hbm: win.HBITMAP) -> (rl.Image, bool) {
	bm: win.BITMAP
	if win.GetObjectW(win.HANDLE(hbm), i32(size_of(bm)), &bm) == 0 || bm.bmWidth <= 0 || bm.bmHeight <= 0 {
		return {}, false
	}
	w := int(bm.bmWidth)
	h := int(bm.bmHeight)
	hdc := win.CreateCompatibleDC(nil)
	if hdc == nil {
		return {}, false
	}
	defer win.DeleteDC(hdc)
	old := win.SelectObject(hdc, win.HGDIOBJ(hbm))
	defer win.SelectObject(hdc, old)

	info: win.BITMAPINFO
	info.bmiHeader.biSize = size_of(win.BITMAPINFOHEADER)
	info.bmiHeader.biWidth = win.LONG(w)
	info.bmiHeader.biHeight = -win.LONG(h)
	info.bmiHeader.biPlanes = 1
	info.bmiHeader.biBitCount = 32
	info.bmiHeader.biCompression = 0

	pixels := rl.MemAlloc(c.uint(w * h * 4))
	if pixels == nil {
		return {}, false
	}
	got := win.GetDIBits(hdc, hbm, 0, u32(h), pixels, &info, 0)
	if got == 0 {
		rl.MemFree(pixels)
		return {}, false
	}
	bytes := ([^]u8)(pixels)
	n := w * h
	for i in 0 ..< n {
		o := i * 4
		b := bytes[o]
		bytes[o] = bytes[o + 2]
		bytes[o + 2] = b
		bytes[o + 3] = 255
	}
	img: rl.Image
	img.data = pixels
	img.width = i32(w)
	img.height = i32(h)
	img.mipmaps = 1
	img.format = .UNCOMPRESSED_R8G8B8A8
	return img, true
}

find_ffmpeg_exe :: proc() -> (string, bool) {
	cands := []string{
		`C:\ffmpeg\bin\ffmpeg.exe`,
		`C:\Program Files\ffmpeg\bin\ffmpeg.exe`,
		`C:\Program Files (x86)\ffmpeg\bin\ffmpeg.exe`,
	}
	for c in cands {
		if os.exists(c) {
			return c, true
		}
	}
	return "ffmpeg.exe", true
}

run_hidden_process :: proc(exe, cmd: string, timeout_ms: u32) -> bool {
	cmd_w: [4096]u16
	_ = win.utf8_to_wstring(cmd_w[:], cmd)
	si: win.STARTUPINFOW
	si.cb = size_of(si)
	si.dwFlags = win.STARTF_USESHOWWINDOW
	si.wShowWindow = u16(win.SW_HIDE)
	pi: win.PROCESS_INFORMATION
	app_name: win.wstring
	if exe != "" && filepath.is_abs(exe) {
		app_name = win.utf8_to_wstring(exe)
	}
	created := win.CreateProcessW(
		app_name,
		win.wstring(raw_data(cmd_w[:])),
		nil,
		nil,
		false,
		win.CREATE_UNICODE_ENVIRONMENT | win.CREATE_NO_WINDOW,
		nil,
		nil,
		&si,
		&pi,
	)
	if !created {
		return false
	}
	wait := win.WaitForSingleObject(pi.hProcess, timeout_ms)
	if wait != win.WAIT_OBJECT_0 {
		win.TerminateProcess(pi.hProcess, 1)
	}
	code: win.DWORD
	win.GetExitCodeProcess(pi.hProcess, &code)
	win.CloseHandle(pi.hProcess)
	win.CloseHandle(pi.hThread)
	return wait == win.WAIT_OBJECT_0 && code == 0
}

find_vlc_exe :: proc() -> (string, bool) {
	cands := []string{
		`C:\Program Files\VideoLAN\VLC\vlc.exe`,
		`C:\Program Files (x86)\VideoLAN\VLC\vlc.exe`,
	}
	for c in cands {
		if os.exists(c) {
			return c, true
		}
	}
	return "", false
}

find_wmp_exe :: proc() -> (string, bool) {
	cands := []string{
		`C:\Program Files\Windows Media Player\wmplayer.exe`,
		`C:\Program Files (x86)\Windows Media Player\wmplayer.exe`,
	}
	for c in cands {
		if os.exists(c) {
			return c, true
		}
	}
	return "", false
}

movie_player :: proc() -> (exe, args_prefix, name: string, ok: bool) {
	if v, found := find_vlc_exe(); found {
		return v, "--fullscreen --play-and-exit --no-video-title-show", "VLC", true
	}
	if w, found := find_wmp_exe(); found {
		return w, "/fullscreen", "Windows Media Player", true
	}
	return "", "", "", false
}
