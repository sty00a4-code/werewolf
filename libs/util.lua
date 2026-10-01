---@param s string
---@return string
function urldecode(s)
    s = s:gsub("%+", " ")
    s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return s
end

---Query-string value from a parsed request, url-decoded. nil if missing.
---@param req Request
---@param key string
---@return string?
function qs(req, key)
    local v = req.params[key]
    if v == nil or v == true then return nil end
    return urldecode(tostring(v))
end

---Escape text for HTML. The html lib does NOT escape, so run every
---piece of user input (player names!) through this.
---@param s any
---@return string
function esc(s)
    return (tostring(s):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;",
    }))
end

---Random hex string (uses /dev/urandom, falls back to math.random).
---@param nbytes integer?
---@return string
function token_hex(nbytes)
    nbytes = nbytes or 16
    local f = io.open("/dev/urandom", "rb")
    local bytes = f and f:read(nbytes)
    if f then f:close() end
    local out = {}
    for k = 1, nbytes do
        out[k] = ("%02x"):format(bytes and bytes:byte(k) or math.random(0, 255))
    end
    return table.concat(out)
end

function string.sepOne(s, sep)
    local i1 = 0
    local i2 = #s + 1
    while i1 < #s do
        if s:sub(i1, i1 + #sep - 1) == sep then
            i1 = i1 - 1
            i2 = i1 + #sep + 1
            break
        end
        i1 = i1 + 1
    end
    return s:sub(1, i1), s:sub(i2)
end

---@param cmd string
---@return file*?
---@return string?
function sh(cmd)
    local p, err = io.popen(cmd, "r")
    if not p then
        return nil, err
    end
    return p
end

---@param path string
---@return table?
---@return string?
function listdir(path)
    local p, err = sh('ls -a1 -- "' .. path .. '"')
    if not p then return nil, err end

    local t = {}
    for line in p:lines() do
        if line ~= '.' and line ~= '..' then
            t[#t + 1] = line
        end
    end
    p:close()
    return t
end

---@param path string
---@return string?
---@return string?
function path_type(path)
    local p, err = sh('stat -c "%F" -- "' .. path .. '" 2>/dev/null')
    if not p then return nil, err end
    local t = p:read "a*"
    p:close()
    return t
end
