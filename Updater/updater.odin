package updater

// SaberUpdater: pulls the latest GitHub release of Saber into the folder it lives in (APP/).
// The release must carry a manifest.ini asset:
//     version=1.4.0
//     Saber.exe=<sha256 hex>
//     SaberFlasher.exe=<sha256 hex>
// Only the exes in UPDATABLE are ever replaced; any other manifest entry is ignored.

import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

DEFAULT_REPO :: "StudioSyndiCatCaius/SaberLauncher" // override with repo= in SaberUpdater.ini
SELF_NAME :: "SaberUpdater.exe"
UPDATABLE :: [?]string{"Saber.exe", "SaberFlasher.exe", SELF_NAME}

main :: proc() {
	ok := run()
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
	if cfg, ok := read_kv(join(dir, "SaberUpdater.ini")); ok {
		if r, has := cfg["repo"]; has && r != "" do repo = r
	}
	local_version := "0"
	if v, ok := read_kv(join(dir, "version.ini")); ok {
		if s, has := v["version"]; has do local_version = s
	}

	base := fmt.aprintf("/%s/releases/latest/download/", repo)
	fmt.printfln("Checking github.com/%s ...", repo)
	manifest_data, mok := http_get("github.com", strings.concatenate({base, "manifest.ini"}))
	if !mok {
		fmt.eprintln("Could not download manifest.ini (no release yet, or offline?)")
		return false
	}
	manifest := parse_kv(string(manifest_data))
	remote_version, has_version := manifest["version"]
	if !has_version {
		fmt.eprintln("manifest.ini has no version=")
		return false
	}
	delete_key(&manifest, "version")

	fmt.printfln("Installed: %s   Latest: %s", local_version, remote_version)
	if compare_versions(remote_version, local_version) <= 0 && !has_arg("--force") {
		fmt.println("Saber is up to date.")
		return true
	}
	if !has_arg("-y") && !confirm(fmt.tprintf("Update to %s? [Y/n] ", remote_version)) {
		return true
	}

	// Validate names and check nothing we replace is running, before touching anything.
	names := make([dynamic]string)
	for name in manifest {
		if name != filepath.base(name) || strings.contains_any(name, "/\\:") || name == "manifest.ini" {
			fmt.eprintln("Refusing suspicious file name in manifest:", name)
			return false
		}
		append(&names, name)
	}
	for name in names {
		if name == SELF_NAME do continue // a running exe can still be renamed
		if is_locked(join(dir, name)) {
			fmt.eprintfln("%s is running. Close it and try again.", name)
			return false
		}
	}

	// Download everything to *.new first; nothing is replaced unless all of it verifies.
	for name in names {
		fmt.printfln("Downloading %s ...", name)
		data, ok := http_get("github.com", strings.concatenate({base, name}))
		if !ok {
			fmt.eprintln("Download failed:", name)
			remove_news(dir, names[:])
			return false
		}
		digest := hex.encode(hash.hash_bytes(.SHA256, data))
		if !strings.equal_fold(string(digest), strings.trim_space(manifest[name])) {
			fmt.eprintln("Checksum mismatch:", name)
			remove_news(dir, names[:])
			return false
		}
		if err := os.write_entire_file(join(dir, strings.concatenate({name, ".new"})), data); err != nil {
			fmt.eprintln("Cannot write", name, err)
			remove_news(dir, names[:])
			return false
		}
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

	_ = os.write_entire_file(join(dir, "version.ini"), fmt.tprintf("version=%s\n", remote_version))
	cleanup_old(dir) // SaberUpdater.exe.old stays until next run if we replaced ourselves
	fmt.printfln("Updated to %s.", remote_version)
	return true
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

join :: proc(a, b: string) -> string {
	p, _ := filepath.join({a, b})
	return p
}
