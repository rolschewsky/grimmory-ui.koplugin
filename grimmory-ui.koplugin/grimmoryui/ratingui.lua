--[[--
Oberfläche der Bitte um einen Stern: das Kästchen unten rechts und der Dialog mit dem QR-Code.
Wann das Kästchen erscheint, entscheidet grimmoryui/rating.
]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local rating = require("grimmoryui/rating")
local UI = require("grimmoryui/ui")
local _ = require("grimmoryui/i18n")

local M = {}

--- Breite des weißen Saums um das Kästchen. Er hebt es von den Covern darunter ab.
M.RING = 12

--- Das Kästchen: Stern, Frage, Kreuz, ein Satz, „Später“ und „Bewerten“.
--- on_choice bekommt "rate", "later" oder "never".
function M.box(on_choice)
    local border, pad_l, pad_r = UI.px(3), UI.px(28), UI.px(8)
    local w = math.min(UI.px(500), UI.width() - 2 * UI.px(32))
    local inner = w - 2 * border - pad_l - pad_r
    local text_w = inner - UI.px(20)
    local close = UI.tap(CenterContainer:new{ dimen = Geom:new{ w = UI.px(72), h = UI.px(72) },
        UI.icon("close", 36) }, function() on_choice("never") end)
    local title_w = inner - UI.px(40 + 14 + 72)
    local head = HorizontalGroup:new{ align = "center",
        UI.icon("star.full", 40), UI.hspan(14),
        UI.textbox(_("Gefällt dir Grimmory?"), 28, title_w, 2, { bold = true, serif = true }),
        close,
    }
    local gap = UI.px(16)
    local bw = math.floor((text_w - gap) / 2)
    local frame = FrameContainer:new{
        bordersize = border, radius = UI.px(16), color = UI.BLACK, background = UI.WHITE, margin = 0,
        padding = 0, padding_top = UI.px(16), padding_bottom = UI.px(28),
        padding_left = pad_l, padding_right = pad_r,
        VerticalGroup:new{ align = "left",
            head,
            UI.textbox(_("Ein Stern auf GitHub hilft anderen, das Plugin zu finden."), 24, text_w, nil,
                { color = UI.DARK }),
            UI.vspan(22),
            HorizontalGroup:new{
                UI.button(_("Später"), function() on_choice("later") end, { width = bw }),
                UI.rawhspan(gap),
                UI.button(_("Bewerten"), function() on_choice("rate") end, { width = bw, primary = true }),
            },
        },
    }
    -- Ein Tippen auf den Saum oder auf freie Fläche im Kästchen verpufft, statt das Cover darunter
    -- zu öffnen.
    return UI.tap(FrameContainer:new{ bordersize = 0, margin = 0, padding = UI.px(M.RING),
        background = UI.WHITE, frame }, function() end)
end

-- Dialog mit dem QR-Code zur Seite des Plugins auf GitHub --------------------------------------

local QRDialog = InputContainer:extend{
    name = "grimmory_rate",
    modal = true,
}

function QRDialog:init()
    local W, H = UI.width(), UI.height()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.ges_events.TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } }
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
    local border, pad = UI.px(3), UI.px(56)
    local w = math.min(UI.px(800), W - 2 * UI.px(48))
    local inner = w - 2 * border - 2 * pad
    local qr = math.max(UI.px(200), math.min(UI.px(504), inner, H - UI.px(720)))
    local url = rating.REPO_URL:gsub("^https://", "")
    self.frame = FrameContainer:new{
        bordersize = border, radius = UI.px(16), color = UI.BLACK, background = UI.WHITE, margin = 0,
        padding = 0, padding_top = UI.px(40), padding_bottom = UI.px(48), padding_left = pad, padding_right = pad,
        VerticalGroup:new{ align = "center",
            UI.textbox(_("Grimmory bewerten"), 44, inner, nil, { bold = true, serif = true, align = "center" }),
            UI.vspan(16),
            UI.textbox(_("Scanne den Code mit dem Handy und vergib auf GitHub einen Stern. Danke!"), 26, inner,
                nil, { align = "center" }),
            UI.vspan(32),
            CenterContainer:new{ dimen = Geom:new{ w = inner, h = qr },
                QRWidget:new{ text = rating.REPO_URL, width = qr, height = qr } },
            UI.vspan(20),
            UI.textbox(url, 22, inner, nil, { color = UI.DARK, align = "center" }),
            UI.vspan(36),
            UI.button(_("Schließen"), function() self:close() end, { width = inner, height = UI.px(88), size = 28 }),
        },
    }
    self[1] = CenterContainer:new{ dimen = Geom:new{ w = W, h = H }, self.frame }
end

function QRDialog:close()
    UIManager:close(self, "ui")
end

function QRDialog:onClose()
    self:close()
    return true
end

function QRDialog:onTapOutside(_, ges)
    if self.frame.dimen and ges.pos:notIntersectWith(self.frame.dimen) then self:close() end
    return true
end

function M.showQR()
    UIManager:show(QRDialog:new{}, "ui")
end

return M
