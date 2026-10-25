-- PlatformInfo: PlayStation 2
-- Factual data only (hardware facts, release dates, serial -> title/developer/publisher/year).
-- No BIOS, artwork, manuals or descriptive text is included; BIOS files must be dumped
-- from your own console. Years are the North American release. Extend `games` freely;
-- check new entries against redump.org.

local REGION_PREFIX = {
    SCUS = "North America", SLUS = "North America",
    SCES = "Europe", SLES = "Europe",
    SCPS = "Japan", SLPS = "Japan", SLPM = "Japan",
    SCKA = "Korea", SLKA = "Korea",
    SCAJ = "Asia",
}

return {
    name = "PlatformInfo: PlayStation 2",
    version = "1.0",
    description = "Titles and facts for PlayStation 2 discs, looked up by serial.",

    actions = {
        count = {
            name = "Count known games",
            description = "How many serials this plugin can name",
            Do = function()
                local n = 0
                for _ in pairs(PLUGIN.games) do n = n + 1 end
                return string.format("%d PlayStation 2 serials known", n)
            end,
        },
    },
    platform = "ps2",

    system = {
        name = "PlayStation 2",
        manufacturer = "Sony Computer Entertainment",
        released = 2000,
        release_dates = { japan = "2000-03-04", north_america = "2000-10-26", europe = "2000-11-24" },
        cpu = "Emotion Engine, 294.912 MHz",
        gpu = "Graphics Synthesizer, 147.456 MHz, 4 MB eDRAM",
        ram = "32 MB RDRAM",
        media = "DVD-ROM, CD-ROM",
        memory_card = "8 MB",
        bios_hint = "Dump a BIOS from your own console into APP/libretro/system",
        core = "pcsx2_libretro.dll",
        serial_prefixes = REGION_PREFIX,
    },

    games = {
        ["SLUS-20312"] = { title = "Final Fantasy X", year = 2001, developer = "Square", publisher = "Square Electronic Arts", genre = "RPG" },
        ["SLUS-20370"] = { title = "Kingdom Hearts", year = 2002, developer = "Square", publisher = "Square Electronic Arts", genre = "Action RPG" },
        ["SLUS-21005"] = { title = "Kingdom Hearts II", year = 2006, developer = "Square Enix", publisher = "Square Enix", genre = "Action RPG" },
        ["SLUS-20144"] = { title = "Metal Gear Solid 2: Sons of Liberty", year = 2001, developer = "Konami", publisher = "Konami", genre = "Stealth action" },
        ["SLUS-20915"] = { title = "Metal Gear Solid 3: Snake Eater", year = 2004, developer = "Konami", publisher = "Konami", genre = "Stealth action" },
        ["SLUS-20062"] = { title = "Grand Theft Auto III", year = 2001, developer = "DMA Design", publisher = "Rockstar Games", genre = "Action" },
        ["SLUS-20552"] = { title = "Grand Theft Auto: Vice City", year = 2002, developer = "Rockstar North", publisher = "Rockstar Games", genre = "Action" },
        ["SLUS-20946"] = { title = "Grand Theft Auto: San Andreas", year = 2004, developer = "Rockstar North", publisher = "Rockstar Games", genre = "Action" },
        ["SCUS-97113"] = { title = "ICO", year = 2001, developer = "Sony Computer Entertainment", publisher = "Sony Computer Entertainment", genre = "Action adventure" },
        ["SCUS-97472"] = { title = "Shadow of the Colossus", year = 2005, developer = "Sony Computer Entertainment", publisher = "Sony Computer Entertainment", genre = "Action adventure" },
        ["SLUS-20469"] = { title = "Xenosaga Episode I: Der Wille zur Macht", year = 2003, developer = "Monolith Soft", publisher = "Namco", genre = "RPG" },
        ["SLUS-21621"] = { title = "Shin Megami Tensei: Persona 3 FES", year = 2008, developer = "Atlus", publisher = "Atlus", genre = "RPG" },
        ["SCUS-97328"] = { title = "Gran Turismo 4", year = 2005, developer = "Polyphony Digital", publisher = "Sony Computer Entertainment", genre = "Racing" },
    },

    on_game = function(game)
        local prefix = (game.serial or ""):sub(1, 4)
        return { region = REGION_PREFIX[prefix] }
    end,
}
