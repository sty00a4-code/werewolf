-- Creates a room and sends the host straight to its screen.
-- The host key lives in the URL, so refreshing the page keeps you in charge of the same game.
return function(state, req, ip)
    local room = state.create_room()
    return response {
        status = STATUS.found,
        headers = { Location = ("/host?code=%s&key=%s"):format(room.code, room.host_key) },
    }
end
