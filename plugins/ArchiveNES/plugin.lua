-- ArchiveNES (experimental): browses the NES ROM set of an Internet Archive item in a tile grid,
-- downloads the ROM you pick and plays it in Saber's libretro host (needs an NES core, e.g. from
-- RetroarchExtras). Box art comes from thumbnails.libretro.com by No-Intro name.
-- Needs Online Mode (Settings). Downloads stay in this plugin's folder (roms/, covers/, roms.txt).

local ITEM = "3DBlockAsiaHwangShinweiUnl"
local FILES_URL = "https://archive.org/metadata/" .. ITEM .. "/files"
local DOWNLOAD_URL = "https://archive.org/download/" .. ITEM .. "/"
local ART_URL = "https://thumbnails.libretro.com/Nintendo%20-%20Nintendo%20Entertainment%20System/Named_Boxarts/"
local ROMS_DIR = PLUGIN_DIR .. "/roms/"
local COVERS_DIR = PLUGIN_DIR .. "/covers/"
local LIST_FILE = PLUGIN_DIR .. "/roms.txt"
local MAX_ART_REQUESTS = 6

local roms = {}      -- { file, title, tags, key (lowercase title for search), art = nil|"have"|"pending"|"none", dl }
local shown = {}     -- roms matching the query
local query = ""
local loading = false
local message = nil
local art_requests = 0

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function url_encode(s)
    return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- libretro thumbnails replace these characters with "_"
local function art_name(stem)
    return (stem:gsub('[&%*/:`<>%?\\|"]', "_"))
end

local function json_unescape(s)
    s = s:gsub("\\u(%x%x%x%x)", function(h) return utf8.char(tonumber(h, 16)) end)
    return (s:gsub("\\(.)", function(c)
        if c == "n" then return "\n" elseif c == "t" then return "\t" end
        return c
    end))
end

local function make_rom(file)
    local stem = file:gsub("%.[Nn][Ee][Ss]$", "")
    local title = stem:match("^(.-)%s*%(") or stem
    local tags = {}
    for t in stem:gmatch("%(([^)]*)%)") do tags[#tags + 1] = t end
    return { file = file, stem = stem, title = title, tags = table.concat(tags, " · "), key = stem:lower() }
end

local function filter()
    shown = {}
    local words = {}
    for w in query:lower():gmatch("%S+") do words[#words + 1] = w end
    for _, r in ipairs(roms) do
        local ok = true
        for _, w in ipairs(words) do
            if not r.key:find(w, 1, true) then ok = false break end
        end
        if ok then shown[#shown + 1] = r end
    end
end

local function set_list(files)
    table.sort(files, function(a, b) return a:lower() < b:lower() end)
    roms = {}
    for _, f in ipairs(files) do roms[#roms + 1] = make_rom(f) end
    filter()
end

local function load_cached_list()
    local f = io.open(LIST_FILE, "rb")
    if not f then return false end
    local files = {}
    for line in f:lines() do
        if line ~= "" then files[#files + 1] = line end
    end
    f:close()
    set_list(files)
    return #files > 0
end

local function fetch_list()
    if loading then return end
    if not Online() then
        message = "Turn on Online Mode (Settings) to load the ROM list."
        return
    end
    loading = true
    message = "Loading the ROM list from archive.org..."
    Http_Get(FILES_URL, function(ok, body, status)
        loading = false
        if not ok then
            message = "Couldn't load the list: " .. tostring(body)
            return
        end
        local files = {}
        for obj in body:gmatch("{(.-)}") do
            local name = obj:match('"name"%s*:%s*"(.-[^\\])"')
            if name then
                name = json_unescape(name)
                if name:lower():match("%.nes$") and not name:find("/") then files[#files + 1] = name end
            end
        end
        if #files == 0 then
            message = "No .nes files found in " .. ITEM
            return
        end
        local f = io.open(LIST_FILE, "wb")
        if f then
            f:write(table.concat(files, "\n"))
            f:close()
        end
        message = nil
        set_list(files)
    end)
end

local function cover_path(r)
    return COVERS_DIR .. art_name(r.stem) .. ".png"
end

-- Called for visible tiles only: fetches box art lazily.
local function want_art(r)
    if r.art then return end
    if exists(cover_path(r)) then r.art = "have" return end
    if not Online() or art_requests >= MAX_ART_REQUESTS then return end
    r.art = "pending"
    art_requests = art_requests + 1
    Http_Download(ART_URL .. url_encode(art_name(r.stem)) .. ".png", cover_path(r), function(ok)
        art_requests = art_requests - 1
        r.art = ok and "have" or "none"
    end)
end

local function play(r)
    local path = ROMS_DIR .. r.file
    if r.saved or exists(path) then
        r.saved = true
        Play_Rom(path, "nes")
        return
    end
    if r.dl then return end
    if not Online() then
        Dialog_Info("Turn on Online Mode (Settings) to download " .. r.title .. ".", { "OK" })
        return
    end
    r.dl = true
    Http_Download(DOWNLOAD_URL .. url_encode(r.file), path, function(ok, err)
        r.dl = nil
        if ok then
            r.saved = true
            Play_Rom(path, "nes")
        else
            Dialog_Info("Couldn't download " .. r.file .. ":\n" .. tostring(err), { "OK" })
        end
    end)
end

local function tile(i)
    local r = shown[i]
    want_art(r)
    local t = { title = r.title, sub = r.tags }
    if r.art == "have" then t.image = cover_path(r) end
    if r.dl then
        t.progress = 0
    else
        if r.saved == nil then r.saved = exists(ROMS_DIR .. r.file) end
        if r.saved then t.badge = "Saved" end
    end
    return t
end

local function frame()
    local sub = #roms > 0 and string.format("%d of %d ROMs  ·  archive.org/details/%s", #shown, #roms, ITEM)
        or ("archive.org/details/" .. ITEM)
    UI_Title("Internet Archive  ·  NES", sub)

    local text, changed = UI_SearchBar("search", query, "Search ROMs")
    if changed then
        query = text
        filter()
    end

    if message then UI_Text(message, loading and "muted" or "warn") end
    if #roms > 0 and #shown == 0 then UI_Text("Nothing matches \"" .. query .. "\".") end

    local picked = UI_Grid("roms", #shown, { cols = 6, aspect = 1.4 }, tile)
    if picked then play(shown[picked]) end
end

local function open()
    if #roms == 0 and not load_cached_list() then fetch_list() end
    UI_Open(frame)
end

return {
    name = "Archive NES",
    version = "0.1.0",
    author = "Saber",
    description = "Experimental: browse and play NES ROMs from an Internet Archive item.",
    platform = "nes",
    actions = {
        browse = {
            name = "Browse ROMs",
            description = "Search the ROM list, A downloads and plays",
            Do = function() open() end,
        },
        refresh = {
            name = "Reload ROM List",
            description = "Fetch the file list from archive.org again",
            online = true,
            Do = function()
                roms, shown = {}, {}
                fetch_list()
                return "Reloading the ROM list..."
            end,
        },
    },
}
