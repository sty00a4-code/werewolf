-- Run from the project folder:  lua5.4 test.lua
-- Engine tests talk to Game directly; the HTTP tests go through route()/request()/response() (no sockets needed).
require "libs"
require "std"
local state = require "gamestate"
local Game = require "game"

local passed = 0
local function check(cond, msg)
    if not cond then error("FAIL: " .. msg, 2) end
    passed = passed + 1
    print("ok  " .. msg)
end

local function logtext(room)
    local t = {}
    for _, e in ipairs(room.log) do t[#t + 1] = e.text end
    return table.concat(t, "\n")
end
local function count(s, pat)
    local n = 0
    for _ in s:gmatch(pat) do n = n + 1 end
    return n
end

--- room with n players "P1".."Pn"; `configure(room)` runs before the start; `roles` (by join order) overrides the deal
local function game(n, roles, configure)
    local room = Game.new("TESTCODE")
    for i = 1, n do assert(room:join("P" .. i)) end
    if configure then configure(room) end
    assert(room:host_act("start"))
    for i, pl in ipairs(room.order) do pl.role = roles[i] end
    return room
end
local function set(room, name, value) return room:host_act("set", nil, { name = name, value = value }) end
local function P(room, i) return room.order[i] end
local BASIC = { "werewolf", "seer", "doctor", "villager", "villager" }

----------------------------------------------------------------------
print("\n-- settings: defaults, validation")
local a, b = Game.new("AAAAAAAA"), Game.new("BBBBBBBB")
check(a.settings.wolves == 0 and a.settings.reveal_role == true and a.settings.tie_rule == "nobody", "defaults match the old behaviour")
assert(set(a, "reveal_role", "0"))
check(a.settings.reveal_role == false and b.settings.reveal_role == true, "rooms don't share settings")
check(set(a, "wolves", "3") and a.settings.wolves == 3, "int rule accepted")
check(not set(a, "wolves", "9") and not set(a, "wolves", "-1") and not set(a, "wolves", "1.5") and not set(a, "wolves", "abc"), "int rule rejects out-of-range / fractional / junk")
check(not set(a, "reveal_role", "yes") and not set(a, "nope", "1"), "bool rule rejects junk, unknown rule rejected")
check(set(a, "tie_rule", "random") and not set(a, "tie_rule", "coin"), "choice rule only takes listed options")
local v0 = a.version
assert(set(a, "allow_abstain", "0"))
check(a.version > v0, "changing a rule bumps the version (clients re-render)")

print("\n-- roles: toggling and the deck")
check(a:host_act("role", nil, { name = "slut", value = "0" }) and a.active_roles.slut == false, "optional role can be disabled")
check(not a:host_act("role", nil, { name = "werewolf", value = "0" }) and not a:host_act("role", nil, { name = "villager", value = "0" }), "core roles can't be disabled")
check(not a:host_act("role", nil, { name = "seer", value = "maybe" }), "role toggle rejects junk")
check(#Game.optional_roles == 3 and Game.optional_roles[1] == "doctor", "optional roles are stable and sorted")

local function plan_of(room, n)
    local plan, err = room:plan_deck(n)
    local m = {}
    for _, e in ipairs(plan) do m[e.role] = e.count end
    return m, err
end
local d = Game.new("DECKDECK")
local m = plan_of(d, 8)
check(m.werewolf == 2 and m.seer == 1 and m.doctor == 1 and m.slut == 1 and m.villager == 3, "8 players, everything on: 2 wolves + 3 specials + 3 villagers")
for _, k in ipairs(Game.optional_roles) do d.active_roles[k] = false end
m = plan_of(d, 8)
check(m.werewolf == 2 and m.villager == 6 and m.seer == nil, "all optional roles off: wolves + villagers only")
d.settings.wolves = 4
local _, err = plan_of(d, 8)
check(err and err:find("too many"), "too many werewolves is refused: " .. tostring(err))
d.settings.wolves = 0
for _, k in ipairs(Game.optional_roles) do d.active_roles[k] = true end
m, err = plan_of(d, 4)
check(not err and m.villager == 0, "4 players with every role on exactly fills the table")
d.settings.wolves = 2
_, err = plan_of(d, 4)
check(err, "more roles than players is refused instead of silently dropping some")

local n = Game.new("DEALDEAL")
for i = 1, 6 do n:join("P" .. i) end
n.settings.wolves = 2
n:host_act("role", nil, { name = "doctor", value = "0" })
local bad = 0
for _ = 1, 40 do
    local g = Game.new("DEALDEAL")
    g.settings.wolves = 2
    g.active_roles.doctor = false
    for i = 1, 6 do g:join("P" .. i) end
    assert(g:host_act("start"))
    local c = {}
    for _, pl in ipairs(g.order) do c[pl.role] = (c[pl.role] or 0) + 1 end
    if c.werewolf ~= 2 or c.doctor or c.seer ~= 1 or c.slut ~= 1 or c.villager ~= 2 then bad = bad + 1 end
end
check(bad == 0, "40 random deals: always 2 wolves, never a disabled role, exact counts")
local g0 = Game.new("STARTERR")
for i = 1, 4 do g0:join("P" .. i) end
g0.settings.wolves = 2
local ok, e = g0:host_act("start")
check(not ok and e:find("too many") and g0.phase == "lobby", "start is refused with a clear reason when the deck is invalid")
check(not Game.new("X"):host_act("start"), "start still needs the minimum player count")

----------------------------------------------------------------------
print("\n-- slut regressions")
local r = game(5, BASIC) -- no slut in the game: this crashed (nil index) before
check(pcall(r.next, r) and r.phase == "day", "night resolves with no slut in the game")
check(pcall(r.next, r) and r.phase == "night", "...and so does the next day")

local SL = { "werewolf", "doctor", "slut", "villager", "villager" }
r = game(5, SL)
assert(r:act(P(r, 1), "kill", P(r, 4).id)); assert(r:act(P(r, 3), "sleep", P(r, 4).id)); assert(r:act(P(r, 2), "protect", P(r, 4).id))
r:next()
check(P(r, 4).alive and P(r, 3).alive, "doctor saves the victim -> the slut he slept with lives too")
r = game(5, SL)
assert(r:act(P(r, 1), "kill", P(r, 4).id)); assert(r:act(P(r, 3), "sleep", P(r, 4).id))
r:next()
check(not P(r, 4).alive and not P(r, 3).alive, "unprotected victim takes the slut with him")
r = game(5, SL)
assert(r:act(P(r, 1), "kill", P(r, 3).id)); assert(r:act(P(r, 3), "sleep", P(r, 4).id))
r:next()
check(not P(r, 3).alive and P(r, 4).alive and count(logtext(r), "P3 was killed") == 1, "slut eaten herself dies exactly once")
r = game(5, SL)
P(r, 3).alive = false
assert(r:act(P(r, 1), "kill", P(r, 4).id))
check(pcall(r.next, r) and count(logtext(r), "was killed in the night") == 1, "dead slut: no crash, no second death")
r = game(5, SL)
assert(r:act(P(r, 1), "kill", P(r, 4).id))
r:next()
check(r.last_verb_target.sleep ~= nil and r.last_verb_target.sleep ~= P(r, 3).id and P(r, r.last_verb_target.sleep).alive ~= nil, "slut who doesn't choose sleeps with a random other player")

----------------------------------------------------------------------
print("\n-- rules take effect")
r = game(5, BASIC, function(rm) set(rm, "reveal_role", "0") end)
assert(r:act(P(r, 1), "kill", P(r, 4).id)); r:next()
check(not logtext(r):find("They were"), "reveal_role off: death message names no role")
local seen = false
for _, pv in ipairs(r:view_for(P(r, 5)).players) do if pv.id == P(r, 4).id and pv.role then seen = true end end
check(not seen, "reveal_role off: dead player's role is hidden from others")
check(r:view_for(P(r, 4)).you.role == "villager", "...but still shown to that player")
r = game(5, BASIC)
assert(r:act(P(r, 1), "kill", P(r, 4).id)); r:next()
seen = false
for _, pv in ipairs(r:view_for(P(r, 5)).players) do if pv.id == P(r, 4).id and pv.role == "villager" then seen = true end end
check(seen and logtext(r):find("They were a Villager"), "reveal_role on: role revealed in log and list")

local function vote_all(room, target_of)
    for i, pl in ipairs(room.order) do
        if pl.alive then assert(room:act(pl, "vote", target_of(i))) end
    end
end
r = game(5, BASIC, function(rm) set(rm, "show_ballots", "0") end)
r:next()
vote_all(r, function(i) return i == 2 and P(r, 3).id or P(r, 2).id end)
check(r.phase == "day", "votes alone don't end the day (host decides)"); r:next()
check(logtext(r):find("The votes have been counted") and not logtext(r):find("Votes:"), "show_ballots off: no tallies published")
r = game(5, BASIC); r:next()
vote_all(r, function(i) return i == 2 and P(r, 3).id or P(r, 2).id end); r:next()
check(logtext(r):find("Votes: P2 %(4%)"), "show_ballots on: tally published")

local function tie(room)
    room:next() -- night -> day
    room.votes = { [P(room, 1).id] = P(room, 2).id, [P(room, 2).id] = P(room, 1).id, [P(room, 3).id] = 0, [P(room, 4).id] = 0, [P(room, 5).id] = 0 }
    room:next()
end
r = game(5, BASIC); tie(r)
check(#r:filter(function(pl) return pl.alive end) == 5 and logtext(r):find("Nobody is eliminated"), "tie_rule nobody: tie eliminates no one")
r = game(5, BASIC, function(rm) set(rm, "tie_rule", "random") end); tie(r)
check(#r:filter(function(pl) return pl.alive end) == 4 and logtext(r):find("Fate picks"), "tie_rule random: exactly one tied player is eliminated")

r = game(5, BASIC); r:next()
check(r:act(P(r, 1), "vote", 0), "abstaining allowed by default")
r = game(5, BASIC, function(rm) set(rm, "allow_abstain", "0") end); r:next()
local ok2, e2 = r:act(P(r, 1), "vote", 0)
check(not ok2 and e2:find("turned off"), "allow_abstain off: abstain refused")
check(not r:view_for(P(r, 1)).action.can_abstain, "...and the phone is told not to show the button")

r = game(5, BASIC, function(rm) set(rm, "first_night_safe", "1") end)
assert(r:act(P(r, 1), "kill", P(r, 4).id)); r:next()
check(#r:filter(function(pl) return pl.alive end) == 5, "first_night_safe: nobody dies night 1")
r:next() -- day -> night 2
assert(r:act(P(r, 1), "kill", P(r, 5).id)); r:next()
check(not P(r, 5).alive, "...but the wolves strike on night 2")

local function everyone_acts(room)
    local w = room:filter(function(pl) return pl.role == "werewolf" end)[1]
    local others = room:filter(function(pl) return pl.alive and pl.role ~= "werewolf" end)
    for _, pl in ipairs(room.order) do
        if pl.alive and Game.roles[pl.role].verb then
            local target = pl == w and others[#others] or w
            if pl.role == "doctor" then target = pl end
            assert(room:act(pl, Game.roles[pl.role].verb, target.id))
        end
    end
end
r = game(5, BASIC); everyone_acts(r)
check(r.phase == "night", "auto_advance off: the host decides when night ends")
r = game(5, BASIC, function(rm) set(rm, "auto_advance", "1") end)
everyone_acts(r)
check(r.phase == "day", "auto_advance on: night ends when the last power role acts")
for i, pl in ipairs(r.order) do if pl.alive then assert(r:act(pl, "vote", 0)) end end
check(r.phase == "night" and r.round == 2, "auto_advance on: day ends when the last vote is in")

r = game(5, BASIC)
assert(r:act(P(r, 2), "inspect", P(r, 1).id)); assert(r:act(P(r, 3), "protect", P(r, 4).id)); r:next(); r:next()
local function targets_of(room, pl) local t = {} for _, x in ipairs(room:view_for(pl).action.targets) do t[x.id] = true end return t end
check(not targets_of(r, P(r, 3))[P(r, 4).id] and targets_of(r, P(r, 3))[P(r, 3).id], "no_repeat on: doctor can't repeat, may self-protect")
r = game(5, BASIC, function(rm) set(rm, "no_repeat", "0"); set(rm, "doctor_self", "0") end)
assert(r:act(P(r, 3), "protect", P(r, 4).id)); r:next(); r:next()
check(targets_of(r, P(r, 3))[P(r, 4).id] and not targets_of(r, P(r, 3))[P(r, 3).id], "no_repeat off: repeat allowed; doctor_self off: can't pick self")

r = Game.new("TOUCHING"); r.touched = 1; r:join("Zed")
check(r.touched > 1, "any change keeps the room alive (touched is updated on bump)")

----------------------------------------------------------------------
print("\n-- views")
local lobby = Game.new("VIEWVIEW")
for i = 1, 5 do lobby:join("P" .. i) end
local hv = lobby:view_for(nil)
check(hv.rules and #hv.rules == #Game.settings_schema and hv.roles and #hv.roles == 5, "host lobby view carries rules and roles")
check(hv.roles[1].key == "werewolf" and hv.roles[1].count == 1 and hv.roles[#hv.roles].key == "villager" and hv.roles[#hv.roles].count == 1, "role counts reflect the player count")
check(lobby:view_for(P(lobby, 1)).rules == nil, "players' phones don't get the config")
lobby.active_roles.doctor = false
local relevant = {}
for _, rr in ipairs(lobby:view_for(nil).rules) do relevant[rr.key] = rr.relevant end
check(relevant.doctor_self == false and relevant.no_repeat == true and relevant.wolves == true, "rules about a disabled role are flagged irrelevant")
lobby.active_roles.doctor = true
assert(lobby:host_act("start"))
check(lobby:view_for(nil).deck and lobby:view_for(P(lobby, 1)).deck, "roles in play are announced by default")
set(lobby, "show_deck", "0") -- refused: game started
check(lobby:view_for(nil).deck ~= nil, "rules are locked once the game started")
lobby:reset_to_lobby()
check(lobby.settings.reveal_role == true and lobby.deck == nil, "play again keeps the rules, drops the deck")
set(lobby, "show_deck", "0"); assert(lobby:host_act("start"))
check(lobby:view_for(nil).deck == nil, "show_deck off: no deck in any view")

----------------------------------------------------------------------
print("\n-- over HTTP")
local function call(method, url)
    local req = assert(request(method .. " " .. url .. " HTTP/1.1\r\n\r\n"))
    local okr, res = route(state, req, "127.0.0.1")
    assert(okr, tostring(res))
    local head, body = res:match("^(.-)\r\n\r\n(.*)$")
    return tonumber(head:match("^HTTP/1.1 (%d+)")), body, head
end
local _, _, head = call("GET", "/create")
local code, key = head:match("code=(%u+)&key=(%x+)")
local room = state.get_room(code)
local function api(path, extra) return call("POST", ("/api/action?code=%s&key=%s&type=%s"):format(code, key, path) .. (extra or "")) end

check(call("GET", "/host?code=" .. code .. "&key=" .. key) == 200, "host page serves")
local toks = {}
for _, nm in ipairs { "Ann", "Bob", "Cy", "Dee", "Eve" } do
    local st, tok = call("POST", "/api/join?code=" .. code .. "&name=" .. nm)
    toks[nm] = tok
end
call("POST", "/api/join?code=" .. code .. "&name=%3Cb%3Ex%3C%2Fb%3E")
local _, lobbyhtml = call("GET", "/api/view?code=" .. code .. "&key=" .. key .. "&v=-1")
check(lobbyhtml:find("toggleRole('slut', 0)", 1, true), "lobby shows an enabled, switch-off-able role")
check(lobbyhtml:find("setting('wolves','1')", 1, true) and lobbyhtml:find("setting('tie_rule','random')", 1, true), "lobby shows stepper and cycling controls")
check(lobbyhtml:find('class="rolerow"', 1, true) and lobbyhtml:find("always", 1, true), "role rows rendered, core roles marked 'always'")
check(lobbyhtml:find("&lt;b&gt;x&lt;/b&gt;", 1, true) and not lobbyhtml:find("<b>x", 1, true), "player names are HTML-escaped on the host screen")
check(api("role", "&name=slut&value=0") == 200 and room.active_roles.slut == false, "toggling a role over HTTP works")
local _, afterhtml = call("GET", "/api/view?code=" .. code .. "&key=" .. key .. "&v=-1")
check(afterhtml:find("toggleRole('slut', 1)", 1, true) and afterhtml:find('class="rolerow off"', 1, true), "...and the lobby re-renders with it switched off")
check(api("set", "&name=wolves&value=2") == 200 and room.settings.wolves == 2, "setting a rule over HTTP works")
check(api("set", "&name=wolves&value=99") == 400, "bad value -> 400")
check(call("POST", ("/api/action?code=%s&token=%s&type=set&name=wolves&value=1"):format(code, toks.Ann)) == 400 and room.settings.wolves == 2, "a player can't change the rules")
local _, phonehtml = call("GET", "/api/view?code=" .. code .. "&token=" .. toks.Ann .. "&v=-1")
check(not phonehtml:find("toggleRole", 1, true) and not phonehtml:find("Rules", 1, true), "phones don't render the config panels")
check(api("start") == 200 and room.phase == "night", "host starts with the configured rules")
local _, nighthost = call("GET", "/api/view?code=" .. code .. "&key=" .. key .. "&v=-1")
check(nighthost:find('class="logbox"', 1, true) and nighthost:find("In play: 2 Werewolves", 1, true) and not nighthost:find("Werewolfs", 1, true), "in-game host screen: fixed log box + roles in play (correct plural)")
local _, nightphone = call("GET", "/api/view?code=" .. code .. "&token=" .. toks.Ann .. "&v=-1")
check(nightphone:find('class="logbox"', 1, true) and nightphone:find("rolechip", 1, true) and nightphone:find('class="card action"', 1, true), "phone screen: role chip, action card, log box")
check(api("next") == 200 and room.phase == "day", "host advances with next")

print(("\nALL %d CHECKS PASSED"):format(passed))
