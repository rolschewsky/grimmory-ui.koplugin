--[[--
Dialog am Ende eines Buchs aus Grimmory statt der Frage von KOReader: als gelesen markieren, den
nächsten Band der Reihe lesen, zurück zu Grimmory oder im Buch bleiben. „Weitere Möglichkeiten“
zeigt die Frage von KOReader.
]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lib = require("grimmoryui/library")
local UI = require("grimmoryui/ui")
local _ = require("grimmoryui/i18n")
local T = _.T

-- Der Name ist der des Dialogs von KOReader: Blättert man weiter, legt KOReader so keinen zweiten
-- darüber.
local BookEnd = InputContainer:extend{
    name = "end_document",
    modal = true,
    plugin = nil,
    book = nil,
    koreader = nil, -- zeigt die Frage von KOReader
    mark = true,
}

function BookEnd:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = UI.width(), h = UI.height() }
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
    self.next_book = lib.nextInSeries(self.plugin.data.books, self.book)
    self:build()
end

function BookEnd:build()
    local W, H = UI.width(), UI.height()
    local b, p = self.book, self.plugin
    local border, pad = UI.px(3), UI.px(48)
    local inner = math.min(UI.px(944), W - 2 * UI.px(32)) - 2 * border - 2 * pad
    local sub = b.seriesName and T(_("%1 · Band %2"), b.seriesName, lib.bandLabel(b.seriesNumber))
        or table.concat(b.authors or {}, ", ")
    local box = UI.box(self.mark and UI.icon("check", 32) or UI.text("", 10), UI.px(44), UI.px(44),
        { border = 3, radius = 6 })
    local check = UI.tap(UI.LeftContainer:new{ dimen = Geom:new{ w = inner, h = UI.px(72) },
        HorizontalGroup:new{ align = "center", box, UI.hspan(20),
            UI.textbox(_("Als gelesen markieren und an Grimmory melden"), 26, inner - UI.px(64)) } }, function()
        self.mark = not self.mark
        self:build()
        UIManager:setDirty(self, "ui")
    end)
    local parts = { align = "left",
        UI.overline(_("ZU ENDE GELESEN")), UI.vspan(10),
        UI.textbox(b.title, 44, inner, 2, { bold = true, serif = true }), UI.vspan(6),
        UI.text(sub, 26, { color = UI.DARK, max_width = inner }), UI.vspan(16),
        check, UI.vspan(16),
    }

    local nb = self.next_book
    if nb then
        local file = p:localFile(nb)
        local cw = UI.px(150)
        local ch = UI.coverHeight(cw)
        local text_w = inner - cw - UI.px(32)
        local title = UI.textbox(nb.title, 36, text_w, 2, { bold = true, serif = true })
        local info = UI.text(file and UI.ON_DEVICE or lib.formatSize(nb.fileSizeKb), 24,
            { color = UI.DARK, max_width = text_w })
        local label = file and _("Band %1 lesen") or _("Band %1 laden und lesen")
        local button = UI.button(T(label, lib.bandLabel(nb.seriesNumber)), function()
            self:finish(function() UIManager:nextTick(function() p:read(nb) end) end)
        end, { primary = true, width = text_w, height = UI.px(88), size = 28 })
        -- Der Knopf schließt unten mit dem Cover ab.
        local gap = math.max(UI.px(12), ch - title:getSize().h - UI.px(6) - info:getSize().h - button:getSize().h)
        table.insert(parts, UI.line(inner, UI.px(2)))
        table.insert(parts, UI.vspan(28))
        table.insert(parts, UI.overline(_("WEITER IN DER REIHE")))
        table.insert(parts, UI.vspan(16))
        table.insert(parts, HorizontalGroup:new{ align = "top",
            UI.cover(p:thumbPath(nb), cw, ch, nb.title), UI.hspan(32),
            VerticalGroup:new{ align = "left", title, UI.vspan(6), info, VerticalSpan:new{ width = gap }, button } })
        table.insert(parts, UI.vspan(32))
    end

    local half = math.floor((inner - UI.px(24)) / 2)
    table.insert(parts, UI.line(inner, UI.px(2)))
    table.insert(parts, UI.vspan(28))
    table.insert(parts, HorizontalGroup:new{
        UI.button(_("Zu Grimmory"), function() self:finish(function() p:leaveBook() end) end,
            { width = half, height = UI.px(88), size = 28 }),
        UI.hspan(24),
        UI.button(_("Im Buch bleiben"), function() self:finish() end, { width = half, height = UI.px(88), size = 28 }),
    })
    table.insert(parts, UI.vspan(8))
    table.insert(parts, UI.tap(CenterContainer:new{ dimen = Geom:new{ w = inner, h = UI.px(72) },
        UI.text(_("Weitere Möglichkeiten von KOReader"), 24, { bold = true, color = UI.DARK }) }, function()
        self:close()
        self.koreader()
    end))

    self.frame = FrameContainer:new{
        bordersize = border, radius = UI.px(16), color = UI.BLACK, background = UI.WHITE, margin = 0,
        padding = pad, padding_top = UI.px(40), padding_bottom = UI.px(16),
        VerticalGroup:new(parts),
    }
    self[1] = CenterContainer:new{ dimen = Geom:new{ w = W, h = H }, self.frame }
end

function BookEnd:close()
    UIManager:close(self, "ui")
end

--- Dialog schließen, das Buch auf Wunsch als gelesen markieren, dann `after`.
function BookEnd:finish(after)
    self:close()
    if self.mark then self.plugin:markFinished(self.book) end
    if after then after() end
end

--- Die Zurück-Taste schließt nur den Dialog.
function BookEnd:onClose()
    self:close()
    return true
end

return BookEnd
