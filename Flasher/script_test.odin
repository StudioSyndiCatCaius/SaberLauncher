package flasher

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// `odin test Flasher -define:ODIN_TEST_THREADS=1` — runs real config.lua scripts through the API.
// Needs internet for the download case. Uses D:\tmp\saber_script_test as scratch space.

TEST_ROOT :: `D:\tmp\saber_script_test`

write_script :: proc(name, body: string) -> string {
	p := fmt.tprintf("%s\\%s.lua", TEST_ROOT, name)
	_ = os.write_entire_file(p, transmute([]u8)body)
	return p
}

reset_job :: proc() {
	for st in job.steps {
		delete(st.name)
		delete(st.detail)
	}
	clear(&job.steps)
	for l in job.log do delete(l)
	clear(&job.log)
	sync.atomic_store(&job.cancel, false)
	job.dest = TEST_ROOT + `\dest`
	job.temp = TEST_ROOT + `\temp`
	job.shared = TEST_ROOT + `\shared`
	delete_tree(job.dest)
	delete_tree(job.temp)
	make_dirs(job.dest)
	make_dirs(job.temp)
}

dump_steps :: proc() {
	for st in job.steps do fmt.printfln("    [%v] %s  %s", st.state, st.name, st.detail)
	for l in job.log do fmt.printfln("    log: %s", l)
}

@(test)
test_install_scripts :: proc(t: ^testing.T) {
	make_dirs(TEST_ROOT)
	make_dirs(TEST_ROOT + `\shared\Emu`)
	_ = os.write_entire_file(TEST_ROOT + `\shared\Emu\emu.txt`, transmute([]u8)string("emulator"))

	// 1. the mockup flow: download -> unzip -> copy contents into the install folder
	reset_job()
	err := run_install_script(write_script("download", `
return {
	link = "https://www.lua.org/ftp/lua-5.4.7.tar.gz",
	OnInstall = function(self, install_path)
		Log("installing into " .. install_path)
		File_Download(self.link, function(file)
			File_Unzip(file, function(folder)
				Dir_Copy(folder, install_path)
			end)
		end)
		Dir_Copy(Shared("Emu"), Path_Join(install_path, "emu"))
	end
}`))
	fmt.println("  download/unzip/copy:")
	dump_steps()
	testing.expectf(t, err == "", "script failed: %s", err)
	// single-root archive -> contents land directly in install_path, not in lua-5.4.7\
	testing.expect(t, os.exists(TEST_ROOT + `\dest\src\lua.h`), "extracted files should be directly in install path")
	testing.expect(t, !os.exists(TEST_ROOT + `\dest\lua-5.4.7`), "archive root folder must not be nested")
	testing.expect(t, os.exists(TEST_ROOT + `\dest\emu\emu.txt`), "Shared() copy")

	// 2. return values work without callbacks too
	reset_job()
	err = run_install_script(write_script("sync", `
File_Write("a.txt", "hello")
local p = File_Copy("a.txt", "b.txt")
assert(File_Exists(p), "copy missing")
assert(File_Read("b.txt") == "hello", "read mismatch")
File_Move("b.txt", "sub/c.txt")
assert(File_Exists("sub/c.txt") and not File_Exists("b.txt"), "move failed")
Dir_Delete("sub")
assert(not Dir_Exists("sub"), "delete failed")
Step("Custom step") Progress(0.5, "half")
`))
	dump_steps()
	testing.expectf(t, err == "", "sync api: %s", err)

	// 3. writes outside the install/temp folder are refused
	reset_job()
	for bad in ([]string{
		`Dir_Copy(SHARED_PATH, "C:\\Windows\\SaberTest")`,
		`File_Write("C:\\saber_test.txt", "x")`,
		`Dir_Delete("C:\\Windows\\Temp")`,
		`Dir_Delete(INSTALL_PATH)`,
		`Dir_Delete(INSTALL_PATH .. "\\..")`,
		`File_Write("..\\escape.txt", "x")`,
		`File_Move(SHARED_PATH .. "\\Emu\\emu.txt", "x.txt")`,
	}) {
		e := run_install_script(write_script("bad", bad))
		testing.expectf(t, strings.contains(e, "not allowed") || strings.contains(e, "must be inside"), "%s -> %q", bad, e)
	}
	testing.expect(t, !os.exists(`C:\saber_test.txt`), "wrote to C:")
	testing.expect(t, os.exists(TEST_ROOT + `\shared\Emu\emu.txt`), "moved a file out of shared")

	// 4. cancel unwinds the script at the next API call
	reset_job()
	sync.atomic_store(&job.cancel, true)
	err = run_install_script(write_script("cancel", `File_Download("https://www.lua.org/ftp/lua-5.4.7.tar.gz") error("should not get here")`))
	testing.expect_value(t, err, CANCELLED_MSG)

	// 5. HTML pages are rejected with a clear message
	reset_job()
	err = run_install_script(write_script("html", `File_Download("https://gamejolt.com/get/build?game=340532&build=931552")`))
	fmt.printfln("  html link -> %s", err)
	testing.expect(t, strings.contains(err, "web page"), err)

	// 6. Lua errors are reported with file/line
	reset_job()
	err = run_install_script(write_script("syntax", `return { OnInstall = function() local x = nil; x.y = 1 end }`))
	fmt.printfln("  runtime error -> %s", err)
	testing.expect(t, strings.contains(err, "syntax.lua"), err)

	// 7. GOG lookups
	reset_job()
	make_dirs(TEST_ROOT + `\gog\Star Wars - Knights of the Old Republic II`)
	make_dirs(TEST_ROOT + `\gog\Rayman 2`)
	job.gog = TEST_ROOT + `\gog`
	err = run_install_script(write_script("gog", `
assert(GetDir_GogGames() == GOG_PATH, "root")
assert(GetDir_GogGames("Rayman 2") == GOG_PATH .. "\\Rayman 2", "exact")
local k = GetDir_GogGames("star wars: knights of the old republic ii")
assert(k == GOG_PATH .. "\\Star Wars - Knights of the Old Republic II", "loose match: " .. tostring(k))
assert(GetDir_GogGames("Not A Game") == nil, "missing -> nil")
`))
	testing.expectf(t, err == "", "gog: %s", err)
	job.gog = ""
	err = run_install_script(write_script("gog_unset", `assert(GetDir_GogGames("Rayman 2") == nil)`))
	testing.expectf(t, err == "", "gog unset: %s", err)

	delete_tree(TEST_ROOT)
	reset_job()
	delete(job.steps)
	delete(job.log)
	job = {}
	delete_tree(TEST_ROOT)
}
