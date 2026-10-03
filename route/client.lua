-- A player's phone. Auth (?token=) is checked by /api/view; this is just the shell.
return function(state, req, ip)
    return require("render").page("client")
end
