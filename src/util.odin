package saber

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"

// Shared helpers: strings, paths, ini text, file copies.

// ---------------------------------------------------------------------------
// Case-insensitive compares are ASCII-only on purpose: everything compared here is a file
// name, extension, serial or ini key, and core's Unicode tables cost exe size.

lower_byte :: #force_inline proc(c: u8) -> u8 { return c >= 'A' && c <= 'Z' ? c | 0x20 : c }
upper_byte :: #force_inline proc(c: u8) -> u8 { return c >= 'a' && c <= 'z' ? c &~ 0x20 : c }

eq_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) do return false
	for i in 0 ..< len(a) do if lower_byte(a[i]) != lower_byte(b[i]) do return false
	return true
}

ascii_lower :: proc(s: string, allocator := context.allocator) -> string {
	b := transmute([]u8)strings.clone(s, allocator)
	for &c in b do c = lower_byte(c)
	return string(b)
}

ascii_upper :: proc(s: string, allocator := context.allocator) -> string {
	b := transmute([]u8)strings.clone(s, allocator)
	for &c in b do c = upper_byte(c)
	return string(b)
}

// Lower-case extension of a file name or path (".png"), temp-allocated.
ext_lower :: proc(name: string) -> string {
	return ascii_lower(filepath.ext(name), context.temp_allocator)
}

has_ext :: proc(name: string, exts: ..string) -> bool {
	e := filepath.ext(name)
	for x in exts do if eq_fold(e, x) do return true
	return false
}

// Steps v through n values with wrap-around.
cycle :: proc(v, delta, n: int) -> int {
	return n <= 0 ? 0 : ((v + delta) % n + n) % n
}

// ---------------------------------------------------------------------------
// Paths

path_join :: proc(parts: []string) -> string {
	p, _ := filepath.join(parts)
	return p
}

// Temp-allocated path join (workers join a lot of paths).
tjoin :: proc(parts: []string) -> string {
	p, _ := filepath.join(parts, context.temp_allocator)
	return p
}

// A folder's entries, temp-allocated (nothing to free); ok = false when it can't be read.
list_dir :: proc(dir: string) -> ([]os.File_Info, bool) {
	fis, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	return fis, err == nil
}

// "650 MB", "4.3 GB"
fmt_bytes :: proc(n: i64) -> string {
	switch {
	case n >= 1024 * 1024 * 1024: return fmt.tprintf("%.1f GB", f64(n) / (1024 * 1024 * 1024))
	case n >= 1024 * 1024:        return fmt.tprintf("%d MB", n / (1024 * 1024))
	case n >= 1024:               return fmt.tprintf("%d KB", n / 1024)
	}
	return fmt.tprintf("%d B", max(n, 0))
}

// ---------------------------------------------------------------------------
// ini text: `key=value` lines; blank lines, `;` / `#` comments and [sections] are skipped,
// "quoted" values lose their quotes.

ini_next :: proc(it: ^string) -> (key, value: string, ok: bool) {
	for line in strings.split_lines_iterator(it) {
		l := strings.trim_space(line)
		if l == "" || l[0] == ';' || l[0] == '#' || l[0] == '[' do continue
		eq := strings.index_byte(l, '=')
		if eq < 0 do continue
		key, value = strings.trim_space(l[:eq]), strings.trim_space(l[eq + 1:])
		if len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"' do value = value[1:len(value) - 1]
		return key, value, true
	}
	return
}

ini_get :: proc(text, key: string) -> (string, bool) {
	it := text
	for k, v in ini_next(&it) do if eq_fold(k, key) do return v, true
	return "", false
}

// Clones the value of `key` into dst (only a non-empty one with `nonempty`); true when found.
ini_str :: proc(text, key: string, dst: ^string, nonempty := false) -> bool {
	v, found := ini_get(text, key)
	if !found || (nonempty && v == "") do return false
	dst^ = strings.clone(v)
	return true
}

ini_bool :: proc(text, key: string, fallback: bool) -> bool {
	v, found := ini_get(text, key)
	return found ? v == "1" || eq_fold(v, "true") : fallback
}

// Waits for a worker thread and frees it (nil is fine).
thread_end :: proc(t: ^^thread.Thread) {
	if t^ == nil do return
	thread.join(t^)
	thread.destroy(t^)
	t^ = nil
}

// ---------------------------------------------------------------------------
// File copies on worker threads

COPY_CANCELLED :: "Cancelled"

// Copies src to dst through <dst>.part, renamed once complete (and, with `verify`, compared
// byte for byte). `cancel` / `copied` are atomics shared with the main thread. "" = done.
copy_file_part :: proc(src, dst: string, buf: []u8, cancel: ^bool, copied: ^i64, verify := false) -> string {
	in_f, oerr := os.open(src)
	if oerr != nil do return fmt.tprintf("Couldn't read %s", filepath.base(src))
	defer os.close(in_f)
	part := strings.concatenate({dst, ".part"}, context.temp_allocator)
	out_f, cerr := os.open(part, {.Write, .Create, .Trunc})
	if cerr != nil do return fmt.tprintf("Couldn't write %s", filepath.base(dst))
	err := ""
	size, _ := os.file_size(in_f)
	for done: i64 = 0; done < size; {
		if sync.atomic_load(cancel) {
			err = COPY_CANCELLED
			break
		}
		n, _ := os.read(in_f, buf[:min(i64(len(buf)), size - done)])
		if n <= 0 {
			err = fmt.tprintf("Couldn't read %s", filepath.base(src))
			break
		}
		done += i64(n)
		if _, werr := os.write(out_f, buf[:n]); werr != nil {
			err = "Couldn't write the copy (disk full?)"
			break
		}
		sync.atomic_add(copied, i64(n))
	}
	os.close(out_f)
	if err == "" && verify && !files_same(src, part) do err = fmt.tprintf("The copy of %s doesn't match", filepath.base(src))
	if err == "" && os.rename(part, dst) != nil do err = fmt.tprintf("Couldn't replace %s (is it in use?)", filepath.base(dst))
	if err != "" do os.remove(part)
	return err
}

// Byte-for-byte compare; with `quick`, files over QUICK_COMPARE_LIMIT only compare sizes.
QUICK_COMPARE_LIMIT :: 16 * 1024 * 1024

files_same :: proc(a, b: string, quick := false) -> bool {
	fa, ea := os.open(a)
	if ea != nil do return false
	defer os.close(fa)
	fb, eb := os.open(b)
	if eb != nil do return false
	defer os.close(fb)
	sa, _ := os.file_size(fa)
	sb, _ := os.file_size(fb)
	if sa != sb do return false
	if quick && sa > QUICK_COMPARE_LIMIT do return true
	// streamed: the PS3 firmware (PS3UPDAT.PUP) is ~200 MB
	CHUNK :: 1024 * 1024
	ba := make([]byte, CHUNK, context.temp_allocator)
	bb := make([]byte, CHUNK, context.temp_allocator)
	for off: i64 = 0; off < sa; off += CHUNK {
		na, _ := os.read_at(fa, ba, off)
		nb, _ := os.read_at(fb, bb, off)
		if na <= 0 || na != nb || string(ba[:na]) != string(bb[:nb]) do return false
	}
	return true
}
