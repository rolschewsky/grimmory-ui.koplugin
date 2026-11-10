--[[--
Einstellungen auf einer Seite: Server mit Extra-Headern und Verbindungstest, Abgleich, Bücher,
Anzeige. Passt nicht alles auf den Bildschirm, wird geblättert.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local api = require("grimmory/api")
local UI = require("grimmory/ui")
local _ = require("grimmory/i18n")
local N_, T = _.ngettext, _.T

local Settings = InputContainer:extend{
    name = "grimmory_settings",
    plugin = nil,
    covers_fullscreen = true,
}

local ROW = 88

function Settings:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = UI.width(), h = UI.height() }
    self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
    end
    self.page = 1
    self.formats_at_open = table.concat(self.plugin:setting("formats"), ",")
    self:refresh()
end

local function innerWidth() return UI.width() - 2 * UI.px(48) end

--- Zeile mit fester Höhe: links Beschriftung (und Zusatz), rechts Wert.
local function row(left, right, callback)
    local box = VerticalGroup:new{
        FrameContainer:new{ bordersize = 0, padding = 0, padding_left = UI.px(48), padding_right = UI.px(48),
            UI.LeftContainer:new{ dimen = Geom:new{ w = innerWidth(), h = UI.px(ROW) - 1 },
                UI.spread(left, right, innerWidth()) } },
        UI.line(UI.width(), 1, UI.LINE),
    }
    return callback and UI.tap(box, callback) or box
end

local function label(text, sub, w)
    local items = { align = "left", UI.text(text, 26, { bold = true, max_width = w }) }
    if sub then table.insert(items, UI.text(sub, 22, { color = UI.GRAY, max_width = w })) end
    return VerticalGroup:new(items)
end

local function chevron() return UI.icon("chevron.right", 32) end

--- Schalter wie im Entwurf: An/Aus als Text und ein Schiebeschalter.
local function switch(on)
    local knob = UI.box(UI.text("", 10), UI.px(34), UI.px(34), {
        border = 0, radius = 17, background = on and UI.WHITE or UI.BLACK })
    local track = FrameContainer:new{
        bordersize = UI.px(3), radius = UI.px(25), color = UI.BLACK, background = on and UI.BLACK or UI.WHITE,
        padding = 0, padding_left = UI.px(5), padding_right = UI.px(5),
        UI.LeftContainer:new{ dimen = Geom:new{ w = UI.px(76), h = UI.px(44) },
            HorizontalGroup:new{ on and UI.hspan(42) or UI.hspan(0), knob } },
    }
    return HorizontalGroup:new{ align = "center",
        UI.text(on and _("An") or _("Aus"), 24, { bold = true, color = on and UI.BLACK or UI.GRAY }), UI.hspan(20), track }
end

function Settings:edit(title, key, opts)
    opts = opts or {}
    local p = self.plugin
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = p:setting(key),
        input_hint = opts.hint,
        text_type = opts.password and "password" or nil,
        buttons = { {
            { text = _("Abbrechen"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Speichern"), is_enter_default = true, callback = function()
                local value = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(dialog)
                p:saveSetting(key, value)
                self:refresh()
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Settings:editHeader(index)
    local p = self.plugin
    local headers = p:setting("headers")
    local h = headers[index] or {}
    local dialog
    local buttons = { { text = _("Abbrechen"), id = "close", callback = function() UIManager:close(dialog) end } }
    if headers[index] then
        table.insert(buttons, 1, { text = _("Entfernen"), callback = function()
            UIManager:close(dialog)
            table.remove(headers, index)
            p:saveSetting("headers", headers)
            self:refresh()
        end })
    end
    table.insert(buttons, { text = _("Speichern"), callback = function()
        local fields = dialog:getFields()
        UIManager:close(dialog)
        local name = (fields[1] or ""):gsub("%s", "")
        if name ~= "" then
            headers[index] = { name = name, value = fields[2] or "" }
            p:saveSetting("headers", headers)
        end
        self:refresh()
    end })
    dialog = MultiInputDialog:new{
        title = _("Extra-Header"),
        fields = {
            { description = _("Name"), text = h.name or "", hint = "X-Api-Key" },
            { description = _("Wert"), text = h.value or "", text_type = "password" },
        },
        buttons = { buttons },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Settings:testConnection()
    local p = self.plugin
    if not p:isConfigured() then
        self.test_result = _("Erst Adresse und Benutzer eintragen")
        self:refresh()
        return
    end
    NetworkMgr:runWhenConnected(function()
        -- Anmeldung und Abfrage blockieren; das Popup vorher zeichnen, sonst sieht man nichts davon.
        local info = InfoMessage:new{ text = _("Verbindung zu Grimmory wird getestet …") }
        UIManager:show(info)
        UIManager:forceRePaint()
        p._client = nil
        local client, err = p:client()
        local ok
        if client then
            client.tokens = {}
            ok, err = client:login()
        end
        if ok then
            -- Auch die Liste abfragen, die der Abgleich braucht: Ein Proxy kann die Anmeldung
            -- durchlassen und Anfragen mit Query trotzdem sperren.
            local me, me_err = client:me()
            local list, list_err = client:getJSON("/api/v1/app/books?page=0&size=1")
            self.test_ok = me ~= nil and list ~= nil
            if self.test_ok then
                self.test_result = T(_("Angemeldet als %1"), me.username or me.name or p:setting("username"))
            else
                self.test_result = T(_("Anmeldung klappt, Abruf nicht: %1"), api.describe(me_err or list_err))
            end
        else
            self.test_ok = false
            self.test_result = api.describe(err)
        end
        UIManager:close(info)
        self:refresh()
    end)
end

function Settings:chooseStartTab()
    local dialog
    local rows = {}
    for _, tab in ipairs(UI.TABS) do
        table.insert(rows, { { text = tab.label, callback = function()
            UIManager:close(dialog)
            self.plugin:saveSetting("start_tab", tab.id)
            self:refresh()
        end } })
    end
    dialog = ButtonDialog:new{ title = _("Startbereich"), buttons = rows }
    UIManager:show(dialog)
end

function Settings:rows()
    local p = self.plugin
    local w = innerWidth() - UI.px(360)
    local list = {}
    local function add(widget) table.insert(list, widget) end
    local function toggle(text, sub, key)
        add(row(label(text, sub, w), switch(p:setting(key)), function()
            p:saveSetting(key, not p:setting(key))
            self:refresh()
        end))
    end
    local function value(text, shown, callback, sub)
        add(row(label(text, sub, w), HorizontalGroup:new{ align = "center",
            UI.text(shown, 24, { color = UI.DARK, max_width = innerWidth() - w - UI.px(60) }), UI.hspan(12),
            chevron() }, callback))
    end
    local function show(v, empty) return (v and v ~= "") and v or empty end
    local function section(text)
        local widget = UI.section(text)
        widget.keep_with_next = true
        add(widget)
    end

    local missing = _("nicht eingetragen")
    section(_("SERVER"))
    value(_("Adresse"), show(p:setting("server"), missing), function()
        self:edit(_("Adresse des Grimmory-Servers"), "server", { hint = "https://grimmory.example.com" })
    end)
    value(_("Benutzer"), show(p:setting("username"), missing), function()
        self:edit(_("Benutzer"), "username")
    end)
    value(_("Passwort"), p:setting("password") ~= "" and "••••••••" or missing, function()
        self:edit(_("Passwort"), "password", { password = true })
    end)
    local headers = p:setting("headers")
    for i, h in ipairs(headers) do
        value(i == 1 and _("Extra-Header") or "", (h.name or "") .. ": ••••", function() self:editHeader(i) end,
            i == 1 and _("gehen bei jeder Anfrage mit") or nil)
    end
    value(#headers == 0 and _("Extra-Header") or "", _("Header hinzufügen"), function() self:editHeader(#headers + 1) end,
        #headers == 0 and _("gehen bei jeder Anfrage mit") or nil)
    local result = self.test_result and UI.text(self.test_result, 22, { bold = self.test_ok,
        color = self.test_ok and UI.BLACK or UI.DARK, max_width = innerWidth() - UI.px(400) })
    add(row(HorizontalGroup:new{ align = "center", label(_("Verbindung"), nil, UI.px(200)), UI.hspan(20),
        UI.button(_("Testen"), function() self:testConnection() end, { height = UI.px(64) }) }, result or nil))

    section(_("ABGLEICH"))
    local minutes, days = p:setting("sync_minutes"), p:setting("remove_read_days")
    toggle(_("Automatisch abgleichen"), T(N_("beim Öffnen, wenn älter als %1 Minute",
        "beim Öffnen, wenn älter als %1 Minuten", minutes), minutes), "auto_sync")
    toggle(_("Lesestand an Grimmory melden"), _("gelesen und angefangen, für alle Geräte"), "report_progress")
    toggle(_("Cover vorab laden"), _("kleine Vorschaubilder beim Abgleich"), "prefetch_covers")

    -- Ein Schalter je Format, das der Server hat oder das gewählt ist. Mindestens eins bleibt an.
    section(_("FORMATE"))
    local counts, selected, names = p.data.formats, {}, {}
    for _, f in ipairs(p:setting("formats")) do selected[f:upper()] = true end
    for f in pairs(counts or {}) do selected[f] = selected[f] or false end
    for f in pairs(selected) do table.insert(names, f) end
    table.sort(names)
    for _, f in ipairs(names) do
        local n = counts and (counts[f] or 0)
        add(row(label(f, n and T(N_("%1 Buch in Grimmory", "%1 Bücher in Grimmory", n), n), w),
            switch(selected[f]), function()
                selected[f] = not selected[f]
                local list = {}
                for _, name in ipairs(names) do if selected[name] then table.insert(list, name) end end
                if #list > 0 then p:saveSetting("formats", list) end
                self:refresh()
            end))
    end

    section(_("BÜCHER"))
    value(_("Speicherort"), p:setting("download_dir"), function() self:edit(_("Speicherort für Downloads"), "download_dir") end)
    toggle(_("Gelesene Bücher entfernen"), T(N_("%1 Tag nach dem Lesen vom Gerät löschen",
        "%1 Tage nach dem Lesen vom Gerät löschen", days), days), "remove_read")
    value(_("Belegter Speicher"), _("Suche öffnen"), function() self:close(); p:showOnDevice() end,
        _("Bücher einzeln vom Gerät entfernen"))

    section(_("ANZEIGE"))
    local start = UI.TABS[1].label
    for _, tab in ipairs(UI.TABS) do if tab.id == p:setting("start_tab") then start = tab.label end end
    value(_("Startbereich"), start, function() self:chooseStartTab() end)
    toggle(_("Beim Start von KOReader öffnen"), _("statt des Dateimanagers"), "autostart")

    section(_("UPDATES"))
    value(_("GitHub-Repo"), show(p:setting("update_repo"), _("nur AppStore")), function()
        self:edit(_("GitHub-Repo für das Selbst-Update"), "update_repo", { hint = _("besitzer/repo") })
    end, _("für Updates ohne AppStore"))
    return list
end

function Settings:refresh()
    local H = UI.height()
    local header = UI.header{ back = _("Einstellungen"), on_back = function() self:close() end }
    local avail = H - UI.headerHeight() - UI.px(104)
    local pages, current, used = { {} }, 1, 0
    local rows = self:rows()
    for i, widget in ipairs(rows) do
        local h = widget:getSize().h
        -- Ein Abschnittskopf kommt nur mit seiner ersten Zeile auf die Seite.
        local need = h + ((widget.keep_with_next and rows[i + 1]) and rows[i + 1]:getSize().h or 0)
        if used + need > avail and #pages[current] > 0 then
            current = current + 1
            pages[current] = {}
            used = 0
        end
        table.insert(pages[current], widget)
        used = used + h
    end
    self.pages = #pages
    self.page = math.min(self.page, self.pages)
    local body = { align = "left" }
    for _, widget in ipairs(pages[self.page]) do table.insert(body, widget) end
    local pager = UI.CenterContainer:new{ dimen = Geom:new{ w = UI.width(), h = UI.px(104) },
        UI.pager(self.page, self.pages, function() self:turn(-1) end, function() self:turn(1) end) }
    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, background = UI.WHITE, width = UI.width(), height = H,
        VerticalGroup:new{ align = "left", header,
            UI.fixed(VerticalGroup:new(body), UI.width(), avail),
            self.pages > 1 and pager or UI.vspan(0) },
    }
    UIManager:setDirty(self, "ui")
end

function Settings:turn(delta)
    local new = math.min(math.max(self.page + delta, 1), self.pages or 1)
    if new ~= self.page then
        self.page = new
        self:refresh()
    end
end

function Settings:onSwipe(_, ges)
    if ges.direction == "west" then self:turn(1); return true end
    if ges.direction == "east" then self:turn(-1); return true end
end

function Settings:onNextPage() self:turn(1); return true end
function Settings:onPrevPage() self:turn(-1); return true end

function Settings:close()
    UIManager:close(self, "flashui")
    if self.plugin.app then self.plugin.app:render() end
    -- Andere Formate wirken erst mit einem neuen Abgleich.
    if table.concat(self.plugin:setting("formats"), ",") ~= self.formats_at_open then self.plugin:sync() end
end

function Settings:onClose()
    self:close()
    return true
end

return Settings
