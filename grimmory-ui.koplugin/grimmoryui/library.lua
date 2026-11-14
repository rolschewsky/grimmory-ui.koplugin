--[[--
Lokales Abbild der Grimmory-Bibliothek: Abgleich mit dem Server und Abfragen für die Oberfläche.

Auf dem Gerät liegt alles unter <Datenordner>/grimmory-ui/:
- library.json: Bücher und Reihen vom letzten Abgleich, dazu welches Buch wo heruntergeladen liegt.
- thumbs/<id>.jpg: kleine Cover. Neu geladen wird nur, wenn sich `coverUpdatedOn` ändert.

Die Abfragefunktionen arbeiten nur auf Tabellen und lassen sich ohne KOReader testen.
]]

local JSON = require("json")
local _ = require("grimmoryui/i18n")

local M = {}

local function lfs() return require("libs/libkoreader-lfs") end

local ok_utf8, Utf8Proc = pcall(require, "ffi/utf8proc")
local function lower(s)
    s = s or ""
    if ok_utf8 and Utf8Proc then return Utf8Proc.lowercase(s) end
    return s:lower()
end

-- Speicher ---------------------------------------------------------------------------------------

--- viewed merkt sich nur auf dem Gerät, wann ein Buch oder eine Reihe zuletzt angesehen wurde:
--- { books = { ["<id>"] = Zeit }, series = { ["<Name>"] = Zeit } }.
function M.empty()
    return { books = {}, series = {}, thumbs = {}, files = {}, details = {}, viewed = {}, synced_at = nil }
end

--- Was ein Abgleich erneuert. Alles andere in library.json gehört dem Gerät.
M.SYNCED = { "books", "series", "thumbs", "formats", "synced_at" }

function M.load(dir)
    local fh = io.open(dir .. "/library.json", "r")
    if not fh then return M.empty() end
    local raw = fh:read("*a")
    fh:close()
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" then return M.empty() end
    local base = M.empty()
    for k, v in pairs(data) do base[k] = v end
    return base
end

--- Schreibt erst in eine temporäre Datei und benennt sie dann um, ein Abbruch hinterlässt so
--- immer eine lesbare library.json.
function M.save(dir, data)
    local tmp = dir .. "/library.json.tmp"
    local fh = io.open(tmp, "w")
    if not fh then return nil, "library.json nicht schreibbar" end
    fh:write(JSON.encode(data))
    fh:close()
    return os.rename(tmp, dir .. "/library.json")
end

-- Abgleich ---------------------------------------------------------------------------------------

--- Welche Cover müssen neu geladen werden? `known` merkt sich coverUpdatedOn je Buch.
function M.thumbsToFetch(books, known, exists)
    local list = {}
    for _, b in ipairs(books) do
        local key = tostring(b.id)
        if known[key] ~= (b.coverUpdatedOn or "") or not exists(key) then
            table.insert(list, b)
        end
    end
    return list
end

--- Nur Bücher in den Formaten `formats` (etwa { "EPUB", "MOBI" }, Schreibweise egal) und nur
--- Reihen, von denen danach noch ein Buch übrig ist. Dazu die Zahl der Bücher je Format auf dem
--- Server, damit die Einstellungen alle Formate anbieten können: { EPUB = 40, PDF = 3 }.
function M.applyFormats(books, series, formats)
    local allowed, counts = {}, {}
    for _, f in ipairs(formats or {}) do allowed[f:upper()] = true end
    local kept, in_series = {}, {}
    for _, b in ipairs(books) do
        local format = (b.primaryFileType or ""):upper()
        if format ~= "" then counts[format] = (counts[format] or 0) + 1 end
        if allowed[format] then
            table.insert(kept, b)
            if b.seriesName then in_series[b.seriesName] = true end
        end
    end
    local kept_series = {}
    for _, s in ipairs(series) do
        if in_series[s.seriesName] then table.insert(kept_series, s) end
    end
    return kept, kept_series, counts
end

--- Gleicht `dir` mit dem Server ab, nur Bücher in den Formaten `formats`.
--- Ergebnis: Tabelle mit books, series, thumbs, failed oder nil und Fehler.
function M.sync(client, dir, data, formats)
    local books, err = client:books()
    if not books then return nil, err end
    local series
    series, err = client:series()
    if not series then return nil, err end
    books, series, data.formats = M.applyFormats(books, series, formats)

    local thumbs_dir = dir .. "/thumbs"
    lfs().mkdir(thumbs_dir)
    local function exists(key)
        return lfs().attributes(thumbs_dir .. "/" .. key .. ".jpg", "mode") == "file"
    end
    local todo = M.thumbsToFetch(books, data.thumbs or {}, exists)
    local fetched, failed = 0, 0
    data.thumbs = data.thumbs or {}
    for _, b in ipairs(todo) do
        local key = tostring(b.id)
        local part = thumbs_dir .. "/" .. key .. ".part"
        local ok = client:thumbnail(b.id, part)
        if ok and os.rename(part, thumbs_dir .. "/" .. key .. ".jpg") then
            data.thumbs[key] = b.coverUpdatedOn or ""
            fetched = fetched + 1
        else
            os.remove(part)
            failed = failed + 1
        end
    end

    -- Erst nach vollständiger Liste aufräumen, ein Netzfehler leert so nie den Bestand.
    local present = {}
    for _, b in ipairs(books) do present[tostring(b.id)] = true end
    for key in pairs(data.thumbs) do
        if not present[key] then
            os.remove(thumbs_dir .. "/" .. key .. ".jpg")
            data.thumbs[key] = nil
        end
    end

    data.books, data.series, data.synced_at = books, series, os.time()
    return { books = #books, series = #series, thumbs = fetched, failed = failed }
end

-- Abfragen ---------------------------------------------------------------------------------------

--- Lesestand eines Buchs: "read", "reading" oder "unread" und Prozent (0–100).
--- `local_percent` (0–1) aus KOReader hat Vorrang vor dem Stand in Grimmory.
function M.readState(book, local_percent, local_status)
    if local_status == "complete" then return "read", 100 end
    local status = book.readStatus or ""
    if status == "READ" then return "read", 100 end
    if local_percent and local_percent > 0 then
        return "reading", math.floor(local_percent * 100 + 0.5)
    end
    local p = tonumber(book.readProgress) or 0
    if p > 0 and p <= 1 then p = p * 100 end
    if status == "READING" or status == "RE_READING" or status == "PAUSED" or p > 0 then
        return "reading", math.floor(p + 0.5)
    end
    return "unread", 0
end

local function contains(hay, needle)
    return lower(hay):find(needle, 1, true) ~= nil
end

--- Volltextsuche über Titel, Autoren und Reihe.
function M.search(books, query)
    local q = lower((query or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if q == "" then return books end
    local hits = {}
    for _, b in ipairs(books) do
        if contains(b.title, q) or contains(b.seriesName, q)
            or contains(table.concat(b.authors or {}, " "), q) then
            table.insert(hits, b)
        end
    end
    return hits
end

--- Genres (Kategorien) mit Anzahl, die häufigsten zuerst.
function M.genres(books)
    local count = {}
    for _, b in ipairs(books) do
        for _, c in ipairs(b.categories or {}) do count[c] = (count[c] or 0) + 1 end
    end
    local list = {}
    for name, n in pairs(count) do table.insert(list, { name = name, count = n }) end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    return list
end

function M.byGenre(books, genre)
    if not genre then return books end
    local list = {}
    for _, b in ipairs(books) do
        for _, c in ipairs(b.categories or {}) do
            if c == genre then table.insert(list, b); break end
        end
    end
    return list
end

--- Bücher einer Reihe nach Bandnummer.
function M.seriesBooks(books, name)
    local list = {}
    for _, b in ipairs(books) do
        if b.seriesName == name then table.insert(list, b) end
    end
    table.sort(list, function(a, b)
        local na, nb = tonumber(a.seriesNumber) or math.huge, tonumber(b.seriesNumber) or math.huge
        if na ~= nb then return na < nb end
        return (a.title or "") < (b.title or "")
    end)
    return list
end

--- Ein Feld je Band 1 … total: "read", "reading", "unread" oder "missing" (nicht in Grimmory).
--- `state(book)` liefert den Lesestand eines Buchs.
function M.seriesSlots(total, books, state)
    local slots = {}
    local n = math.max(tonumber(total) or 0, 0)
    for _, b in ipairs(books) do
        local num = math.floor(tonumber(b.seriesNumber) or 0)
        if num > n then n = num end
    end
    for i = 1, n do slots[i] = "missing" end
    local rank = { missing = 0, unread = 1, reading = 2, read = 3 }
    for _, b in ipairs(books) do
        local num = math.floor(tonumber(b.seriesNumber) or 0)
        if num >= 1 then
            local s = state(b)
            if rank[s] > rank[slots[num]] then slots[num] = s end
        end
    end
    return slots
end

--- Seite `page` (ab 1) einer Liste und die Zahl der Seiten.
function M.paginate(list, page, per_page)
    local pages = math.max(1, math.ceil(#list / per_page))
    page = math.min(math.max(page or 1, 1), pages)
    local slice = {}
    for i = (page - 1) * per_page + 1, math.min(page * per_page, #list) do
        table.insert(slice, list[i])
    end
    return slice, pages, page
end

--- `n` zufällige, verschiedene Einträge. `rnd(m)` liefert eine Zahl 1 … m.
function M.pickRandom(list, n, rnd)
    rnd = rnd or math.random
    local pool = {}
    for i, v in ipairs(list) do pool[i] = v end
    local picks = {}
    for _ = 1, math.min(n, #pool) do
        table.insert(picks, table.remove(pool, rnd(#pool)))
    end
    return picks
end

--- `n` zufällige Bücher, gewichtet nach Reihe: Eine Reihe zählt so viel wie ein Einzelband, sonst
--- käme eine Reihe mit 40 Bänden vierzigmal so oft dran. Aus jeder gezogenen Reihe kommt ein
--- zufälliger Band. Gibt es weniger Reihen und Einzelbände als `n`, füllen weitere Bücher auf.
function M.pickRandomBySeries(books, n, rnd)
    rnd = rnd or math.random
    local units, by_series = {}, {}
    for _, b in ipairs(books) do
        local name = b.seriesName ~= "" and b.seriesName or nil
        if not name then
            table.insert(units, { b })
        elseif by_series[name] then
            table.insert(by_series[name], b)
        else
            by_series[name] = { b }
            table.insert(units, by_series[name])
        end
    end
    local picks, taken = {}, {}
    for _, unit in ipairs(M.pickRandom(units, n, rnd)) do
        local b = unit[rnd(#unit)]
        table.insert(picks, b)
        taken[b] = true
    end
    if #picks < n then
        for _, b in ipairs(M.pickRandom(books, #books, rnd)) do
            if #picks >= n then break end
            if not taken[b] then table.insert(picks, b) end
        end
    end
    return picks
end

--- Die zuletzt hinzugefügten Bücher.
function M.recent(books, n)
    local list = {}
    for i, b in ipairs(books) do list[i] = b end
    table.sort(list, function(a, b) return (a.addedOn or "") > (b.addedOn or "") end)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
end

--- Nachname des ersten Autors: das letzte Wort, „doyle“ aus „Arthur Conan Doyle“.
local function lastName(book)
    local author = (book.authors or {})[1] or ""
    return lower(author:match("(%S+)%s*$") or author)
end

--- Fester Rang je Buch und `seed`: „Zufall“ mischt so nicht bei jedem Blättern neu.
local function shuffleRank(book, seed)
    local s = tostring(book.id) .. ":" .. tostring(seed)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
    return h
end

--- Bücher sortiert: added (zuletzt hinzugefügt), title, author (Nachname), series (Reihen in
--- Bandfolge, Einzelbände nach Titel dazwischen), read (zuletzt gelesen), viewed (zuletzt
--- angesehen laut `viewed`, siehe M.empty), size (größte zuerst) oder random (mit `seed`).
function M.sortBooks(books, mode, seed, viewed)
    local list = {}
    for i, b in ipairs(books) do list[i] = b end
    local function title(b) return lower(b.title or "") end
    local function byTitle(a, b) return title(a) < title(b) end
    local function newest(a, b)
        local da, db = a.addedOn or "", b.addedOn or ""
        if da ~= db then return da > db end
        return byTitle(a, b)
    end
    local cmp
    if mode == "title" then
        cmp = byTitle
    elseif mode == "author" then
        cmp = function(a, b)
            local la, lb = lastName(a), lastName(b)
            if la ~= lb then return la < lb end
            return byTitle(a, b)
        end
    elseif mode == "series" then
        local function key(b)
            return lower((b.seriesName and b.seriesName ~= "") and b.seriesName or b.title or "")
        end
        cmp = function(a, b)
            local ka, kb = key(a), key(b)
            if ka ~= kb then return ka < kb end
            local na, nb = tonumber(a.seriesNumber) or math.huge, tonumber(b.seriesNumber) or math.huge
            if na ~= nb then return na < nb end
            return byTitle(a, b)
        end
    elseif mode == "read" then
        cmp = function(a, b)
            local ra, rb = a.lastReadTime or "", b.lastReadTime or ""
            if ra ~= rb then return ra > rb end
            return (a.addedOn or "") > (b.addedOn or "")
        end
    elseif mode == "viewed" then
        local seen = (viewed or {}).books or {}
        cmp = function(a, b)
            local va, vb = seen[tostring(a.id)] or 0, seen[tostring(b.id)] or 0
            if va ~= vb then return va > vb end
            return newest(a, b)
        end
    elseif mode == "size" then
        cmp = function(a, b)
            local sa, sb = tonumber(a.fileSizeKb) or 0, tonumber(b.fileSizeKb) or 0
            if sa ~= sb then return sa > sb end
            return byTitle(a, b)
        end
    elseif mode == "random" then
        cmp = function(a, b)
            local ra, rb = shuffleRank(a, seed), shuffleRank(b, seed)
            if ra ~= rb then return ra < rb end
            return tostring(a.id) < tostring(b.id)
        end
    else
        cmp = newest
    end
    table.sort(list, cmp)
    return list
end

--- Reihen sortiert: read (zuletzt gelesen), viewed (zuletzt angesehen, ein angesehenes Buch zählt
--- für seine Reihe) oder name. Reihen ohne Treffer folgen, die zuletzt ergänzte zuerst.
function M.sortSeries(series, books, mode, viewed)
    local list = {}
    for i, s in ipairs(series) do list[i] = s end
    if mode == "name" then
        table.sort(list, function(a, b) return (a.seriesName or "") < (b.seriesName or "") end)
        return list
    end
    local last, none = {}, ""
    if mode == "viewed" then
        viewed, none = viewed or {}, 0
        for name, t in pairs(viewed.series or {}) do last[name] = t end
        local seen = viewed.books or {}
        for _, b in ipairs(books) do
            local t = seen[tostring(b.id)]
            if b.seriesName and t and t > (last[b.seriesName] or 0) then last[b.seriesName] = t end
        end
    else
        for _, b in ipairs(books) do
            if b.seriesName and (b.lastReadTime or "") > (last[b.seriesName] or "") then
                last[b.seriesName] = b.lastReadTime
            end
        end
    end
    table.sort(list, function(a, b)
        local la, lb = last[a.seriesName] or none, last[b.seriesName] or none
        if la ~= lb then return la > lb end
        return (a.latestAddedOn or "") > (b.latestAddedOn or "")
    end)
    return list
end

--- Der nächste Band derselben Reihe in der Bibliothek, nil ohne.
function M.nextInSeries(books, book)
    local n = tonumber(book.seriesNumber)
    if not (book.seriesName and n) then return nil end
    local best, best_n
    for _, b in ipairs(books) do
        local bn = tonumber(b.seriesNumber)
        if b.seriesName == book.seriesName and bn and bn > n and (not best_n or bn < best_n) then
            best, best_n = b, bn
        end
    end
    return best
end

--- Das Buch, an dem zuletzt gelesen wurde und das noch nicht fertig ist.
function M.continueReading(books, state)
    local best
    for _, b in ipairs(books) do
        if state(b) == "reading" and (not best or (b.lastReadTime or "") > (best.lastReadTime or "")) then
            best = b
        end
    end
    return best
end

--- Dezimalpunkt durch das Trennzeichen der Sprache ersetzen: "4.5" wird "4,5".
function M.decimal(num)
    return (tostring(num):gsub("%.", _(",")))
end

--- "2,3 MB" aus Kilobyte.
function M.formatSize(kb)
    return M.decimal(string.format("%.1f", (tonumber(kb) or 0) / 1024)) .. " MB"
end

--- "15" oder "4,5" aus der Bandnummer.
function M.bandLabel(num)
    num = tonumber(num)
    if not num then return "" end
    if num == math.floor(num) then return tostring(math.floor(num)) end
    return M.decimal(num)
end

--- Jahr aus einem Datum wie "2019-03-07".
function M.year(date)
    return (date or ""):match("^(%d%d%d%d)") or ""
end

return M
