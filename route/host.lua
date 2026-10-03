-- Shared screen. Auth (?key=) is checked by /api/view; this is just the shell.
return function(state, req, ip)
    return require("render").page("host")
end
