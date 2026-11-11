package updater

// SaberUpdater: pulls Saber's rolling public release into the folder it lives in (APP/).
// The release is the one tagged `latest` (RELEASE_TAG; ReleaseLatest.py overwrites it), with an asset
// SaberLauncher_<platform>.zip (any SaberLauncher*.zip as a fallback). The tag isn't a version: the
// version is the `Version: x.y.z` line of the release notes (else a version in the release name).
// GitHub supplies the zip's sha256 through its API; it is kept in version.ini (sha256=), so a
// re-published build of the same version still counts as an update.
// Only the exes in UPDATABLE are ever taken from the zip; nothing else is touched.

import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/ini"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

DEFAULT_REPO :: "StudioSyndiCatCaius/SaberLauncher" // override with repo= in SaberUpdater.ini
RELEASE_TAG :: "latest" // override with tag= in SaberUpdater.ini
PLATFORM :: "Windows"   // asset SaberLauncher_<PLATFORM>.zip
SELF_NAME :: "SaberUpdater.exe"
UPDATABLE :: [?]string{"Saber.exe", "SaberFlasher.exe", SELF_NAME}

Release :: struct {
	tag_name: string,
	name:     string,
	body:     string,
	assets:   []struct {
		name:                 string,
		browser_download_url: string,
		digest:               string, // "sha256:<hex>"
	},
}

// Set by run() in --check mode.
update_available: bool

// Flags used by Saber's "Check for updates":
//   --check    only compare versions; exit 0 = up to date, 10 = update available, 1 = error
//   --wait     wait (up to 30 s) for Saber.exe to exit before replacing it
//   --restart  start Saber.exe again when done (whether or not the update worked)
main :: proc() {
	ok := run()
	if has_arg("--check") {
		os.exit(10 if ok && update_available else (0 if ok else 1))
	}
	if has_arg("--restart") {
		restart_saber()
	}
	if !has_arg("-y") {
		fmt.println("\nPress Enter to close.")
		buf: [16]byte
		_, _ = os.read(os.stdin, buf[:])
	}
	os.exit(0 if ok else 1)
}

run :: proc() -> bool {
	dir, derr := os.get_executable_directory(context.allocator)
	if derr != nil {
		fmt.eprintln("Cannot find own folder:", derr)
		return false
	}
	cleanup_old(dir)

	repo := DEFAULT_REPO
	tag := RELEASE_TAG
	if cfg, ok := read_kv(join(dir, "SaberUpdater.ini")); ok {
		if r, has := cfg["repo"]; has && r != "" do repo = r
		if t, has := cfg["tag"]; has && t != "" do tag = t
	}
	local_version, local_digest := "0", ""
	if v, ok := read_kv(join(dir, "version.ini")); ok {
		if s, has := v["version"]; has do local_version = s
		if s, has := v["sha256"]; has do local_digest = s
	}

	fmt.printfln("Checking github.com/%s (release %s) ...", repo, tag)
	release_json, rok := http_get("api.github.com", fmt.tprintf("/repos/%s/releases/tags/%s", repo, tag))
	release: Release
	if !rok || json.unmarshal(release_json, &release) != nil {
		fmt.eprintfln("Could not read release '%s' (not published yet, or offline?)", tag)
		return false
	}
	url, digest: string
	want := fmt.tprintf("SaberLauncher_%s.zip", PLATFORM)
	for a in release.assets {
		if strings.equal_fold(a.name, want) {
			url, digest = a.browser_download_url, a.digest
			break
		}
		if url == "" && strings.has_prefix(a.name, "SaberLauncher") && strings.has_suffix(a.name, ".zip") {
			url, digest = a.browser_download_url, a.digest
		}
	}
	if url == "" {
		fmt.eprintfln("Release '%s' has no %s asset", tag, want)
		return false
	}
	remote_version := release_version(&release)
	remote_digest := strings.trim_prefix(digest, "sha256:")

	forced := has_arg("--force")
	cmp := compare_versions(remote_version, local_version)
	// same version re-published (a new build): it's newer when the zip's checksum changed
	rebuilt := cmp == 0 && local_digest != "" && remote_digest != "" && !strings.equal_fold(local_digest, remote_digest)
	if !looks_like_version(remote_version) {
		// release without a version: only the checksum can tell (unknown local build = update)
		cmp = 0
		rebuilt = remote_digest != "" && !strings.equal_fold(local_digest, remote_digest)
		remote_version = local_version
	}
	if looks_like_version(release_version(&release)) {
		fmt.printfln("Installed: %s   Latest: %s", local_version, remote_version)
	} else {
		fmt.printfln("Installed: %s   Latest: (release has no version, comparing checksums)", local_version)
	}
	if rebuilt do fmt.println("The release was rebuilt since this install.")
	if (cmp < 0 || (cmp == 0 && !rebuilt)) && !forced {
		fmt.println("Saber is up to date.")
		// Interactive runs may still reinstall the same (or older) release.
		if has_arg("--check") || has_arg("-y") || !confirm_no(fmt.tprintf("Reinstall %s anyway? [y/N] ", remote_version)) {
			return true
		}
		forced = true
	}
	if has_arg("--check") {
		update_available = true
		return true
	}
	if !forced && !has_arg("-y") && !confirm(fmt.tprintf("Update to %s? [Y/n] ", remote_version)) {
		return true
	}

	if has_arg("--wait") {
		for _ in 0 ..< 60 {
			if !is_locked(join(dir, "Saber.exe")) do break
			win.Sleep(500)
		}
	}
	for name in UPDATABLE {
		if name == SELF_NAME do continue // a running exe can still be renamed
		if is_locked(join(dir, name)) {
			fmt.eprintfln("%s is running. Close it and try again.", name)
			return false
		}
	}

	fmt.println("Downloading", url, "...")
	host, path := split_url(url)
	zip_data, zok := http_get(host, path)
	if !zok {
		fmt.eprintln("Download failed")
		return false
	}
	if strings.has_prefix(digest, "sha256:") {
		expected := digest[len("sha256:"):]
		if !strings.equal_fold(string(hex.encode(hash.hash_bytes(.SHA256, zip_data))), expected) {
			fmt.eprintln("Checksum mismatch, download is corrupt")
			return false
		}
	} else {
		fmt.println("(GitHub gave no checksum; relying on the zip's CRCs)")
	}

	// Extract to *.new first; nothing is replaced unless every exe unpacks cleanly.
	updatable := UPDATABLE
	files, zerr := zip_extract(zip_data, updatable[:])
	if zerr != "" {
		fmt.eprintln("Bad zip:", zerr)
		return false
	}
	names := make([dynamic]string)
	for name in UPDATABLE {
		data, has := files[name]
		if !has do continue
		if err := os.write_entire_file(join(dir, strings.concatenate({name, ".new"})), data); err != nil {
			fmt.eprintln("Cannot write", name, err)
			remove_news(dir, names[:])
			_ = os.remove(join(dir, strings.concatenate({name, ".new"})))
			return false
		}
		append(&names, name)
	}
	if len(names) == 0 {
		fmt.eprintln("Zip contains none of Saber.exe, SaberFlasher.exe, SaberUpdater.exe")
		return false
	}

	// Swap: name -> name.old, name.new -> name. Roll back on any failure.
	swapped := make([dynamic]string)
	for name in names {
		path := join(dir, name)
		old := strings.concatenate({path, ".old"})
		_ = os.remove(old)
		had_old := os.exists(path)
		if had_old && os.rename(path, old) != nil {
			fmt.eprintln("Cannot replace", name)
			rollback(dir, swapped[:])
			remove_news(dir, names[:])
			return false
		}
		if os.rename(strings.concatenate({path, ".new"}), path) != nil {
			if had_old do _ = os.rename(old, path)
			fmt.eprintln("Cannot install", name)
			rollback(dir, swapped[:])
			remove_news(dir, names[:])
			return false
		}
		append(&swapped, name)
	}

	_ = os.write_entire_file(join(dir, "version.ini"), fmt.tprintf("version=%s\nsha256=%s\n", remote_version, remote_digest))
	cleanup_old(dir) // SaberUpdater.exe.old stays until next run if we replaced ourselves
	fmt.printfln("Updated to %s.", remote_version)
	return true
}

restart_saber :: proc() {
	dir, err := os.get_executable_directory(context.allocator)
	if err != nil do return
	fmt.println("Starting Saber ...")
	win.ShellExecuteW(nil, win.L("open"), win.utf8_to_wstring(join(dir, "Saber.exe")), nil, win.utf8_to_wstring(dir), win.SW_SHOWNORMAL)
}

rollback :: proc(dir: string, swapped: []string) {
	for name in swapped {
		path := join(dir, name)
		_ = os.remove(path)
		_ = os.rename(strings.concatenate({path, ".old"}), path)
	}
}

remove_news :: proc(dir: string, names: []string) {
	for name in names do _ = os.remove(join(dir, strings.concatenate({name, ".new"})))
}

cleanup_old :: proc(dir: string) {
	matches, _ := filepath.glob(join(dir, "*.old"))
	for m in matches do _ = os.remove(m)
}

// A running exe can't be opened for exclusive write access.
is_locked :: proc(path: string) -> bool {
	if !os.exists(path) do return false
	h := win.CreateFileW(win.utf8_to_wstring(path), win.GENERIC_WRITE, 0, nil, win.OPEN_EXISTING, 0, nil)
	if h == win.INVALID_HANDLE_VALUE {
		return win.GetLastError() == win.ERROR_SHARING_VIOLATION
	}
	win.CloseHandle(h)
	return false
}

// Version of a release: a "Version: 0.3.6" / "version=0.3.6" line in the notes, else the first
// version-looking word of the name ("Latest-Public v0.3.6"), else the tag (older numbered releases).
release_version :: proc(r: ^Release) -> string {
	it := r.body
	for line in strings.split_lines_iterator(&it) {
		l := strings.trim_left(strings.trim_space(line), "*_# ")
		if len(l) < 8 || !strings.equal_fold(l[:7], "version") do continue
		words := strings.fields(strings.trim_left(l[7:], ":=*_ \t"))
		if len(words) == 0 do continue
		v := strings.trim_prefix(words[0], "v")
		if looks_like_version(v) do return v
	}
	for word in strings.fields(r.name) {
		v := strings.trim_prefix(strings.trim_prefix(word, "v"), "V")
		if looks_like_version(v) do return v
	}
	return strings.trim_prefix(r.tag_name, "v")
}

looks_like_version :: proc(s: string) -> bool {
	if s == "" || s[0] < '0' || s[0] > '9' do return false
	for c in s do if !(c == '.' || (c >= '0' && c <= '9')) do return false
	return true
}

// "1.10.0" > "1.9.2"; missing parts count as 0.
compare_versions :: proc(a, b: string) -> int {
	pa := strings.split(strings.trim_prefix(strings.trim_space(a), "v"), ".")
	pb := strings.split(strings.trim_prefix(strings.trim_space(b), "v"), ".")
	for i in 0 ..< max(len(pa), len(pb)) {
		x, y: int
		if i < len(pa) do x, _ = strconv.parse_int(pa[i])
		if i < len(pb) do y, _ = strconv.parse_int(pb[i])
		if x != y do return 1 if x > y else -1
	}
	return 0
}

read_kv :: proc(path: string) -> (map[string]string, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return nil, false
	return parse_kv(string(data)), true
}

parse_kv :: proc(src: string) -> map[string]string {
	m := make(map[string]string)
	it := ini.iterator_from_string(src)
	for key, value in ini.iterate(&it) {
		m[strings.clone(key)] = strings.clone(value)
	}
	return m
}

has_arg :: proc(arg: string) -> bool {
	for a in os.args[1:] do if a == arg do return true
	return false
}

confirm :: proc(prompt: string) -> bool {
	fmt.print(prompt)
	buf: [16]byte
	n, _ := os.read(os.stdin, buf[:])
	answer := strings.trim_space(string(buf[:n]))
	return answer == "" || answer == "y" || answer == "Y"
}

// Like confirm, but defaults to No.
confirm_no :: proc(prompt: string) -> bool {
	fmt.print(prompt)
	buf: [16]byte
	n, _ := os.read(os.stdin, buf[:])
	answer := strings.trim_space(string(buf[:n]))
	return answer == "y" || answer == "Y"
}

join :: proc(a, b: string) -> string {
	p, _ := filepath.join({a, b})
	return p
}

// "https://host/path" -> host, "/path"
split_url :: proc(url: string) -> (host, path: string) {
	rest := strings.trim_prefix(url, "https://")
	i := strings.index_byte(rest, '/')
	if i < 0 do return rest, "/"
	return rest[:i], rest[i:]
}
