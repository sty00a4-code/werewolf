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
---@field settings table<string, any>   host-configurable rules, see Game.settings_schema
---@field deck { role: string, count: integer }[]?   role split dealt at game start
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
    max_wolves = 5,
    log_lines = 100, -- how much history a client receives (the log box scrolls)
}
local cfg = Game.config

Game.roles = {
    werewolf = {
        name = "Werewolf",
        team = "wolves",
        verb = "kill",
        core = true,
        plural = "Werewolves",
        blurb = "Each night the pack chooses someone to eat",
    },
    villager = {
        name = "Villager",
        team = "village",
        core = true,
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

---Roles the host may switch on or off in the lobby (everything that isn't `core`), in a stable order.
---@type string[]
Game.optional_roles = {}
for key, role in pairs(Game.roles) do
    if not role.core then Game.optional_roles[#Game.optional_roles + 1] = key end
end
table.sort(Game.optional_roles)

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

---@class SettingDef
---@field key string
---@field label string
---@field help string                  shown as a tooltip; avoid double quotes
---@field kind "bool"|"int"|"choice"
---@field default boolean|integer|string
---@field min integer?                 int only
---@field max integer?                 int only
---@field options { value: string, label: string }[]?   choice only
---@field format (fun(value: any): string)?                optional display text
---@field requires string[]?           only relevant while one of these roles is enabled

---Every rule the host can change in the lobby. The lobby UI and the validation are both generated from this table,
---so adding a rule = adding an entry here and reading `g.settings.<key>` where it applies.
---@type SettingDef[]
Game.settings_schema = {
    {
        key = "wolves",
        label = "Werewolves",
        kind = "int",
        default = 0,
        min = 0,
        max = cfg.max_wolves,
        format = function(v) return v == 0 and "Auto" or tostring(v) end,
        help = "Auto gives one werewolf per four players.",
    },
    {
        key = "show_deck",
        label = "Announce roles in play",
        kind = "bool",
        default = true,
        help = "Tell everyone which roles are in the game (not who has them).",
    },
    {
        key = "first_night_safe",
        label = "Peaceful first night",
        kind = "bool",
        default = false,
        help = "The wolves cannot kill anyone on the first night.",
    },
    {
        key = "auto_advance",
        label = "Auto-advance",
        kind = "bool",
        default = false,
        help =
        "Move on as soon as everybody has acted instead of waiting for the host. Night then ends the moment the last power role acts, which can hint at who has one.",
    },
    {
        key = "doctor_self",
        label = "Doctor may self-protect",
        kind = "bool",
        default = true,
        requires = { "doctor" },
        help = "Allow the doctor to protect themselves.",
    },
    {
        key = "no_repeat",
        label = "No repeat targets",
        kind = "bool",
        default = true,
        requires = { "doctor", "slut" },
        help = "The doctor and the slut cannot pick the same player two nights in a row.",
    },
    {
        key = "reveal_role",
        label = "Reveal roles of the dead",
        kind = "bool",
        default = true,
        help = "Say what a player was when they die, and show it on the player list.",
    },
    {
        key = "show_ballots",
        label = "Show vote counts",
        kind = "bool",
        default = true,
        help = "After the day vote, publish how many votes each player received.",
    },
    {
        key = "tie_rule",
        label = "Tied vote",
        kind = "choice",
        default = "nobody",
        options = { { value = "nobody", label = "No one dies" }, { value = "random", label = "Random pick" } },
        help = "What happens when the top spot of the day vote is tied.",
    },
    {
        key = "allow_abstain",
        label = "Allow abstaining",
        kind = "bool",
        default = true,
        help = "Players may vote for nobody.",
    },
}

---@type table<string, SettingDef>
Game.settings_by_key = {}
for _, def in ipairs(Game.settings_schema) do Game.settings_by_key[def.key] = def end

---@return table<string, any>
local function default_settings()
    local out = {}
    for _, def in ipairs(Game.settings_schema) do out[def.key] = def.default end
    return out
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
        local s = g.settings
        return g:filter(function(pl)
            if not pl.alive then return false end
            if s.no_repeat and pl.id == g.last_verb_target.protect then return false end
            if not s.doctor_self and pl == actor then return false end
            return true
        end)
    end,
    apply = function(g, actor, target)
        g.night.verb_target.protect = target.id
    end,
}
verbs.sleep = {
    prompt = "Choose someone to sleep with. (if you don't it will be randomized)",
    targets = function(g, actor)
        local s = g.settings
        return g:filter(function(pl)
            return pl.alive and pl ~= actor and not (s.no_repeat and pl.id == g.last_verb_target.sleep)
        end)
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
        players = {}, -- id -> Player
        order = {},   -- Players in join order
        active_roles = active_roles,
        settings = default_settings(),
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
    self.touched = os.time()
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

---How many of each role a game with `n` players would get, plus a complaint if that isn't playable.
---@param n integer
---@return { role: string, count: integer }[] plan  werewolf, then the enabled optional roles, then villagers
---@return string? err
function Game:plan_deck(n)
    local wolves = self.settings.wolves
    if wolves == 0 then wolves = math.max(1, math.floor(n / 4)) end
    local plan, used = { { role = "werewolf", count = wolves } }, wolves
    for _, key in ipairs(Game.optional_roles) do
        if self.active_roles[key] then
            plan[#plan + 1] = { role = key, count = 1 }
            used = used + 1
        end
    end
    plan[#plan + 1] = { role = "villager", count = math.max(0, n - used) }

    local err
    if n > 0 then
        local max_wolves = math.max(1, math.floor((n - 1) / 2)) -- the wolves must start as a minority
        if wolves > max_wolves then
            err = ("%d werewolves is too many for %d players (max %d)."):format(wolves, n, max_wolves)
        elseif used > n then
            err = ("%d players are too few for the enabled roles. Disable a role or add players."):format(n)
        end
    end
    return plan, err
end

---One shuffled role per player.
---@return string[]? pool
---@return string? err
function Game:build_deck()
    local plan, err = self:plan_deck(#self.order)
    if err then return nil, err end
    local pool = {}
    for _, entry in ipairs(plan) do
        for _ = 1, entry.count do pool[#pool + 1] = entry.role end
    end
    return shuffle(pool)
end

---Validate and store one rule. `raw` is the string that came in over HTTP.
---@param key string
---@param raw string?
---@return boolean ok
---@return string? err
function Game:set_setting(key, raw)
    if self.phase ~= "lobby" then return false, "Rules can only be changed in the lobby." end
    local def = Game.settings_by_key[key]
    if not def then return false, "Unknown rule." end
    local value
    if def.kind == "bool" then
        if raw == "1" or raw == "true" then
            value = true
        elseif raw == "0" or raw == "false" then
            value = false
        else
            return false, "Expected on or off."
        end
    elseif def.kind == "int" then
        value = tonumber(raw)
        if not value or math.floor(value) ~= value or value < def.min or value > def.max then
            return false, ("%s must be a whole number from %d to %d."):format(def.label, def.min, def.max)
        end
        value = math.floor(value) -- always store a real integer (never 3.0)
    elseif def.kind == "choice" then
        for _, option in ipairs(def.options) do
            if option.value == raw then value = option.value end
        end
        if value == nil then return false, "Not a valid choice." end
    end
    self.settings[key] = value
    self:bump()
    return true
end

function Game:reset_to_lobby()
    self.phase, self.round, self.winner = "lobby", 0, nil
    self.night, self.votes, self.last_verb_target = nil, {}, {}
    self.deck, self.log = nil, {}
    for _, pl in ipairs(self.order) do
        pl.role, pl.alive, pl.notes = nil, true, {}
    end
    self:bump()
end

---@param kind "start" | "kick" | "next" | "restart" | "set" | "role"
---@param target_id integer?
---@param extra { name: string?, value: string? }?  for "set" (rule name + value) and "role" (role key + 1/0)
---@return boolean ok
---@return string? err
function Game:host_act(kind, target_id, extra)
    extra = extra or {}
    if kind == "start" then
        if self.phase ~= "lobby" then return false, "The game already started." end
        if #self.order < cfg.min_players then
            return false, ("You need at least %d players."):format(cfg.min_players)
        end
        local pool, err = self:build_deck()
        if not pool then return false, err end
        for idx, pl in ipairs(self.order) do
            pl.role, pl.alive, pl.notes = pool[idx], true, {}
        end
        self.deck = (self:plan_deck(#self.order))
        self.round = 0
        self:say("The game begins. Night falls on the village...")
        self:begin_night()
        return true
    elseif kind == "set" then
        return self:set_setting(extra.name, extra.value)
    elseif kind == "role" then
        if self.phase ~= "lobby" then return false, "Roles can only be changed in the lobby." end
        local role = extra.name and Game.roles[extra.name]
        if not role or role.core then return false, "That role can't be switched off." end
        if extra.value == "1" then
            self.active_roles[extra.name] = true
        elseif extra.value == "0" then
            self.active_roles[extra.name] = false
        else
            return false, "Expected on or off."
        end
        self:bump()
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
---@param kind "vote" | "kill" | "inspect" | "protect" | "sleep"
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
        self:maybe_advance()
        return true
    elseif self.phase == "day" then
        if kind ~= "vote" then return false, "It's daytime: vote instead." end
        if target_id == 0 then
            if not self.settings.allow_abstain then return false, "Abstaining is turned off." end
        else
            local target = self.players[target_id]
            if not target or not target.alive or target == player then return false, "You can't vote for that player." end
        end
        self.votes[player.id] = target_id
        self:bump()
        self:maybe_advance()
        return true
    end
    return false, "Nothing to do right now."
end

---With the "auto-advance" rule on, move to the next phase as soon as everybody has acted.
function Game:maybe_advance()
    if not self.settings.auto_advance then return end
    if (self.phase == "night" and self:night_complete()) or (self.phase == "day" and self:day_complete()) then
        self:next()
    end
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
        local verb = Game.roles[pl.role].verb
        if pl.alive and verb and not self.night.acted[pl.id] and #verbs[verb].targets(self, pl) > 0 then return false end
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
    if self.settings.reveal_role then
        self:say(("%s %s. They were a %s."):format(pl.name, how, Game.roles[pl.role].name))
    else
        self:say(("%s %s."):format(pl.name, how))
    end
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
    local s, night = self.settings, self.night
    local tally = {}
    for _, tid in pairs(night.wolf_votes) do tally[tid] = (tally[tid] or 0) + 1 end
    local top = leaders(tally)
    local victim = top[1] and self.players[top[math.random(#top)]] -- ties: random among the leaders
    if s.first_night_safe and self.round == 1 then victim = nil end

    -- The slut sleeps somewhere every night; if she didn't choose, it is random.
    -- (No living slut = nothing to do. This used to crash whenever the role was disabled.)
    local slut = self:filter(function(pl) return pl.role == "slut" and pl.alive end)[1]
    if slut and night.verb_target.sleep == nil then
        local options = verbs.sleep.targets(self, slut)
        if #options > 0 then night.verb_target.sleep = options[math.random(#options)].id end
    end

    local died = victim and victim.id ~= night.verb_target.protect and victim or nil
    if died then
        self:kill(died, "was killed in the night")
        -- she only dies with him if he really died (not if the doctor saved him)
        if slut and slut.alive and night.verb_target.sleep == died.id then
            self:kill(slut, "was killed in the night")
        end
    else
        self:say("Dawn breaks. Nobody died last night.") -- deliberately vague: doesn't reveal a save
    end

    self.last_verb_target = {}
    for verb, target in pairs(night.verb_target) do
        self.last_verb_target[verb] = target
    end

    local winner = self:check_win()
    if winner then return self:finish(winner) end
    self.phase, self.votes = "day", {}
    self:bump()
end

function Game:resolve_day()
    local s = self.settings
    local tally = {}
    for _, tid in pairs(self.votes) do
        if tid ~= 0 then tally[tid] = (tally[tid] or 0) + 1 end
    end
    local top, best = leaders(tally)

    -- ballots are secret until now, then (optionally) published
    local rows = {}
    for tid, n in pairs(tally) do rows[#rows + 1] = { name = self.players[tid].name, n = n } end
    table.sort(rows, function(x, y)
        if x.n ~= y.n then return x.n > y.n end
        return x.name < y.name
    end)
    if #rows == 0 then
        self:say("Nobody voted.")
    elseif s.show_ballots then
        local parts = {}
        for _, row in ipairs(rows) do parts[#parts + 1] = ("%s (%d)"):format(row.name, row.n) end
        self:say("Votes: " .. table.concat(parts, ", "))
    else
        self:say("The votes have been counted.")
    end

    local eliminated
    if #top == 1 then
        eliminated = self.players[top[1]]
    elseif #top > 1 and s.tie_rule == "random" then
        self:say("The vote was tied. Fate picks one of them.")
        eliminated = self.players[top[math.random(#top)]]
    elseif best > 0 then
        self:say("The vote was tied. Nobody is eliminated.")
    end
    if eliminated then self:kill(eliminated, "was voted out by the village") end

    local winner = self:check_win()
    if winner then return self:finish(winner) end
    self:begin_night()
end

--- Advances the phase
function Game:next()
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
---@field can_abstain boolean?
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
            chosen_name = mine and (mine == 0 and "nobody" or self.players[mine].name),
            can_abstain = self.settings.allow_abstain,
        }
    end
end

---@class PlayerView
---@field id integer
---@field name string
---@field alive boolean
---@field role string?
---@field team string?

---@class RuleView
---@field key string
---@field label string
---@field help string
---@field kind "bool"|"int"|"choice"
---@field value boolean|integer|string
---@field display string
---@field min integer?
---@field max integer?
---@field options { value: string, label: string }[]?
---@field relevant boolean   false while none of the roles this rule is about are enabled

---@class RoleView
---@field key string
---@field name string
---@field blurb string
---@field team string
---@field core boolean       can't be switched off
---@field active boolean
---@field count integer?     how many would be dealt with the current player count

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
---@field rules RuleView[]?        host lobby only
---@field roles RoleView[]?        host lobby only
---@field deck_error string?       host lobby only: why the game can't start with these settings
---@field deck { role: string, count: integer }[]?   roles in play, once the game started (and "announce roles" is on)
---@return RuleView[]
function Game:rules_view()
    local out = {}
    for _, def in ipairs(Game.settings_schema) do
        local value = self.settings[def.key]
        local display
        if def.kind == "bool" then
            display = value and "On" or "Off"
        elseif def.kind == "int" then
            display = def.format and def.format(value) or tostring(value)
        else
            for _, option in ipairs(def.options) do
                if option.value == value then display = option.label end
            end
        end
        local relevant = def.requires == nil
        for _, key in ipairs(def.requires or {}) do
            if self.active_roles[key] then relevant = true end
        end
        out[#out + 1] = {
            key = def.key,
            label = def.label,
            help = def.help,
            kind = def.kind,
            value = value,
            display = display,
            min = def.min,
            max = def.max,
            options = def.options,
            relevant = relevant,
        }
    end
    return out
end

---@return RoleView[]
function Game:roles_view()
    local counts = {}
    for _, entry in ipairs((self:plan_deck(#self.order))) do counts[entry.role] = entry.count end
    local keys = { "werewolf" }
    for _, key in ipairs(Game.optional_roles) do keys[#keys + 1] = key end
    keys[#keys + 1] = "villager"

    local out = {}
    for _, key in ipairs(keys) do
        local role = Game.roles[key]
        local active = role.core == true or self.active_roles[key] == true
        out[#out + 1] = {
            key = key,
            name = role.name,
            blurb = role.blurb,
            team = role.team,
            core = role.core == true,
            active = active,
            count = (active and #self.order > 0) and counts[key] or nil,
        }
    end
    return out
end

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
        local show = self.phase == "over" or (not pl.alive and self.settings.reveal_role) or pl == viewer
            or (viewer_wolf and team_of(pl) == "wolves")
        v.players[#v.players + 1] = { id = pl.id, name = pl.name, alive = pl.alive, role = show and pl.role or nil }
    end

    if viewer then
        v.you = { id = viewer.id, name = viewer.name, role = viewer.role, alive = viewer.alive, team = team_of(viewer) }
        v.notes = viewer.notes
        v.action = self:action_for(viewer)
    end

    if self.phase == "lobby" and not viewer then -- the host configures the round here
        v.rules, v.roles = self:rules_view(), self:roles_view()
        local _, err = self:plan_deck(#self.order)
        v.deck_error = err
    elseif self.deck and self.settings.show_deck then
        v.deck = {}
        for _, entry in ipairs(self.deck) do
            if entry.count > 0 then v.deck[#v.deck + 1] = entry end
        end
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
