--[[--
Übersetzungen. Die Texte im Code sind deutsch und zugleich die Schlüssel, `l10n/<sprache>.lua`
ordnet ihnen die Übersetzung zu. Die Sprache kommt aus KOReader, ohne Datei für sie gilt Englisch.
Fehlt ein Eintrag in einer Sprache, steht er englisch da.

    local _ = require("grimmoryui/i18n")
    _("Regal")
    _.T(_("Seite %1 von %2"), 3, 7)
    _.ngettext("%1 Buch", "%1 Bücher", n)

Plural: Der Eintrag ist dann eine Liste der Formen, die Regel der Sprache wählt eine aus.
Platzhalter %1, %2 … dürfen in der Übersetzung die Reihenfolge wechseln.
]]

local M = {}

-- Welche Pluralform gilt für n? Nach den Plural-Forms von gettext, Formen ab 1 gezählt.
local function zeroOne(n) return n > 1 and 2 or 1 end
local function one() return 1 end
local PLURAL = {
    fr = zeroOne, hi = zeroOne, bn = zeroOne,
    ja = one, zh_CN = one, id = one,
    pl = function(n)
        if n == 1 then return 1 end
        local a, b = n % 10, n % 100
        return (a >= 2 and a <= 4 and (b < 12 or b > 14)) and 2 or 3
    end,
    ro = function(n)
        if n == 1 then return 1 end
        local b = n % 100
        return (n == 0 or (b >= 1 and b <= 19)) and 2 or 3
    end,
}
local function default(n) return n == 1 and 1 or 2 end

local function load(code)
    local ok, t = pcall(require, "grimmoryui/l10n/" .. code)
    if ok and type(t) == "table" then return t end
end

--- Eigene Sprache des Plugins aus seinen Einstellungen, nil heißt „wie KOReader“.
local function ownLanguage()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not (ok_ds and ok_ls) then return nil end
    local ok, lang = pcall(function()
        return LuaSettings:open(DataStorage:getSettingsDir() .. "/grimmory-ui.lua"):readSetting("language")
    end)
    return ok and lang or nil
end

--- Sprache des Plugins, sonst aus KOReader: "de", "pt_BR", "C" (Englisch) oder nil außerhalb von
--- KOReader.
local function language()
    local own = ownLanguage()
    if own then return own end
    local lang = G_reader_settings and G_reader_settings:readSetting("language")
    if lang then return lang end
    local ok, gettext = pcall(require, "gettext")
    return ok and type(gettext) == "table" and gettext.current_lang or nil
end

-- Außerhalb von KOReader (Tests) und auf Deutsch bleiben die Schlüssel stehen.
local lang = language()
local primary, rule, english
if lang and not lang:match("^de") then
    local code = lang:match("^[^.:]+")
    local base = code:match("^%a+")
    if code ~= "C" and base ~= "en" then
        primary = load(code) or load(base)
        rule = PLURAL[load(code) and code or base] or default
    end
    english = load("en")
end
M.lang = lang

--- Sprachen mit Übersetzung, mit ihrem eigenen Namen. Code wie in KOReader.
M.LANGUAGES = {
    { code = "de", name = "Deutsch" }, { code = "en", name = "English" }, { code = "fr", name = "Français" },
    { code = "es", name = "Español" }, { code = "it", name = "Italiano" }, { code = "pt", name = "Português" },
    { code = "pl", name = "Polski" }, { code = "ro", name = "Română" }, { code = "nl", name = "Nederlands" },
    { code = "el", name = "Ελληνικά" }, { code = "zh_CN", name = "简体中文" }, { code = "ja", name = "日本語" },
    { code = "hi", name = "हिन्दी" }, { code = "bn", name = "বাংলা" }, { code = "id", name = "Bahasa Indonesia" },
}

--- Eigener Name einer Sprache aus KOReader ("pt_BR" → "Português"), sonst der Code.
function M.languageName(code)
    if not code then return nil end
    local base = code:match("^%a+")
    if code == "C" or base == "en" then return "English" end
    for _, l in ipairs(M.LANGUAGES) do if l.code == code then return l.name end end
    for _, l in ipairs(M.LANGUAGES) do if l.code == base then return l.name end end
    return code
end

local function lookup(msgid)
    local s = primary and primary[msgid]
    if s ~= nil then return s, rule end
    s = english and english[msgid]
    if s ~= nil then return s, default end
end

function M.gettext(msgid)
    local s = lookup(msgid)
    if type(s) == "table" then s = s[1] end
    return s or msgid
end

function M.ngettext(singular, plural, n)
    local s, pick = lookup(singular)
    if type(s) == "table" then return s[math.min(pick(n), #s)] end
    if s then return s end
    return n == 1 and singular or plural
end

--- Setzt Werte für %1, %2 … ein.
function M.T(fmt, ...)
    local args = { ... }
    return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

return setmetatable(M, { __call = function(_, msgid) return M.gettext(msgid) end })
