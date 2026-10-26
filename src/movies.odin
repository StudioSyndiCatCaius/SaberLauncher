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

extract_thumb_ffmpeg :: proc(video_path, dest_png: string) -> bool {
	exe, found := find_ffmpeg_exe()
	if !found {
		return false
	}
	cmd := fmt.tprintf(
		"%s -y -ss 8 -i %s -frames:v 1 -vf scale=640:-2 -q:v 4 %s",
		quote_arg(exe),
		quote_arg(video_path),
		quote_arg(dest_png),
	)
	if !run_hidden_process(exe, cmd, 20000) {
		cmd = fmt.tprintf(
			"%s -y -ss 1 -i %s -frames:v 1 -vf scale=640:-2 %s",
			quote_arg(exe),
			quote_arg(video_path),
			quote_arg(dest_png),
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
		"%s -I dummy --dummy-quiet --no-audio --no-video-title-show --video-filter=scene --scene-format=png --scene-ratio=100000 --scene-prefix=thumb --scene-replace --scene-path=%s --start-time=8 --stop-time=9 --run-time=1 --play-and-exit %s",
		quote_arg(exe),
		quote_arg(out_dir),
		quote_arg(video_path),
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

movie_launch :: proc(m: ^Movie) -> (ok: bool, err: string) {
	if m == nil || m.path == "" || !os.exists(m.path) {
		return false, "Movie file missing"
	}
	exe, prefix, player_name, found := movie_player()
	if !found {
		return false, MOVIE_PLAYER_HINT
	}
	cmd := fmt.tprintf("%s %s %s", quote_arg(exe), prefix, quote_arg(m.path))
	pi, created := spawn_process(exe, cmd, filepath.dir(exe))
	if !created {
		return false, fmt.tprintf("Could not start %s", player_name)
	}
	run_session(pi, .Movie, m.title, filepath.base(exe))
	return true, ""
}
