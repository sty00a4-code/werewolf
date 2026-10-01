function WRAPPER(opts)
    local file = assert(io.open("style.css", "r"))
    local STYLE = file:read("a")
    file:close()
    return "<!DOCTYPE html>" .. tostring(html {
        head {
            meta { charset = "UTF-8" },
            meta { name = "viewport", content = "width=device-width, initial-scale=1.0" },
            style { type = "text/css", STYLE },
        },
        body(opts),
    })
end
