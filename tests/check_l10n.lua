-- Prüft die Übersetzungen gegen die englische Datei, die alle Schlüssel enthält: fehlende und
-- überzählige Einträge, Platzhalter %1 … und die Zahl der Pluralformen. Aufruf aus dem Repo-Ordner:
--   luajit tests/check_l10n.lua
local dir = "grimmory.koplugin/grimmory/l10n/"
local FORMS = { pl = 3, ro = 3, ja = 1, zh_CN = 1, id = 1 }
local DATE = "[aAbBdeHIjmMpyY]"

local function placeholders(s)
    local t = {}
    for d in s:gmatch("%%(%d)") do t[#t + 1] = d end
    table.sort(t)
    return table.concat(t, ",")
end

local en = dofile(dir .. "en.lua")
local codes = {}
local p = io.popen('ls "' .. dir .. '"')
for name in p:lines() do
    local code = name:match("^(.+)%.lua$")
    if code and code ~= "en" then codes[#codes + 1] = code end
end
p:close()
table.sort(codes)

local problems = 0
local function bad(code, msg)
    problems = problems + 1
    print(code .. ": " .. msg)
end

for _, code in ipairs(codes) do
    local ok, t = pcall(dofile, dir .. code .. ".lua")
    if not ok then
        bad(code, tostring(t))
    else
        for id, ref in pairs(en) do
            local v = t[id]
            local want = placeholders(id)
            if v == nil then
                bad(code, "fehlt: " .. id)
            elseif type(ref) == "table" then
                local n = FORMS[code] or 2
                if type(v) ~= "table" or #v ~= n then
                    bad(code, string.format("%d Pluralformen erwartet: %s", n, id))
                else
                    for _, form in ipairs(v) do
                        if placeholders(form) ~= want then bad(code, "Platzhalter: " .. form) end
                    end
                end
            elseif type(v) ~= "string" then
                bad(code, "Text erwartet: " .. id)
            elseif id:find("%%[HdM]") then
                for spec in v:gmatch("%%(.)") do
                    if not spec:match(DATE) then bad(code, "Datumsformat: " .. v) end
                end
            elseif placeholders(v) ~= want then
                bad(code, "Platzhalter: " .. v)
            end
        end
        for id in pairs(t) do
            if en[id] == nil then bad(code, "überzählig: " .. id) end
        end
    end
end
print(string.format("%d Sprachen geprüft, %d Probleme", #codes, problems))
os.exit(problems == 0 and 0 or 1)
