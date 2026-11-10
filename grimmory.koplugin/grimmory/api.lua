--[[--
Client für die Grimmory-API (getestet gegen Grimmory 3.5.0).

Anmeldung per JWT: POST /api/v1/auth/login liefert ein Zugangs-Token (2 Stunden) und ein
Erneuerungs-Token (30 Tage). Läuft das Zugangs-Token ab, erneuert der Client es einmal und
wiederholt den Aufruf. Klappt das nicht, meldet er sich neu an.

Jeder HTTPS-Aufruf prüft das Zertifikat gegen das CA-Bundle von KOReader und den Hostnamen,
weil LuaSec von sich aus weder das eine noch das andere tut.
]]

local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local _ = require("grimmory/i18n")

-- Relativ zum Arbeitsverzeichnis von KOReader.
local CAFILE = "data/ca-bundle.crt"

local M = {}

--- Passt ein Name aus dem Zertifikat (auch `*.domain`) auf den Host?
function M.hostMatches(pattern, host)
    pattern, host = pattern:lower(), host:lower()
    if pattern == host then return true end
    local suffix = pattern:match("^%*(%.[^*]+)$")
    if not suffix then return false end
    return host:match("^[^.]+(%..+)$") == suffix
end

--- Basisadresse ohne abschließenden Schrägstrich, nur http(s).
function M.normalizeBase(base)
    base = (base or ""):gsub("%s", ""):gsub("/+$", "")
    if not base:match("^https?://[^/]+") then return nil end
    return base
end

--- Dateiname aus einem Content-Disposition-Header, ohne Pfadanteile.
function M.filenameFromDisposition(value)
    if not value then return nil end
    local name = value:match("filename%*=[Uu][Tt][Ff]%-8''([^;]+)")
    if name then
        name = name:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    else
        name = value:match('filename="([^"]+)"') or value:match("filename=([^;]+)")
    end
    if not name then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("[/\\]", "_")
    if name == "" or name == "." or name == ".." then return nil end
    return name
end

--- Klartext für einen Fehler: Zahl = HTTP-Status, sonst Meldung.
function M.describe(err)
    if err == 401 then return _("Anmeldung abgelehnt (401)") end
    if err == 403 then return _("Zugriff verweigert (403), Rechte oder Header prüfen") end
    if err == 404 then return _("Nicht gefunden (404), Adresse prüfen") end
    if err == 502 or err == 504 then return _.T(_("Server hinter dem Proxy nicht erreichbar (%1)"), err) end
    if type(err) == "number" then return "HTTP " .. err end
    -- Meldungen von LuaSocket und LuaSec. LuaSec meldet eine Zeitüberschreitung als „wantread“,
    -- beim Handshake wie beim Warten auf die Antwort (etwa wenn ein Proxy das Ziel nicht erreicht).
    local text = tostring(err or _("unbekannter Fehler"))
    local timeout = _("Keine Antwort vom Server (Zeitüberschreitung), Netz und Freigaben prüfen")
    local unresolved = _("Name nicht auflösbar, Adresse prüfen")
    local known = {
        { "^wantread", timeout },
        { "^wantwrite", timeout },
        { "^timeout", timeout },
        { "^connection refused", _("Verbindung abgelehnt, Adresse und Port prüfen") },
        -- Kommt vom Gerät selbst, bevor eine Anfrage rausgeht, etwa wenn das WLAN nach dem Aufwachen noch verbindet.
        { "^network is unreachable", _("Kein Netz, WLAN noch nicht verbunden? Gleich noch einmal versuchen") },
        { "^host or service not provided", _("Adresse unvollständig") },
        { "not known", unresolved },
        { "^host not found", unresolved },
    }
    for _, k in ipairs(known) do
        if text:find(k[1]) then return k[2] .. " (" .. text .. ")" end
    end
    return text
end

local function certNames(cert)
    local names = {}
    local ok, exts = pcall(cert.extensions, cert)
    if ok and type(exts) == "table" then
        for _, ext in pairs(exts) do
            if type(ext) == "table" and type(ext.dNSName) == "table" then
                for _, name in ipairs(ext.dNSName) do table.insert(names, name) end
            end
        end
    end
    return names
end

-- Wie LuaSec, aber mit Prüfung der Kette gegen das CA-Bundle und des Hostnamens.
local function checkedCreate()
    local https = require("ssl.https")
    local base_create = https.tcp{
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
        verify = "peer",
        cafile = CAFILE,
    }
    return function()
        local conn = base_create()
        local connect = conn.connect
        conn.connect = function(self, host, port)
            local ok = connect(self, host, port)
            local cert = self.sock:getpeercertificate()
            for _, name in ipairs(cert and certNames(cert) or {}) do
                if M.hostMatches(name, host) then return ok end
            end
            self.sock:close()
            socket.try(nil, _.T(_("Zertifikat passt nicht zu %1"), host))
        end
        return conn
    end
end

local Client = {}
Client.__index = Client

--- cfg: base, username, password, headers ({ {name=, value=}, … }), tokens (gespeicherte Tokens),
--- on_tokens (Funktion, bekommt neue Tokens zum Speichern).
function M.new(cfg)
    local base = M.normalizeBase(cfg.base)
    if not base then return nil, _("Server-Adresse ungültig") end
    return setmetatable({
        base = base,
        username = cfg.username or "",
        password = cfg.password or "",
        headers = cfg.headers or {},
        tokens = cfg.tokens or {},
        on_tokens = cfg.on_tokens,
    }, Client)
end

--- Ein HTTP-Aufruf mit Zertifikatsprüfung bei https. opts: json (Tabelle als Body),
--- file (Body in diese Datei), redirect (Vorgabe false).
--- Gibt Status-Code, Body und Header zurück, bei Netzwerkfehlern nil und die Meldung.
function M.fetch(method, full_url, headers, opts)
    opts = opts or {}
    local chunks = {}
    local req = { url = full_url, method = method, headers = headers, redirect = opts.redirect or false }
    if full_url:match("^https://") then req.create = checkedCreate() end
    if opts.json then
        local body = JSON.encode(opts.json)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
        req.source = ltn12.source.string(body)
    end
    local fh
    if opts.file then
        fh = io.open(opts.file, "wb")
        if not fh then return nil, _.T(_("Datei nicht schreibbar: %1"), opts.file) end
        req.sink = ltn12.sink.file(fh)
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    else
        req.sink = ltn12.sink.table(chunks)
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end
    local code, resp_headers, status = socket.skip(1, http.request(req))
    socketutil:reset_timeout()
    if resp_headers == nil then return nil, tostring(status or code) end
    return code, table.concat(chunks), resp_headers
end

--- Ein Aufruf gegen den Server. opts wie bei fetch, dazu auth (Vorgabe true).
function Client:raw(method, path, opts)
    opts = opts or {}
    local headers = { ["Accept"] = "application/json" }
    for _, h in ipairs(self.headers) do
        if h.name and h.name ~= "" then headers[h.name] = h.value or "" end
    end
    if opts.auth ~= false and self.tokens.access then
        headers["Authorization"] = "Bearer " .. self.tokens.access
    end
    return M.fetch(method, self.base .. path, headers, opts)
end

local function decode(body)
    local ok, data = pcall(JSON.decode, body)
    if ok and type(data) == "table" then return data end
    return nil
end

function Client:storeTokens(data)
    self.tokens = {
        access = data.accessToken,
        refresh = data.refreshToken or self.tokens.refresh,
    }
    if self.on_tokens then self.on_tokens(self.tokens) end
end

function Client:login()
    local code, body = self:raw("POST", "/api/v1/auth/login",
        { json = { username = self.username, password = self.password }, auth = false })
    local data = code == 200 and decode(body)
    if not data or not data.accessToken then return nil, code or body end
    self:storeTokens(data)
    return true
end

-- Das Erneuerungs-Token gilt erst zwei Minuten nach der Ausstellung. Schlägt die Erneuerung fehl,
-- bleibt die Neuanmeldung.
function Client:refresh()
    if not self.tokens.refresh then return nil end
    local code, body = self:raw("POST", "/api/v1/auth/refresh",
        { json = { refreshToken = self.tokens.refresh }, auth = false })
    local data = code == 200 and decode(body)
    if not data or not data.accessToken then return nil, code end
    self:storeTokens(data)
    return true
end

--- Wie raw, aber mit Anmeldung bei Bedarf: Bei 401 einmal erneuern oder neu anmelden.
function Client:call(method, path, opts)
    if not self.tokens.access then
        local ok, err = self:login()
        if not ok then return nil, err end
    end
    local code, body, headers = self:raw(method, path, opts)
    if code == 401 then
        if not (self:refresh() or self:login()) then return 401 end
        code, body, headers = self:raw(method, path, opts)
    end
    return code, body, headers
end

function Client:getJSON(path)
    local code, body = self:call("GET", path)
    if code ~= 200 then return nil, code or body end
    local data = decode(body)
    if not data then return nil, _("Antwort ist kein JSON") end
    return data
end

--- Alle Seiten einer Spring-Page-Antwort ({content, hasNext}) einsammeln.
function Client:getAllPages(path, size)
    local sep = path:find("?", 1, true) and "&" or "?"
    local items, page = {}, 0
    while true do
        local data, err = self:getJSON(string.format("%s%spage=%d&size=%d", path, sep, page, size or 100))
        if not data then return nil, err end
        for _, item in ipairs(data.content or {}) do table.insert(items, item) end
        if not data.hasNext then return items end
        page = page + 1
    end
end

function Client:me() return self:getJSON("/api/v1/users/me") end
function Client:books() return self:getAllPages("/api/v1/app/books?sort=addedOn&dir=desc") end
function Client:series() return self:getAllPages("/api/v1/app/series") end
function Client:bookDetail(id) return self:getJSON("/api/v1/app/books/" .. id) end

--- Lädt das kleine Cover (250 × 350) in `file`.
function Client:thumbnail(id, file)
    local code = self:call("GET", "/api/v1/media/book/" .. id .. "/thumbnail", { file = file })
    return code == 200, code
end

--- Lädt das Buch in `file`. Gibt den Dateinamen aus dem Header zurück.
function Client:download(id, file)
    local code, err, headers = self:call("GET", "/api/v1/books/" .. id .. "/download", { file = file })
    if code ~= 200 then return nil, code or err end
    return M.filenameFromDisposition(headers and headers["content-disposition"]) or true
end

--- Lesestatus in Grimmory setzen, z. B. "READ" oder "READING".
function Client:setStatus(id, status)
    local code = self:call("PUT", "/api/v1/app/books/" .. id .. "/status", { json = { status = status } })
    return code == 200 or code == 204, code
end

return M
