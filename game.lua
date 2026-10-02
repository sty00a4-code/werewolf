math.randomseed(os.time())

---@alias Phase "lobby"|"night"|"day"|"over"

---@class Player
---@field id integer
---@field name string
---@field token string            secret, identifies this browser tab
---@field role string?            key into Game.roles (nil in the lobby)
---@field alive boolean
---@field notes string[]          private info only this player ever sees

---@class Game
---@field code string
---@field host_key string
---@field created integer
---@field touched integer
---@field version integer
---@field phase Phase
---@field round integer
---@field next_id integer
---@field players Player[]
---@field order Player[]
---@field active_roles table<string, boolean>
---@field wolves integer?
---@field by_token table<string, Player>
---@field log { round: integer, text: string }[]
---@field night { wolf_votes: integer[], acted: integer[], verb_target: table<string, integer> }?
---@field votes integer[]
---@field last_verb_target table<string, integer>
---@field winner string?
local Game = {}
Game.__index = Game

Game.config = {
    min_players = 4,
    max_players = 20,
    log_lines = 10,
}
local cfg = Game.config

Game.roles = {
    werewolf = {
        name = "Werewolf",
        team = "wolves",
        verb = "kill",
        blurb = "Each night the pack chooses someone to eat",
    },
    villager = {
        name = "Villager",
        team = "village",
        blurb = "No special powers, you are just an average guy",
    },
    seer = {
        name = "Seer",
        team = "village",
        verb = "inspect",
        blurb = "Each night you learn whether one player is a werewolf",
    },
    doctor = {
        name = "Doctor",
        team = "village",
        verb = "protect",
        blurb = "Each night you protect one player from the wolves. (not the same player two nights in a row)",
    },
    slut = {
        name = "Slut",
        team = "village",
        verb = "sleep",
        blurb = "Each night you have a one night stand with a player. If they get eaten at night so do you.",
    },
}

---@param p Player
---@return string?
local function team_of(p)
    local r = p.role and Game.roles[p.role]
    return r and r.team
end

---@param t any[]
---@return any[]
local function shuffle(t)
    for k = #t, 2, -1 do
        local j = math.random(k)
        t[k], t[j] = t[j], t[k]
    end
    return t
end

---@param name string
---@return string?
local function clean_name(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("%c", "")
    name = name:match("^%s*(.-)%s*$")
    local len
    if utf8 then len = utf8.len(name) else len = #name end
    if not len or len < 1 or len > 16 then return nil end
    return name
end

---Pick the winner of a tally {id -> count}. Returns the list of tied leaders and the top count.
---@param tally integer[]
---@return table
---@return integer
local function leaders(tally)
    local best, top = 0, {}
    for id, n in pairs(tally) do
        if n > best then
            best, top = n, { id }
        elseif n == best then
            top[#top + 1] = id
        end
    end
    return top, best
end

---@class Verb
---@field prompt string
---@field targets fun(g: Game, actor: Player): Player[] list of Players the actor may pick;
---@field apply fun(g: Game, actor: Player, target: Player) side effects of the choice
---@type table<string, Verb>
local verbs = {}

verbs.kill = {
    prompt = "Choose who the pack eats tonight",
    targets = function(g, actor)
        return g:filter(function(pl) return pl.alive and team_of(pl) ~= "wolves" end)
    end,
    apply = function(g, actor, target)
        g.night.wolf_votes[actor.id] = target.id
    end,
}
verbs.inspect = {
    prompt = "Choose someone to inspect",
    targets = function(g, actor)
        return g:filter(function(pl) return pl.alive and pl ~= actor end)
    end,
    apply = function(g, actor, target)
        local wolf = team_of(target) == "wolves"
        actor.notes[#actor.notes + 1] = ("Night %d: %s %s a werewolf."):format(g.round, target.name,
            wolf and "IS" or "is NOT")
    end,
}
verbs.protect = {
    prompt = "Choose someone to protect",
    targets = function(g, actor)
        return g:filter(function(pl) return pl.alive and pl.id ~= g.last_verb_target.protect end)
    end,
    apply = function(g, actor, target)
        g.night.verb_target.protect = target.id
    end,
}
verbs.sleep = {
    prompt = "Choose someone to sleep with. (if you don't it will be randomized)",
    targets = function(g, actor)
        return g:filter(function(pl) return pl.alive and pl.id ~= g.last_verb_target.sleep and pl.id ~= actor.id end)
    end,
    apply = function(g, actor, target)
        g.night.verb_target.sleep = target.id
    end,
}

---@param code string
---@return Game
function Game.new(code)
    local now = os.time()
    local active_roles = {}
    for name in pairs(Game.roles) do
        active_roles[name] = true
    end
    return setmetatable({
        code = code,
        host_key = token_hex(8),
        created = now,
        touched = now,
        version = 1, -- bumped on EVERY change; clients poll with the version they have
        phase = "lobby",
        round = 0,
        next_id = 1,
        players = {},  -- id -> Player
        order = {},    -- Players in join order
        active_roles = active_roles,
        by_token = {}, -- token -> Player
        log = {},      -- public history, {round=, text=}
        night = nil,   -- {wolf_votes={}, acted={}, protect=nil} during night
        votes = {},    -- voter id -> target id (0 = abstain) during day
        winner = nil,
        last_verb_target = {},
    }, Game)
end

function Game:bump()
    self.version = self.version + 1
end

---@param text string
function Game:say(text)
    self.log[#self.log + 1] = { round = self.round, text = text }
    self:bump()
end

---@param pred fun(pl: Player): boolean
---@return Player[]
function Game:filter(pred)
    local out = {}
    for _, pl in ipairs(self.order) do
        if pred(pl) then out[#out + 1] = pl end
    end
    return out
end

---@param key string
---@return boolean
function Game:is_host(key)
    return type(key) == "string" and key == self.host_key
end

---@param token string
---@return Player
function Game:player_by_token(token)
    return token and self.by_token[token] or nil
end

---@param name string
---@return Player? player
---@return string? err
function Game:join(name)
    if self.phase ~= "lobby" then return nil, "That game has already started." end
    if #self.order >= cfg.max_players then return nil, "That game is full." end
    local name = clean_name(name)
    if not name then return nil, "Pick a name between 1 and 16 characters." end
    for _, other in ipairs(self.order) do
        if other.name:lower() == name:lower() then return nil, "That name is taken." end
    end
    local pl = { id = self.next_id, name = name, token = token_hex(16), alive = true, notes = {} }
    self.next_id = self.next_id + 1
    self.players[pl.id] = pl
    self.order[#self.order + 1] = pl
    self.by_token[pl.token] = pl
    self:bump()
    return pl
end

---@param n integer
---@param active table<string, boolean>
---@param wolves integer?
---@return string[]
local function role_pool(n, active, wolves)
    wolves = wolves or math.max(1, math.floor(n / 4))
    local pool = {}
    for _ = 1, wolves do pool[#pool + 1] = "werewolf" end
    for name in pairs(Game.roles) do
        if name ~= "werewolf" and name ~= "villager" and active[name] then
            pool[#pool + 1] = name
        end
    end
    while #pool < n do pool[#pool + 1] = "villager" end
    return shuffle(pool)
end

function Game:reset_to_lobby()
    self.phase, self.round, self.winner = "lobby", 0, nil
    self.night, self.votes, self.last_verb_target = nil, {}, {}
    self.log = {}
    for _, pl in ipairs(self.order) do
        pl.role, pl.alive, pl.notes = nil, true, {}
    end
    self:bump()
end

---@param kind "start" | "kick" | "next" | "restart"
---@param target_id integer?
---@return boolean ok
---@return string? err
function Game:host_act(kind, target_id)
    if kind == "start" then
        if self.phase ~= "lobby" then return false, "The game already started." end
        if #self.order < cfg.min_players then
            return false, ("You need at least %d players."):format(cfg.min_players)
        end
        local pool = role_pool(#self.order, self.active_roles, self.wolves)
        for idx, pl in ipairs(self.order) do
            pl.role, pl.alive, pl.notes = pool[idx], true, {}
        end
        self.round = 0
        self:say("The game begins. Night falls on the village...")
        self:begin_night()
        return true
    elseif kind == "kick" then
        local pl = self.players[target_id]
        if self.phase ~= "lobby" or not pl then return false, "Can't kick that player." end
        self.players[pl.id] = nil
        self.by_token[pl.token] = nil
        for idx, other in ipairs(self.order) do
            if other == pl then
                table.remove(self.order, idx)
                break
            end
        end
        self:bump()
        return true
    elseif kind == "next" then
        if self.phase ~= "night" and self.phase ~= "day" then return false, "Nothing to go to next." end
        self:next()
        return true
    elseif kind == "restart" then
        if self.phase ~= "over" then return false, "The game isn't over." end
        self:reset_to_lobby()
        return true
    end
    return false, "Unknown host action."
end

---@param list Player[]
---@param id integer
---@return boolean
local function contains(list, id)
    for _, pl in ipairs(list) do
        if pl.id == id then return true end
    end
    return false
end

---@param player Player
---@param kind "vote" | "kill" | "inspect" | "protect"
---@param target_id integer?  (0 = abstain, for votes)
---@return boolean ok
---@return string? err
function Game:act(player, kind, target_id)
    if not player.alive then return false, "You are dead." end
    if self.phase == "night" then
        local verb = Game.roles[player.role].verb
        if not verb or kind ~= verb then return false, "That isn't your night action." end
        if self.night.acted[player.id] then return false, "You already made your choice." end
        local target = self.players[target_id]
        if not target or not contains(verbs[verb].targets(self, player), target.id) then
            return false, "You can't choose that player."
        end
        self.night.acted[player.id] = target.id
        verbs[verb].apply(self, player, target)
        self:bump()
        return true
    elseif self.phase == "day" then
        if kind ~= "vote" then return false, "It's daytime: vote instead." end
        if target_id ~= 0 then
            local target = self.players[target_id]
            if not target or not target.alive or target == player then return false, "You can't vote for that player." end
        end
        self.votes[player.id] = target_id
        self:bump()
        return true
    end
    return false, "Nothing to do right now."
end

function Game:begin_night()
    local now = os.time()
    self.round = self.round + 1
    self.phase = "night"
    self.night = { wolf_votes = {}, acted = {}, verb_target = {} }
    self.votes = {}
    self:bump()
end

---@return boolean
function Game:night_complete()
    for _, pl in ipairs(self.order) do
        if pl.alive and Game.roles[pl.role].verb and not self.night.acted[pl.id] then return false end
    end
    return true
end

---@return boolean
function Game:day_complete()
    for _, pl in ipairs(self.order) do
        if pl.alive and self.votes[pl.id] == nil then return false end
    end
    return true
end

function Game:kill(pl, how)
    pl.alive = false
    self:say(("%s %s. They were a %s."):format(pl.name, how, Game.roles[pl.role].name))
end

---@return string?
function Game:check_win()
    local wolves, village = 0, 0
    for _, pl in ipairs(self.order) do
        if pl.alive then
            if team_of(pl) == "wolves" then wolves = wolves + 1 else village = village + 1 end
        end
    end
    if wolves == 0 then return "village" end
    if wolves >= village then return "wolves" end
end

---@param winner string
function Game:finish(winner)
    self.phase, self.winner = "over", winner
    if winner == "village" then
        self:say("The village wins! Every werewolf is gone.")
    else
        self:say("The werewolves win! They now outnumber the village.")
    end
end

function Game:resolve_night()
    local tally = {}
    for _, tid in pairs(self.night.wolf_votes) do tally[tid] = (tally[tid] or 0) + 1 end
    local top = leaders(tally)
    local victim = top[1] and self.players[top[math.random(#top)]] -- ties: random among the leaders
    if self.night.verb_target.sleep == nil then
        local slut = self:filter(function(pl)
            return pl.role == "slut"
        end)[1]
        local pls = self:filter(function(pl)
            return pl.id ~= slut.id and pl.id ~= self.last_verb_target.sleep
        end)
        self.night.verb_target.sleep = pls[math.random(#pls)].id
    end

    if victim and victim.id ~= self.night.verb_target.protect then
        self:kill(victim, "was killed in the night")
    else
        self:say("Dawn breaks. Nobody died last night.") -- deliberately vague: doesn't reveal a save
    end
    if victim and self.night.verb_target.sleep == victim.id then
        local slut = self:filter(function(pl)
            return pl.role == "slut"
        end)[1]
        self:kill(slut, "was killed in the night")
    end
    self.last_verb_target = {}
    for verb, target in pairs(self.night.verb_target) do
        self.last_verb_target[verb] = target
    end

    local winner = self:check_win()
    if winner then return self:finish(winner) end
    self.phase, self.votes = "day", {}
    self:bump()
end

function Game:resolve_day()
    local tally = {}
    for _, tid in pairs(self.votes) do
        if tid ~= 0 then tally[tid] = (tally[tid] or 0) + 1 end
    end
    local top, best = leaders(tally)

    -- ballots are secret until now, then published
    local rows = {}
    for tid, n in pairs(tally) do rows[#rows + 1] = { name = self.players[tid].name, n = n } end
    table.sort(rows, function(x, y)
        if x.n ~= y.n then return x.n > y.n end
        return x.name < y.name
    end)
    local parts = {}
    for _, row in ipairs(rows) do parts[#parts + 1] = ("%s (%d)"):format(row.name, row.n) end
    self:say(#parts > 0 and ("Votes: " .. table.concat(parts, ", ")) or "Nobody voted.")

    if #top == 1 then
        self:kill(self.players[top[1]], "was voted out by the village")
    elseif best > 0 then
        self:say("The vote was tied. Nobody is eliminated.")
    end

    local winner = self:check_win()
    if winner then return self:finish(winner) end
    self:begin_night()
end

--- Advances the phase
function Game:next()
    local now = os.time()
    self.touched = now
    if self.phase == "night" then
        self:resolve_night()
    elseif self.phase == "day" then
        self:resolve_day()
    end
end

---@class ActionView
---@field prompt string
---@field verb string?
---@field targets { id: integer, name: string }[]?
---@field locked boolean?
---@field chosen integer?
---@field chosen_name string?
---@param viewer Player
---@return ActionView?
function Game:action_for(viewer)
    if not viewer or not viewer.alive then return nil end
    local function names(list)
        local out = {}
        for _, pl in ipairs(list) do out[#out + 1] = { id = pl.id, name = pl.name } end
        return out
    end

    if self.phase == "night" then
        local verb = Game.roles[viewer.role].verb
        if not verb then
            return { prompt = "Night falls. Close your eyes and wait for dawn." }
        end
        local chosen = self.night.acted[viewer.id]
        if chosen then
            return {
                verb = verb,
                prompt = verbs[verb].prompt,
                locked = true,
                chosen = chosen,
                chosen_name = self
                    .players[chosen].name
            }
        end
        return { verb = verb, prompt = verbs[verb].prompt, targets = names(verbs[verb].targets(self, viewer)) }
    elseif self.phase == "day" then
        local mine = self.votes[viewer.id]
        local targets = self:filter(function(pl) return pl.alive and pl ~= viewer end)
        return {
            verb = "vote",
            prompt = "Who is a werewolf? Cast your vote.",
            targets = names(targets),
            chosen = mine,
            chosen_name = mine and (mine == 0 and "nobody" or self.players[mine].name)
        }
    end
end

---@class PlayerView
---@field id integer
---@field name string
---@field alive boolean
---@field role string?
---@field team string?

---@class View
---@field code string
---@field phase Phase
---@field round integer
---@field winner string
---@field min_players integer
---@field players PlayerView[]
---@field log string[]
---@field you PlayerView?
---@field notes string[]?
---@field action ActionView?
---@field pack { wolf: string, target: string }[]?
---@field progress { voted: integer, total: integer }?
---@field join_url string?
---@field alt_urls string[]?
---@param viewer Player?  nil = the shared host screen
---@return View
function Game:view_for(viewer)
    local viewer_wolf = viewer and team_of(viewer) == "wolves"
    ---@type View
    local v = {
        code = self.code,
        phase = self.phase,
        round = self.round,
        winner = self.winner,
        min_players = cfg.min_players,
        players = {},
        log = {},
    }

    for _, pl in ipairs(self.order) do
        local show = self.phase == "over" or not pl.alive or pl == viewer
            or (viewer_wolf and team_of(pl) == "wolves")
        v.players[#v.players + 1] = { id = pl.id, name = pl.name, alive = pl.alive, role = show and pl.role or nil }
    end

    if viewer then
        v.you = { id = viewer.id, name = viewer.name, role = viewer.role, alive = viewer.alive, team = team_of(viewer) }
        v.notes = viewer.notes
        v.action = self:action_for(viewer)
    end

    if self.phase == "night" and viewer_wolf then
        v.pack = {}
        for wid, tid in pairs(self.night.wolf_votes) do
            v.pack[#v.pack + 1] = { wolf = self.players[wid].name, target = self.players[tid].name }
        end
    end

    if self.phase == "day" then -- how many have voted (not who or for whom)
        local alive, voted = 0, 0
        for _, pl in ipairs(self.order) do
            if pl.alive then
                alive = alive + 1
                if self.votes[pl.id] ~= nil then voted = voted + 1 end
            end
        end
        v.progress = { voted = voted, total = alive }
    end

    for idx = math.max(1, #self.log - cfg.log_lines + 1), #self.log do
        v.log[#v.log + 1] = ("%s: %s"):format(self.log[idx].round, self.log[idx].text)
    end
    return v
end

return Game
