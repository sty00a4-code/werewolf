-- GET /api/view?code=..&(token=..|key=..)&v=<version the client already has>
--   204 -> nothing changed
--   200 -> HTML fragment for #app, plus X-Version / X-Server-Time headers
local render = require "render"

---@param state GameState
return function(state, req, ip)
    local code = qs(req, "code")
    if not code then
        return response { status = STATUS.bad_request, body = "No 'code' parameter given" }
    end
    local room = state.get_room(code)
    if not room then
        return response { status = STATUS.not_found, body = "Game not found" }
    end
    local player
    local key = qs(req, "key")
    if key then
        if not room:is_host(key) then return response { status = STATUS.forbidden, body = "Bad host key" } end
    else
        local token = qs(req, "token")
        if not token then
            return response { status = STATUS.bad_request, body = "No 'token' parameter given" }
        end
        player = room:player_by_token(token)
        if not player then return response { status = STATUS.forbidden, body = "Unknown player" } end
    end
    local headers = { ["X-Version"] = room.version, ["X-Server-Time"] = os.time(), ["Cache-Control"] = "no-store" }
    if tonumber(qs(req, "v")) == room.version then
        return response { status = STATUS.no_content, headers = headers }
    end
    local view = room:view_for(player)
    return response { headers = headers, body = player and render.client(view) or render.host(view) }
end
