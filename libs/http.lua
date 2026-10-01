local MAX_REQUEST = 8 * 1024 * 1024
local MAX_HEADERS = 64 * 1024
local MAX_HEADER_COUNT = 100
local MAX_BODY = 4 * 1024 * 1024
STATUS = {
    continue = 100,
    switching_protocols = 101,
    processing = 102,
    early_hints = 103,

    ok = 200,
    created = 201,
    accepted = 202,
    non_authoritative_information = 203,
    no_content = 204,
    reset_content = 205,
    partial_content = 206,
    multi_status = 207,
    already_reported = 208,
    im_used = 226,

    multiple_choices = 300,
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    use_proxy = 305,
    temporary_redirect = 307,
    permanent_redirect = 308,

    bad_request = 400,
    unauthorized = 401,
    payment_required = 402,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    proxy_authentication_required = 407,
    request_timeout = 408,
    conflict = 409,
    gone = 410,
    length_required = 411,
    precondition_failed = 412,
    payload_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,
    range_not_satisfiable = 416,
    expectation_failed = 417,
    im_a_teapot = 418,
    unprocessable_content = 422,
    locked = 423,
    failed_dependency = 424,
    too_early = 425,
    upgrade_required = 426,
    precondition_required = 428,
    too_many_requests = 429,
    request_header_fields_too_large = 431,
    unavailable_for_legal_reasons = 451,

    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,
    http_version_not_supported = 505,
    variant_also_negotiates = 506,
    insufficient_storage = 507,
    loop_detected = 508,
    not_extended = 510,
    network_authentication_required = 511,
}
local function validate_header(s)
    return not tostring(s):find("[\r\n]")
end
---@alias Request { method: string, path: string, version: string, headers: table, body: string, params: table<string, string|boolean> }
---@param s string
---@return Request?
---@return string?
function request(s)
    if type(s) ~= "string" then return nil, "Input must be string" end
    if #s > MAX_REQUEST then
        return nil, "Request too large"
    end
    s = s:gsub("\r\n", "\n")
    local first_nl = s:find("\n", 1, true)
    local head_line, rest
    if first_nl then
        head_line = s:sub(1, first_nl - 1)
        rest = s:sub(first_nl + 1) -- may be headers + body or empty
    else
        head_line = s
        rest = ""
    end
    if head_line == "" then return nil, "Empty request" end
    ---@type string, string, string
    local method, url, version = head_line:match("^(%S+)%s+(%S+)%s+(HTTP/%d+%.%d+)$")
    if not method then return nil, "Malformed request line" end
    local path, args = url:sepOne("?")
    local params = {}
    for pair in args:gmatch("([^&]+)") do
        local k, v = pair:match("^([^=]*)=(.*)$")
        if k then
            params[k] = v
        else
            params[pair] = true
        end
    end
    local headers = {}
    local body = ""
    local sep = rest:find("\n\n", 1, true)
    if sep then
        local headers_block = rest:sub(1, sep - 1)
        body = rest:sub(sep + 2)
        local header_count = 0
        for line in headers_block:gmatch("([^\n]*)\n?") do
            if header_count > MAX_HEADER_COUNT then
                return nil, "Too many headers"
            end
            if line ~= "" then
                local k, v = line:match("^([^:]+):%s*(.*)$")
                if validate_header(k) and not k:find("%s") then
                    if not k then return nil, "Malformed header line: " .. tostring(line) end
                    k = k:lower()
                    if headers[k] then
                        headers[k] = headers[k] .. ", " .. v
                    else
                        headers[k] = v
                    end
                    header_count = header_count + 1
                end
            end
        end
    end
    local cl = headers["content-length"]
    if cl ~= nil then
        local n = tonumber(cl)
        if not n or n < 0 then return nil, "Invalid Content-Length" end
        body = body:sub(1, n)
    end
    if #body > MAX_BODY then
        return nil, "Body too large"
    end
    local te = headers["transfer-encoding"]
    if te and te:lower():find("chunked", 1, true) then
        return nil, "chunked transfer-encoding not supported"
    end
    return {
        method = method,
        path = path,
        version = version,
        headers = headers,
        body = body,
        params = params
    }
end

---@param t { status: integer?, reason: string?, reasons: string[]?, headers: table, body: string? }
---@return string
function response(t)
    t = t or {}
    local status = t.status or STATUS.ok
    local reason = t.reason or (t.reasons and t.reasons[status]) or ""
    local headers = t.headers or {}
    local body = t.body or ""
    local body_len = type(body) == "string" and #body or 0
    if headers["Content-Length"] == nil and headers["content-length"] == nil then
        headers["Content-Length"] = tostring(body_len)
    end
    if headers["Connection"] == nil and headers["connection"] == nil then
        headers["Connection"] = "close"
    end
    local function norm_header_key(k)
        if k == nil then return "" end
        return tostring(k)
    end
    local head = "HTTP/1.1 " .. tostring(status) .. (reason ~= "" and (" " .. reason) or "") .. "\r\n"
    local hdr = {}
    for k, v in pairs(headers) do
        if v ~= nil then
            table.insert(hdr, norm_header_key(k) .. ": " .. tostring(v))
        end
    end
    head = head .. table.concat(hdr, "\r\n") .. "\r\n\r\n"
    return head .. (type(body) == "string" and body or tostring(body))
end

function recv_crlf(c)
    local lines = {}
    local size = 0
    while true do
        local line, err = c:receive("*l")
        if not line then
            return nil, err, table.concat(lines, "\r\n")
        end
        size = size + #line + 2
        if size > MAX_HEADERS then
            return nil, "header too large"
        end
        if line == "" then
            break
        end
        lines[#lines + 1] = line
    end
    return table.concat(lines, "\r\n") .. "\r\n\r\n"
end
