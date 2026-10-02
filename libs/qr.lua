-- libs/qr.lua: dependency-free QR code encoder (byte mode, versions 1-10, ECC level L or M).
-- Plenty for URLs up to ~210 characters. Written without bitwise operators so it runs on Lua 5.1-5.5.
--
--   local qr = require "libs.qr"
--   local svg = qr.svg("http://192.168.1.20:8000/?code=ABCDEFGH")   -- string, drop into the page as-is
--   local matrix, size = qr.encode(text, "M")                         -- matrix[y][x] == true for dark, 0-based
local M = {}

----------------------------------------------------------------------
-- tiny bit helpers
----------------------------------------------------------------------
local function bit(n, i) return math.floor(n / 2 ^ i) % 2 end

local function xor(a, b)
    local r, p = 0, 1
    while a > 0 or b > 0 do
        if a % 2 ~= b % 2 then r = r + p end
        a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
    end
    return r
end

----------------------------------------------------------------------
-- Reed-Solomon over GF(256), polynomial 0x11D
----------------------------------------------------------------------
local EXP, LOG = {}, {}
do
    local x = 1
    for k = 0, 254 do
        EXP[k], LOG[x] = x, k
        x = x * 2
        if x >= 256 then x = xor(x, 0x11D) end
    end
    for k = 255, 511 do EXP[k] = EXP[k - 255] end
end

local function gmul(a, b)
    if a == 0 or b == 0 then return 0 end
    return EXP[LOG[a] + LOG[b]]
end

local generators = {}
local function generator(n) -- coefficients high -> low, leading 1
    if generators[n] then return generators[n] end
    local g = { 1 }
    for k = 0, n - 1 do
        local ng = {}
        for j = 1, #g + 1 do ng[j] = 0 end
        for j = 1, #g do
            ng[j] = xor(ng[j], g[j])
            ng[j + 1] = xor(ng[j + 1], gmul(g[j], EXP[k]))
        end
        g = ng
    end
    generators[n] = g
    return g
end

local function rs_remainder(data, n)
    local gen = generator(n)
    local rem = {}
    for k = 1, n do rem[k] = 0 end
    for _, byte in ipairs(data) do
        local factor = xor(byte, rem[1])
        table.remove(rem, 1)
        rem[n] = 0
        for k = 1, n do rem[k] = xor(rem[k], gmul(gen[k + 1], factor)) end
    end
    return rem
end

----------------------------------------------------------------------
-- Version tables: {ec codewords per block, blocks in group 1, data cw each, blocks in group 2, data cw each}
----------------------------------------------------------------------
local EC = {
    M = { { 10, 1, 16, 0, 0 }, { 16, 1, 28, 0, 0 }, { 26, 1, 44, 0, 0 }, { 18, 2, 32, 0, 0 }, { 24, 2, 43, 0, 0 },
        { 16, 4, 27, 0, 0 }, { 18, 4, 31, 0, 0 }, { 22, 2, 38, 2, 39 }, { 22, 3, 36, 2, 37 }, { 26, 4, 43, 1, 44 } },
    L = { { 7, 1, 19, 0, 0 }, { 10, 1, 34, 0, 0 }, { 15, 1, 55, 0, 0 }, { 20, 1, 80, 0, 0 }, { 26, 1, 108, 0, 0 },
        { 18, 2, 68, 0, 0 }, { 20, 2, 78, 0, 0 }, { 24, 2, 97, 0, 0 }, { 30, 2, 116, 0, 0 }, { 18, 2, 68, 2, 69 } },
}
local FORMAT_BITS = { L = 1, M = 0 }
local ALIGN = { {}, { 6, 18 }, { 6, 22 }, { 6, 26 }, { 6, 30 }, { 6, 34 }, { 6, 22, 38 }, { 6, 24, 42 }, { 6, 26, 46 }, { 6, 28, 50 } }

----------------------------------------------------------------------
-- 1. text -> interleaved codewords
----------------------------------------------------------------------
local function codewords(text, level)
    local tbl = EC[level]
    assert(tbl, "level must be 'L' or 'M'")
    local version, e, cap, ccbits
    for v = 1, 10 do
        e = tbl[v]
        cap = e[2] * e[3] + e[4] * e[5]
        ccbits = v < 10 and 8 or 16
        if 4 + ccbits + 8 * #text <= cap * 8 then
            version = v
            break
        end
    end
    assert(version, "text too long for a version 10 QR code")

    local bits = {}
    local function put(value, n)
        for k = n - 1, 0, -1 do bits[#bits + 1] = bit(value, k) end
    end
    put(4, 4) -- byte mode
    put(#text, ccbits)
    for k = 1, #text do put(text:byte(k), 8) end
    for _ = 1, math.min(4, cap * 8 - #bits) do bits[#bits + 1] = 0 end
    while #bits % 8 ~= 0 do bits[#bits + 1] = 0 end

    local data = {}
    for k = 1, #bits, 8 do
        local v = 0
        for j = 0, 7 do v = v * 2 + bits[k + j] end
        data[#data + 1] = v
    end
    local pads, pi = { 0xEC, 0x11 }, 0
    while #data < cap do
        data[#data + 1] = pads[pi % 2 + 1]
        pi = pi + 1
    end

    local blocks, pos = {}, 1
    local function add(count, size)
        for _ = 1, count do
            local d = {}
            for k = 0, size - 1 do d[#d + 1] = data[pos + k] end
            pos = pos + size
            blocks[#blocks + 1] = { data = d, ec = rs_remainder(d, e[1]) }
        end
    end
    add(e[2], e[3])
    add(e[4], e[5])

    local out = {}
    for k = 1, (e[5] > 0 and e[5] or e[3]) do
        for _, blk in ipairs(blocks) do
            if blk.data[k] then out[#out + 1] = blk.data[k] end
        end
    end
    for k = 1, e[1] do
        for _, blk in ipairs(blocks) do out[#out + 1] = blk.ec[k] end
    end
    return out, version
end

----------------------------------------------------------------------
-- 2. codewords -> module matrix
----------------------------------------------------------------------
local function new_grid(size, init)
    local g = {}
    for y = 0, size - 1 do
        g[y] = {}
        for x = 0, size - 1 do g[y][x] = init end
    end
    return g
end

local function draw_format(m, fn, size, level, mask)
    local data = FORMAT_BITS[level] * 8 + mask
    local rem = data
    for _ = 1, 10 do rem = xor(rem * 2, (math.floor(rem / 512) % 2) * 0x537) end
    local bits = xor(data * 1024 + rem, 0x5412)
    local function set(x, y, v)
        m[y][x] = v; fn[y][x] = true
    end
    for k = 0, 5 do set(8, k, bit(bits, k) == 1) end
    set(8, 7, bit(bits, 6) == 1)
    set(8, 8, bit(bits, 7) == 1)
    set(7, 8, bit(bits, 8) == 1)
    for k = 9, 14 do set(14 - k, 8, bit(bits, k) == 1) end
    for k = 0, 7 do set(size - 1 - k, 8, bit(bits, k) == 1) end
    for k = 8, 14 do set(8, size - 15 + k, bit(bits, k) == 1) end
    set(8, size - 8, true) -- the always-dark module
end

local function draw_version(m, fn, size, version)
    if version < 7 then return end
    local rem = version
    for _ = 1, 12 do rem = xor(rem * 2, (math.floor(rem / 2048) % 2) * 0x1F25) end
    local bits = version * 4096 + rem
    for k = 0, 17 do
        local v = bit(bits, k) == 1
        local a, b = size - 11 + k % 3, math.floor(k / 3)
        m[b][a], fn[b][a] = v, true
        m[a][b], fn[a][b] = v, true
    end
end

local function apply_mask(m, fn, size, mask)
    for y = 0, size - 1 do
        for x = 0, size - 1 do
            if not fn[y][x] then
                local inv
                if mask == 0 then
                    inv = (x + y) % 2 == 0
                elseif mask == 1 then
                    inv = y % 2 == 0
                elseif mask == 2 then
                    inv = x % 3 == 0
                elseif mask == 3 then
                    inv = (x + y) % 3 == 0
                elseif mask == 4 then
                    inv = (math.floor(x / 3) + math.floor(y / 2)) % 2 == 0
                elseif mask == 5 then
                    inv = (x * y) % 2 + (x * y) % 3 == 0
                elseif mask == 6 then
                    inv = ((x * y) % 2 + (x * y) % 3) % 2 == 0
                else
                    inv = ((x + y) % 2 + (x * y) % 3) % 2 == 0
                end
                if inv then m[y][x] = not m[y][x] end
            end
        end
    end
end

local function count_plain(s, pat)
    local n, from = 0, 1
    while true do
        local a = s:find(pat, from, true)
        if not a then return n end
        n, from = n + 1, a + 1
    end
end

local function penalty(m, size)
    local score, dark = 0, 0
    for pass = 1, 2 do
        for a = 0, size - 1 do
            local run, prev, line = 0, nil, {}
            for c = 0, size - 1 do
                local v
                if pass == 1 then v = m[a][c] else v = m[c][a] end
                line[#line + 1] = v and "1" or "0"
                if v == prev then
                    run = run + 1
                else
                    if run >= 5 then score = score + 3 + (run - 5) end
                    run, prev = 1, v
                end
            end
            if run >= 5 then score = score + 3 + (run - 5) end
            local s = table.concat(line)
            score = score + 40 * (count_plain(s, "00001011101") + count_plain(s, "10111010000"))
        end
    end
    for y = 0, size - 1 do
        for x = 0, size - 1 do
            if m[y][x] then dark = dark + 1 end
            if y < size - 1 and x < size - 1 then
                local v = m[y][x]
                if m[y][x + 1] == v and m[y + 1][x] == v and m[y + 1][x + 1] == v then score = score + 3 end
            end
        end
    end
    local total = size * size
    local k = math.ceil(math.abs(dark * 20 - total * 10) / total) - 1
    return score + k * 10
end

---@param text string
---@param level "L"|"M"?  error correction, default "M" (~15% damage tolerated)
---@return table matrix  matrix[y][x] == true when dark (0-based)
---@return integer size
function M.encode(text, level, force_mask)
    level = level or "M"
    local cw, version = codewords(text, level)
    local size = version * 4 + 17
    local m, fn = new_grid(size, false), new_grid(size, false)
    local function set(x, y, v)
        if x >= 0 and x < size and y >= 0 and y < size then m[y][x], fn[y][x] = v, true end
    end

    for k = 0, size - 1 do -- timing
        set(6, k, k % 2 == 0)
        set(k, 6, k % 2 == 0)
    end
    for _, c in ipairs { { 3, 3 }, { size - 4, 3 }, { 3, size - 4 } } do -- finders + separators
        for dy = -4, 4 do
            for dx = -4, 4 do
                local d = math.max(math.abs(dx), math.abs(dy))
                set(c[1] + dx, c[2] + dy, d ~= 2 and d ~= 4)
            end
        end
    end
    local pos = ALIGN[version]
    for i1, cy in ipairs(pos) do
        for j1, cx in ipairs(pos) do
            if not ((i1 == 1 and j1 == 1) or (i1 == 1 and j1 == #pos) or (i1 == #pos and j1 == 1)) then
                for dy = -2, 2 do
                    for dx = -2, 2 do set(cx + dx, cy + dy, math.max(math.abs(dx), math.abs(dy)) ~= 1) end
                end
            end
        end
    end
    draw_format(m, fn, size, level, 0) -- reserve the format area
    draw_version(m, fn, size, version)

    local idx, total = 0, #cw * 8
    local right = size - 1
    while right >= 1 do
        if right == 6 then right = 5 end
        for vert = 0, size - 1 do
            for j = 0, 1 do
                local x = right - j
                local y = ((right + 1) % 4 < 2) and (size - 1 - vert) or vert
                if not fn[y][x] and idx < total then
                    m[y][x] = bit(cw[math.floor(idx / 8) + 1], 7 - idx % 8) == 1
                    idx = idx + 1
                end
            end
        end
        right = right - 2
    end

    local best, best_score = 0, math.huge
    for mask = force_mask or 0, force_mask or 7 do
        apply_mask(m, fn, size, mask)
        draw_format(m, fn, size, level, mask)
        local sc = penalty(m, size)
        if sc < best_score then best, best_score = mask, sc end
        apply_mask(m, fn, size, mask) -- undo
    end
    apply_mask(m, fn, size, best)
    draw_format(m, fn, size, level, best)
    return m, size
end

--- SVG string (black on white, with the 4-module quiet zone scanners need).
---@param text string
---@param opts { level: string?, quiet: integer? }?
---@return string
function M.svg(text, opts)
    opts = opts or {}
    local m, size = M.encode(text, opts.level)
    local quiet = opts.quiet or 1
    local d = {}
    for y = 0, size - 1 do
        local x = 0
        while x < size do
            if m[y][x] then
                local start = x
                while x < size and m[y][x] do x = x + 1 end
                d[#d + 1] = ("M%d %dh%dv1h-%dz"):format(start + quiet, y + quiet, x - start, x - start)
            else
                x = x + 1
            end
        end
    end
    local dim = size + 2 * quiet
    return ('<svg xmlns="http://www.w3.org/2000/svg" class="qr" viewBox="0 0 %d %d" shape-rendering="crispEdges"><rect width="100%%" height="100%%" fill="#fff"/><path d="%s" fill="#000"/></svg>')
        :format(dim, dim,
            table.concat(d))
end

return M
