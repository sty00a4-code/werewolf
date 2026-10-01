-- Registry of live games, keyed by the 8-letter code.
-- server.lua passes this object to every route as `state`.
-- (Everything game-specific lives in game.lua.)
local Game = require "game"

local rooms = {}
local ROOM_TTL = 6 * 60 * 60 -- forget rooms nobody has touched for 6h

local function new_code()
    while true do
        local c = {}
        for k = 1, 8 do c[k] = string.char(math.random(65, 90)) end
        local code = table.concat(c)
        if not rooms[code] then return code end
    end
end

---@class GameState
---@field create_room fun(): Game
---@field get_room fun(code: string): Game?
---@type GameState
return setmetatable({
    ---@return Game
    create_room = function()
        local now = os.time()
        for code, r in pairs(rooms) do
            if now - r.touched > ROOM_TTL then rooms[code] = nil end
        end
        local room = Game.new(new_code())
        rooms[room.code] = room
        return room
    end,
    ---@param code string?
    ---@return Game?
    get_room = function(code)
        return code and rooms[code:upper()] or nil
    end,
}, {
    __name = "state",
    __newindex = function() end,
})
