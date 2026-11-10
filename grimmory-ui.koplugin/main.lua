--[[--
Grimmory für KOReader: zeigt die Bibliothek eines Grimmory-Servers, lädt Bücher herunter und
öffnet sie im Reader von KOReader. Auf Wunsch erscheint das Plugin beim Start statt des
Dateimanagers und nach dem Lesen wieder.

Einstellungen in koreader/settings/grimmory-ui.lua, Daten in <Datenordner>/grimmory-ui/. Der Name
„grimmory“ gehört dem offiziellen Plugin Grimmory Sync, bis Version 1.0.0 lag dieses Plugin auch
dort und wird beim ersten Start übernommen.
]]

local BookList = require("ui/widget/booklist")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local api = require("grimmoryui/api")
local library = require("grimmoryui/library")
local rating = require("grimmoryui/rating")
local _ = require("grimmoryui/i18n")
local N_, T = _.ngettext, _.T

local DEFAULTS = {
    server = "",
    username = "",
    password = "",
    headers = {},
    auto_sync = true,
    sync_minutes = 30,
    report_progress = true,
    prefetch_covers = true,
    formats = { "EPUB", "MOBI" }, -- nur diese Formate kommen beim Abgleich mit
    remove_read = false,
    remove_read_days = 30,
    start_tab = "start",
    autostart = true,
    regal_sort = "added", -- regal_genre und language haben keine Vorgabe
    update_repo = "rolschewsky/grimmory-ui.koplugin",
}

-- Zustand über alle Dateimanager-Instanzen hinweg. KOReader legt das Plugin für jeden Dateimanager
-- und jeden Reader neu an, das Modul selbst bleibt aber geladen.
local session = { started = false, reopen = false, last_book = nil, just_finished = false }

local NAME = "grimmory-ui"

--- Einstellungen und Daten aus der Zeit, als das Plugin noch „grimmory“ hieß, übernehmen. Nur wenn
--- dort unsere library.json liegt: Grimmory Sync nutzt denselben Namen, seine Dateien bleiben unberührt.
local function adoptOldNames(settings_file, data_dir)
    local old_dir = DataStorage:getFullDataDir() .. "/grimmory"
    if lfs.attributes(data_dir, "mode") or lfs.attributes(old_dir .. "/library.json", "mode") ~= "file" then return end
    util.makePath(data_dir)
    os.rename(old_dir .. "/library.json", data_dir .. "/library.json")
    os.rename(old_dir .. "/thumbs", data_dir .. "/thumbs")
    local old_settings = DataStorage:getSettingsDir() .. "/grimmory.lua"
    if not lfs.attributes(settings_file, "mode") and lfs.attributes(old_settings, "mode") == "file" then
        local src = io.open(old_settings, "rb")
        local dst = src and io.open(settings_file, "wb")
        if dst then dst:write(src:read("*a")); dst:close() end
        if src then src:close() end
    end
    logger.info("Grimmory: Einstellungen und Daten von „grimmory“ übernommen")
end

local Grimmory = WidgetContainer:extend{
    name = NAME,
    is_doc_only = false,
}

function Grimmory:init()
    local settings_file = DataStorage:getSettingsDir() .. "/" .. NAME .. ".lua"
    self.dir = DataStorage:getFullDataDir() .. "/" .. NAME
    adoptOldNames(settings_file, self.dir)
    self.settings = LuaSettings:open(settings_file)
    util.makePath(self.dir .. "/thumbs")
    self.data = library.load(self.dir)
    self.data.details = self.data.details or {}
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    if not self.ui.document then
        local first_start = not session.started
        session.started = true
        local back_from_reader = session.reopen
        session.reopen = false
        if back_from_reader then session.just_finished = self:reportLastBook() end
        if back_from_reader or (first_start and self:setting("autostart")) then
            UIManager:nextTick(function() self:showApp() end)
        end
    end
end

function Grimmory:onDispatcherRegisterActions()
    Dispatcher:registerAction("grimmory_ui_show", {
        category = "none", event = "ShowGrimmoryUI", title = _("Grimmory öffnen"),
        filemanager = true, reader = true,
    })
end

function Grimmory:onShowGrimmoryUI()
    self:showApp()
    return true
end

function Grimmory:addToMainMenu(menu_items)
    menu_items.grimmory_ui = {
        text = "Grimmory",
        sorting_hint = "tools",
        callback = function() self:showApp() end,
    }
end

-- Einstellungen ------------------------------------------------------------------------------

function Grimmory:setting(key)
    local value = self.settings:readSetting(key)
    if value == nil or value == "" then -- ein geleertes Feld gilt als nicht gesetzt
        if key == "download_dir" then return self:defaultDownloadDir() end
        return DEFAULTS[key]
    end
    return value
end

function Grimmory:saveSetting(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
    if key == "server" or key == "username" or key == "password" or key == "headers" then
        self.settings:delSetting("tokens")
        self.settings:flush()
        self._client = nil
    end
end

function Grimmory:defaultDownloadDir()
    local home = G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getFullDataDir()
    return home .. "/Grimmory"
end

function Grimmory:isConfigured()
    return self:setting("server") ~= "" and self:setting("username") ~= ""
end

function Grimmory:client()
    if self._client then return self._client end
    local client, err = api.new{
        base = self:setting("server"),
        username = self:setting("username"),
        password = self:setting("password"),
        headers = self:setting("headers"),
        tokens = self.settings:readSetting("tokens") or {},
        on_tokens = function(tokens)
            self.settings:saveSetting("tokens", tokens)
            self.settings:flush()
        end,
    }
    self._client = client
    return client, err
end

-- Bibliothek ---------------------------------------------------------------------------------

function Grimmory:save()
    local ok, err = library.save(self.dir, self.data)
    if not ok then logger.warn("Grimmory: library.json nicht gespeichert:", err) end
end

function Grimmory:thumbPath(book)
    return self.dir .. "/thumbs/" .. tostring(book.id) .. ".jpg"
end

function Grimmory:localFile(book)
    local path = self.data.files[tostring(book.id)]
    if path and lfs.attributes(path, "mode") == "file" then return path end
    return nil
end

--- Lesestand: "read", "reading" oder "unread" und Prozent. Der Stand in KOReader geht vor.
function Grimmory:state(book)
    local file = self:localFile(book)
    if file then
        local info = BookList.getBookInfo(file) or {}
        return library.readState(book, info.percent_finished, info.status)
    end
    return library.readState(book)
end

function Grimmory:syncedLabel()
    local t = self.data.synced_at
    if not t then return _("noch nicht abgeglichen") end
    if os.date("%Y%m%d", t) == os.date("%Y%m%d") then return os.date(_("abgeglichen %H:%M"), t) end
    return os.date(_("abgeglichen %d.%m."), t)
end

--- „vor 2 Min.“ seit dem letzten Abgleich, nil ohne Abgleich.
function Grimmory:syncedAgo()
    local t = self.data.synced_at
    if not t then return nil end
    local min = math.floor((os.time() - t) / 60)
    if min < 1 then return _("gerade eben") end
    if min < 60 then return T(N_("vor %1 Min.", "vor %1 Min.", min), min) end
    local hours = math.floor(min / 60)
    if hours < 24 then return T(N_("vor %1 Std.", "vor %1 Std.", hours), hours) end
    local days = math.floor(hours / 24)
    return T(N_("vor %1 Tag", "vor %1 Tagen", days), days)
end

local function stripHtml(s)
    s = (s or ""):gsub("<[Bb][Rr]%s*/?>", "\n"):gsub("</[Pp]>", "\n\n"):gsub("<[^>]+>", "")
    s = s:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'")
        :gsub("&lt;", "<"):gsub("&gt;", ">")
    return (s:gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Grimmory:bookDescription(book)
    return self.data.details[tostring(book.id)]
end

--- Klappentext nachladen, wenn das WLAN ohnehin an ist. Ohne Netz bleibt er leer.
function Grimmory:fetchDetail(book)
    local key = tostring(book.id)
    if self.data.details[key] or not self:isConfigured() or not NetworkMgr:isConnected() then return end
    local detail = self:client():bookDetail(book.id)
    if detail and detail.description then
        self.data.details[key] = stripHtml(detail.description)
        self:save()
    end
end

-- Abgleich -----------------------------------------------------------------------------------

function Grimmory:sync(silent, on_done)
    if not self:isConfigured() then
        UIManager:show(InfoMessage:new{ text = _("Bitte zuerst in den Einstellungen den Server eintragen.") })
        return
    end
    NetworkMgr:runWhenConnected(function()
        local info = InfoMessage:new{ text = _("Abgleich mit Grimmory …") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local client = self:client()
        local result, err
        local formats = self:setting("formats")
        if self:setting("prefetch_covers") then
            result, err = library.sync(client, self.dir, self.data, formats)
        else
            result, err = library.sync({
                books = function() return client:books() end,
                series = function() return client:series() end,
                thumbnail = function() return false end,
            }, self.dir, self.data, formats)
        end
        if result then
            self:pushReadStates()
            self:removeOldReads()
            self:save()
        end
        UIManager:close(info)
        if result then
            if not silent then
                UIManager:show(InfoMessage:new{ timeout = 3, text = T(_("Abgeglichen: %1, %2."),
                    T(N_("%1 Buch", "%1 Bücher", result.books), result.books),
                    T(N_("%1 Reihe", "%1 Reihen", result.series), result.series)) })
            end
            if self.app then
                self.app:reroll()
                self.app:render()
            end
        else
            UIManager:show(InfoMessage:new{ text = T(_("Abgleich fehlgeschlagen: %1"), api.describe(err)) })
        end
        if on_done then on_done(result ~= nil) end
    end)
end

--- Abgleich beim Öffnen, wenn der letzte länger her ist und das WLAN schon an ist. on_done läuft
--- danach, ohne Abgleich sofort.
function Grimmory:maybeAutoSync(on_done)
    local age = os.time() - (self.data.synced_at or 0)
    if self:setting("auto_sync") and self:isConfigured() and NetworkMgr:isConnected()
        and age >= self:setting("sync_minutes") * 60 then
        self:sync(true, on_done)
    elseif on_done then
        on_done()
    end
end

--- Lesestand aus KOReader an Grimmory melden, nur was sich geändert hat.
function Grimmory:pushReadStates()
    if not self:setting("report_progress") then return end
    local client = self:client()
    for _, book in ipairs(self.data.books) do
        local file = self:localFile(book)
        if file then
            local info = BookList.getBookInfo(file) or {}
            local wanted
            if info.status == "complete" then
                wanted = "READ"
            elseif (info.percent_finished or 0) > 0 then
                wanted = "READING"
            end
            if wanted and book.readStatus ~= wanted and not (wanted == "READING" and book.readStatus == "READ") then
                if client:setStatus(book.id, wanted) then book.readStatus = wanted end
            end
        end
    end
end

--- Nach dem Lesen: Stand des zuletzt geöffneten Buchs melden, wenn das WLAN an ist. Gibt true
--- zurück, wenn das Buch zu Ende gelesen ist, und zählt es für die Bitte um einen Stern.
function Grimmory:reportLastBook()
    local id = session.last_book
    if not id then return false end
    local finished = false
    for _, book in ipairs(self.data.books) do
        if book.id == id then
            local file = self:localFile(book)
            if file then
                BookList.resetBookInfoCache(file)
                local info = BookList.getBookInfo(file)
                finished = info ~= nil and info.status == "complete"
            end
        end
    end
    if finished then self:countFinished(id) end
    if self:isConfigured() and NetworkMgr:isConnected() then
        pcall(self.pushReadStates, self)
        self:save()
    end
    return finished
end

--- Gelesene Bücher nach der eingestellten Frist vom Gerät entfernen.
function Grimmory:removeOldReads()
    if not self:setting("remove_read") then return end
    local limit = os.time() - self:setting("remove_read_days") * 86400
    for _, book in ipairs(self.data.books) do
        local file = self:localFile(book)
        if file then
            local summary = DocSettings:open(file):readSetting("summary") or {}
            local y, m, d = (summary.modified or ""):match("^(%d+)-(%d+)-(%d+)")
            if summary.status == "complete" and y
                and os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d) } < limit then
                self:removeDownload(book)
            end
        end
    end
end

-- Herunterladen und Öffnen -------------------------------------------------------------------

local function uniquePath(dir, name)
    local base, ext = name:match("^(.*)(%.[^.]+)$")
    base, ext = base or name, ext or ""
    local path, n = dir .. "/" .. name, 1
    while lfs.attributes(path, "mode") do
        n = n + 1
        path = string.format("%s/%s (%d)%s", dir, base, n, ext)
    end
    return path
end

--- Lädt ein Buch und gibt den Pfad zurück, bei Fehlern nil und Meldung.
function Grimmory:download(book)
    local dir = self:setting("download_dir")
    util.makePath(dir)
    local part = dir .. "/.grimmory-" .. tostring(book.id) .. ".part"
    local name, err = self:client():download(book.id, part)
    if not name then
        os.remove(part)
        return nil, api.describe(err)
    end
    if type(name) ~= "string" then
        name = book.primaryFileName or (tostring(book.id) .. "." .. (book.primaryFileType or "epub"):lower())
    end
    local path = uniquePath(dir, name)
    if not os.rename(part, path) then
        os.remove(part)
        return nil, _("Datei konnte nicht abgelegt werden")
    end
    self.data.files[tostring(book.id)] = path
    self:save()
    return path
end

function Grimmory:downloadAndOpen(book)
    NetworkMgr:runWhenConnected(function()
        local info = InfoMessage:new{ text = T(_("Wird geladen: %1"), book.title or "") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local path, err = self:download(book)
        UIManager:close(info)
        if path then
            self:openFile(path, book)
        else
            UIManager:show(InfoMessage:new{ text = T(_("Laden fehlgeschlagen: %1"), err) })
        end
    end)
end

function Grimmory:downloadMany(books, on_done)
    NetworkMgr:runWhenConnected(function()
        local failed = 0
        for i, book in ipairs(books) do
            local info = InfoMessage:new{ text = T(_("Lade %1 von %2: %3"), i, #books, book.title or "") }
            UIManager:show(info)
            UIManager:forceRePaint()
            if not self:download(book) then failed = failed + 1 end
            UIManager:close(info)
        end
        if failed > 0 then
            UIManager:show(InfoMessage:new{ text = T(N_("%1 Buch konnte nicht geladen werden.",
                "%1 Bücher konnten nicht geladen werden.", failed), failed) })
        end
        if on_done then on_done() end
    end)
end

function Grimmory:removeDownload(book)
    local file = self:localFile(book)
    if file then os.remove(file) end
    self.data.files[tostring(book.id)] = nil
    self:save()
end

function Grimmory:markRead(book, read)
    local status = read and "READ" or "UNREAD"
    book.readStatus = status
    local file = self:localFile(book)
    if file then
        local ds = DocSettings:open(file)
        local summary = ds:readSetting("summary") or {}
        summary.status = read and "complete" or "reading"
        summary.modified = os.date("%Y-%m-%d")
        ds:saveSetting("summary", summary)
        ds:flush()
        BookList.resetBookInfoCache(file)
    end
    if self:isConfigured() and NetworkMgr:isConnected() then self:client():setStatus(book.id, status) end
    self:save()
end

function Grimmory:openFile(file, book)
    session.reopen = true
    session.last_book = book and book.id
    self:closeApp()
    if self.ui.document then
        self.ui:switchDocument(file)
    else
        self.ui:openFile(file)
    end
end

-- Fenster ------------------------------------------------------------------------------------

function Grimmory:showApp()
    if self.app then return end
    local App = require("grimmoryui/app")
    self.app = App:new{ plugin = self }
    UIManager:show(self.app)
    local just_finished = session.just_finished
    session.just_finished = false
    -- Die Bitte um einen Stern erst nach dem Abgleich, nie währenddessen.
    UIManager:nextTick(function()
        self:maybeAutoSync(function() self:offerRating(just_finished) end)
    end)
end

function Grimmory:closeApp()
    if self.menu then UIManager:close(self.menu); self.menu = nil end
    if self.app then
        UIManager:close(self.app, "flashui")
        self.app = nil
    end
end

function Grimmory:showMenu()
    local Menu = require("grimmoryui/menu")
    self.menu = Menu:new{ plugin = self }
    UIManager:show(self.menu)
end

function Grimmory:closeMenu()
    if self.menu then
        UIManager:close(self.menu, "ui")
        self.menu = nil
    end
end

function Grimmory:showSettings()
    self:closeMenu()
    local Settings = require("grimmoryui/settings")
    UIManager:show(Settings:new{ plugin = self })
end

--- Suche mit Filter „Auf dem Gerät“, zugleich die Übersicht über den belegten Speicher.
function Grimmory:showOnDevice()
    self:closeMenu()
    if not self.app then self:showApp() end
    self.app.search_filter = "device"
    self.app.search_sort = "size"
    self.app:setTab("suche")
end

function Grimmory:exitToKOReader()
    self:closeApp()
end

-- Sprache ------------------------------------------------------------------------------------

--- Name der Sprache, die das Plugin gerade nutzt, für das Menü.
function Grimmory:languageLabel()
    local own = self:setting("language")
    if own then return _.languageName(own) end
    return _("Wie KOReader")
end

--- Sprache nur für das Plugin wählen. Die Texte stehen beim Laden fest, deshalb wirkt der Wechsel
--- nach einem Neustart von KOReader, den KOReader selbst anbietet.
function Grimmory:showLanguage()
    self:closeMenu()
    local own = self:setting("language")
    local koreader = G_reader_settings:readSetting("language")
    local items = { { label = _("Wie KOReader"), right = _.languageName(koreader) or "English", value = false,
        selected = not own } }
    for _, l in ipairs(_.LANGUAGES) do
        table.insert(items, { label = l.name, value = l.code, selected = l.code == own })
    end
    local Picker = require("grimmoryui/picker")
    UIManager:show(Picker:new{
        back = _("Sprache"), items = items,
        on_pick = function(code)
            code = code or nil
            if code == own then return end
            self:saveSetting("language", code)
            UIManager:askForRestart(_("Die neue Sprache gilt nach einem Neustart von KOReader."))
        end,
    })
end

-- Bitte um einen Stern -----------------------------------------------------------------------

function Grimmory:ratingState()
    local saved = self.settings:readSetting("rating")
    return type(saved) == "table" and saved or {}
end

function Grimmory:countFinished(id)
    local state = self:ratingState()
    if rating.record(state, id) then self:saveSetting("rating", state) end
end

function Grimmory:offerRating(just_finished)
    if self.app and rating.due(self:ratingState(), os.time(), just_finished) then self.app:showRating() end
end

function Grimmory:answerRating(choice)
    local state = self:ratingState()
    rating.answer(state, choice, os.time())
    self:saveSetting("rating", state)
end

function Grimmory:showRatingQR()
    self:closeMenu()
    require("grimmoryui/ratingui").showQR()
end

-- Über und Selbst-Update ---------------------------------------------------------------------

function Grimmory:showAbout()
    self:closeMenu()
    local version = self.version or "?"
    local repo = self:setting("update_repo")
    local text = T(_("Grimmory-Plugin %1"), version) .. "\n\n"
        .. _("Zeigt die Bibliothek eines Grimmory-Servers und öffnet die Bücher in KOReader.")
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Nach Updates suchen"),
        ok_callback = function() self:checkUpdate(repo, version) end,
    })
end

function Grimmory:checkUpdate(repo, version)
    local updater = require("grimmoryui/updater")
    NetworkMgr:runWhenConnected(function()
        local release, err = updater.check(repo, version)
        if not release then
            UIManager:show(InfoMessage:new{ text = err and T(_("Prüfung fehlgeschlagen: %1"), err)
                or T(_("Version %1 ist aktuell."), version) })
            return
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("Version %1 ist verfügbar."), release.version) .. "\n\n" .. release.notes:sub(1, 600),
            ok_text = _("Installieren"),
            ok_callback = function()
                local info = InfoMessage:new{ text = _("Update wird geladen …") }
                UIManager:show(info)
                UIManager:forceRePaint()
                local ok, install_err = updater.install(release.url, self.path, self.dir)
                UIManager:close(info)
                if ok then
                    UIManager:askForRestart(_("Update installiert. KOReader jetzt neu starten?"))
                else
                    UIManager:show(InfoMessage:new{ text = T(_("Update fehlgeschlagen: %1"), install_err) })
                end
            end,
        })
    end)
end

return Grimmory
