--[[--
Bitte um einen Stern auf GitHub, ohne KOReader testbar.

Das Kästchen erscheint zum ersten Mal, wenn man nach dem dritten mit dem Plugin zu Ende gelesenen
Buch ins Plugin zurückkommt. „Später“ fragt nach 30 Tagen noch ein einziges Mal, „Bewerten“ und
das Kreuz fragen nie wieder. Gezählt wird nur auf dem Gerät, gesendet wird nichts.

Der Zustand ist eine Tabelle in den Einstellungen: finished (gezählte Buch-IDs), count, asked
(wie oft beantwortet), snooze_until, done.
]]

local M = {}

M.REPO_URL = "https://github.com/rolschewsky/grimmory-ui.koplugin"
M.AFTER_BOOKS = 3
M.SNOOZE = 30 * 86400

--- Ein zu Ende gelesenes Buch zählen, jedes nur einmal. Gibt true zurück, wenn es neu war.
function M.record(state, book_id)
    if state.done or book_id == nil then return false end
    state.finished = state.finished or {}
    local key = tostring(book_id)
    if state.finished[key] then return false end
    state.finished[key] = true
    state.count = (state.count or 0) + 1
    return true
end

--- Ob das Kästchen jetzt erscheinen soll. `just_finished`: gerade ein Buch zu Ende gelesen.
function M.due(state, now, just_finished)
    if state.done then return false end
    local asked = state.asked or 0
    if asked == 0 then return just_finished == true and (state.count or 0) >= M.AFTER_BOOKS end
    return asked == 1 and now >= (state.snooze_until or 0)
end

--- Antwort merken: "rate", "later" oder "never".
function M.answer(state, choice, now)
    state.asked = (state.asked or 0) + 1
    if choice == "later" and state.asked < 2 then
        state.snooze_until = now + M.SNOOZE
    else
        state.done = true
        state.finished = nil
    end
end

return M
