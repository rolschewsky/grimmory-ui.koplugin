--[[--
Übersetzungen. Die Texte im Code sind deutsch und zugleich die Schlüssel, `l10n/<sprache>.lua`
ordnet ihnen die Übersetzung zu. Die Sprache kommt aus KOReader, ohne Datei für sie gilt Englisch.
Fehlt ein Eintrag in einer Sprache, steht er englisch da.

    local _ = require("grimmory/i18n")
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
    local ok, t = pcall(require, "grimmory/l10n/" .. code)
    if ok and type(t) == "table" then return t end
end

--- Sprache aus KOReader: "de", "pt_BR", "C" (Englisch) oder nil außerhalb von KOReader.
local function language()
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
