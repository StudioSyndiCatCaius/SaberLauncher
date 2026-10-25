-- RetroarchExtras: downloads the libretro cores Saber plays discs with, from the libretro buildbot
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
    local jobs = {}
    for _, c in ipairs(cores) do
        table.insert(jobs, { name = c.file, url = BUILDBOT .. c.file .. ".zip", dest = CORES_DIR })
        if c.extra then
            table.insert(jobs, { name = c.system .. " assets", url = c.extra.url, dest = c.extra.dest })
        end
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

local function core_action(c)
    return {
        name = "Download " .. c.system .. " core",
        description = c.file .. (c.extra and " + PPSSPP assets" or "") .. " (re-downloads the latest if installed)",
        online = true,
        Do = function()
            if busy then return "A download is already running" end
            download({ c })
        end,
    }
end

return {
    name = "RetroarchExtras",
    version = "1.0",
    description = "Downloads the libretro cores Saber plays PlayStation, PlayStation 2 and PSP discs with. " ..
        "Cores are open source (GPL) from buildbot.libretro.com. BIOS files are not included: put your own in APP/libretro/system.",

    settings = {
        offer = {
            name = "Offer Missing Cores",
            description = "Ask to download the core when a disc is inserted that no installed core can play",
            type = "boolean",
            default = true,
            order = 1,
        },
    },

    actions = {
        missing = {
            name = "Download Missing Cores",
            description = "Every platform without a core: PS1 (swanstation), PS2 (pcsx2), PSP (ppsspp)",
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
        ps1 = core_action(CORES[1]),
        ps2 = core_action(CORES[2]),
        psp = core_action(CORES[3]),
    },

    on_disc = function(game)
        if game.kind ~= "disc" or busy or offered[game.platform] then return end
        if not Setting("offer") or not Online() then return end
        local c = core_for(game.platform)
        if not c or installed(c) then return end
        offered[game.platform] = true
        Dialog_Info(string.format("No %s core is installed, so %s can't be played yet.\nDownload %s now?",
            c.system, game.title ~= "" and game.title or "this disc", c.file), { "Download", "Not now" }, function(index)
            if index == 1 then download({ c }) end
        end)
    end,
}
