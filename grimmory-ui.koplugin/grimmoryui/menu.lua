--[[--
Das Hamburger-Menü: klappt von links über die Seite. Ein Tippen daneben schließt es.
]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local VerticalGroup = require("ui/widget/verticalgroup")
local lib = require("grimmoryui/library")
local UI = require("grimmoryui/ui")
local _ = require("grimmoryui/i18n")
local N_, T = _.ngettext, _.T

local Menu = InputContainer:extend{
    name = "grimmory_menu",
    plugin = nil,
}

function Menu:init()
    local W, H = UI.width(), UI.height()
    self.drawer_w = math.min(UI.px(780), math.floor(W * 0.8))
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.ges_events.TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } }
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
    self[1] = self:build()
end

function Menu:item(icon, label, sub, callback)
    local w = self.drawer_w - UI.px(3)
    return UI.tap(VerticalGroup:new{
        FrameContainer:new{ bordersize = 0, padding = 0, padding_left = UI.px(48), padding_right = UI.px(24),
            UI.LeftContainer:new{ dimen = Geom:new{ w = w - UI.px(72), h = UI.px(127) },
                HorizontalGroup:new{ align = "center", UI.icon(icon, 48), UI.hspan(28), VerticalGroup:new{
                    align = "left",
                    UI.text(label, 30, { bold = true, max_width = w - UI.px(200) }),
                    UI.text(sub, 22, { color = UI.GRAY, max_width = w - UI.px(200) }) } } } },
        UI.line(w, 1, UI.LINE),
    }, callback)
end

function Menu:build()
    local p = self.plugin
    local w = self.drawer_w - UI.px(3)
    local on_device, kb = 0, 0
    for _, b in ipairs(p.data.books) do
        if p:localFile(b) then
            on_device = on_device + 1
            kb = kb + (tonumber(b.fileSizeKb) or 0)
        end
    end
    local host = (p:setting("server") or ""):gsub("^https?://", "")
    local function books(n) return T(N_("%1 Buch", "%1 Bücher", n), n) end
    local ago = p:syncedAgo()
    local top = HorizontalGroup:new{ align = "top",
        VerticalGroup:new{ align = "left",
            UI.text("Grimmory", 44, { bold = true, serif = true }), UI.vspan(10),
            UI.text(p:setting("username") ~= "" and p:setting("username") or _("nicht angemeldet"), 26,
                { bold = true, max_width = w - UI.px(200) }),
            UI.text(host ~= "" and host or _("kein Server eingetragen"), 22,
                { color = UI.GRAY, max_width = w - UI.px(200) }) },
    }
    local close = UI.tap(UI.CenterContainer:new{ dimen = Geom:new{ w = UI.px(112), h = UI.px(112) },
        UI.icon("close", 44) }, function() p:closeMenu() end)
    local items = VerticalGroup:new{
        align = "left",
        FrameContainer:new{ bordersize = 0, padding = 0, padding_left = UI.px(48), padding_top = UI.px(28),
            padding_bottom = UI.px(20),
            UI.spread(top, close, w - UI.px(48) - UI.px(8)) },
        UI.line(w, UI.px(2)),
        self:item("cre.render.reload", _("Jetzt abgleichen"),
            (ago and T(_("zuletzt %1"), ago) or _("noch nicht abgeglichen")) .. " · " .. books(#p.data.books),
            function() p:closeMenu(); p:sync() end),
        self:item("book.opened", UI.ON_DEVICE, books(on_device) .. " · " .. lib.formatSize(kb),
            function() p:showOnDevice() end),
        self:item("appbar.settings", _("Einstellungen"), _("Server, Abgleich, Speicher"),
            function() p:showSettings() end),
        self:item("appbar.textsize", _("Sprache"), p:languageLabel(), function() p:showLanguage() end),
        self:item("info", _("Über Grimmory"), T(_("Plugin %1 · Updates"), p.version or "?"),
            function() p:showAbout() end),
        self:item("star.empty", _("Grimmory bewerten"), _("Stern auf GitHub, per QR-Code"),
            function() p:showRatingQR() end),
        self:item("exit", _("Zurück zu KOReader"), _("Dateimanager öffnen"),
            function() p:closeMenu(); p:exitToKOReader() end),
    }
    local status = NetworkMgr:isConnected() and _("WLAN verbunden") or _("WLAN aus")
    local footer = FrameContainer:new{ bordersize = 0, padding = 0, padding_left = UI.px(48),
        padding_top = UI.px(28), padding_bottom = UI.px(28),
        UI.text(status, 22, { color = UI.DARK }) }
    local fill = UI.height() - items:getSize().h - footer:getSize().h - UI.px(2)
    return HorizontalGroup:new{ align = "top",
        FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, background = UI.WHITE,
            VerticalGroup:new{ align = "left", items, UI.line(w, math.max(0, fill), UI.WHITE),
                UI.line(w, UI.px(2)), footer } },
        UI.line(UI.px(3), UI.height()),
    }
end

function Menu:onTapOutside(_, ges)
    if ges.pos.x > self.drawer_w then self.plugin:closeMenu() end
    return true
end

function Menu:onClose()
    self.plugin:closeMenu()
    return true
end

return Menu
