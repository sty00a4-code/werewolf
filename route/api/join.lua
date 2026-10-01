-- POST /api/join?code=ABCDEFGH&name=Alice  ->  200 body = player token
return function(state, req, ip)
    local room = state.get_room(qs(req, "code"))
    if not room then return response { status = STATUS.not_found, body = "No game with that code." } end
    local player, err = room:join(qs(req, "name"))
    if not player then return response { status = STATUS.bad_request, body = err } end
    return response { body = player.token }
end
