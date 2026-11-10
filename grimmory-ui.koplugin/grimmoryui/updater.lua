--[[--
Selbst-Update über GitHub-Releases, ohne Rechner.

Ein Release trägt ein Zip `grimmory-ui.koplugin-vX.Y.Z.zip`, das den Ordner `grimmory-ui.koplugin/`
enthält. Das Update lädt es herunter, packt es neben den Plugin-Ordner aus und tauscht den Ordner
erst danach aus. Bricht etwas ab, bleibt die alte Version unberührt.
]]

local JSON = require("json")
local api = require("grimmoryui/api")
local version = require("grimmoryui/version")
local _ = require("grimmoryui/i18n")

local M = {}

local FOLDER = "grimmory-ui.koplugin"

local HEADERS = {
    ["Accept"] = "application/vnd.github+json",
    ["User-Agent"] = FOLDER,
}

--- Das passende Zip aus einem Release, oder nil.
function M.pickAsset(release)
    for _, asset in ipairs(type(release) == "table" and release.assets or {}) do
        if (asset.name or ""):match("^grimmory%-ui%.koplugin.*%.zip$") then return asset end
    end
    return nil
end

--- Fragt das neueste Release ab. Ergebnis: { version, notes, url } oder nil (keins neuer) bzw.
--- nil und Fehler.
function M.check(repo, current)
    if not repo or repo == "" then return nil, _("Kein GitHub-Repo eingetragen") end
    local headers = {}
    for k, v in pairs(HEADERS) do headers[k] = v end
    local code, body = api.fetch("GET", "https://api.github.com/repos/" .. repo .. "/releases/latest", headers)
    if code ~= 200 then return nil, api.describe(code or body) end
    local ok, release = pcall(JSON.decode, body)
    if not ok or type(release) ~= "table" then return nil, _("Antwort von GitHub ist kein JSON") end
    local asset = M.pickAsset(release)
    if not asset or not version.newer(release.tag_name, current) then return nil end
    return { version = release.tag_name, notes = release.body or "", url = asset.browser_download_url }
end

--- Lädt `url` nach `file` und folgt dabei Weiterleitungen (GitHub leitet auf seinen Speicher um).
function M.download(url, file)
    for _ = 1, 5 do
        local headers = { ["User-Agent"] = HEADERS["User-Agent"] }
        local code, err, resp = api.fetch("GET", url, headers, { file = file })
        if code == 200 then return true end
        local location = resp and resp.location
        if not (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) or not location then
            os.remove(file)
            return nil, api.describe(code or err)
        end
        url = location
    end
    os.remove(file)
    return nil, _("Zu viele Weiterleitungen")
end

--- Lädt das Release-Zip, packt es in einen Nachbarordner aus und tauscht dann den Plugin-Ordner.
--- `plugin_path` ist der Ordner grimmory-ui.koplugin, `work_dir` ein beschreibbarer Arbeitsordner.
function M.install(url, plugin_path, work_dir)
    local Archiver = require("ffi/archiver")
    local ffiUtil = require("ffi/util")
    local util = require("util")
    local lfs = require("libs/libkoreader-lfs")

    local zip = work_dir .. "/update.zip"
    local ok, err = M.download(url, zip)
    if not ok then return nil, err end

    local parent = ffiUtil.dirname(plugin_path)
    local staging = parent .. "/.grimmory-ui-update"
    if lfs.attributes(staging, "mode") then ffiUtil.purgeDir(staging) end
    util.makePath(staging)

    local arc = Archiver.Reader:new()
    if not arc:open(zip) then
        os.remove(zip)
        return nil, _.T(_("Zip nicht lesbar: %1"), arc.err)
    end
    for entry in arc:iterate() do
        if entry.mode == "file" then
            local target = staging .. "/" .. entry.path
            util.makePath(ffiUtil.dirname(target))
            if not arc:extractToPath(entry.path, target) then break end
        end
    end
    err = arc.err
    arc:close()
    os.remove(zip)
    local fresh = staging .. "/" .. FOLDER
    if err or lfs.attributes(fresh .. "/main.lua", "mode") ~= "file" then
        ffiUtil.purgeDir(staging)
        return nil, err or _.T(_("Zip enthält keinen Ordner %1"), FOLDER)
    end

    -- Erst die alte Version beiseitelegen, dann die neue an ihren Platz. Geht das schief, kommt die
    -- alte zurück.
    local old = parent .. "/.grimmory-ui-old"
    if lfs.attributes(old, "mode") then ffiUtil.purgeDir(old) end
    if not os.rename(plugin_path, old) then
        ffiUtil.purgeDir(staging)
        return nil, _("Plugin-Ordner nicht beschreibbar")
    end
    if not os.rename(fresh, plugin_path) then
        os.rename(old, plugin_path)
        ffiUtil.purgeDir(staging)
        return nil, _("Neue Version konnte nicht abgelegt werden")
    end
    ffiUtil.purgeDir(old)
    ffiUtil.purgeDir(staging)
    return true
end

return M
