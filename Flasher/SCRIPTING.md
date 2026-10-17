# Preconfig install scripts (`config.lua`)

A preconfig folder may contain `config.lua` next to `_Saber/`. It runs when the preconfig is flashed,
after the game folder (if any) is copied and before `_Saber` is written. Lua 5.4.

```lua
return {
    link = "https://example.com/game.zip",   -- any fields you like; available as self.*

    OnInstall = function(self, install_path)
        File_Download(self.link, function(file)
            File_Unzip(file, function(folder)
                Dir_Copy(folder, install_path)
            end)
        end)
    end
}
```

## Fields

| Field | Effect |
|---|---|
| `gog_name = "Star Wars - KotOR2"` | Before `OnInstall`, the GOG game is copied into the install folder (found in the Settings GOG folder, else via GOG's install records). Use for mods built on a GOG game. Fails if the game isn't installed. |
| `link`, `url`, `*_url`, `*_link` | Marks the config as downloading (Download badge). |

## Functions

Every function blocks until done, then calls the optional callback with the result **and** returns it,
so `local f = File_Download(url)` works too. Long calls show up as steps with live progress; the user
can Cancel at any time, which stops the current step and ends the script.

Relative paths resolve against the install folder. Writes, moves and deletes are only allowed inside
the install folder or the job's temp folder; reads/copies *from* anywhere are fine.

| Function | Returns | Notes |
|---|---|---|
| `File_Download(url, [cb(file)])` | file path | Saved in `TEMP_PATH`. Web pages (HTML) are rejected — use a direct link. |
| `File_Unzip(archive, [cb(folder, root)])` | folder, root | zip, 7z, rar, tar.gz… (Windows tar). `root` is the archive laid out as-is; `folder` is its single top folder if it has exactly one, else the same as `root`. Use `root` when that top folder belongs in the game (e.g. an archive holding only `Override\`). Alias `File_Extract`. |
| `Dir_Copy(src, dst, [cb(dst)])` | dst | Copies the *contents* of `src` into `dst` (merges). |
| `File_Copy(src, dst)` | dst | `dst` may be a folder. |
| `File_Move(src, dst)` | dst | Both paths must be writable. |
| `File_Delete(path)` / `Dir_Delete(path)` | bool | Can't delete the install folder itself. |
| `Dir_Create(path)` | path | |
| `File_Exists(path)` / `Dir_Exists(path)` | bool | |
| `File_Read(path)` | string or nil | |
| `File_Write(path, text)` | | |
| `Run(exe, [args], [cb(code)], [hidden])` | exit code | Waits for the program (installers etc.). Cancel kills it. |
| `Step(name)` | | Starts a custom step in the progress list. |
| `Progress(0..1, [detail])` | | Progress of the current step. |
| `Log(msg)` / `print(msg)` | | Shown under the steps. |
| `Path_Join(a, b, ...)` | string | |
| `GetDir_GogGames([game])` | path or nil | No arg: the GOG games folder from Flasher > Settings. With a game: that game's folder (exact name, else case/punctuation-insensitive match). nil if not set / not found. |
| `Shared(name)` | path | `<source>\shared\<name>`, for files shared between preconfigs (emulators…). |

Globals: `INSTALL_PATH`, `TEMP_PATH`, `CONFIG_PATH` (the preconfig folder), `SHARED_PATH`, `GOG_PATH`.

Errors (`error("...")`, a failed call) stop the install and are shown in the overlay with file:line.
