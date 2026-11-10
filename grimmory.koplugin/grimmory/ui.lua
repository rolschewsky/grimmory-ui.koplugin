--[[--
Bausteine der Oberfläche: Kopfzeile, Leiste unten, Blättern, Cover, Plaketten, Kästchen je Band.

Alle Maße stammen aus den Entwürfen und sind Pixel bei 300 ppi (Kindle Paperwhite). `UI.px`
rechnet sie auf die Pixeldichte des Geräts um, damit Schrift und Cover überall physisch gleich
groß sind. Auf größeren Bildschirmen passen so mehr Spalten und Zeilen.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local _ = require("grimmory/i18n")

local Screen = Device.screen

local UI = {}

UI.BLACK = Blitbuffer.COLOR_BLACK
UI.WHITE = Blitbuffer.COLOR_WHITE
UI.GRAY = Blitbuffer.COLOR_GRAY_5        -- Zweitinformation, #555
UI.DARK = Blitbuffer.COLOR_GRAY_3        -- #333
UI.LINE = Blitbuffer.COLOR_GRAY_B        -- Trennlinien
UI.SECTION = Blitbuffer.COLOR_GRAY_E     -- Abschnittsköpfe
UI.MISSING = Blitbuffer.COLOR_LIGHT_GRAY -- Band fehlt in Grimmory

local factor = (Screen:getDPI() or 300) / 300
local font_unit = Screen:scaleBySize(1000) / 1000

--- Entwurfs-Pixel (300 ppi) in Geräte-Pixel.
function UI.px(v)
    return math.max(1, math.floor(v * factor + 0.5))
end

function UI.width() return Screen:getWidth() end
function UI.height() return Screen:getHeight() end

local FONTS = {
    sans = "NotoSans-Regular.ttf", sansb = "NotoSans-Bold.ttf",
    serif = "NotoSerif-Regular.ttf", serifb = "NotoSerif-Bold.ttf",
}

--- Schrift in Entwurfs-Pixeln. Font:getFace skaliert selbst noch einmal, das wird hier ausgeglichen.
function UI.face(size, bold, serif)
    local key = (serif and "serif" or "sans") .. (bold and "b" or "")
    return Font:getFace(FONTS[key], math.max(6, math.floor(size * factor / font_unit + 0.5)))
end

function UI.vspan(h) return VerticalSpan:new{ width = UI.px(h) } end
function UI.hspan(w) return HorizontalSpan:new{ width = UI.px(w) } end
function UI.rawhspan(w) return HorizontalSpan:new{ width = math.max(0, w) } end

function UI.line(w, h, color)
    return LineWidget:new{ background = color or UI.BLACK, dimen = Geom:new{ w = w, h = h } }
end

--- Einzeiliger Text, bei Überlänge mit „…“.
function UI.text(str, size, o)
    o = o or {}
    return TextWidget:new{
        text = str or "",
        face = UI.face(size, o.bold, o.serif),
        fgcolor = o.color or UI.BLACK,
        max_width = o.max_width,
    }
end

--- Höhe von `lines` Zeilen in UI.textbox, um Raster vorab auszurechnen. Gemessen, weil
--- TextBoxWidget unter die letzte Zeile noch Platz für Unterlängen legt.
local measured = {}
function UI.textboxHeight(size, lines, o)
    o = o or {}
    local key = table.concat({ size, lines, tostring(o.bold), tostring(o.serif), o.line_height or "" }, ":")
    if not measured[key] then
        local box = UI.textbox(string.rep("Mg\n", lines - 1) .. "Mg", size, UI.px(400), nil, o)
        measured[key] = box:getSize().h
        box:free()
    end
    return measured[key]
end

--- Mehrzeiliger Text, höchstens `lines` Zeilen, dann „…“.
function UI.textbox(str, size, width, lines, o)
    o = o or {}
    local args = {
        text = str or "",
        face = UI.face(size, o.bold, o.serif),
        width = width,
        fgcolor = o.color or UI.BLACK,
        alignment = o.align or "left",
        line_height = o.line_height or 0.25,
    }
    local box = TextBoxWidget:new(args)
    if not lines then return box end
    local lh = math.floor((1 + args.line_height) * args.face.size + 0.5)
    if box:getSize().h <= lh * lines + (box.line_glyph_extra_height or 0) then return box end
    box:free()
    local limited = {}
    for k, v in pairs(args) do limited[k] = v end
    limited.height = lh * lines
    limited.height_overflow_show_ellipsis = true
    return TextBoxWidget:new(limited)
end

function UI.icon(name, size, o)
    o = o or {}
    return IconWidget:new{ icon = name, width = UI.px(size), height = UI.px(size), dim = o.dim }
end

-- Antippbarer Bereich ------------------------------------------------------------------------

local Tap = InputContainer:extend{ callback = nil, hold_callback = nil }

function Tap:init()
    local range = function() return self.dimen end
    self.ges_events = {
        GrimmoryTap = { GestureRange:new{ ges = "tap", range = range } },
        GrimmoryHold = { GestureRange:new{ ges = "hold", range = range } },
    }
end

--- Ob die Geste auf dieser Fläche liegt. Eine äußere Fläche reicht ihr Ereignis erst an die inneren
--- weiter; ohne diese Prüfung löste ein Tippen irgendwo im Kästchen die erste innere Fläche aus.
local function inside(self, ges)
    return not (ges and ges.pos and self.dimen) or self.dimen:contains(ges.pos)
end

function Tap:onGrimmoryTap(_, ges)
    if self.callback and inside(self, ges) then self.callback(); return true end
end

function Tap:onGrimmoryHold(_, ges)
    if self.hold_callback and inside(self, ges) then self.hold_callback(); return true end
end

function UI.tap(widget, callback, hold_callback)
    return Tap:new{ callback = callback, hold_callback = hold_callback, widget }
end

-- Rahmen und Knöpfe --------------------------------------------------------------------------

--- Rahmen mit fester Außengröße w × h, Inhalt mittig.
function UI.box(child, w, h, o)
    o = o or {}
    local b = o.border == 0 and 0 or UI.px(o.border or 2)
    return FrameContainer:new{
        bordersize = b, padding = 0, margin = 0,
        radius = o.radius and UI.px(o.radius) or nil,
        color = o.color or UI.BLACK,
        background = o.background or UI.WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = w - 2 * b, h = h - 2 * b }, child },
    }
end

--- Knopf mit Text. o: primary (schwarz), width, height, size.
function UI.button(label, callback, o)
    o = o or {}
    local text = UI.text(label, o.size or 26, { bold = true, color = o.primary and UI.WHITE or UI.BLACK })
    local w = o.width or (text:getSize().w + UI.px(48))
    local h = o.height or UI.px(72)
    local box = UI.box(text, w, h, {
        border = o.border or 2, radius = 12,
        background = o.primary and UI.BLACK or UI.WHITE,
    })
    return UI.tap(box, callback)
end

--- Auswahlfeld wie „Sortiert: Reihe“.
function UI.dropdown(label, value, callback)
    local row = HorizontalGroup:new{
        align = "center",
        UI.text(label, 26, { color = UI.GRAY }),
        UI.hspan(10),
        UI.text(value, 26, { bold = true }),
        UI.hspan(10),
        UI.icon("control.expand", 28),
    }
    return UI.tap(UI.box(row, row:getSize().w + UI.px(48), UI.px(72), { radius = 12 }), callback)
end

--- Blättern: ‹ Seite x von y ›.
function UI.pager(page, pages, on_prev, on_next)
    local function arrow(icon, enabled, cb)
        local box = UI.box(UI.icon(icon, 40, { dim = not enabled }), UI.px(96), UI.px(72), {
            radius = 12, color = enabled and UI.BLACK or UI.LINE,
        })
        return UI.tap(box, enabled and cb or nil)
    end
    return HorizontalGroup:new{
        align = "center",
        arrow("chevron.left", page > 1, on_prev),
        CenterContainer:new{
            dimen = Geom:new{ w = UI.px(190), h = UI.px(72) },
            UI.text(_.T(_("Seite %1 von %2"), page, pages), 24),
        },
        arrow("chevron.right", page < pages, on_next),
    }
end

--- Zeile mit linkem und rechtem Teil, auf `w` verteilt.
function UI.spread(left, right, w)
    local lw = left and left:getSize().w or 0
    local rw = right and right:getSize().w or 0
    local row = { align = "center" }
    if left then table.insert(row, left) end
    table.insert(row, UI.rawhspan(w - lw - rw))
    if right then table.insert(row, right) end
    return HorizontalGroup:new(row)
end

--- Inhalt mit seitlichem Rand von 48 Entwurfs-Pixeln.
--- Feste Größe, Inhalt oben links. FrameContainer.width/height wirken nur beim Malen, nicht auf
--- getSize(), deshalb rutschte die Leiste unten sonst unter kurzen Inhalt.
function UI.fixed(child, w, h)
    return WidgetContainer:new{ dimen = Geom:new{ w = w, h = h }, child }
end

function UI.padded(child, top, bottom)
    return FrameContainer:new{
        bordersize = 0, margin = 0,
        padding = 0, padding_left = UI.px(48), padding_right = UI.px(48),
        padding_top = UI.px(top or 0), padding_bottom = UI.px(bottom or 0),
        child,
    }
end

-- Kopfzeile und Leiste unten -----------------------------------------------------------------

--- o: title, subtitle, on_menu (Hamburger links) oder back (Text) + on_back, right (Widget).
function UI.header(o)
    local W, H = UI.width(), UI.px(112)
    -- Der Titel steht mittig, links liegt das Menü (112), rechts manchmal ein Knopf.
    local max_w = W - 2 * UI.px(o.right and 240 or 136)
    local title = { align = "center",
        UI.text(o.title, 40, { bold = true, serif = true, max_width = max_w }) }
    if o.subtitle then
        table.insert(title, UI.text(o.subtitle, 22, { color = UI.GRAY, max_width = max_w }))
    end
    local left
    if o.on_menu then
        left = UI.tap(CenterContainer:new{ dimen = Geom:new{ w = UI.px(112), h = H }, UI.icon("appbar.menu", 52) },
            o.on_menu)
    elseif o.on_back then
        local content = HorizontalGroup:new{
            align = "center",
            UI.icon("chevron.left", 44), UI.hspan(8),
            UI.text(o.back or "", 30, { bold = true, max_width = W - UI.px(320) }),
        }
        left = UI.tap(FrameContainer:new{
            bordersize = 0, padding = 0, padding_left = UI.px(16), padding_right = UI.px(24),
            CenterContainer:new{ dimen = Geom:new{ w = content:getSize().w, h = H }, content },
        }, o.on_back)
        title = nil
    end
    local layers = { dimen = Geom:new{ w = W, h = H } }
    if title then
        table.insert(layers, CenterContainer:new{ dimen = Geom:new{ w = W, h = H }, VerticalGroup:new(title) })
    end
    if left then
        table.insert(layers, LeftContainer:new{ dimen = Geom:new{ w = W, h = H }, left })
    end
    if o.right then
        table.insert(layers, RightContainer:new{ dimen = Geom:new{ w = W, h = H },
            HorizontalGroup:new{ o.right, UI.hspan(24) } })
    end
    return VerticalGroup:new{ OverlapGroup:new(layers), UI.line(W, UI.px(3)) }
end

UI.TABS = {
    { id = "start", label = _("Start") },
    { id = "reihen", label = _("Reihen") },
    { id = "stoebern", label = _("Stöbern") },
    { id = "regal", label = _("Regal") },
    { id = "suche", label = _("Suche") },
}

function UI.nav(active, on_select)
    local W = UI.width()
    local w, h, bar = math.floor(W / #UI.TABS), UI.px(112), UI.px(8)
    local row = { align = "top" }
    for _, tab in ipairs(UI.TABS) do
        local sel = tab.id == active
        table.insert(row, UI.tap(VerticalGroup:new{
            UI.line(w, bar, sel and UI.BLACK or UI.WHITE),
            CenterContainer:new{ dimen = Geom:new{ w = w, h = h - bar }, UI.text(tab.label, 28, { bold = sel }) },
        }, function() on_select(tab.id) end))
    end
    return VerticalGroup:new{ UI.line(W, UI.px(3)), HorizontalGroup:new(row) }
end

function UI.navHeight() return UI.px(112) + UI.px(3) end
function UI.headerHeight() return UI.px(112) + UI.px(3) end

-- Cover, Plaketten, Fortschritt --------------------------------------------------------------

--- Grimmory liefert Vorschaubilder randlos in 250 × 350. Kästen im selben Format zeigen sie ohne Leisten.
function UI.coverHeight(w) return math.floor(w * 1.4 + 0.5) end

--- Cover in fester Größe w × h mit Rahmen. Das Bild füllt den Kasten, Überstand wird mittig
--- abgeschnitten: keine Leisten, keine Verzerrung. Ohne Bild steht der Titel im Rahmen.
function UI.cover(path, w, h, title)
    local b = UI.px(2)
    local iw, ih = w - 2 * b, h - 2 * b
    local inner
    if path and lfs.attributes(path, "mode") == "file" then
        -- Erst die Originalgröße lesen (das dekodierte Bild bleibt im Cache), dann so skalieren,
        -- dass es den Kasten deckt. Das +1 verhindert eine Lücke durch Abrunden.
        local probe = ImageWidget:new{ file = path, file_do_cache = true, scale_factor = 1 }
        local o = probe:getSize()
        probe:free()
        inner = ImageWidget:new{ file = path, file_do_cache = true, width = iw, height = ih,
            scale_factor = math.max((iw + 1) / o.w, (ih + 1) / o.h) }
    else
        inner = UI.textbox(title, 20, iw - UI.px(16), 5, { align = "center", serif = true })
    end
    return FrameContainer:new{
        bordersize = b, padding = 0, margin = 0, color = UI.BLACK, background = UI.WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = iw, h = ih }, inner },
    }
end

function UI.progressBar(percent, w, h)
    return ProgressWidget:new{
        width = w, height = h, percentage = math.min(math.max((percent or 0) / 100, 0), 1),
        margin_h = 0, margin_v = 0, radius = 0, bordersize = UI.px(2),
        bordercolor = UI.BLACK, fillcolor = UI.BLACK, bgcolor = UI.WHITE,
    }
end

UI.ON_DEVICE = Device:isKindle() and _("Auf dem Kindle") or _("Auf dem Gerät")

--- Zustand eines Buchs als kurze Zeile: Haken, Fortschritt, auf dem Gerät oder Größe.
--- state: "read" | "reading" | "unread"; downloaded: bool; size: Text wie "2,3 MB".
function UI.statusLine(state, percent, downloaded, size, w, font)
    if state == "read" then
        return HorizontalGroup:new{ align = "center", UI.icon("check", 26), UI.hspan(8), UI.text(_("Gelesen"), 22) }
    elseif state == "reading" then
        local label = UI.text(percent .. " %", 22, { bold = true })
        local bar_w = math.min(UI.px(96), (w or UI.px(190)) - label:getSize().w - UI.px(10))
        return HorizontalGroup:new{ align = "center", UI.progressBar(percent, bar_w, UI.px(16)), UI.hspan(10), label }
    elseif downloaded then
        return HorizontalGroup:new{ align = "center", UI.icon("book.opened", 26), UI.hspan(8),
            UI.text(UI.ON_DEVICE, font or 22, { max_width = w }) }
    end
    return HorizontalGroup:new{ align = "center", UI.icon("move.down", 26, { dim = true }), UI.hspan(8),
        UI.text(size or "", 22, { color = UI.GRAY }) }
end

--- Cover mit Plakette unten links (Regal-Kachel). Ungelesen und nicht geladen: keine Plakette.
function UI.badgedCover(path, w, h, title, state, percent, downloaded)
    local cover = UI.cover(path, w, h, title)
    if state == "unread" and not downloaded then return cover end
    local badge
    if state == "reading" then
        local label = UI.text(percent .. " %", 20, { bold = true })
        local inner_w = w - UI.px(4) - UI.px(20)
        badge = FrameContainer:new{
            bordersize = 0, padding = UI.px(10), margin = 0, background = UI.WHITE,
            HorizontalGroup:new{ align = "center",
                UI.progressBar(percent, inner_w - label:getSize().w - UI.px(10), UI.px(14)),
                UI.hspan(10), label },
        }
        badge.overlap_offset = { UI.px(2), h - UI.px(2) - badge:getSize().h }
    else
        -- Text darf, was nach Abstand (2 × 6), Rand, Innenabstand und Symbol (26 + 8) bleibt.
        local text_w = w - UI.px(12) - UI.px(4) - UI.px(18) - UI.px(34)
        local content = UI.statusLine(state, percent, downloaded, nil, text_w, 18)
        badge = FrameContainer:new{
            bordersize = UI.px(2), radius = UI.px(19), color = UI.BLACK, background = UI.WHITE,
            padding = 0, padding_left = UI.px(8), padding_right = UI.px(10),
            padding_top = UI.px(4), padding_bottom = UI.px(4),
            content,
        }
        badge.overlap_offset = { UI.px(6), h - UI.px(6) - badge:getSize().h }
    end
    return OverlapGroup:new{ dimen = Geom:new{ w = w, h = h }, cover, badge }
end

-- Kästchen je Band, ab 20 Bänden ein durchgehender Balken -------------------------------------

local Slots = Widget:extend{ states = nil, width = 0, height = 0 }

function Slots:getSize() return Geom:new{ w = self.width, h = self.height } end

local function paintSlot(bb, x, y, w, h, state, border)
    if state == "missing" then
        bb:paintRect(x, y, w, h, UI.MISSING)
        return
    end
    if state == "read" then
        bb:paintRect(x, y, w, h, UI.BLACK)
    elseif state == "reading" then
        bb:paintRect(x, y, math.floor(w / 2), h, UI.BLACK)
    end
    if border > 0 then bb:paintBorder(x, y, w, h, border, UI.BLACK) end
end

function Slots:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local n = #self.states
    if n == 0 then return end
    if n >= 20 then
        local b = UI.px(3)
        local inner = self.width - 2 * b
        for i, state in ipairs(self.states) do
            local sx = x + b + math.floor((i - 1) * inner / n)
            local ex = x + b + math.floor(i * inner / n)
            if state ~= "unread" then paintSlot(bb, sx, y + b, ex - sx, self.height - 2 * b, state, 0) end
        end
        bb:paintBorder(x, y, self.width, self.height, b, UI.BLACK)
        return
    end
    local gap = UI.px(6)
    local box = math.min(UI.px(30), math.floor((self.width - gap * (n - 1)) / n))
    local border = box < UI.px(16) and UI.px(2) or UI.px(3)
    for i, state in ipairs(self.states) do
        paintSlot(bb, x + (i - 1) * (box + gap), y, box, self.height, state, border)
    end
end

function UI.slots(states, w, h)
    return Slots:new{ states = states, width = w, height = UI.px(h or 26) }
end

-- Zeilen und Abschnitte ----------------------------------------------------------------------

--- Graue Abschnittsleiste wie „SERVER“.
function UI.section(label, right)
    local W = UI.width()
    local h = UI.px(56)
    local text = UI.text(label, 22, { bold = true })
    local content = UI.spread(text, right, W - 2 * UI.px(48))
    return VerticalGroup:new{
        UI.line(W, UI.px(2)),
        FrameContainer:new{ bordersize = 0, padding = 0, padding_left = UI.px(48), padding_right = UI.px(48),
            background = UI.SECTION,
            CenterContainer:new{ dimen = Geom:new{ w = W - 2 * UI.px(48), h = h }, content } },
        UI.line(W, 1, UI.LINE),
    }
end

--- Überschrift eines Abschnitts in Serifenschrift.
function UI.heading(text)
    return UI.padded(UI.text(text, 34, { bold = true, serif = true }), 24, 12)
end

--- Kleine graue Überschrift in Großbuchstaben, z. B. „ZUFÄLLIGE REIHE“.
function UI.overline(text)
    return UI.text(text, 22, { bold = true, color = UI.GRAY })
end

--- Pill für Kategorien.
function UI.pill(label, o)
    o = o or {}
    local text = UI.text(label, 22, { bold = o.active, color = o.active and UI.WHITE or UI.BLACK })
    local w = text:getSize().w + UI.px(32)
    return UI.box(text, w, UI.px(o.height or 40), {
        radius = (o.height or 40) / 2, background = o.active and UI.BLACK or UI.WHITE,
    })
end

UI.VerticalGroup = VerticalGroup
UI.HorizontalGroup = HorizontalGroup
UI.FrameContainer = FrameContainer
UI.CenterContainer = CenterContainer
UI.LeftContainer = LeftContainer
UI.OverlapGroup = OverlapGroup
UI.Geom = Geom

return UI
