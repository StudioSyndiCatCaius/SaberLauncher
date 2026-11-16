package saber

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

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
	fis, _ := list_dir(movies_dir)
	for fi in fis {
		base := fi.name if fi.name != "" else filepath.base(fi.fullpath)
		if fi.type == .Directory || !has_ext(base, ..VIDEO_EXTS) do continue
		m: Movie
		m.path = strings.clone(fi.fullpath)
		m.title = strings.clone(filepath.stem(base))
		m.thumb_file = resolve_movie_thumb(movies_dir, filepath.stem(base), m.path)
		movie_load_thumb(&m)
		append(out, m)
	}
}


thumbs_dir :: proc(movies_dir: string) -> string {
	dir := tjoin({movies_dir, "_thumbs"})
	_ = os.make_directory(dir)
	return dir
}

file_mtime :: proc(path: string) -> (time.Time, bool) {
	fi, err := os.stat(path, context.temp_allocator)
	return fi.modification_time, err == nil
}

// The cached thumbnail is at least as new as the video.
cache_is_fresh :: proc(cache_path, video_path: string) -> bool {
	ct, cok := file_mtime(cache_path)
	if !cok do return false
	vt, vok := file_mtime(video_path)
	return !vok || time.time_to_unix_nano(ct) >= time.time_to_unix_nano(vt)
}

// <stem>.png/.jpg/... beside the video, else a frame grabbed into _thumbs (cached).
resolve_movie_thumb :: proc(movies_dir, stem, video_path: string) -> string {
	for ext in ([]string{".png", ".jpg", ".jpeg", ".webp"}) {
		if cand := tjoin({movies_dir, fmt.tprintf("%s%s", stem, ext)}); os.exists(cand) do return strings.clone(cand)
	}
	cache := path_join({thumbs_dir(movies_dir), fmt.tprintf("%s.png", stem)})
	if cache_is_fresh(cache, video_path) || extract_movie_thumb(video_path, cache) || os.exists(cache) do return cache
	// Empty marker: rescans skip the slow extractors (delete _thumbs to retry).
	_ = os.write_entire_file(cache, []u8{})
	delete(cache)
	return ""
}

movie_load_thumb :: proc(m: ^Movie) {
	if m.thumb_file == "" do return
	if fi, err := os.stat(m.thumb_file, context.temp_allocator); err != nil || fi.size == 0 do return
	m.thumb, m.has_thumb = load_texture_smooth(m.thumb_file)
}

extract_movie_thumb :: proc(video_path, dest_png: string) -> bool {
	return extract_thumb_shell(video_path, dest_png) || extract_thumb_ffmpeg(video_path, dest_png) || extract_thumb_vlc(video_path, dest_png)
}

extract_thumb_ffmpeg :: proc(video_path, dest_png: string) -> bool {
	exe := find_ffmpeg_exe() or_return
	// 8 s in first; short clips: 1 s in
	for seek in ([2]string{"-ss 8", "-ss 1"}) {
		cmd := fmt.tprintf("%s -y %s -i %s -frames:v 1 -vf scale=640:-2 -q:v 4 %s", quote_arg(exe), seek, quote_arg(video_path), quote_arg(dest_png))
		if run_hidden_process(exe, cmd, 20000) do return os.exists(dest_png)
	}
	return false
}

extract_thumb_vlc :: proc(video_path, dest_png: string) -> bool {
	exe := find_vlc_exe() or_return
	out_dir := filepath.dir(dest_png)
	cmd := fmt.tprintf(
		"%s -I dummy --dummy-quiet --no-audio --no-video-title-show --video-filter=scene --scene-format=png --scene-ratio=100000 --scene-prefix=thumb --scene-replace --scene-path=%s --start-time=8 --stop-time=9 --run-time=1 --play-and-exit %s",
		quote_arg(exe),
		quote_arg(out_dir),
		quote_arg(video_path),
	)
	_ = run_hidden_process(exe, cmd, 25000)
	for name in ([]string{"thumb.png", "thumb00001.png", "thumb00000.png"}) {
		if c := tjoin({out_dir, name}); os.exists(c) {
			if c != dest_png do _ = os.rename(c, dest_png)
			break
		}
	}
	return os.exists(dest_png)
}

unload_all_movies :: proc() {
	for &m in app.movies do unload_tex(&m.thumb, &m.has_thumb)
}

movie_launch :: proc(m: ^Movie) -> (ok: bool, err: string) {
	if m == nil || m.path == "" || !os.exists(m.path) do return false, "Movie file missing"
	exe, prefix, player_name, found := movie_player()
	if !found do return false, MOVIE_PLAYER_HINT
	cmd := fmt.tprintf("%s %s %s", quote_arg(exe), prefix, quote_arg(m.path))
	pi, created := spawn_process(exe, cmd, filepath.dir(exe))
	if !created do return false, fmt.tprintf("Could not start %s", player_name)
	run_session(pi, .Movie, m.title, filepath.base(exe))
	return true, ""
}
