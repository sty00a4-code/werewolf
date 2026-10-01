local Game = require "game"
local M = {}

local TITLES = { lobby = "LOBBY", night = "NIGHT", day = "DAY", over = "GAME OVER" }

---@param v View
---@return table
local function header(v)
    local title = TITLES[v.phase]
    if v.phase == "night" or v.phase == "day" then title = title .. " " .. v.round end
    local kids = { class = "bar", h2 { title } }
    return div(kids)
end

---@param v View
---@param with_kick boolean
---@return HTMLElement
local function roster(v, with_kick)
    local items = { class = "roster" }
    for _, pl in ipairs(v.players) do
        local kids = { class = pl.alive and "alive" or "dead", esc(pl.name) }
        ---@diagnostic disable-next-line: assign-type-mismatch
        if pl.role then kids[#kids + 1] = em { " (" .. Game.roles[pl.role].name .. ")" } end
        ---@diagnostic disable-next-line: assign-type-mismatch
        if with_kick then kids[#kids + 1] = button { class = "small", onclick = ("act('kick', %d)"):format(pl.id), "x" } end
        items[#items + 1] = li(kids)
    end
    return div { class = "card", h3 { ("Players (%d)"):format(#v.players) }, ul(items) }
end

---@param v View
---@return HTMLElement?
local function log_box(v)
    if #v.log == 0 then return nil end
    local kids = { class = "card log", h3 { "What happened" } }
    for idx = #v.log, 1, -1 do kids[#kids + 1] = p { esc(v.log[idx]) } end
    return div(kids)
end

---@param v View
---@return HTMLElement?
local function banner(v)
    if v.phase ~= "over" then return nil end
    return div { class = "card banner", h2 { v.winner == "village" and "The village wins!" or "The werewolves win!" } }
end

---@param v View
---@return HTMLElement?
local function role_card(v)
    local role = Game.roles[v.you.role]
    local kids = { class = "card role-" .. v.you.team, h3 { "You are the ", strong { role.name } }, p { role.blurb } }
    if not v.you.alive then kids[#kids + 1] = p { class = "dead-note", "You are dead. Watch quietly, no talking!" } end
    return div(kids)
end

---@param v View
---@return HTMLElement?
local function action_card(v)
    local a = v.action
    if not a then return nil end
    local kids = { class = "card action", h3 { a.prompt } }
    if a.locked then
        kids[#kids + 1] = p { "You chose ", strong { esc(a.chosen_name) }, ". Waiting for dawn..." }
    elseif a.verb then
        for _, t in ipairs(a.targets) do
            kids[#kids + 1] = button {
                class = (a.chosen == t.id) and "selected" or nil,
                onclick = ("act('%s', %d)"):format(a.verb, t.id),
                esc(t.name),
            }
        end
        if a.verb == "vote" then
            kids[#kids + 1] = button { class = (a.chosen == 0) and "selected" or nil, onclick = "act('vote', 0)", "Abstain" }
            kids[#kids + 1] = p { em { v.progress.voted .. " of " .. v.progress.total .. " have voted." } }
        end
    end
    return div(kids)
end

---@param v View
---@return HTMLElement[]
local function private_cards(v)
    local out = {}
    if v.notes and #v.notes > 0 then
        local kids = { class = "card notes", h3 { "Your secret knowledge" } }
        for _, n in ipairs(v.notes) do kids[#kids + 1] = p { esc(n) } end
        out[#out + 1] = div(kids)
    end
    if v.pack and #v.pack > 0 then
        local kids = { class = "card notes", h3 { "The pack's choices" } }
        for _, e in ipairs(v.pack) do kids[#kids + 1] = p { esc(e.wolf) .. " wants " .. esc(e.target) } end
        out[#out + 1] = div(kids)
    end
    return out
end

---@param parts HTMLElement[]
---@return string
local function assemble(parts)
    local list = { id = "view" }
    for _, part in ipairs(parts) do list[#list + 1] = part end
    return tostring(div(list))
end

---@param v View
---@return string
function M.client(v)
    local parts = { header(v) }
    if v.phase == "lobby" then
        parts[#parts + 1] = div { class = "card", h3 { "You're in, ", esc(v.you.name), "!" }, p { "Waiting for the host to start the game." } }
        parts[#parts + 1] = roster(v, false)
    else
        parts[#parts + 1] = banner(v)
        parts[#parts + 1] = role_card(v)
        parts[#parts + 1] = roster(v, false)
        parts[#parts + 1] = action_card(v)
        for _, c in ipairs(private_cards(v)) do parts[#parts + 1] = c end
        parts[#parts + 1] = log_box(v)
    end
    return assemble(parts)
end

---fragment for the shared host screen (public information only)
---@param v View
---@return string
function M.host(v)
    local parts = { header(v) }
    if v.phase == "lobby" then
        parts[#parts + 1] = div { class = "card", p { "Join at this site with the code:" }, div { class = "bigcode", v.code } }
        parts[#parts + 1] = roster(v, true)
        parts[#parts + 1] = p { em { ("Need at least %d players."):format(v.min_players) } }
        parts[#parts + 1] = button { onclick = "act('start')", "START GAME" }
    else
        parts[#parts + 1] = banner(v)
        parts[#parts + 1] = roster(v, false)
        if v.phase == "night" then
            parts[#parts + 1] = p { "Night falls. Everyone close your eyes and wait to be called by the host." }
        elseif v.phase == "day" then
            parts[#parts + 1] = p { "Discuss, then vote on your phones. Votes in: " .. v.progress.voted .. "/" .. v.progress.total }
        end
        parts[#parts + 1] = log_box(v)
        if v.phase == "over" then
            parts[#parts + 1] = button { onclick = "act('restart')", "PLAY AGAIN" }
        else
            parts[#parts + 1] = button { class = "small", onclick = "act('next')", "Next" }
        end
    end
    return assemble(parts)
end

local CLIENT_JS = [==[
const q = new URLSearchParams(location.search);
const code = q.get('code') || '';
const auth = q.get('key')
    ? 'key=' + encodeURIComponent(q.get('key'))
    : 'token=' + encodeURIComponent(q.get('token') || '');
const app = document.getElementById('app');
let version = -1, skew = 0, busy = false, again = false, stopped = false;

async function poll() {
    if (stopped) return;
    if (busy) { again = true; return; }
    busy = true;
    try {
    const r = await fetch('/api/view?code=' + code + '&' + auth + '&v=' + version, { cache: 'no-store' });
    const st = r.headers.get('X-Server-Time');
    if (st) skew = Number(st) - Date.now() / 1000;
    if (r.status === 200) {            // something changed: swap in the new fragment
        app.innerHTML = await r.text();
        version = Number(r.headers.get('X-Version'));
        tick();
    } else if (r.status >= 400) {      // game gone / bad token: stop polling and say why
        stopped = true;
        app.textContent = await r.text();
    }                                  // 204 = nothing new
    } catch (e) { /* server busy or restarting: retry on the next tick */ }
    busy = false;
    if (again) { again = false; poll(); }
}

async function act(type, target) {
    const r = await fetch('/api/action?code=' + code + '&' + auth + '&type=' + type + '&target=' + (target ?? ''), { method: 'POST' });
    if (!r.ok) alert(await r.text());
    poll();
}

function tick() { // countdowns run locally between polls
    const now = Date.now() / 1000 + skew;
    document.querySelectorAll('[data-end]').forEach(el => {
        el.textContent = Math.max(0, Math.ceil(Number(el.dataset.end) - now)) + 's';
    });
}

setInterval(tick, 250);
setInterval(poll, 1000);
poll();
]==]

--- the static page shell for /host and /client; everything inside #app arrives via polling
function M.page()
    return response {
        body = WRAPPER {
            h1 { img { src = "/wolf.png", width = "64", height = "64" }, "Were Wolf" },
            div { id = "app", class = "game", p { "Loading..." } },
            script { CLIENT_JS },
        },
    }
end

return M
