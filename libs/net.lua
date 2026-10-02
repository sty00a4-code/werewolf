-- libs/net.lua: work out which address(es) phones on the same wifi can use to reach this server.
--
--   local net = require "libs.net"
--   net.set_port(8000)                      -- server.lua calls this once after binding
--   local url, all = net.join_url("ABCDEFGH")
--   --> "http://192.168.1.23:8000/?code=ABCDEFGH", { {ip=..., iface=...}, ... } best first
--
-- Override auto-detection with the environment variable WW_HOST (e.g. WW_HOST=192.168.1.50 lua server.lua).
local M = { port = 8000 }

local ok_socket, socket = pcall(require, "socket")

local function is_private(ip)
    local a, b = ip:match("^(%d+)%.(%d+)%.")
    a, b = tonumber(a), tonumber(b)
    if not a then return false end
    return a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168)
end

local function usable(ip)
    return type(ip) == "string" and ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
        and not ip:match("^127%.") and not ip:match("^169%.254%.") and ip ~= "0.0.0.0"
end

-- VPNs, containers and VMs: reachable from this machine only, or not by your guests
local VIRTUAL = { "^lo", "^docker", "^br%-", "^veth", "^virbr", "^vmnet", "^vboxnet", "^tun", "^utun", "^wg",
    "^ppp", "^tailscale", "^zt", "^awdl", "^llw", "^bridge" }
local function is_virtual(iface)
    for _, pat in ipairs(VIRTUAL) do
        if iface:match(pat) then return true end
    end
    return false
end

local function run(cmd)
    local ok, p = pcall(io.popen, cmd .. " 2>/dev/null", "r")
    if not ok or not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    return out
end

--- The address of the interface the OS would use to reach the outside world. A UDP "connect"
--- sends nothing; it only makes the kernel pick a route. We try a few targets so it still works
--- on a router with no internet (private targets match the local subnet route).
local function route_ip()
    if not ok_socket then return nil end
    for _, target in ipairs { "8.8.8.8", "192.168.1.1", "192.168.0.1", "10.0.0.1" } do
        local u = socket.udp()
        if u then
            u:settimeout(0.2)
            local connected = u:setpeername(target, 9)
            local ip = connected and u:getsockname()
            u:close()
            if usable(ip) then return ip end
        end
    end
end

--- Every IPv4 address on this machine, with the interface name when we can tell.
local function interface_ips()
    local found = {}
    -- Linux (iproute2)
    for iface, ip in run("ip -4 -o addr show"):gmatch("%d+:%s+(%S+)%s+inet%s+(%d+%.%d+%.%d+%.%d+)/") do
        found[#found + 1] = { iface = iface, ip = ip }
    end
    if #found > 0 then return found end
    -- macOS / BSD / old net-tools
    local iface
    for line in run("ifconfig"):gmatch("[^\n]+") do
        local name = line:match("^([%w%-_%.]+):?%s")
        if name then iface = name end
        local ip = line:match("inet%s+addr:(%d+%.%d+%.%d+%.%d+)") or line:match("inet%s+(%d+%.%d+%.%d+%.%d+)")
        if ip and iface then found[#found + 1] = { iface = iface, ip = ip } end
    end
    if #found > 0 then return found end
    -- last resort (Linux)
    for ip in run("hostname -I"):gmatch("%d+%.%d+%.%d+%.%d+") do
        found[#found + 1] = { iface = "?", ip = ip }
    end
    return found
end

local cache, cached_at = nil, 0

--- Candidate addresses, best first. Cached for a few seconds (the host screen asks often).
---@return { ip: string, iface: string }[]
function M.lan_ips()
    local now = os.time()
    if cache and now - cached_at < 10 then return cache end

    local iface_of, ifaces = {}, interface_ips()
    for _, e in ipairs(ifaces) do iface_of[e.ip] = e.iface end

    local cands, seen = {}, {}
    local function add(ip, iface, bonus)
        if not usable(ip) or seen[ip] then return end
        seen[ip] = true
        local score = is_private(ip) and 10 or 50 -- private ranges are what home wifi uses
        if iface and is_virtual(iface) then score = score + 20 end
        cands[#cands + 1] = { ip = ip, iface = iface or "?", score = score + bonus, n = #cands }
    end

    local forced = os.getenv("WW_HOST")
    if forced and forced ~= "" then add(forced, "WW_HOST", -100) end
    local primary = route_ip()
    if primary then add(primary, iface_of[primary], -1) end -- wins ties against other real interfaces
    for _, e in ipairs(ifaces) do add(e.ip, e.iface, 0) end

    table.sort(cands, function(x, y)
        if x.score ~= y.score then return x.score < y.score end
        return x.n < y.n
    end)
    cache, cached_at = cands, now
    return cands
end

---@param port integer|string
function M.set_port(port)
    M.port = tonumber(port) or M.port
end

--- URL players should open (the QR code encodes this). Falls back to 127.0.0.1 if no network is found.
---@param code string
---@return string url
---@return { ip: string, iface: string }[] all_candidates
function M.join_url(code)
    local ips = M.lan_ips()
    local ip = ips[1] and ips[1].ip or "127.0.0.1"
    return ("http://%s:%d/?code=%s"):format(ip, M.port, code), ips
end

return M
