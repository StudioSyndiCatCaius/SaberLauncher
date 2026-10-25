-- EasyGameCovers: box art for PlayStation / PlayStation 2 / PSP discs, by serial, from
--   https://github.com/xlenore/psx-covers   https://github.com/xlenore/ps2-covers
--   PSP: libretro's serial list names the game, its box art comes from thumbnails.libretro.com
-- Covers are downloaded on demand (never bundled) into this plugin's covers/ folder.
-- Needs Online Mode (Settings) to download; covers already on disk are always shown.

local SOURCES = {
    ps1 = "https://raw.githubusercontent.com/xlenore/psx-covers/main/covers/",
    ps2 = "https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/",
    psp = "https://thumbnails.libretro.com/Sony%20-%20PlayStation%20Portable/Named_Boxarts/",
}
-- serial -> No-Intro name, for sources that name covers by title
local NAME_LISTS = {
    psp = "https://raw.githubusercontent.com/libretro/libretro-database/master/metadat/serial/Sony%20-%20PlayStation%20Portable.dat",
}
local STYLES = { "default", "3d" } -- folder names in the repos, per Cover Style option

local function style()
    return Setting("style") == "3D" and "3d" or "default"
end

-- libretro only has flat PSP covers (png); 3D falls back to flat
local function style_for(game, st)
    return NAME_LISTS[game.platform] and "default" or st
end

local function ext(game, st)
    if NAME_LISTS[game.platform] then return ".png" end
    return st == "3d" and ".png" or ".jpg"
end

-- relative to the plugin folder
local function cover_rel(game, st)
    st = style_for(game, st)
    return "covers/" .. game.platform .. "/" .. st .. "/" .. game.serial .. ext(game, st)
end

local function abs(rel)
    return PLUGIN_DIR .. "\\" .. rel:gsub("/", "\\")
end

local function exists(rel)
    local f = io.open(abs(rel), "rb")
    if f then f:close() return true end
    return false
end

-- names[platform] = { [serial] = "Legend of Heroes, The - Trails in the Sky (USA)" }, loaded on demand
local names = {}
local names_loading = {}

local function load_names(plat)
    local f = io.open(abs("covers/" .. plat .. "/names.dat"), "rb")
    if not f then return false end
    local text = f:read("a")
    f:close()
    local map, last = {}, nil
    for line in text:gmatch("[^\r\n]+") do
        local c = line:match('^%s*comment%s+"(.*)"')
        if c then last = c end
        local s = line:match('serial%s+"([^"]+)"')
        if s and last then map[s:upper()] = last end
    end
    names[plat] = map
    return true
end

local function url_encode(s)
    return (s:gsub("[^%w%-%._~]", function(ch) return string.format("%%%02X", ch:byte()) end))
end

-- nil while the name list isn't loaded, false when the serial isn't known
local function cover_url(game, st)
    if NAME_LISTS[game.platform] then
        local map = names[game.platform]
        if not map then return nil end
        local name = map[game.serial]
        if not name then return false end
        name = name:gsub('[&%*/:`<>%?\\|"]', "_") -- libretro thumbnail naming rule
        return SOURCES[game.platform] .. url_encode(name) .. ".png"
    end
    return SOURCES[game.platform] .. st .. "/" .. game.serial .. ext(game, st)
end

-- Per-session state, so automatic checks never fetch twice or retry forever:
local pending = {} -- serial -> true while queued / downloading
local failed = {}  -- serial -> reason, after a failed attempt (cleared by the action / Online Mode on)
local queue = {}   -- games waiting for the downloader
local busy = false -- a progress dialog is running the queue

local function needs_cover(g, st)
    return SOURCES[g.platform] and g.serial ~= "" and not exists(cover_rel(g, st))
end

-- Works through `queue` one download at a time behind a progress dialog.
-- quiet = only speak up when something went wrong (automatic checks).
local function run_queue(quiet)
    if busy or #queue == 0 then return end
    busy = true
    local st = style()
    local total, finished, got, missing, current = #queue, 0, 0, {}, nil
    Dialog_Process("Downloading covers", function()
        if current == nil and #queue > 0 then
            local g = table.remove(queue, 1)
            current = g
            local plat = g.platform
            if NAME_LISTS[plat] and not names[plat] and not load_names(plat) then
                -- fetch the serial -> name list first; g goes back to the front and is retried after
                table.insert(queue, 1, g)
                if not names_loading[plat] then
                    names_loading[plat] = true
                    Http_Download(NAME_LISTS[plat], "covers/" .. plat .. "/names.dat", function(ok, result)
                        names_loading[plat] = nil
                        if not ok then
                            names[plat] = {} -- unknown serials -> reported as missing below
                            saber.log("name list for " .. plat .. " failed: " .. tostring(result))
                        end
                        current = nil
                    end)
                end
            elseif not needs_cover(g, st) then -- appeared meanwhile (another style, manual copy...)
                pending[g.serial] = nil
                finished, current = finished + 1, nil
            elseif not cover_url(g, st) then
                pending[g.serial] = nil
                failed[g.serial] = "not in the name list"
                missing[#missing + 1] = g.serial .. " (not in the name list)"
                finished, current = finished + 1, nil
            else
                Http_Download(cover_url(g, st), cover_rel(g, st), function(ok, result)
                    pending[g.serial] = nil
                    if ok then
                        got = got + 1
                        Set_Art(g.serial, result)
                    else
                        failed[g.serial] = tostring(result)
                        missing[#missing + 1] = g.serial .. " (" .. tostring(result) .. ")"
                        saber.log("no cover for " .. g.serial .. ": " .. tostring(result))
                    end
                    finished, current = finished + 1, nil
                end)
            end
        end
        total = math.max(total, finished + #queue + (current and 1 or 0))
        local label = current and (current.title or current.serial) or "Finishing..."
        return finished / total, label .. "  (" .. finished .. " of " .. total .. ")"
    end, function(cancelled)
        busy = false
        for _, g in ipairs(queue) do pending[g.serial] = nil end
        queue = {}
        if cancelled then
            Dialog_Info(string.format("Stopped. %d cover(s) downloaded.", got))
        elseif #missing > 0 then
            Dialog_Info("No cover found for:\n" .. table.concat(missing, "\n"))
        elseif not quiet then
            Dialog_Info(string.format("Downloaded %d cover(s).", got))
        end
    end)
end

-- Queues every game in `games` that's missing a cover.
-- force = also retry serials that failed before (manual action).
local function ensure_covers(games, quiet, force)
    if not Online() then return 0 end
    local st = style()
    local added = 0
    for _, g in ipairs(games) do
        if force then failed[g.serial] = nil end
        if needs_cover(g, st) and not pending[g.serial] and not failed[g.serial] then
            pending[g.serial] = true
            queue[#queue + 1] = g
            added = added + 1
        end
    end
    run_queue(quiet)
    return added
end

local function auto_enabled()
    return Plugins_GetSetting('EasyGameCovers', 'autodownload') and Online()
end

-- Point every current game at the cover of the selected style (or clear it).
local function refresh_art()
    local st = style()
    for _, g in ipairs(Disc_Games()) do
        if SOURCES[g.platform] then
            local rel = cover_rel(g, st)
            Set_Art(g.serial, exists(rel) and abs(rel) or nil)
        end
    end
end

return {
    name = "EasyGameCovers",
    version = "1.0",
    description = "Downloads box art for inserted PlayStation and PlayStation 2 discs.",

    settings = {
        style = { name = "Cover Style", description = "Flat box scans or 3D case renders", type = 'enum', options = { 'Flat', '3D' }, default = 1, order = 1 },
        autodownload = {
            name = "AutoDownload Covers",
            description = "Autodownload relevant cover when a detected game is inserted",
            type = 'boolean',
            default = true,
            order = 2,
        },
    },

    --actions appear in the plugin menu
    actions = {
        current = {
            name = "Download Covers for Current Discs & Drives",
            description = "Every inserted disc, plus drive games with serial= in saber.ini; retries earlier failures",
            online = true,
            Do = function()
                local games = Disc_Games()
                if #games == 0 then
                    Dialog_Info("No disc or identified drive game is inserted.")
                    return
                end
                if ensure_covers(games, false, true) == 0 and not busy then
                    Dialog_Info("Everything inserted already has a cover.")
                end
            end,
        },
        delete = {
            name = "Delete Downloaded Covers",
            description = "Remove every cover this plugin has downloaded",
            Do = function()
                Dialog_Info("Delete all downloaded covers?", { "Cancel", "Delete" }, function(index)
                    if index ~= 2 then return end
                    failed = {}
                    local n = 0
                    for plat in pairs(SOURCES) do
                        for _, st in ipairs(STYLES) do
                            local dir = "covers/" .. plat .. "/" .. st
                            for _, f in ipairs(List_Dir(dir)) do
                                if os.remove(abs(dir .. "/" .. f)) then n = n + 1 end
                            end
                        end
                    end
                    for _, g in ipairs(Disc_Games()) do Set_Art(g.serial, nil) end
                    Dialog_Info(string.format("Deleted %d cover(s).", n))
                end)
            end,
        },
    },

    -- Every scan: point Saber at a cover that's already on disk.
    on_game = function(game)
        if not SOURCES[game.platform] then return end
        local rel = cover_rel(game, style())
        if exists(rel) then return { box = abs(rel) } end
    end,

    -- On game inserted & detected: if the setting is on, download the relevant cover.
    on_disc = function(game)
        if auto_enabled() then ensure_covers({ game }, true, false) end
    end,

    -- After every scan: catches discs whose insert was missed (Online Mode off at the time,
    -- disc still spinning up, a failed attempt on a previous run...).
    on_scan = function(games)
        if auto_enabled() then ensure_covers(games, true, false) end
    end,

    -- Online Mode just came on: fetch what was missed while offline.
    on_online = function(enabled)
        if enabled then
            failed = {}
            if Plugins_GetSetting('EasyGameCovers', 'autodownload') then ensure_covers(Disc_Games(), true, false) end
        end
    end,

    on_setting = function(key)
        if key == "style" then refresh_art() end
        if auto_enabled() then ensure_covers(Disc_Games(), true, false) end
    end,
}
