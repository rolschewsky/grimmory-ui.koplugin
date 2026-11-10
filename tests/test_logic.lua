-- Selbsttest der reinen Logik ohne KOReader. Aufruf aus dem Repo-Ordner:
--   luajit tests/test_logic.lua   (auf dem Kindle: /mnt/us/koreader/luajit …)
package.path = "grimmory-ui.koplugin/?.lua;" .. package.path
for _, name in ipairs{ "json", "socket.http", "ssl.https", "libs/libkoreader-lfs", "ltn12",
        "socket", "socketutil", "logger" } do
    package.preload[name] = function() return {} end
end

local api = require("grimmoryui/api")
local lib = require("grimmoryui/library")
local version = require("grimmoryui/version")

-- Hostnamen im Zertifikat
assert(api.hostMatches("grimmory.example.com", "GRIMMORY.example.com"))
assert(api.hostMatches("*.example.com", "grimmory.example.com"))
assert(not api.hostMatches("*.example.com", "a.b.example.com"))
assert(not api.hostMatches("*.example.com", "example.com"))

-- Server-Adresse
assert(api.normalizeBase(" https://grimmory.example.com/ ") == "https://grimmory.example.com")
assert(api.normalizeBase("http://10.0.0.5:6060") == "http://10.0.0.5:6060")
assert(api.normalizeBase("grimmory.example.com") == nil)
assert(api.normalizeBase(nil) == nil)

-- Fehlertexte
assert(api.describe(403):find("403"))
assert(api.describe("wantread"):find("^Keine Antwort vom Server"))
assert(api.describe("connection refused"):find("^Verbindung abgelehnt"))
assert(api.describe("network is unreachable"):find("^Kein Netz"))
assert(api.describe("irgendwas") == "irgendwas")
assert(api.describe(nil) == "unbekannter Fehler")

-- Dateiname aus dem Download
assert(api.filenameFromDisposition('attachment; filename="Die hohle Nadel - Maurice Leblanc (1909).epub"')
    == "Die hohle Nadel - Maurice Leblanc (1909).epub")
assert(api.filenameFromDisposition("attachment; filename*=UTF-8''Annes%20Haus%20der%20Tr%C3%A4ume.epub")
    == "Annes Haus der Träume.epub")
assert(api.filenameFromDisposition('attachment; filename="../../etc/passwd"') == ".._.._etc_passwd")
assert(api.filenameFromDisposition('attachment; filename=".."') == nil)
assert(api.filenameFromDisposition(nil) == nil)

-- Lesestand
assert(lib.readState({ readStatus = "READ" }) == "read")
assert(select(2, lib.readState({ readStatus = "READING", readProgress = 42 })) == 42)
assert(select(2, lib.readState({ readProgress = 0.3 })) == 30)
assert(lib.readState({}) == "unread")
assert(select(2, lib.readState({ readStatus = "UNREAD" }, 0.64)) == 64)
assert(lib.readState({ readStatus = "READING" }, 0.5, "complete") == "read")

-- Suche, Genres, Reihen
local books = {
    { id = 1, title = "Fünf Wochen im Ballon", authors = { "Jules Verne" }, seriesName = "Außergewöhnliche Reisen",
      seriesNumber = 1, categories = { "Abenteuer" }, addedOn = "2026-01-01T10:00:00Z" },
    { id = 2, title = "Reise zum Mittelpunkt der Erde", authors = { "Jules Verne" },
      seriesName = "Außergewöhnliche Reisen", seriesNumber = 2, categories = { "Abenteuer", "Science-Fiction" },
      addedOn = "2026-03-01T10:00:00Z", readStatus = "READING", lastReadTime = "2026-03-05T10:00:00Z" },
    { id = 3, title = "Pater Browns Einfalt", authors = { "G. K. Chesterton" }, seriesName = "Pater Brown",
      seriesNumber = 1, categories = { "Krimi" }, addedOn = "2026-02-01T10:00:00Z", readStatus = "READ" },
    { id = 4, title = "Die Abenteuer des Kapitän Hatteras", authors = { "Jules Verne" },
      seriesName = "Außergewöhnliche Reisen", seriesNumber = 4.0, categories = { "Abenteuer" },
      addedOn = "2025-12-01T10:00:00Z" },
}
assert(#lib.search(books, "verne") == 3)
assert(#lib.search(books, "  chesterton ") == 1)
assert(#lib.search(books, "") == 4)
local genres = lib.genres(books)
assert(genres[1].name == "Abenteuer" and genres[1].count == 3)
assert(genres[2].name == "Krimi" and genres[3].name == "Science-Fiction")
assert(#lib.byGenre(books, "Krimi") == 1)

local sw = lib.seriesBooks(books, "Außergewöhnliche Reisen")
assert(sw[1].id == 1 and sw[2].id == 2 and sw[3].id == 4)
local function state(b) return (lib.readState(b)) end
local slots = lib.seriesSlots(5, sw, state)
assert(#slots == 5)
assert(slots[1] == "unread" and slots[2] == "reading" and slots[3] == "missing" and slots[4] == "unread")
assert(slots[5] == "missing")
assert(#lib.seriesSlots(nil, sw, state) == 4)

-- Sortierungen von Regal und Suche
local function ids(list) local t = {} for i, b in ipairs(list) do t[i] = b.id end return table.concat(t, ",") end
assert(ids(lib.sortBooks({ { id = 1, title = "B", fileSizeKb = 10 }, { id = 2, title = "A", fileSizeKb = "900" },
    { id = 3, title = "A", fileSizeKb = 10 } }, "size")) == "2,3,1") -- größte zuerst, gleich groß nach Titel
assert(ids(lib.sortBooks(books, "added")) == "2,3,1,4")
assert(ids(lib.sortBooks(books, "title")) == "4,1,3,2")    -- Die, Fünf, Pater, Reise
assert(ids(lib.sortBooks(books, "author")) == "3,4,1,2")   -- Chesterton vor Verne, darin nach Titel
assert(ids(lib.sortBooks(books, "series")) == "1,2,4,3")   -- Reihe in Bandfolge, „Pater Brown“ danach
assert(ids(lib.sortBooks(books, "read")) == "2,3,1,4")     -- gelesen zuerst, dann nach Zugang
assert(ids(lib.sortBooks(books, "random", 7)) == ids(lib.sortBooks(books, "random", 7)))
assert(#lib.sortBooks(books, "random", 7) == 4 and books[1].id == 1) -- Original bleibt unverändert

-- Seiten, Zufall, Neuzugänge, Weiterlesen
local list = {}
for i = 1, 23 do list[i] = i end
local slice, pages, page = lib.paginate(list, 3, 8)
assert(pages == 3 and page == 3 and #slice == 7 and slice[1] == 17)
slice, pages, page = lib.paginate({}, 5, 8)
assert(pages == 1 and page == 1 and #slice == 0)
local picks = lib.pickRandom({ "a", "b", "c" }, 5, function() return 1 end)
assert(#picks == 3 and picks[1] == "a" and picks[3] == "c")

-- Zufall nach Reihe gewichtet: 40 Bände einer Reihe zählen so viel wie ein Einzelband.
local shelf = { { id = "solo" }, { id = "leer", seriesName = "" } }
for i = 1, 40 do shelf[#shelf + 1] = { id = i, seriesName = "Außergewöhnliche Reisen" } end
math.randomseed(7)
local hits = {}
for _ = 1, 3000 do
    local id = lib.pickRandomBySeries(shelf, 1)[1].id
    local key = type(id) == "number" and "reihe" or id
    hits[key] = (hits[key] or 0) + 1
end
for _, key in ipairs({ "solo", "leer", "reihe" }) do assert(hits[key] > 850 and hits[key] < 1150, key) end
picks = lib.pickRandomBySeries(shelf, 3)
local series_picks = 0
for _, b in ipairs(picks) do if b.seriesName == "Außergewöhnliche Reisen" then series_picks = series_picks + 1 end end
assert(#picks == 3 and series_picks == 1)
assert(#lib.pickRandomBySeries(shelf, 5) == 5)
assert(#lib.pickRandomBySeries({}, 3) == 0)

-- Formatfilter beim Abgleich: nur gewählte Formate, Reihen ohne Buch fallen weg, Zählung aller Formate.
local server_books = {
    { id = 1, primaryFileType = "EPUB", seriesName = "A" }, { id = 2, primaryFileType = "PDF", seriesName = "B" },
    { id = 3, primaryFileType = "mobi" }, { id = 4, primaryFileType = "CBZ", seriesName = "A" }, { id = 5 },
}
local kept, kept_series, counts = lib.applyFormats(server_books, { { seriesName = "A" }, { seriesName = "B" } },
    { "epub", "MOBI" })
assert(#kept == 2 and kept[1].id == 1 and kept[2].id == 3)
assert(#kept_series == 1 and kept_series[1].seriesName == "A")
assert(counts.EPUB == 1 and counts.PDF == 1 and counts.MOBI == 1 and counts.CBZ == 1 and counts[""] == nil)
assert(#lib.applyFormats(server_books, {}, nil) == 0)
assert(lib.recent(books, 2)[1].id == 2 and lib.recent(books, 2)[2].id == 3)
assert(lib.continueReading(books, state).id == 2)

-- Cover neu laden?
local todo = lib.thumbsToFetch(books, { ["1"] = "", ["2"] = "alt" }, function(key) return key ~= "3" end)
assert(#todo == 3 and todo[1].id == 2 and todo[2].id == 3 and todo[3].id == 4)

-- Formate
assert(lib.formatSize(2374) == "2,3 MB")
assert(lib.bandLabel(15.0) == "15" and lib.bandLabel(4.5) == "4,5" and lib.bandLabel(nil) == "")
assert(lib.year("2019-03-07") == "2019" and lib.year(nil) == "")

-- Versionen für das Selbst-Update
assert(version.newer("v1.2.0", "1.1.9"))
assert(version.newer("1.10.0", "1.9.3"))
assert(not version.newer("v1.2.0", "1.2.0"))
assert(not version.newer("1.2.0-beta1", "1.2.0"))
assert(version.newer("1.2.0", "1.2.0-beta1"))
assert(not version.newer("kaputt", "1.0.0"))

-- Release-Zip auswählen
local updater = require("grimmoryui/updater")
assert(updater.pickAsset({ assets = { { name = "notes.txt" }, { name = "grimmory-ui.koplugin-v1.2.0.zip" } } }).name
    == "grimmory-ui.koplugin-v1.2.0.zip")
assert(updater.pickAsset({ assets = { { name = "other.koplugin.zip" } } }) == nil)
-- Das Zip von Grimmory Sync (Ordner grimmory.koplugin) darf nie als Update gelten
assert(updater.pickAsset({ assets = { { name = "grimmory.koplugin-v1.2.0.zip" } } }) == nil)
assert(updater.pickAsset(nil) == nil)

-- Bitte um einen Stern: erst nach dem dritten gelesenen Buch, „Später“ nur einmal
local rating = require("grimmoryui/rating")
local st = {}
assert(rating.record(st, 1) and not rating.record(st, 1))
assert(rating.record(st, 2))
assert(not rating.due(st, 0, true))
assert(rating.record(st, "3"))
assert(rating.due(st, 0, true) and not rating.due(st, 0, false))
rating.answer(st, "later", 1000)
assert(not rating.due(st, 1000 + 29 * 86400, false))
assert(rating.due(st, 1000 + 30 * 86400, false))
rating.answer(st, "later", 1000 + 30 * 86400)
assert(st.done and not rating.due(st, 1e10, true))
assert(not rating.record(st, 4))
for _, choice in ipairs({ "rate", "never" }) do
    local s = { count = 3 }
    rating.answer(s, choice, 0)
    assert(s.done and not rating.due(s, 1e10, true))
end

print("ok")
