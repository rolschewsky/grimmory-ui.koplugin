--[[--
Das Vollbild-Fenster des Plugins: fünf Bereiche (Start, Reihen, Stöbern, Regal, Suche) mit der
Leiste unten, dazu die Detailseiten für eine Reihe und ein Buch.

Geblättert wird mit den Pfeilen oben, mit Wischen nach links oder rechts oder mit den Blättertasten.
Die Zurück-Taste schließt eine Detailseite, auf einer Bereichsseite das ganze Fenster.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local lib = require("grimmory/library")
local UI = require("grimmory/ui")
local _ = require("grimmory/i18n")
local N_, T = _.ngettext, _.T

local App = InputContainer:extend{
    name = "grimmory_app",
    plugin = nil,
    covers_fullscreen = true,
}

local M48 = 48

-- Hilfen -------------------------------------------------------------------------------------

local function margin() return UI.px(M48) end
local function innerWidth() return UI.width() - 2 * margin() end

--- Spalten für ein Raster mit Zellen von mindestens `cell_min` Entwurfs-Pixeln.
local function columns(cell_min)
    local gap = UI.px(32)
    local cols = math.max(2, math.floor((innerWidth() + gap) / (UI.px(cell_min) + gap)))
    return cols, math.floor((innerWidth() - (cols - 1) * gap) / cols), gap
end

--- Zeile über die volle Breite mit fester Höhe, Inhalt senkrecht mittig, Linie darunter.
local function rowBox(content, h, callback, line)
    local box = VerticalGroup:new{
        FrameContainer:new{
            bordersize = 0, padding = 0, padding_left = margin(), padding_right = margin(),
            UI.LeftContainer:new{ dimen = Geom:new{ w = innerWidth(), h = h - 1 }, content },
        },
        UI.line(UI.width(), 1, line == false and UI.WHITE or UI.LINE),
    }
    return callback and UI.tap(box, callback) or box
end

local function first(list) return type(list) == "table" and list[1] or nil end

--- „3 Bücher“: Anzahl mit Wort in der passenden Pluralform.
local function count(n, singular, plural) return T(N_(singular, plural, n), n) end

--- Höhe des zweizeiligen Titels unter einem Cover.
local function titleHeight() return UI.textboxHeight(22, 2, { bold = true }) end


local function countRead(states)
    local n = 0
    for _, s in ipairs(states) do if s == "read" then n = n + 1 end end
    return n
end

--- Überlagerung, bei der die obere Ebene Eingaben zuerst bekommt. OverlapGroup fragt sonst die
--- untere zuerst, und ein Tippen auf das Bewertungs-Kästchen öffnete das Cover darunter.
local TopFirst = OverlapGroup:extend{}

function TopFirst:propagateEvent(event)
    for i = #self, 1, -1 do
        if self[i]:handleEvent(event) then return true end
    end
    return false
end

-- Aufbau -------------------------------------------------------------------------------------

function App:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = UI.width(), h = UI.height() }
    self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
    end
    self.tab = self.tab or self.plugin:setting("start_tab")
    self.stack = {}
    self.page = {}
    self.search_query = ""
    self.search_sort = "added"
    self.reihen_sort = "read"
    self:reroll()
    self:render()
end

function App:data() return self.plugin.data end

function App:state(book)
    return self.plugin:state(book)
end

function App:subtitle(prefix)
    local synced = self.plugin:syncedLabel()
    if prefix then return prefix .. " · " .. synced end
    return synced
end

--- Neu würfeln: zufällige Bücher für Start und Stöbern, zufällige Reihe, drei Genres. Bücher sind
--- nach Reihe gewichtet, Reihen kommen alle gleich oft dran, unabhängig von der Zahl ihrer Bände.
function App:reroll()
    local books = self:data().books
    self.random = {
        start = lib.pickRandomBySeries(books, 8),
        book = first(lib.pickRandomBySeries(books, 1)),
        series = first(lib.pickRandom(self:data().series, 1)),
        genres = {},
        genre_books = {},
        genre_tab = 1,
    }
    local genres = {}
    for _, g in ipairs(lib.genres(books)) do
        if g.count >= 2 then table.insert(genres, g) end
    end
    for i, g in ipairs(lib.pickRandom(genres, 3)) do
        self.random.genres[i] = g
        self.random.genre_books[i] = lib.pickRandomBySeries(lib.byGenre(books, g.name), 8)
    end
end

function App:render(refresh)
    local screen = self.stack[#self.stack]
    local H = UI.height()
    local header, body_h, nav
    if screen then
        header = UI.header{ back = screen.title, on_back = function() self:pop() end }
        body_h = H - UI.headerHeight()
    else
        nav = UI.nav(self.tab, function(id) self:setTab(id) end)
        body_h = H - UI.headerHeight() - UI.navHeight()
    end
    local body, head
    if screen and screen.kind == "series" then
        head, body = self:screenSeries(body_h, screen)
    elseif screen and screen.kind == "book" then
        head, body = self:screenBook(body_h, screen)
    else
        local fn = ({ start = self.screenStart, reihen = self.screenReihen, stoebern = self.screenStoebern,
            regal = self.screenRegal, suche = self.screenSuche })[self.tab] or self.screenStart
        head, body = fn(self, body_h)
    end
    header = header or UI.header(head)
    local content = VerticalGroup:new{
        align = "left",
        header,
        UI.fixed(body, UI.width(), body_h),
    }
    if nav then table.insert(content, nav) end
    local root = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, background = UI.WHITE,
        width = UI.width(), height = H, content,
    }
    if self.rating_box then
        -- Unten rechts über dem Inhalt, 32 px über der Leiste, der weiße Saum ragt darüber hinaus.
        local RatingUI = require("grimmory/ratingui")
        local box = RatingUI.box(function(choice) self:answerRating(choice) end)
        local size, ring = box:getSize(), UI.px(RatingUI.RING)
        box.overlap_offset = { UI.width() - UI.px(32) + ring - size.w,
            H - (nav and UI.navHeight() or 0) - UI.px(32) + ring - size.h }
        root = TopFirst:new{ dimen = Geom:new{ w = UI.width(), h = H }, root, box }
    end
    if self[1] then self[1]:free() end
    self[1] = root
    UIManager:setDirty(self, refresh or "flashui")
end

--- Bitte um einen Stern zeigen. Das Kästchen bleibt, bis es beantwortet ist.
function App:showRating()
    self.rating_box = true
    self:render("ui")
end

function App:answerRating(choice)
    self.rating_box = false
    self.plugin:answerRating(choice)
    self:render("ui")
    if choice == "rate" then require("grimmory/ratingui").showQR() end
end

function App:setTab(id)
    self.tab = id
    self.stack = {}
    self:render()
end

function App:push(screen)
    table.insert(self.stack, screen)
    self:render()
end

function App:pop()
    table.remove(self.stack)
    self:render()
end

function App:pageKey()
    local screen = self.stack[#self.stack]
    if screen then return screen.kind .. ":" .. tostring(screen.name or screen.id) end
    return self.tab
end

function App:getPage() return self.page[self:pageKey()] or 1 end

function App:turnPage(delta)
    local key = self:pageKey()
    local pages = self.pages or 1
    local new = math.min(math.max((self.page[key] or 1) + delta, 1), pages)
    if new ~= (self.page[key] or 1) then
        self.page[key] = new
        self:render()
    end
end

function App:resetPage() self.page[self:pageKey()] = 1 end

function App:pager(pages)
    self.pages = pages
    return UI.pager(self:getPage(), pages, function() self:turnPage(-1) end, function() self:turnPage(1) end)
end

function App:onSwipe(_, ges)
    if ges.direction == "west" then self:turnPage(1); return true end
    if ges.direction == "east" then self:turnPage(-1); return true end
end

function App:onNextPage() self:turnPage(1); return true end
function App:onPrevPage() self:turnPage(-1); return true end

function App:onClose()
    if self.rating_box then
        self:answerRating("later") -- die Zurück-Taste wirkt wie „Später“
    elseif #self.stack > 0 then
        self:pop()
    else
        self.plugin:closeApp()
    end
    return true
end

-- Gemeinsame Teile ---------------------------------------------------------------------------

function App:openBook(book)
    self.plugin:fetchDetail(book)
    self:push({ kind = "book", id = book.id, title = book.title })
end

--- Klappentext nach dem Zeichnen nachladen und Stöbern neu zeichnen. Je Buch nur ein Versuch.
function App:fetchLater(book)
    self.fetch_tried = self.fetch_tried or {}
    if self.fetch_tried[book.id] then return end
    self.fetch_tried[book.id] = true
    UIManager:scheduleIn(0.5, function()
        if self.plugin.app ~= self then return end
        self.plugin:fetchDetail(book)
        if self.plugin:bookDescription(book) and self.tab == "stoebern" and #self.stack == 0 then
            self:render("ui")
        end
    end)
end

function App:openSeries(name)
    self:push({ kind = "series", name = name, title = name })
end

--- Kachel: Cover und Titel, optional mit Plakette.
function App:bookCell(book, cw, ch, badged)
    local cover
    if badged then
        local state, percent = self:state(book)
        cover = UI.badgedCover(self.plugin:thumbPath(book), cw, ch, book.title, state, percent,
            self.plugin:localFile(book) ~= nil)
    else
        cover = UI.cover(self.plugin:thumbPath(book), cw, ch, book.title)
    end
    return UI.tap(VerticalGroup:new{
        align = "left", cover, UI.vspan(8), UI.textbox(book.title, 22, cw, 2, { bold = true }),
    }, function() self:openBook(book) end)
end

function App:bookRow(books, cols, cw, gap, ch, badged)
    local row = { align = "top" }
    for i = 1, math.min(cols, #books) do
        if i > 1 then table.insert(row, UI.rawhspan(gap)) end
        table.insert(row, self:bookCell(books[i], cw, ch, badged))
    end
    return UI.padded(HorizontalGroup:new(row))
end

--- Bis zu drei Cover gefächert, das erste oben.
function App:fan(books, w, h, offset)
    local layers = { dimen = Geom:new{ w = w + 2 * offset, h = h } }
    for i = math.min(3, #books), 1, -1 do
        local c = UI.cover(self.plugin:thumbPath(books[i]), w, h, books[i].title)
        c.overlap_offset = { (i - 1) * offset, 0 }
        table.insert(layers, c)
    end
    return OverlapGroup:new(layers)
end

function App:seriesInfo(s)
    local books = lib.seriesBooks(self:data().books, s.seriesName)
    local states = lib.seriesSlots(s.seriesTotal, books, function(b) return (self:state(b)) end)
    local genre = ""
    for _, b in ipairs(books) do
        if first(b.categories) then genre = first(b.categories); break end
    end
    return books, states, genre
end

function App:seriesSummaryText(states)
    local read, reading, missing = countRead(states), nil, 0
    for i, st in ipairs(states) do
        if st == "reading" and not reading then reading = i end
        if st == "missing" then missing = missing + 1 end
    end
    local parts = { read == #states and T(_("alle %1 gelesen"), #states)
        or T(_("%1 von %2 gelesen"), read, #states) }
    if reading then table.insert(parts, T(_("Band %1 angefangen"), reading)) end
    if missing > 0 then table.insert(parts, count(missing, "%1 fehlt", "%1 fehlen")) end
    return table.concat(parts, " · ")
end

function App:searchField(placeholder, value, on_change)
    local h = UI.px(84)
    local text = value ~= "" and UI.text(value, 28, { max_width = innerWidth() - UI.px(100) })
        or UI.text(placeholder, 28, { color = UI.GRAY })
    local field = UI.FrameContainer:new{
        bordersize = UI.px(3), radius = UI.px(12), padding = 0, padding_left = UI.px(24),
        UI.LeftContainer:new{ dimen = Geom:new{ w = innerWidth() - UI.px(30), h = h - UI.px(6) },
            HorizontalGroup:new{ align = "center", UI.icon("appbar.search", 36), UI.hspan(16), text } },
    }
    return UI.padded(UI.tap(field, function()
        local dialog
        dialog = InputDialog:new{
            title = placeholder,
            input = value,
            buttons = { {
                { text = _("Leeren"), callback = function() UIManager:close(dialog); on_change("") end },
                { text = _("Suchen"), is_enter_default = true, callback = function()
                    local q = dialog:getInputText()
                    UIManager:close(dialog)
                    on_change(q)
                end },
            } },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end), 24, 0)
end

function App:choose(title, options, on_pick)
    local dialog
    local rows = {}
    for _, opt in ipairs(options) do
        table.insert(rows, { { text = opt.label, callback = function()
            UIManager:close(dialog)
            on_pick(opt.value)
        end } })
    end
    dialog = ButtonDialog:new{ title = title, buttons = rows, rows_per_page = 8 }
    UIManager:show(dialog)
end

-- Start --------------------------------------------------------------------------------------

--- Gruß nach Tageszeit statt eines festen Titels.
local function greeting()
    local hour = tonumber(os.date("%H"))
    if hour >= 5 and hour < 11 then return _("Guten Morgen") end
    if hour >= 11 and hour < 18 then return _("Guten Tag") end
    if hour >= 18 and hour < 23 then return _("Guten Abend") end
    return _("Gute Nacht")
end

--- „grimmory.example.com · letzter Abgleich vor 2 Min.“: nur der Hostname, ohne Schema und Port.
function App:startSubtitle()
    local host = self.plugin:setting("server"):match("^%a+://([^/:]+)")
    local ago = self.plugin:syncedAgo()
    local synced = ago and T(_("letzter Abgleich %1"), ago) or _("noch nicht abgeglichen")
    return host and (host .. " · " .. synced) or synced
end

function App:screenStart(h)
    local head = { title = greeting(), subtitle = self:startSubtitle(), on_menu = function() self.plugin:showMenu() end }
    local data = self:data()
    if #data.books == 0 then return head, self:emptyHint() end
    local parts = { align = "left" }
    local used = 0
    local current = lib.continueReading(data.books, function(b) return (self:state(b)) end)
    if current then
        local block = self:continueBlock(current)
        table.insert(parts, block)
        used = used + block:getSize().h
    end
    local cols, cw, gap = columns(220)
    local headings = { UI.heading(_("Zufällige Bücher")), UI.heading(_("Zuletzt hinzugefügt")) }
    -- Cover so hoch, dass beide Zeilen mit etwas Luft zur Leiste passen, höchstens so hoch, wie die Breite erlaubt. Wird es zu klein, nur eine Zeile.
    local extra = headings[1]:getSize().h + UI.px(8) + titleHeight()
    local rows = 2
    local ch = math.min(UI.coverHeight(cw), math.floor((h - used - UI.px(16)) / 2) - extra)
    if ch < UI.px(150) then
        rows = 1
        ch = math.min(UI.coverHeight(cw), h - used - UI.px(16) - extra)
    end
    if ch >= UI.px(100) then
        table.insert(parts, headings[1])
        table.insert(parts, self:bookRow(self.random.start, cols, cw, gap, ch))
        if rows == 2 then
            table.insert(parts, headings[2])
            table.insert(parts, self:bookRow(lib.recent(data.books, cols), cols, cw, gap, ch))
        end
    end
    return head, VerticalGroup:new(parts)
end

function App:continueBlock(book)
    local state, percent = self:state(book)
    local text_w = innerWidth() - UI.px(180) - UI.px(36)
    local series = book.seriesName and T(_("%1 · Band %2"), book.seriesName, lib.bandLabel(book.seriesNumber)) or
        table.concat(book.authors or {}, ", ")
    local col = VerticalGroup:new{
        align = "left",
        UI.overline(_("WEITERLESEN")), UI.vspan(10),
        UI.textbox(book.title, 40, text_w, 2, { bold = true, serif = true }), UI.vspan(8),
        UI.text(series, 26, { color = UI.DARK, max_width = text_w }), UI.vspan(24),
        UI.progressBar(state == "reading" and percent or 0, text_w, UI.px(18)), UI.vspan(10),
        UI.text(string.format("%d %%", percent or 0), 24),
    }
    local row = HorizontalGroup:new{ align = "top",
        UI.cover(self.plugin:thumbPath(book), UI.px(180), UI.coverHeight(UI.px(180)), book.title), UI.hspan(36), col }
    return UI.tap(VerticalGroup:new{
        UI.padded(row, 32, 32), UI.line(UI.width(), UI.px(2)),
    }, function()
        local file = self.plugin:localFile(book)
        if file then self.plugin:openFile(file, book) else self:openBook(book) end
    end)
end

function App:emptyHint()
    local text = self.plugin:isConfigured()
        and _("Noch keine Bücher. Im Menü oben links „Jetzt abgleichen“ wählen.")
        or _("Noch kein Server eingerichtet. Im Menü oben links die Einstellungen öffnen.")
    return UI.padded(UI.textbox(text, 28, innerWidth()), 48, 0)
end

-- Reihen -------------------------------------------------------------------------------------

function App:sortedSeries()
    local list = {}
    local query = self.reihen_query or ""
    for _, s in ipairs(self:data().series) do
        local hit = query == "" or #lib.search({ { title = s.seriesName, authors = s.authors } }, query) > 0
        if hit then table.insert(list, s) end
    end
    if self.reihen_sort == "name" then
        table.sort(list, function(a, b) return (a.seriesName or "") < (b.seriesName or "") end)
    else
        local last = {}
        for _, b in ipairs(self:data().books) do
            if b.seriesName and (b.lastReadTime or "") > (last[b.seriesName] or "") then
                last[b.seriesName] = b.lastReadTime
            end
        end
        table.sort(list, function(a, b)
            local la, lb = last[a.seriesName] or "", last[b.seriesName] or ""
            if la ~= lb then return la > lb end
            return (a.latestAddedOn or "") > (b.latestAddedOn or "")
        end)
    end
    return list
end

function App:screenReihen(h)
    local all = self:data().series
    local head = { title = _("Reihen"), subtitle = self:subtitle(count(#all, "%1 Reihe", "%1 Reihen")),
        on_menu = function() self.plugin:showMenu() end }
    local search = self:searchField(_("Reihe oder Autor suchen"), self.reihen_query or "", function(q)
        self.reihen_query = q
        self:resetPage()
        self:render()
    end)
    local row_h = UI.px(164)
    local fixed = search:getSize().h + UI.px(104) + UI.px(2)
    local per_page = math.max(1, math.floor((h - fixed) / row_h))
    local slice, pages = lib.paginate(self:sortedSeries(), self:getPage(), per_page)
    local sort = UI.dropdown(_("Sortiert:"), self.reihen_sort == "name" and _("Name") or _("Zuletzt gelesen"), function()
        self:choose(_("Sortieren"), { { label = _("Zuletzt gelesen"), value = "read" }, { label = _("Name"), value = "name" } },
            function(v) self.reihen_sort = v; self:resetPage(); self:render() end)
    end)
    local parts = { align = "left", search,
        UI.padded(UI.spread(sort, self:pager(pages), innerWidth()), 16, 16), UI.line(UI.width(), UI.px(2)) }
    for _, s in ipairs(slice) do table.insert(parts, self:seriesRow(s, row_h)) end
    return head, VerticalGroup:new(parts)
end

function App:seriesRow(s, row_h)
    local books, states, genre = self:seriesInfo(s)
    local fan = self:fan(books, UI.px(100), UI.coverHeight(UI.px(100)), UI.px(40))
    local chevron = UI.icon("chevron.right", 40)
    local text_w = innerWidth() - fan:getSize().w - UI.px(32) - chevron:getSize().w - UI.px(32)
    local meta = { first(s.authors) }
    if genre ~= "" then table.insert(meta, genre) end
    local read = countRead(states)
    table.insert(meta, read == #states and #states > 0 and T(_("alle %1 gelesen"), #states)
        or T(_("%1 von %2 gelesen"), read, #states))
    local col = VerticalGroup:new{
        align = "left",
        UI.text(s.seriesName, 34, { bold = true, serif = true, max_width = text_w }),
        UI.text(table.concat(meta, " · "), 24, { color = UI.DARK, max_width = text_w }),
        UI.vspan(14),
        UI.slots(states, text_w),
    }
    local row = HorizontalGroup:new{ align = "center", fan, UI.hspan(32), col, UI.hspan(32), chevron }
    return rowBox(row, row_h, function() self:openSeries(s.seriesName) end)
end

-- Eine Reihe ---------------------------------------------------------------------------------

function App:screenSeries(h, screen)
    local s
    for _, item in ipairs(self:data().series) do
        if item.seriesName == screen.name then s = item; break end
    end
    s = s or { seriesName = screen.name, authors = {} }
    local books, states = self:seriesInfo(s)
    local text_w = innerWidth() - UI.px(218) - UI.px(40)
    local in_lib = 0
    for _, st in ipairs(states) do if st ~= "missing" then in_lib = in_lib + 1 end end
    local hero = HorizontalGroup:new{ align = "center",
        self:fan(books, UI.px(130), UI.coverHeight(UI.px(130)), UI.px(44)), UI.hspan(40),
        VerticalGroup:new{ align = "left",
            UI.textbox(s.seriesName, 52, text_w, 2, { bold = true, serif = true }),
            UI.text(T(_("%1 · %2, %3 in Grimmory"), first(s.authors) or "", count(#states, "%1 Band", "%1 Bände"), #books),
                26, { color = UI.DARK, max_width = text_w }),
            UI.vspan(18), UI.slots(states, text_w, 28), UI.vspan(10),
            UI.text(self:seriesSummaryText(states), 24, { color = UI.GRAY, max_width = text_w }),
        } }

    local missing, missing_kb = {}, 0
    for _, b in ipairs(books) do
        if not self.plugin:localFile(b) then
            table.insert(missing, b)
            missing_kb = missing_kb + (tonumber(b.fileSizeKb) or 0)
        end
    end
    local row_h = UI.px(84)
    local hero_box = UI.padded(hero, 28, 24)
    local fixed = hero_box:getSize().h + UI.px(88) + UI.px(2)
    local per_page = math.max(1, math.floor((h - fixed) / row_h))
    local slice, pages = lib.paginate(books, self:getPage(), per_page)
    local load = #missing > 0 and UI.button(T(N_("%1 fehlenden laden · %2", "%1 fehlende laden · %2", #missing),
        #missing, lib.formatSize(missing_kb)), function() self.plugin:downloadMany(missing, function() self:render() end) end)
    local parts = { align = "left", hero_box,
        UI.padded(UI.spread(load or nil, self:pager(pages), innerWidth()), 0, 16), UI.line(UI.width(), UI.px(2)) }
    for _, b in ipairs(slice) do
        local state, percent = self:state(b)
        local status = UI.statusLine(state, percent, self.plugin:localFile(b) ~= nil, lib.formatSize(b.fileSizeKb),
            UI.px(210))
        local info = {}
        if lib.year(b.publishedDate) ~= "" then table.insert(info, lib.year(b.publishedDate)) end
        if b.pageCount then table.insert(info, count(b.pageCount, "%1 Seite", "%1 Seiten")) end
        local title_w = innerWidth() - UI.px(120) - status:getSize().w - UI.px(20)
        local left = HorizontalGroup:new{ align = "center",
            UI.LeftContainer:new{ dimen = Geom:new{ w = UI.px(120), h = row_h - 1 },
                UI.text(lib.bandLabel(b.seriesNumber), 32, { bold = true, serif = true }) },
            VerticalGroup:new{ align = "left",
                UI.text(b.title, 28, { bold = true, max_width = title_w }),
                UI.text(table.concat(info, " · "), 22, { color = UI.GRAY, max_width = title_w }) },
        }
        table.insert(parts, rowBox(UI.spread(left, status, innerWidth()), row_h, function() self:openBook(b) end))
    end
    return nil, VerticalGroup:new(parts)
end

-- Stöbern ------------------------------------------------------------------------------------

function App:screenStoebern(h)
    local head = { title = _("Stöbern"), subtitle = _("Zufällig aus deiner Bibliothek"),
        on_menu = function() self.plugin:showMenu() end,
        right = UI.button(_("Neu würfeln"), function() self:reroll(); self:render() end, { height = UI.px(80) }) }
    local data = self:data()
    if #data.books == 0 then return head, self:emptyHint() end
    local parts = { align = "left" }
    local s = self.random.series
    if s then
        local books, states = self:seriesInfo(s)
        local fan = self:fan(books, UI.px(100), UI.coverHeight(UI.px(100)), UI.px(40))
        local text_w = innerWidth() - fan:getSize().w - UI.px(32)
        local block = HorizontalGroup:new{ align = "top", fan, UI.hspan(32), VerticalGroup:new{ align = "left",
            UI.overline(_("ZUFÄLLIGE REIHE")),
            UI.text(s.seriesName, 40, { bold = true, serif = true, max_width = text_w }),
            UI.text((first(s.authors) or "") .. " · " .. count(#states, "%1 Band", "%1 Bände"), 22,
                { color = UI.GRAY, max_width = text_w }),
            UI.vspan(14), UI.slots(states, text_w), UI.vspan(10),
            UI.text(self:seriesSummaryText(states), 22, { max_width = text_w }),
        } }
        table.insert(parts, UI.tap(VerticalGroup:new{ UI.padded(block, 24, 24), UI.line(UI.width(), UI.px(2)) },
            function() self:openSeries(s.seriesName) end))
    end
    local b = self.random.book
    if b then
        local text_w = innerWidth() - UI.px(180) - UI.px(32)
        local meta = {}
        if b.pageCount then table.insert(meta, count(b.pageCount, "%1 Seite", "%1 Seiten")) end
        if b.publishedDate then table.insert(meta, lib.year(b.publishedDate)) end
        if b.seriesName then table.insert(meta, b.seriesName .. " " .. lib.bandLabel(b.seriesNumber)) end
        if first(b.authors) then table.insert(meta, first(b.authors)) end
        local pills = { align = "center" }
        local labels = {}
        for _, c in ipairs(b.categories or {}) do table.insert(labels, c) end
        for _, t in ipairs(b.tags or {}) do table.insert(labels, t) end
        for i, label in ipairs(labels) do
            if i > 3 then break end
            if i > 1 then table.insert(pills, UI.hspan(10)) end
            table.insert(pills, UI.pill(label))
        end
        local col = { align = "left",
            UI.overline(_("ZUFÄLLIGES BUCH")),
            UI.textbox(b.title, 40, text_w, 2, { bold = true, serif = true }),
            UI.text(table.concat(meta, " · "), 22, { color = UI.GRAY, max_width = text_w }),
        }
        if #pills > 0 then
            table.insert(col, UI.vspan(12))
            table.insert(col, HorizontalGroup:new(pills))
        end
        -- Klappentext immer in voller Höhe, sonst springt das Layout, wenn er nachgeladen wird.
        local desc = self.plugin:bookDescription(b)
        table.insert(col, UI.vspan(12))
        table.insert(col, UI.fixed(desc and UI.textbox(desc, 24, text_w, 4) or UI.vspan(0),
            text_w, UI.textboxHeight(24, 4)))
        if not desc then self:fetchLater(b) end
        local block = HorizontalGroup:new{ align = "top",
            UI.cover(self.plugin:thumbPath(b), UI.px(180), UI.coverHeight(UI.px(180)), b.title), UI.hspan(32),
            VerticalGroup:new(col) }
        table.insert(parts, UI.tap(VerticalGroup:new{ UI.padded(block, 24, 24), UI.line(UI.width(), UI.px(2)) },
            function() self:openBook(b) end))
    end
    if #self.random.genres > 0 then
        table.insert(parts, UI.padded(UI.overline(_("ZUFÄLLIGE GENRES")), 20, 6))
        local tab_w = math.floor(innerWidth() / #self.random.genres)
        local tabs = { align = "top" }
        for i, g in ipairs(self.random.genres) do
            local sel = i == self.random.genre_tab
            table.insert(tabs, UI.tap(VerticalGroup:new{
                UI.CenterContainer:new{ dimen = Geom:new{ w = tab_w, h = UI.px(76) }, HorizontalGroup:new{
                    align = "center",
                    UI.text(g.name, 32, { bold = sel, serif = true, max_width = tab_w - UI.px(60) }),
                    UI.hspan(10), UI.text(tostring(g.count), 22, { color = UI.GRAY }) } },
                UI.line(tab_w, UI.px(8), sel and UI.BLACK or UI.WHITE),
            }, function() self.random.genre_tab = i; self:render("ui") end))
        end
        table.insert(parts, UI.padded(VerticalGroup:new{ HorizontalGroup:new(tabs), UI.line(innerWidth(), UI.px(2)) }))
        local used = 0
        for _, p in ipairs(parts) do used = used + p:getSize().h end
        local cols, cw, gap = columns(220)
        local ch = math.min(UI.coverHeight(cw), h - used - UI.px(20) - UI.px(8) - titleHeight() - UI.px(16))
        if ch > UI.px(120) then
            table.insert(parts, UI.vspan(20))
            table.insert(parts, self:bookRow(self.random.genre_books[self.random.genre_tab] or {}, cols, cw, gap, ch))
        end
    end
    return head, VerticalGroup:new(parts)
end

-- Regal --------------------------------------------------------------------------------------

function App:screenRegal(h)
    local data = self:data()
    local head = { title = _("Regal"), subtitle = self:subtitle(count(#data.books, "%1 Buch", "%1 Bücher")),
        on_menu = function() self.plugin:showMenu() end }
    local books = lib.byGenre(lib.recent(data.books, #data.books), self.regal_genre)
    local genre = UI.HorizontalGroup:new{ align = "center",
        UI.text(_("Genre:"), 26, { color = UI.GRAY }), UI.hspan(12),
        UI.tap(UI.box(HorizontalGroup:new{ align = "center",
            UI.icon("appbar.search", 28), UI.hspan(10),
            UI.text(self.regal_genre or _("Alle Genres"), 26, { bold = true, max_width = UI.px(260) }) },
            UI.px(380), UI.px(72), { radius = 12 }), function() self:pickGenre() end) }
    local cols, cw, gap = columns(220)
    local fixed = UI.px(104) + UI.px(2) + UI.px(8) + UI.px(16) -- Kopfzeile, Linie, Abstand, Luft unten
    local cell_h = UI.px(250) + UI.px(8) + titleHeight()
    local rows = math.max(1, math.floor((h - fixed + UI.px(20)) / (cell_h + UI.px(20))))
    local ch = math.min(UI.coverHeight(cw),
        math.floor((h - fixed - (rows - 1) * UI.px(20)) / rows) - UI.px(8) - titleHeight())
    local slice, pages = lib.paginate(books, self:getPage(), cols * rows)
    local parts = { align = "left",
        UI.padded(UI.spread(genre, self:pager(pages), innerWidth()), 16, 16),
        UI.line(UI.width(), UI.px(2)), UI.vspan(8) }
    for r = 1, rows do
        local row_books = {}
        for c = 1, cols do row_books[c] = slice[(r - 1) * cols + c] end
        if #row_books == 0 then break end
        if r > 1 then table.insert(parts, UI.vspan(20)) end
        table.insert(parts, self:bookRow(row_books, cols, cw, gap, ch, true))
    end
    return head, VerticalGroup:new(parts)
end

--- Genre wählen, mit Suche bei vielen Genres.
function App:pickGenre(filter)
    local options = { { label = _("Alle Genres") .. " · " .. #self:data().books, value = false } }
    if not filter then
        table.insert(options, { label = _("Genre suchen …"), value = "__search" })
    end
    for _, g in ipairs(lib.genres(self:data().books)) do
        if not filter or #lib.search({ { title = g.name } }, filter) > 0 then
            table.insert(options, { label = string.format("%s · %d", g.name, g.count), value = g.name })
        end
    end
    self:choose(_("Genre"), options, function(v)
        if v == "__search" then
            local dialog
            dialog = InputDialog:new{
                title = _("Genre suchen"),
                buttons = { { { text = _("Suchen"), is_enter_default = true, callback = function()
                    local q = dialog:getInputText()
                    UIManager:close(dialog)
                    self:pickGenre(q)
                end } } },
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
            return
        end
        self.regal_genre = v or nil
        self:resetPage()
        self:render()
    end)
end

-- Suche --------------------------------------------------------------------------------------

local FILTERS = {
    { id = "device", label = nil },
    { id = "reading", label = _("Angefangen") },
    { id = "unread", label = _("Ungelesen") },
    { id = "read", label = _("Gelesen") },
}

local SORTS = {
    { value = "added", label = _("Zuletzt hinzugefügt") },
    { value = "title", label = _("Titel") },
    { value = "size", label = _("Größe") },
}

function App:searchResults()
    local list = {}
    for _, b in ipairs(lib.search(self:data().books, self.search_query)) do
        local keep = true
        if self.search_filter == "device" then
            keep = self.plugin:localFile(b) ~= nil
        elseif self.search_filter then
            keep = (self:state(b)) == self.search_filter
        end
        if keep then table.insert(list, b) end
    end
    if self.search_sort == "title" then
        table.sort(list, function(a, b) return (a.title or "") < (b.title or "") end)
    elseif self.search_sort == "size" then
        table.sort(list, function(a, b) return (tonumber(a.fileSizeKb) or 0) > (tonumber(b.fileSizeKb) or 0) end)
    else
        table.sort(list, function(a, b) return (a.addedOn or "") > (b.addedOn or "") end)
    end
    return list
end

function App:screenSuche(h)
    local data = self:data()
    local results = self:searchResults()
    local subtitle
    if self.search_filter == "device" then
        local kb = 0
        for _, b in ipairs(results) do kb = kb + (tonumber(b.fileSizeKb) or 0) end
        subtitle = count(#results, "%1 Buch", "%1 Bücher") .. " · " .. lib.formatSize(kb)
    else
        subtitle = self:subtitle(count(#data.books, "%1 Buch", "%1 Bücher"))
    end
    local head = { title = _("Suche"), subtitle = subtitle, on_menu = function() self.plugin:showMenu() end }
    local search = self:searchField(_("Titel, Autor oder Reihe"), self.search_query, function(q)
        self.search_query = q
        self:resetPage()
        self:render()
    end)
    local on_device = 0
    for _, b in ipairs(data.books) do if self.plugin:localFile(b) then on_device = on_device + 1 end end
    local chips = { align = "center" }
    for i, f in ipairs(FILTERS) do
        local active = self.search_filter == f.id
        local label = f.label or string.format("%s · %d", UI.ON_DEVICE, on_device)
        if i > 1 then table.insert(chips, UI.hspan(12)) end
        table.insert(chips, UI.tap(UI.pill(label, { active = active, height = 56 }), function()
            self.search_filter = (not active) and f.id or nil
            self:resetPage()
            self:render()
        end))
    end
    local sort_label = SORTS[1].label
    for _, s in ipairs(SORTS) do if s.value == self.search_sort then sort_label = s.label end end
    local sort = UI.dropdown(_("Sortiert:"), sort_label, function()
        self:choose(_("Sortieren"), SORTS, function(v) self.search_sort = v; self:resetPage(); self:render() end)
    end)
    local row_h = UI.px(122)
    local chip_row = UI.padded(HorizontalGroup:new(chips), 16, 0)
    local fixed = search:getSize().h + chip_row:getSize().h + UI.px(104) + UI.px(2)
    local per_page = math.max(1, math.floor((h - fixed) / row_h))
    local slice, pages = lib.paginate(results, self:getPage(), per_page)
    local parts = { align = "left", search, chip_row,
        UI.padded(UI.spread(sort, self:pager(pages), innerWidth()), 16, 16), UI.line(UI.width(), UI.px(2)) }
    for _, b in ipairs(slice) do table.insert(parts, self:listRow(b, row_h)) end
    return head, VerticalGroup:new(parts)
end

function App:listRow(b, row_h)
    local state, percent = self:state(b)
    local file = self.plugin:localFile(b)
    local right
    if self.search_filter == "device" and file then
        right = HorizontalGroup:new{ align = "center",
            UI.text(lib.formatSize(b.fileSizeKb), 24, { bold = true }), UI.hspan(20),
            UI.tap(UI.box(UI.icon("close", 30), UI.px(64), UI.px(64), { radius = 10 }), function()
                self:confirmRemove(b)
            end) }
    else
        right = UI.statusLine(state, percent, file ~= nil, lib.formatSize(b.fileSizeKb), UI.px(190))
    end
    local text_w = innerWidth() - UI.px(76) - UI.px(28) - right:getSize().w - UI.px(28)
    local sub = { first(b.authors) }
    if b.seriesName then table.insert(sub, T(_("%1 · Band %2"), b.seriesName, lib.bandLabel(b.seriesNumber))) end
    local left = HorizontalGroup:new{ align = "center",
        UI.cover(self.plugin:thumbPath(b), UI.px(76), UI.coverHeight(UI.px(76)), b.title), UI.hspan(28),
        VerticalGroup:new{ align = "left",
            UI.text(b.title, 28, { bold = true, max_width = text_w }),
            UI.text(table.concat(sub, " · "), 22, { color = UI.GRAY, max_width = text_w }) } }
    return rowBox(UI.spread(UI.tap(left, function() self:openBook(b) end), right, innerWidth()), row_h)
end

function App:confirmRemove(b)
    UIManager:show(ConfirmBox:new{
        text = T(_("„%1“ vom Gerät entfernen? In Grimmory bleibt das Buch."), b.title),
        ok_text = _("Entfernen"),
        ok_callback = function()
            self.plugin:removeDownload(b)
            self:render()
        end,
    })
end

-- Buch ---------------------------------------------------------------------------------------

function App:screenBook(h, screen)
    local b
    for _, item in ipairs(self:data().books) do
        if item.id == screen.id then b = item; break end
    end
    if not b then return nil, self:emptyHint() end
    local file = self.plugin:localFile(b)
    local state = self:state(b)
    local text_w = innerWidth() - UI.px(320) - UI.px(44)
    local col = { align = "left" }
    if b.seriesName then
        local total
        for _, s in ipairs(self:data().series) do
            if s.seriesName == b.seriesName and s.seriesTotal then total = s.seriesTotal end
        end
        local band = lib.bandLabel(b.seriesNumber)
        table.insert(col, UI.overline(total and T(_("%1 · BAND %2 VON %3"), b.seriesName:upper(), band, total)
            or T(_("%1 · BAND %2"), b.seriesName:upper(), band)))
        table.insert(col, UI.vspan(12))
    end
    table.insert(col, UI.textbox(b.title, 52, text_w, 3, { bold = true, serif = true }))
    table.insert(col, UI.vspan(8))
    table.insert(col, UI.text(table.concat(b.authors or {}, ", "), 32, { max_width = text_w }))
    table.insert(col, UI.vspan(28))
    local facts = {
        { _("Verlag"), table.concat({ b.publisher or "", lib.year(b.publishedDate) }, b.publisher and b.publishedDate
            and ", " or "") },
        { _("Umfang"), b.pageCount and count(b.pageCount, "%1 Seite", "%1 Seiten") or "" },
        { _("Datei"), string.format("%s · %s", b.primaryFileType or "", lib.formatSize(b.fileSizeKb)) },
        { _("Kategorie"), table.concat(b.categories or {}, ", ") },
        { "Goodreads", b.goodreadsRating and T(_("%1 von 5"), lib.decimal(b.goodreadsRating)) or "" },
    }
    for _, f in ipairs(facts) do
        if f[2] ~= "" then
            table.insert(col, HorizontalGroup:new{ align = "top",
                UI.LeftContainer:new{ dimen = Geom:new{ w = UI.px(170), h = UI.px(40) },
                    UI.text(f[1], 26, { color = UI.GRAY }) },
                UI.text(f[2], 26, { max_width = text_w - UI.px(170) }) })
        end
    end
    local top = HorizontalGroup:new{ align = "top",
        UI.cover(self.plugin:thumbPath(b), UI.px(320), UI.coverHeight(UI.px(320)), b.title), UI.hspan(44), VerticalGroup:new(col) }

    local primary = file
        and UI.button(_("Lesen"), function() self.plugin:openFile(file, b) end,
            { primary = true, width = innerWidth(), height = UI.px(112), size = 32 })
        or UI.button(T(_("Herunterladen und lesen · %1"), lib.formatSize(b.fileSizeKb)),
            function() self.plugin:downloadAndOpen(b) end,
            { primary = true, width = innerWidth(), height = UI.px(112), size = 32 })
    local half = math.floor((innerWidth() - UI.px(20)) / 2)
    local secondary = { align = "center",
        UI.button(state == "read" and _("Als ungelesen markieren") or _("Als gelesen markieren"), function()
            self.plugin:markRead(b, state ~= "read")
            self:render()
        end, { width = b.seriesName and half or innerWidth(), height = UI.px(96), size = 28 }) }
    if b.seriesName then
        table.insert(secondary, UI.hspan(20))
        table.insert(secondary, UI.button(_("Ganze Reihe ansehen"), function() self:openSeries(b.seriesName) end,
            { width = half, height = UI.px(96), size = 28 }))
    end
    local parts = { align = "left", UI.padded(top, 40, 40), UI.padded(primary), UI.vspan(20),
        UI.padded(HorizontalGroup:new(secondary)) }
    local used = 0
    for _, p in ipairs(parts) do used = used + p:getSize().h end
    local desc = self.plugin:bookDescription(b)
    if desc and h - used > UI.px(160) then
        local lh = math.floor(1.5 * UI.px(28))
        local lines = math.max(1, math.floor((h - used - UI.px(40) - UI.px(54) - UI.px(70)) / lh))
        table.insert(parts, UI.padded(VerticalGroup:new{ align = "left",
            UI.text(_("Klappentext"), 30, { bold = true }), UI.vspan(12),
            UI.textbox(desc, 28, innerWidth(), lines, { line_height = 0.5 }) }, 40, 0))
    end
    if file then
        table.insert(parts, UI.padded(UI.tap(UI.text(_("Vom Gerät entfernen"), 26, { bold = true, color = UI.DARK }),
            function() self:confirmRemove(b) end), 20, 0))
    end
    return nil, VerticalGroup:new(parts)
end

return App
