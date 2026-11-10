--[[--
Vergleich von Versionsnummern wie "v1.4.0" oder "1.4.0-beta2" für das Selbst-Update.
Eine Vorabversion ist älter als dieselbe Version ohne Zusatz.
]]

local M = {}

function M.parse(v)
    local major, minor, patch, pre = tostring(v or ""):match("^v?(%d+)%.(%d+)%.?(%d*)%-?(.*)$")
    if not major then return nil end
    return { tonumber(major), tonumber(minor), tonumber(patch) or 0, pre = pre }
end

--- Ist `a` neuer als `b`? Unlesbare Versionen sind nie neuer.
function M.newer(a, b)
    local va, vb = M.parse(a), M.parse(b)
    if not va or not vb then return false end
    for i = 1, 3 do
        if va[i] ~= vb[i] then return va[i] > vb[i] end
    end
    if va.pre == vb.pre then return false end
    if va.pre == "" then return true end
    if vb.pre == "" then return false end
    return va.pre > vb.pre
end

return M
