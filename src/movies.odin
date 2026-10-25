package saber

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import rl "vendor:raylib"
import win "core:sys/windows"

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

Movie :: struct {
	title:     string,
	path:      string,
	thumb:     rl.Texture2D,
	has_thumb: bool,
	thumb_file: string,
}

VIDEO_EXTS :: []string{".mp4", ".mkv", ".avi", ".mov", ".wmv", ".webm", ".m4v", ".mpg", ".mpeg", ".flv", ".ts", ".m2ts"}

// Cached on scan; the Movies page shows it every frame.
movie_player_label: string

scan_movies :: proc(out: ^[dynamic]Movie, movies_dir: string) {
	_, _, movie_player_label, _ = movie_player()
	if !os.exists(movies_dir) {
		return
	}
	fis, err := os.read_all_directory_by_path(movies_dir, context.allocator)
	if err != nil {
		return
	}
	defer os.file_info_slice_delete(fis, context.allocator)

	for fi in fis {
		if fi.type == .Directory {
			continue
		}
		base := fi.name if fi.name != "" else filepath.base(fi.fullpath)
		ext := strings.to_lower(filepath.ext(base), context.temp_allocator)
		if !is_video_ext(ext) {
			continue
		}
		m: Movie
		m.path = strings.clone(fi.fullpath)
		m.title = strings.clone(filepath.stem(base))
		m.thumb_file = resolve_movie_thumb(movies_dir, filepath.stem(base), m.path)
		movie_load_thumb(&m)
		append(out, m)
	}
}

is_video_ext :: proc(ext: string) -> bool {
	for e in VIDEO_EXTS {
		if ext == e {
			return true
		}
	}
	return false
}

thumbs_dir :: proc(movies_dir: string) -> string {
	dir := path_join({movies_dir, "_thumbs"})
	_ = os.make_directory(dir)
	return dir
}

file_mtime :: proc(path: string) -> (time.Time, bool) {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	return fi.modification_time, true
}

cache_is_fresh :: proc(cache_path, video_path: string) -> bool {
	if !os.exists(cache_path) {
		return false
	}
	ct, cok := file_mtime(cache_path)
	vt, vok := file_mtime(video_path)
	if !cok || !vok {
		return os.exists(cache_path)
	}
	return time.time_to_unix_nano(ct) >= time.time_to_unix_nano(vt)
}

resolve_movie_thumb :: proc(movies_dir, stem, video_path: string) -> string {
	for ext in ([]string{".png", ".jpg", ".jpeg", ".webp"}) {
		cand := path_join({movies_dir, fmt.tprintf("%s%s", stem, ext)})
		if os.exists(cand) {
			return cand
		}
	}
	cache := path_join({thumbs_dir(movies_dir), fmt.tprintf("%s.png", stem)})
	if cache_is_fresh(cache, video_path) {
		return cache
	}
	if extract_movie_thumb(video_path, cache) || os.exists(cache) {
		return cache
	}
	// Empty marker: rescans skip the slow extractors (delete _thumbs to retry).
	_ = os.write_entire_file(cache, []u8{})
	return ""
}

movie_load_thumb :: proc(m: ^Movie) {
	if m.thumb_file == "" {
		return
	}
	if fi, err := os.stat(m.thumb_file, context.temp_allocator); err != nil || fi.size == 0 {
		return
	}
	m.thumb, m.has_thumb = load_texture_smooth(m.thumb_file)
}

ensure_movie_com :: proc() {
	if movie_com_ready {
		return
	}
	hr := win.CoInitializeEx(nil, .APARTMENTTHREADED)
	movie_com_ready = win.SUCCEEDED(int(hr)) || i32(hr) == -2147417850 // already inited / RPC_E_CHANGED_MODE
}

extract_movie_thumb :: proc(video_path, dest_png: string) -> bool {
	if extract_thumb_shell(video_path, dest_png) {
		return true
	}
	if extract_thumb_ffmpeg(video_path, dest_png) {
		return true
	}
	if extract_thumb_vlc(video_path, dest_png) {
		return true
	}
	return false
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
	item_ptr: rawptr
	hr := win.SHCreateItemFromParsingName(win.utf8_to_wstring(path), nil, win.IID_IShellItem, &item_ptr)
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

extract_thumb_ffmpeg :: proc(video_path, dest_png: string) -> bool {
	exe, found := find_ffmpeg_exe()
	if !found {
		return false
	}
	cmd := fmt.tprintf(
		"\"%s\" -y -ss 8 -i \"%s\" -frames:v 1 -vf scale=640:-2 -q:v 4 \"%s\"",
		exe,
		video_path,
		dest_png,
	)
	if !run_hidden_process(exe, cmd, 20000) {
		cmd = fmt.tprintf(
			"\"%s\" -y -ss 1 -i \"%s\" -frames:v 1 -vf scale=640:-2 \"%s\"",
			exe,
			video_path,
			dest_png,
		)
		if !run_hidden_process(exe, cmd, 20000) {
			return false
		}
	}
	return os.exists(dest_png)
}

extract_thumb_vlc :: proc(video_path, dest_png: string) -> bool {
	exe, found := find_vlc_exe()
	if !found {
		return false
	}
	out_dir := filepath.dir(dest_png)
	cmd := fmt.tprintf(
		"\"%s\" -I dummy --dummy-quiet --no-audio --no-video-title-show --video-filter=scene --scene-format=png --scene-ratio=100000 --scene-prefix=thumb --scene-replace --scene-path=\"%s\" --start-time=8 --stop-time=9 --run-time=1 --play-and-exit \"%s\"",
		exe,
		out_dir,
		video_path,
	)
	_ = run_hidden_process(exe, cmd, 25000)
	cands := []string{
		path_join({out_dir, "thumb.png"}),
		path_join({out_dir, "thumb00001.png"}),
		path_join({out_dir, "thumb00000.png"}),
	}
	for c in cands {
		if os.exists(c) {
			if c != dest_png {
				_ = os.rename(c, dest_png)
			}
			return os.exists(dest_png)
		}
	}
	return os.exists(dest_png)
}

movie_unload_thumb :: proc(m: ^Movie) {
	if m.has_thumb {
		rl.UnloadTexture(m.thumb)
		m.has_thumb = false
	}
}

unload_all_movies :: proc() {
	for &m in app.movies {
		movie_unload_thumb(&m)
	}
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

movie_launch :: proc(m: ^Movie) -> (ok: bool, err: string) {
	if m == nil || m.path == "" || !os.exists(m.path) {
		return false, "Movie file missing"
	}
	exe, prefix, player_name, found := movie_player()
	if !found {
		return false, "Install VLC (preferred) or Windows Media Player"
	}
	cmd := fmt.tprintf("\"%s\" %s \"%s\"", exe, prefix, m.path)
	pi, created := spawn_process(exe, cmd, filepath.dir(exe))
	if !created {
		return false, fmt.tprintf("Could not start %s", player_name)
	}
	run_session(pi, .Movie, m.title, filepath.base(exe))
	return true, ""
}
