---@param state table
---@param req Request
---@param ip string
---@return boolean, string?
function route(state, req, ip)
    local not_found = response { status = STATUS.not_found, body = "not found" }
    -- plain path segments only: blocks "/../server" style traversal into other .lua files
    if not req.path:match("^/[%w_]+[%w_/]*$") or req.path:find("//", 1, true) then
        return true, not_found
    end
    local chunk = loadfile("route" .. req.path .. ".lua")
    if not chunk then
        return true, not_found
    end
    local ok, f = pcall(chunk)
    if not ok then
        return ok, f
    end
    return pcall(f, state, req, ip)
end
