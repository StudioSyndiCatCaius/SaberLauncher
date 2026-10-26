-- RetroarchExtras: downloads the libretro cores Saber plays discs and ROMs with, from the libretro buildbot
--   https://buildbot.libretro.com/nightly/windows/x86_64/latest/
-- Cores go to APP/libretro/cores (PSP also gets PPSSPP's assets in APP/libretro/system/PPSSPP).
-- Cores are GPL software by their authors (sources: https://github.com/libretro); never BIOS files.
-- Needs Online Mode (Settings).

local BUILDBOT = "https://buildbot.libretro.com/nightly/windows/x86_64/latest/"
local CORES_DIR = SABER_DIR .. "/libretro/cores"
local SYSTEM_DIR = SABER_DIR .. "/libretro/system"

-- `alts` are other cores Saber also accepts for the platform (see RETRO_CORES in src/retro.odin)
local CORES = {
    { platform = "ps1", system = "PlayStation", file = "swanstation_libretro.dll",
      alts = { "mednafen_psx_hw_libretro.dll", "mednafen_psx_libretro.dll", "pcsx_rearmed_libretro.dll" } },
    { platform = "ps2", system = "PlayStation 2", file = "pcsx2_libretro.dll" },
    { platform = "psp", system = "PlayStation Portable", file = "ppsspp_libretro.dll",
      extra = { url = "https://buildbot.libretro.com/assets/system/PPSSPP.zip", dest = SYSTEM_DIR, check = "PPSSPP" } },
    { platform = "dc", system = "Dreamcast", file = "flycast_libretro.dll" },
    -- cartridge systems (ROM files on a drive)
    { platform = "nes", system = "NES", file = "mesen_libretro.dll",
      alts = { "nestopia_libretro.dll", "fceumm_libretro.dll", "quicknes_libretro.dll" } },
    { platform = "snes", system = "Super Nintendo", file = "snes9x_libretro.dll",
      alts = { "bsnes_libretro.dll", "snes9x2010_libretro.dll" } },
    { platform = "gb", system = "Game Boy", file = "gambatte_libretro.dll",
      alts = { "sameboy_libretro.dll", "mgba_libretro.dll" } },
    { platform = "gbc", system = "Game Boy Color", file = "gambatte_libretro.dll",
      alts = { "sameboy_libretro.dll", "mgba_libretro.dll" } },
    { platform = "gba", system = "Game Boy Advance", file = "mgba_libretro.dll",
      alts = { "vbam_libretro.dll", "vba_next_libretro.dll" } },
    { platform = "n64", system = "Nintendo 64", file = "mupen64plus_next_libretro.dll",
      alts = { "parallel_n64_libretro.dll" } },
    { platform = "nds", system = "Nintendo DS", file = "melondsds_libretro.dll",
      alts = { "melonds_libretro.dll", "desmume_libretro.dll" } },
    { platform = "md", system = "Mega Drive / Genesis", file = "genesis_plus_gx_libretro.dll",
      alts = { "picodrive_libretro.dll" } },
    { platform = "sms", system = "Master System", file = "genesis_plus_gx_libretro.dll",
      alts = { "picodrive_libretro.dll" } },
    { platform = "gg", system = "Game Gear", file = "genesis_plus_gx_libretro.dll" },
    { platform = "pce", system = "PC Engine / TurboGrafx-16", file = "mednafen_pce_fast_libretro.dll",
      alts = { "mednafen_pce_libretro.dll" } },
    { platform = "a2600", system = "Atari 2600", file = "stella_libretro.dll",
      alts = { "stella2014_libretro.dll" } },
}

local busy = false
local offered = {} -- platforms already offered this session

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function installed(core)
    if exists(CORES_DIR .. "/" .. core.file) then return true end
    for _, alt in ipairs(core.alts or {}) do
        if exists(CORES_DIR .. "/" .. alt) then return true end
    end
    return false
end

local function core_for(platform)
    for _, c in ipairs(CORES) do
        if c.platform == platform then return c end
    end
end

-- Downloads + unpacks each core (and its extra assets) behind a progress dialog.
local function download(cores)
    if busy or #cores == 0 then return end
    busy = true
    local jobs, queued = {}, {}
    for _, c in ipairs(cores) do
        -- systems can share a core (Game Boy / Color, Mega Drive / Master System)
        if queued[c.file] then goto continue end
        queued[c.file] = true
        table.insert(jobs, { name = c.file, url = BUILDBOT .. c.file .. ".zip", dest = CORES_DIR })
        if c.extra then
            table.insert(jobs, { name = c.system .. " assets", url = c.extra.url, dest = c.extra.dest })
        end
        ::continue::
    end
    local total, done, current, stop = #jobs, 0, nil, false
    local errors, got = {}, {}

    Dialog_Process("Downloading cores", function()
        if current == nil and not stop and #jobs > 0 then
            local job = table.remove(jobs, 1)
            current = job
            local tmp = "tmp/" .. job.name:gsub("[^%w%.%-_]", "_") .. ".zip"
            Http_Download(job.url, tmp, function(ok, err)
                if ok then
                    local unzipped, uerr = Unzip(tmp, job.dest)
                    if unzipped then
                        table.insert(got, job.name)
                    else
                        table.insert(errors, job.name .. ": " .. tostring(uerr))
                    end
                else
                    table.insert(errors, job.name .. ": " .. tostring(err))
                end
                os.remove(PLUGIN_DIR .. "/" .. tmp)
                done = done + 1
                current = nil
            end)
        end
        if current == nil and (stop or #jobs == 0) then return 1 end
        local label = current and ("Downloading " .. current.name) or "Finishing"
        return done / total, string.format("%s (%d/%d)", label, done + 1, total)
    end, function(cancelled)
        if cancelled then stop = true end
        busy = false
        local lines = {}
        if #got > 0 then table.insert(lines, "Installed: " .. table.concat(got, ", ")) end
        if #errors > 0 then table.insert(lines, "Failed:\n" .. table.concat(errors, "\n")) end
        if cancelled then table.insert(lines, "Stopped.") end
        if #lines > 0 then Dialog_Info(table.concat(lines, "\n\n")) end
        saber.log(table.concat(lines, " | "))
    end)
end

local function missing()
    local list = {}
    for _, c in ipairs(CORES) do
        if not installed(c) then table.insert(list, c) end
    end
    return list
end

-- One menu row per system; picking it downloads (or updates) that system's core.
local function choose_core()
    local items = {}
    for _, c in ipairs(CORES) do
        table.insert(items, {
            name = c.system .. (installed(c) and "  (installed)" or ""),
            description = c.file .. (c.extra and " + PPSSPP assets" or "") ..
                (installed(c) and " - re-downloads the latest nightly" or ""),
            Do = function()
                if busy then return "A download is already running" end
                if not Online() then return "Turn on Online Mode to download cores" end
                download({ c })
            end,
        })
    end
    Dialog_Menu("Pick a system to download its emulator core.", items)
end

return {
    name = "RetroarchExtras",
    version = "1.1",
    description = "Downloads the libretro cores Saber plays PlayStation, PS2, PSP and Dreamcast discs, and NES to Nintendo DS ROMs with. " ..
        "Cores are open source (GPL) from buildbot.libretro.com. BIOS files are not included: put your own in APP/libretro/system.",

    settings = {
        offer = {
            name = "Offer Missing Cores",
            description = "Ask to download the core when a disc or ROM is inserted that no installed core can play",
            type = "boolean",
            default = true,
            order = 1,
        },
    },

    actions = {
        missing = {
            name = "Download Missing Cores",
            description = "Every platform without a core, from PlayStation discs to Game Boy Advance and DS ROMs",
            online = true,
            Do = function()
                if busy then return "A download is already running" end
                local list = missing()
                if #list == 0 then return "All cores are installed" end
                download(list)
            end,
        },
        update = {
            name = "Update All Cores",
            description = "Re-download the latest nightly of every core",
            online = true,
            Do = function()
                if busy then return "A download is already running" end
                download(CORES)
            end,
        },
        choose = {
            name = "Download a Core...",
            description = "Pick one system from the list",
            online = true,
            Do = function()
                if busy then return "A download is already running" end
                choose_core()
            end,
        },
    },

    on_disc = function(game)
        if (game.kind ~= "disc" and game.kind ~= "rom") or busy or offered[game.platform] then return end
        if not Setting("offer") or not Online() then return end
        local c = core_for(game.platform)
        if not c or installed(c) then return end
        offered[game.platform] = true
        Dialog_Info(string.format("No %s core is installed, so %s can't be played yet.\nDownload %s now?",
            c.system, game.title ~= "" and game.title or "this game", c.file), { "Download", "Not now" }, function(index)
            if index == 1 then download({ c }) end
        end)
    end,
}
