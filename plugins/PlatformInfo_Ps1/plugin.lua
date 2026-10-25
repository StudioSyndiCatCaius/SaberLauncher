-- PlatformInfo: PlayStation
-- Factual data only (hardware facts, release dates, serial -> title/developer/publisher/year).
-- No BIOS, artwork, manuals or descriptive text is included; BIOS files must be dumped
-- from your own console. Years are the North American release. Extend `games` freely;
-- check new entries against redump.org (serials are printed on the disc ring / case spine).

local REGION_PREFIX = {
    SCUS = "North America", SLUS = "North America",
    SCES = "Europe", SLES = "Europe", SCED = "Europe", SLED = "Europe",
    SCPS = "Japan", SLPS = "Japan", SLPM = "Japan", SIPS = "Japan", SCPM = "Japan",
}

-- shared rows for multi-disc games
local function discs(serials, fields)
    local t = {}
    for i, s in ipairs(serials) do
        local row = { disc = i, discs = #serials }
        for k, v in pairs(fields) do row[k] = v end
        t[s] = row
    end
    return t
end

local games = {
    ["SCUS-94900"] = { title = "Crash Bandicoot", year = 1996, developer = "Naughty Dog", publisher = "Sony Computer Entertainment", genre = "Platformer" },
    ["SCUS-94154"] = { title = "Crash Bandicoot 2: Cortex Strikes Back", year = 1997, developer = "Naughty Dog", publisher = "Sony Computer Entertainment", genre = "Platformer" },
    ["SCUS-94244"] = { title = "Crash Bandicoot: Warped", year = 1998, developer = "Naughty Dog", publisher = "Sony Computer Entertainment", genre = "Platformer" },
    ["SCUS-94426"] = { title = "Crash Team Racing", year = 1999, developer = "Naughty Dog", publisher = "Sony Computer Entertainment", genre = "Kart racing" },
    ["SCUS-94228"] = { title = "Spyro the Dragon", year = 1998, developer = "Insomniac Games", publisher = "Sony Computer Entertainment", genre = "Platformer" },
    ["SCUS-94425"] = { title = "Spyro 2: Ripto's Rage!", year = 1999, developer = "Insomniac Games", publisher = "Sony Computer Entertainment", genre = "Platformer" },
    ["SCUS-94467"] = { title = "Spyro: Year of the Dragon", year = 2000, developer = "Insomniac Games", publisher = "Sony Computer Entertainment", genre = "Platformer" },
    ["SCUS-94194"] = { title = "Gran Turismo", year = 1998, developer = "Polyphony Digital", publisher = "Sony Computer Entertainment", genre = "Racing" },
    ["SCUS-94221"] = { title = "Final Fantasy Tactics", year = 1998, developer = "Square", publisher = "Sony Computer Entertainment", genre = "Tactical RPG" },
    ["SLUS-00067"] = { title = "Castlevania: Symphony of the Night", year = 1997, developer = "Konami", publisher = "Konami", genre = "Action" },
    ["SLUS-00707"] = { title = "Silent Hill", year = 1999, developer = "Konami", publisher = "Konami", genre = "Survival horror" },
    ["SLUS-00402"] = { title = "Tekken 3", year = 1998, developer = "Namco", publisher = "Namco", genre = "Fighting" },
    ["SLUS-01040"] = { title = "Vagrant Story", year = 2000, developer = "Square", publisher = "Square Electronic Arts", genre = "Action RPG" },
}

local function merge(rows)
    for k, v in pairs(rows) do games[k] = v end
end

merge(discs({ "SCUS-94163", "SCUS-94164", "SCUS-94165" },
    { title = "Final Fantasy VII", year = 1997, developer = "Square", publisher = "Sony Computer Entertainment", genre = "RPG" }))
merge(discs({ "SLUS-00892", "SLUS-00908", "SLUS-00909", "SLUS-00910" },
    { title = "Final Fantasy VIII", year = 1999, developer = "Square", publisher = "Square Electronic Arts", genre = "RPG" }))
merge(discs({ "SLUS-01251", "SLUS-01295", "SLUS-01296", "SLUS-01297" },
    { title = "Final Fantasy IX", year = 2000, developer = "Square", publisher = "Square Electronic Arts", genre = "RPG" }))
merge(discs({ "SLUS-01041", "SLUS-01080" },
    { title = "Chrono Cross", year = 2000, developer = "Square", publisher = "Square Electronic Arts", genre = "RPG" }))
merge(discs({ "SLUS-00594", "SLUS-00776" },
    { title = "Metal Gear Solid", year = 1998, developer = "Konami", publisher = "Konami", genre = "Stealth action" }))
merge(discs({ "SLUS-00421", "SLUS-00592" },
    { title = "Resident Evil 2", year = 1998, developer = "Capcom", publisher = "Capcom", genre = "Survival horror" }))

return {
    name = "PlatformInfo: PlayStation",
    version = "1.0",
    description = "Titles and facts for PlayStation discs, looked up by serial.",

    actions = {
        count = {
            name = "Count known games",
            description = "How many serials this plugin can name (Dialog_Info demo)",
            Do = function()
                local n = 0
                for _ in pairs(PLUGIN.games) do n = n + 1 end
                Dialog_Info(string.format("This plugin can name %d PlayStation discs by serial.", n), { "OK", "Check the list" }, function(index)
                    if index == 2 then PLUGIN.actions.check.Do() end
                end)
            end,
        },
        check = {
            name = "Check game list",
            description = "Walks every entry and reports missing fields (Dialog_Process demo)",
            Do = function()
                local serials = {}
                for s in pairs(PLUGIN.games) do serials[#serials + 1] = s end
                table.sort(serials)
                local i, missing = 0, 0
                Dialog_Process("Starting...", function()
                    -- one entry per frame; slowed down so the bar is visible
                    local t = os.clock() + 0.05
                    while os.clock() < t do end
                    i = i + 1
                    local s = serials[i]
                    local g = PLUGIN.games[s]
                    if not (g.title and g.year and g.developer and g.publisher) then missing = missing + 1 end
                    return i / #serials, s .. "  " .. (g.title or "?")
                end, function(cancelled)
                    if cancelled then
                        Dialog_Info(string.format("Stopped after %d of %d entries.", i, #serials))
                    else
                        Dialog_Info(string.format("%d entries checked, %d with missing fields.", #serials, missing))
                    end
                end)
            end,
        },
    },
    platform = "ps1",

    system = {
        name = "PlayStation",
        manufacturer = "Sony Computer Entertainment",
        released = 1994,
        release_dates = { japan = "1994-12-03", north_america = "1995-09-09", europe = "1995-09-29" },
        cpu = "MIPS R3000A-compatible, 33.8688 MHz",
        ram = "2 MB main, 1 MB video, 512 KB sound",
        media = "CD-ROM",
        memory_card = "128 KB (15 blocks)",
        bios_hint = "Dump a BIOS from your own console (e.g. SCPH-1001 for North America) into APP/libretro/system",
        core = "swanstation_libretro.dll",
        -- second letter: C = Sony first-party, L = licensed third-party
        serial_prefixes = REGION_PREFIX,
    },

    games = games,

    -- Fallback for discs not in the table: at least the region from the serial prefix.
    on_game = function(game)
        local prefix = (game.serial or ""):sub(1, 4)
        return { region = REGION_PREFIX[prefix] }
    end,
}
