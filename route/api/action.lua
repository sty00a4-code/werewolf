-- POST /api/action?code=..&(token=..|key=..)&type=vote&target=3
return function(state, req, ip)
    local room = state.get_room(qs(req, "code"))
    if not room then return response { status = STATUS.not_found, body = "Game not found." } end

    local kind, target = qs(req, "type"), tonumber(qs(req, "target"))
    local ok, err
    local key = qs(req, "key")
    if key then
        if not room:is_host(key) then return response { status = STATUS.forbidden, body = "Bad host key." } end
        ok, err = room:host_act(kind, target)
    else
        local player = room:player_by_token(qs(req, "token"))
        if not player then return response { status = STATUS.forbidden, body = "Unknown player." } end
        ok, err = room:act(player, kind, target)
    end
    if not ok then return response { status = STATUS.bad_request, body = err or "Invalid action." } end
    return response { body = "ok" }
end
