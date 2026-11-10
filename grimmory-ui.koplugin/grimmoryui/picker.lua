--[[--
Auswahlseite im Stil des Plugins: eine Liste, die blättert statt scrollt, auf Wunsch mit Suchfeld.
Die Seite öffnet dort, wo der gewählte Eintrag steht.

    Picker:new{ back = _("Regal"), searchable = true, search_hint = _("Genre suchen"),
        items = { { label = "Krimi", right = "21", value = "Krimi", selected = true, keep = false }, … },
        on_pick = function(value) … end }

Ein Eintrag mit `keep` bleibt bei jeder Suche stehen (etwa „Alle Genres“).
]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local lib = require("grimmoryui/library")
local UI = require("grimmoryui/ui")
local _ = require("grimmoryui/i18n")

local Picker = InputContainer:extend{
    name = "grimmory_picker",
    covers_fullscreen = true,
    back = "",
    items = nil,
    searchable = false,
    search_hint = nil,
    on_pick = nil,
}

local ROW = 88

local function innerWidth() return UI.width() - 2 * UI.px(48) end

function Picker:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = UI.width(), h = UI.height() }
    self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
    end
    self.query = ""
    self.page = nil -- beim ersten Zeichnen die Seite des gewählten Eintrags
    self:render()
end

function Picker:filtered()
    local q = self.query:gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then return self.items end
    local list = {}
    for _, item in ipairs(self.items) do
        if item.keep or #lib.search({ { title = item.label } }, q) > 0 then table.insert(list, item) end
    end
    return list
end

function Picker:searchField()
    local h = UI.px(84)
    local text = self.query ~= "" and UI.text(self.query, 28, { max_width = innerWidth() - UI.px(100) })
        or UI.text(self.search_hint or "", 28, { color = UI.GRAY })
    local field = FrameContainer:new{
        bordersize = UI.px(3), radius = UI.px(12), padding = 0, padding_left = UI.px(24),
        UI.LeftContainer:new{ dimen = Geom:new{ w = innerWidth() - UI.px(30), h = h - UI.px(6) },
            HorizontalGroup:new{ align = "center", UI.icon("appbar.search", 36), UI.hspan(16), text } },
    }
    return UI.padded(UI.tap(field, function()
        local dialog
        dialog = InputDialog:new{
            title = self.search_hint,
            input = self.query,
            buttons = { {
                { text = _("Leeren"), callback = function()
                    UIManager:close(dialog)
                    self.query, self.page = "", 1
                    self:render()
                end },
                { text = _("Suchen"), is_enter_default = true, callback = function()
                    self.query, self.page = dialog:getInputText(), 1
                    UIManager:close(dialog)
                    self:render()
                end },
            } },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end), 24, 24)
end

function Picker:row(item)
    local mark = item.selected and UI.icon("check", 32) or UI.hspan(32)
    local left = HorizontalGroup:new{ align = "center", mark, UI.hspan(16),
        UI.text(item.label, 28, { bold = item.selected, max_width = innerWidth() - UI.px(220) }) }
    local right = item.right and UI.text(item.right, 24, { color = UI.GRAY }) or nil
    return UI.tap(VerticalGroup:new{
        FrameContainer:new{ bordersize = 0, padding = 0, padding_left = UI.px(48), padding_right = UI.px(48),
            UI.LeftContainer:new{ dimen = Geom:new{ w = innerWidth(), h = UI.px(ROW) - 1 },
                UI.spread(left, right, innerWidth()) } },
        UI.line(UI.width(), 1, UI.LINE),
    }, function() self:pick(item) end)
end

function Picker:render()
    local H = UI.height()
    local parts = { align = "left", UI.header{ back = self.back, on_back = function() self:close() end } }
    local avail = H - UI.headerHeight() - UI.px(104)
    if self.searchable then
        local field = self:searchField()
        table.insert(parts, field)
        avail = avail - field:getSize().h
    end
    table.insert(parts, UI.line(UI.width(), UI.px(2)))
    local items = self:filtered()
    local per_page = math.max(1, math.floor((avail - UI.px(2)) / UI.px(ROW)))
    if not self.page then
        self.page = 1
        for i, item in ipairs(items) do
            if item.selected then self.page = math.floor((i - 1) / per_page) + 1 end
        end
    end
    local slice, pages, page = lib.paginate(items, self.page, per_page)
    self.page, self.pages = page, pages
    local list = { align = "left" }
    for _, item in ipairs(slice) do table.insert(list, self:row(item)) end
    if #slice == 0 then
        table.insert(list, UI.padded(UI.text(_("Nichts gefunden"), 26, { color = UI.GRAY }), 32, 0))
    end
    table.insert(parts, UI.fixed(VerticalGroup:new(list), UI.width(), avail - UI.px(2)))
    if pages > 1 then
        table.insert(parts, UI.CenterContainer:new{ dimen = Geom:new{ w = UI.width(), h = UI.px(104) },
            UI.pager(page, pages, function() self:turn(-1) end, function() self:turn(1) end) })
    end
    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, background = UI.WHITE, width = UI.width(), height = H,
        VerticalGroup:new(parts),
    }
    UIManager:setDirty(self, "ui")
end

function Picker:turn(delta)
    local new = math.min(math.max(self.page + delta, 1), self.pages or 1)
    if new ~= self.page then
        self.page = new
        self:render()
    end
end

function Picker:pick(item)
    self:close()
    if self.on_pick then self.on_pick(item.value) end
end

function Picker:close()
    UIManager:close(self, "ui")
end

function Picker:onSwipe(_, ges)
    if ges.direction == "west" then self:turn(1); return true end
    if ges.direction == "east" then self:turn(-1); return true end
end

function Picker:onNextPage() self:turn(1); return true end
function Picker:onPrevPage() self:turn(-1); return true end

function Picker:onClose()
    self:close()
    return true
end

return Picker
