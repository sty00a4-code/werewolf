local socket = require "socket"
require "libs"
require "std"

local server = assert(socket.bind("*", 8000))
local IP, PORT = server:getsockname()
print(("[SERVE] http://%s:%s"):format(IP, PORT))

local state = require "gamestate"
while true do
    local success, err = pcall(function()
        local client = server:accept()
        if client then
            client:settimeout(1)
            local ip = client:getpeername()
            local header_blob, err = recv_crlf(client)
            if not header_blob then
                client:send(response { status = STATUS.not_acceptable, body = err or "ERROR 1" })
                goto continue
            end

            local cl = header_blob:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")
            local content_len = cl and tonumber(cl) or 0

            local body = ""
            while content_len > 0 do
                local chunk = client:receive(math.min(65536, content_len))
                if not chunk then
                    goto continue
                end
                body = body .. chunk
                content_len = content_len - #chunk
            end

            local msg = header_blob .. body
            local req, err = request(msg)
            if not req then
                client:send(response { status = STATUS.not_acceptable, body = err or "ERROR 1" })
                goto continue
            end
            if req.path ~= "/api/view" then -- polled every second per player; keep the log readable
                print(("[CLIENT] %s: %s %q"):format(ip, req.method, req.path))
            end
            if req.path == "/" then
                req.path = "/home"
            end
            if req.path == "/wolf.png" or req.path == "/favicon.ico" then
                local file = assert(io.open("wolf.png", "r"))
                local PNG = file:read("a")
                file:close()
                client:send(response {
                    status = STATUS.ok,
                    body = PNG
                })
                goto continue
            end

            local ok, res = route(state, req, ip)
            if not ok then
                client:send(response {
                    status = STATUS.internal_server_error,
                    body = res or "ERROR 2"
                })
                goto continue
            end
            client:send(tostring(res))
        end
        ::continue::
        client:close()
    end)
    if not success then
        print("[ERROR] " .. err)
    end
end
