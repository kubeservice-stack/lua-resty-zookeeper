-- Minimal ZooKeeper client for OpenResty / ngx_lua
-- Provides: new, set_timeout, connect, add_auth, exists, get_data, close
-- Notes:
--  - This implementation focuses on correct CONNECT handshake and basic
--    request/response framing for common operations.
--  - It uses ngx.socket.tcp (OpenResty). If you use a different environment,
--    adapt socket creation accordingly.
--  - This client is synchronous: it assumes one-request-at-a-time per connection.
--    Concurrent usage from multiple coroutines requires external synchronization.
--  - It avoids FFI and uses pure-Lua big-endian packing/unpacking for portability.
--
-- Minimal ZooKeeper client for OpenResty / plain Lua
-- Robust CONNECT handshake parsing with fallback heuristics.

local ngx = ngx
local socket = ngx and ngx.socket or require("socket") -- fallback for plain Lua (luasocket)

-- safe cjson loading with fallback stub
local cjson_ok, cjson = pcall(require, "cjson.safe")
if not cjson_ok then
    cjson_ok, cjson = pcall(require, "cjson")
end
if not cjson_ok or not cjson then
    cjson = {
        encode = function(_) return nil, "cjson not available" end,
        decode = function(_) return nil, "cjson not available" end,
    }
end

local _M = {
    _VERSION = "0.2.5",
    ZOO_OPEN_ACL_UNSAFE = { { perms = 0x1f, scheme = "world", id = "anyone" } },
}

local mt = { __index = _M }

local OP_CODES = {
    CONNECT = -100,
    CREATE = 1,
    DELETE = 2,
    EXISTS = 3,
    GET_DATA = 4,
    SET_DATA = 5,
    AUTH = 100,
    CLOSE = -1,
    PING = -101,
    GET_CHILDREN = 8,
}

local SESSION_STATES = {
    DISCONNECTED = 0,
    CONNECTED = 1,
    EXPIRED = 2,
}

-- Utilities: big-endian pack/unpack (pure Lua)
local function uint32_to_be(num)
    num = (num % 4294967296)
    local b1 = math.floor(num / 16777216) % 256
    local b2 = math.floor(num / 65536) % 256
    local b3 = math.floor(num / 256) % 256
    local b4 = num % 256
    return string.char(b1, b2, b3, b4)
end

local function be_to_uint32(s, offset)
    offset = offset or 1
    if #s < offset + 3 then
        return nil, "not enough bytes for uint32"
    end
    local b1 = string.byte(s, offset)
    local b2 = string.byte(s, offset + 1)
    local b3 = string.byte(s, offset + 2)
    local b4 = string.byte(s, offset + 3)
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

local function uint64_parts_to_be(high, low)
    high = (high or 0) % 4294967296
    low = (low or 0) % 4294967296
    return uint32_to_be(high) .. uint32_to_be(low)
end

local function be_to_uint64_parts(s, offset)
    offset = offset or 1
    local hi, err = be_to_uint32(s, offset)
    if not hi then return nil, err end
    local lo, err2 = be_to_uint32(s, offset + 4)
    if not lo then return nil, err2 end
    return hi, lo
end

local function serialize_string(str)
    str = str or ""
    return uint32_to_be(#str) .. str
end

local function deserialize_string(s, offset)
    offset = offset or 1
    local len, err = be_to_uint32(s, offset)
    if not len then return nil, offset, "failed read string length: " .. (err or "") end
    local start_pos = offset + 4
    local end_pos = start_pos + len - 1
    if #s < end_pos then
        return nil, offset, "not enough bytes for string content"
    end
    local str = s:sub(start_pos, end_pos)
    return str, end_pos + 1
end

local function read_packet(sock)
    local len_data, err = sock:receive(4)
    if not len_data then
        return nil, "failed receive length: " .. (err or "unknown")
    end
    local total_len, err2 = be_to_uint32(len_data, 1)
    if not total_len then
        return nil, "invalid length field: " .. (err2 or "")
    end
    if total_len == 0 then
        return "", nil
    end
    local payload, err3 = sock:receive(total_len)
    if not payload then
        return nil, "failed receive payload: " .. (err3 or "unknown")
    end
    return payload, nil
end

local function serialize_request_header(opcode, xid, payload_len)
    local total_len = 4 + 4 + (payload_len or 0)
    local len_bin = uint32_to_be(total_len)
    local xid_bin = uint32_to_be(xid)
    local opcode_bin = uint32_to_be(opcode)
    return len_bin .. xid_bin .. opcode_bin
end

-- convert unsigned 32-bit to signed 32-bit
local function to_signed32(n)
    if not n then return nil end
    if n >= 2147483648 then
        return n - 4294967296
    end
    return n
end

local function deserialize_response(payload)
    if #payload < 16 then
        return nil, "response too short"
    end
    local xid, _ = be_to_uint32(payload, 1)
    local zxid_hi, zxid_lo = be_to_uint64_parts(payload, 5)
    local err_u, _ = be_to_uint32(payload, 13)
    local err_code = to_signed32(err_u)
    local user_payload = payload:sub(17)
    return {
        xid = xid,
        zxid_hi = zxid_hi,
        zxid_lo = zxid_lo,
        err = err_code,
        payload = user_payload,
    }, nil
end

local function to_hex(s)
    return (s:gsub('.', function(c) return string.format('%02X', string.byte(c)) end))
end

-- Robust connect response parsing with scanning heuristics
local function deserialize_connect_response(payload)
    if not payload or #payload < 8 then
        return nil, "connect response too short (need >=8 for sessionId), got length=" .. tostring(#payload)
    end

    -- Attempt 1: assume payload starts with sessionId
    local sid_hi, sid_lo = be_to_uint64_parts(payload, 1)
    local function attempt_passwd_then_timeout(base)
        base = base or 1
        local passwd_len_off = base + 8
        if #payload < passwd_len_off + 3 + 4 then
            return nil, "not enough bytes to contain passwd length + timeout"
        end
        local passwd_len, err = be_to_uint32(payload, passwd_len_off)
        if not passwd_len then return nil, "failed read passwd length: " .. tostring(err) end
        local passwd_start = passwd_len_off + 4
        local passwd_end = passwd_start + passwd_len - 1
        if #payload < passwd_end + 4 then
            return nil, string.format("not enough bytes for passwd (need %d, have %d) and timeout", passwd_len, #payload - (passwd_start - 1))
        end
        local passwd = passwd_len > 0 and payload:sub(passwd_start, passwd_end) or ""
        local timeout = be_to_uint32(payload, passwd_end + 1)
        if not timeout then return nil, "failed read timeout after passwd" end
        local numeric = sid_hi * 4294967296 + sid_lo
        return {
            sid_hi = sid_hi,
            sid_lo = sid_lo,
            session_id = numeric < 9007199254740992 and numeric or nil,
            session_id_raw = uint64_parts_to_be(sid_hi, sid_lo),
            passwd = passwd,
            timeout = timeout,
        }, nil
    end

    local function attempt_timeout_then_passwd(base)
        base = base or 1
        local timeout_off = base + 8
        if #payload < timeout_off + 3 + 4 then
            return nil, "not enough bytes to contain timeout + passwd length"
        end
        local timeout = be_to_uint32(payload, timeout_off)
        if not timeout then return nil, "failed read timeout at offset " .. tostring(timeout_off) end
        local passwd_len_off = timeout_off + 4
        if #payload < passwd_len_off + 3 then
            if #payload == passwd_len_off - 1 then
                local numeric = sid_hi * 4294967296 + sid_lo
                return {
                    sid_hi = sid_hi,
                    sid_lo = sid_lo,
                    session_id = numeric < 9007199254740992 and numeric or nil,
                    session_id_raw = uint64_parts_to_be(sid_hi, sid_lo),
                    passwd = "",
                    timeout = timeout,
                }, nil
            end
            return nil, "not enough bytes for passwd length after timeout"
        end
        local passwd_len = be_to_uint32(payload, passwd_len_off)
        if not passwd_len then return nil, "failed read passwd length after timeout" end
        local passwd_start = passwd_len_off + 4
        local passwd_end = passwd_start + passwd_len - 1
        if #payload < passwd_end then
            return nil, string.format("not enough bytes for passwd (need %d, have %d)", passwd_len, #payload - (passwd_start - 1))
        end
        local passwd = passwd_len > 0 and payload:sub(passwd_start, passwd_end) or ""
        local numeric = sid_hi * 4294967296 + sid_lo
        return {
            sid_hi = sid_hi,
            sid_lo = sid_lo,
            session_id = numeric < 9007199254740992 and numeric or nil,
            session_id_raw = uint64_parts_to_be(sid_hi, sid_lo),
            passwd = passwd,
            timeout = timeout,
        }, nil
    end

    -- Try standard parses with sessionId at offset 1
    local res, err = attempt_passwd_then_timeout(1)
    if res then return res, nil end
    local res2, err2 = attempt_timeout_then_passwd(1)
    if res2 then return res2, nil end

    -- If payload may be wrapped (e.g. normal response header present), try user-payload at offset 17
    if #payload >= 16 then
        local user_payload = payload:sub(17)
        if #user_payload >= 8 then
            local up_sid_hi, up_sid_lo = be_to_uint64_parts(user_payload, 1)
            sid_hi, sid_lo = up_sid_hi, up_sid_lo
            local r3, e3 = attempt_passwd_then_timeout(1)
            if r3 then return r3, nil end
            local r4, e4 = attempt_timeout_then_passwd(1)
            if r4 then return r4, nil end
            sid_hi, sid_lo = be_to_uint64_parts(payload, 1)
        end
    end

    -- Scanning heuristic:
    local max_passwd_len = 4096
    local plen = #payload
    for i = 1, plen - 4 do
        local possible_len, _ = be_to_uint32(payload, i)
        if possible_len and possible_len >= 0 and possible_len <= max_passwd_len then
            local passwd_start = i + 4
            local passwd_end = passwd_start + possible_len - 1
            if passwd_end <= plen then
                local timeout = nil
                if passwd_end + 4 <= plen then
                    timeout = be_to_uint32(payload, passwd_end + 1)
                elseif i - 4 >= 1 then
                    timeout = be_to_uint32(payload, i - 4)
                end
                local sid_candidate_off = nil
                if timeout then
                    local timeout_off = (passwd_end + 1 <= plen) and (passwd_end + 1) or (i - 4)
                    local cand_end = timeout_off - 1
                    local cand_start = cand_end - 7
                    if cand_start >= 1 then
                        sid_candidate_off = cand_start
                    end
                end
                if not sid_candidate_off then
                    if plen >= 8 then sid_candidate_off = 1 end
                end
                if sid_candidate_off then
                    local s_hi, s_lo = be_to_uint64_parts(payload, sid_candidate_off)
                    if s_hi and s_lo then
                        local numeric = s_hi * 4294967296 + s_lo
                        local passwd = possible_len > 0 and payload:sub(passwd_start, passwd_end) or ""
                        return {
                            sid_hi = s_hi,
                            sid_lo = s_lo,
                            session_id = numeric < 9007199254740992 and numeric or nil,
                            session_id_raw = uint64_parts_to_be(s_hi, s_lo),
                            passwd = passwd,
                            timeout = timeout or 0,
                        }, nil
                    end
                end
            end
        end
    end

    local hexpayload = to_hex(payload)
    local msg = "failed parse connect response; attempts:\n" ..
                "  passwd-then-timeout error: " .. tostring(err) .. "\n" ..
                "  timeout-then-passwd error: " .. tostring(err2) .. "\n" ..
                "payload length: " .. tostring(#payload) .. "\n" ..
                "payload hex: " .. hexpayload
    return nil, msg
end

local function send_request(self, opcode, payload)
    payload = payload or ""
    local xid = self.xid
    local header = serialize_request_header(opcode, xid, #payload)
    local req = header .. payload
    local bytes, err = self.sock:send(req)
    if not bytes then
        return nil, "send failed: " .. (err or "unknown")
    end
    self.xid = (self.xid + 1) % 4294967296
    local raw_payload, err2 = read_packet(self.sock)
    if not raw_payload then
        return nil, "receive failed: " .. (err2 or "unknown")
    end
    local res, err3 = deserialize_response(raw_payload)
    if not res then
        return nil, "deserialize response failed: " .. (err3 or "unknown")
    end
    if res.xid ~= xid then
        if ngx and ngx.log then
            ngx.log(ngx.WARN, "zk: xid mismatch: sent=", xid, " got=", res.xid)
        else
            io.stderr:write(string.format("zk: xid mismatch: sent=%s got=%s\n", tostring(xid), tostring(res.xid)))
        end
    end
    return res, nil
end

-- serialize ACL array (count + entries). Each ACL: perms(int32) + scheme(string) + id(string)
local function serialize_acl_array(acls)
    local parts = {}
    parts[#parts + 1] = uint32_to_be(#acls)
    for _, acl in ipairs(acls) do
        local perms = acl.perms or acl.perm or 0
        parts[#parts + 1] = uint32_to_be(perms)
        parts[#parts + 1] = serialize_string(acl.scheme or acl[1] or "")
        parts[#parts + 1] = serialize_string(acl.id or acl[2] or "")
    end
    return table.concat(parts)
end

function _M.new(opts)
    opts = opts or {}
    local sock, err
    if ngx and ngx.socket then
        sock = ngx.socket.tcp()
    else
        sock, err = socket.tcp()
        if not sock then
            return nil, "socket.tcp failed: " .. (err or "")
        end
    end

    local self = {
        sock = sock,
        timeout = opts.timeout or 3000,
        session_state = SESSION_STATES.DISCONNECTED,
        session_id = 0,
        session_passwd = "",
        connect_string = opts.connect_string or "127.0.0.1:2181",
        session_timeout = opts.session_timeout or 30000,
        xid = 1,
        auth = nil,
        debug = opts.debug or false,
    }

    if ngx and ngx.socket then
        self.sock:settimeout(self.timeout)
    else
        pcall(function() self.sock:settimeout(self.timeout / 1000) end)
    end

    return setmetatable(self, mt), nil
end

function _M.set_timeout(self, timeout)
    self.timeout = timeout or self.timeout
    if ngx and ngx.socket then
        self.sock:settimeout(self.timeout)
    else
        pcall(function() self.sock:settimeout(self.timeout / 1000) end)
    end
end

function _M.connect(self, connect_string, session_timeout)
    self.connect_string = connect_string or self.connect_string
    self.session_timeout = session_timeout or self.session_timeout

    local function split(str, sep)
        local res = {}
        for s in string.gmatch(str, "([^" .. sep .. "]+)") do
            table.insert(res, s)
        end
        return res
    end

    local nodes = split(self.connect_string, ",")
    if #nodes == 0 then return nil, "empty connect string" end

    local first = nodes[1]
    local parts = split(first, ":")
    local host = parts[1]
    local port = tonumber(parts[2]) or 2181
    if not host then return nil, "invalid node: " .. tostring(first) end

    local ok, err = self.sock:connect(host, port)
    if not ok then return nil, "connect failed: " .. (err or "unknown") end

    if ngx and ngx.socket then
        self.sock:settimeout(self.timeout)
    else
        pcall(function() self.sock:settimeout(self.timeout / 1000) end)
    end

    local protocol_version = 0
    local last_zxid_hi, last_zxid_lo = 0, 0
    local timeout_ms = self.session_timeout
    local sid_hi, sid_lo = 0, 0
    local passwd = ""

    local payload = {
        uint32_to_be(protocol_version),
        uint64_parts_to_be(last_zxid_hi, last_zxid_lo),
        uint32_to_be(timeout_ms),
        uint64_parts_to_be(sid_hi, sid_lo),
        serialize_string(passwd),
    }
    local payload_str = table.concat(payload)
    local req = uint32_to_be(#payload_str) .. payload_str

    local bytes, send_err = self.sock:send(req)
    if not bytes then
        pcall(function() self.sock:close() end)
        return nil, "send handshake failed: " .. (send_err or "unknown")
    end

    local payload_recv, rerr = read_packet(self.sock)
    if not payload_recv then
        pcall(function() self.sock:close() end)
        return nil, "receive handshake failed: " .. (rerr or "unknown")
    end

    if self.debug then
        local h = to_hex(payload_recv)
        if ngx and ngx.log then
            ngx.log(ngx.DEBUG, "zk: handshake payload len=", #payload_recv)
            ngx.log(ngx.DEBUG, "zk: handshake payload hex=", h)
        else
            print("zk: handshake payload len=", #payload_recv)
            print("zk: handshake payload hex=", h)
        end
    end

    local conn_res, derr = deserialize_connect_response(payload_recv)
    if not conn_res and #payload_recv >= 16 then
        local user_payload = payload_recv:sub(17)
        local cr2, derr2 = deserialize_connect_response(user_payload)
        if cr2 then
            conn_res = cr2
            derr = nil
        else
            if derr then derr = derr .. "\nwrapped-attempt: " .. tostring(derr2) end
        end
    end

    if not conn_res then
        pcall(function() self.sock:close() end)
        return nil, "invalid connect response: " .. (derr or "unknown")
    end

    if conn_res.session_id then
        self.session_id = conn_res.session_id
    else
        self.session_id = tostring(conn_res.sid_hi) .. ":" .. tostring(conn_res.sid_lo)
    end
    self.session_passwd = conn_res.passwd or ""
    self.session_timeout = conn_res.timeout or self.session_timeout
    self.session_state = SESSION_STATES.CONNECTED

    return true, nil
end

function _M.add_auth(self, auth_type, creds)
    if self.session_state ~= SESSION_STATES.CONNECTED then return nil, "not connected" end
    local payload = serialize_string(auth_type) .. serialize_string(creds)
    local res, err = send_request(self, OP_CODES.AUTH, payload)
    if not res then return nil, err end
    if res.err ~= 0 then return nil, "auth failed, err=" .. tostring(res.err) end
    self.auth = { type = auth_type, creds = creds }
    return true, nil
end

function _M.exists(self, path)
    if self.session_state ~= SESSION_STATES.CONNECTED then return nil, "not connected" end
    local payload = serialize_string(path) .. uint32_to_be(0)
    local res, err = send_request(self, OP_CODES.EXISTS, payload)
    if not res then return nil, err end
    if res.err ~= 0 then
        if res.err == -101 then -- ZNONODE
            return false, nil
        end
        return nil, "zk error code: " .. tostring(res.err)
    end
    if res.payload and #res.payload > 0 then return true, nil end
    return false, nil
end

function _M.get_data(self, path)
    if self.session_state ~= SESSION_STATES.CONNECTED then return nil, "not connected" end
    local payload = serialize_string(path) .. uint32_to_be(0)
    local res, err = send_request(self, OP_CODES.GET_DATA, payload)
    if not res then return nil, err end
    if res.err ~= 0 then
        if res.err == -101 then -- ZNONODE
            return nil, "node does not exist"
        end
        return nil, "zk error code: " .. tostring(res.err)
    end
    local data, off, derr = deserialize_string(res.payload, 1)
    if data == nil then return nil, "failed parse data: " .. (derr or "unknown") end
    return data, nil
end

-- create(path, data, mode, sequential)
-- mode: "persistent" (default) or "ephemeral"
-- sequential: boolean, if true sets the sequence bit
-- returns created_path, nil on success
function _M.create(self, path, data, mode, sequential)
    if self.session_state ~= SESSION_STATES.CONNECTED then return nil, "not connected" end
    if not path or type(path) ~= "string" then return nil, "invalid path" end
    data = data or ""
    mode = mode or "persistent"
    sequential = not not sequential

    -- flags: ephemeral = 1, sequence = 2
    local flags = 0
    if mode == "ephemeral" or mode == "ephemeral_sequential" then
        flags = flags + 1
    end
    if sequential then
        flags = flags + 2
    end

    -- default ACL if none provided
    local acl = self.ZOO_OPEN_ACL_UNSAFE or _M.ZOO_OPEN_ACL_UNSAFE
    local acl_bin = serialize_acl_array(acl)

    local payload = serialize_string(path) .. serialize_string(data) .. acl_bin .. uint32_to_be(flags)
    local res, err = send_request(self, OP_CODES.CREATE, payload)
    if not res then return nil, err end
    if res.err ~= 0 then
        if res.err == -101 then
            return nil, "parent node does not exist"
        end
        if res.err == -110 then -- ZNODEEXISTS
            return nil, "node already exists"
        end
        return nil, "zk error code: " .. tostring(res.err)
    end
    -- payload contains created path (string)
    local created, off, derr = deserialize_string(res.payload, 1)
    if created == nil then
        return nil, "failed parse created path: " .. (derr or "unknown")
    end
    return created, nil
end

-- get_children(path) -> returns table of child names
function _M.get_children(self, path)
    if self.session_state ~= SESSION_STATES.CONNECTED then return nil, "not connected" end
    local payload = serialize_string(path) .. uint32_to_be(0) -- watch = 0
    local res, err = send_request(self, OP_CODES.GET_CHILDREN, payload)
    if not res then return nil, err end
    if res.err ~= 0 then
        if res.err == -101 then -- ZNONODE
            return nil, "node does not exist"
        end
        return nil, "zk error code: " .. tostring(res.err)
    end
    local children = {}
    local offset = 1
    local count, cerr = be_to_uint32(res.payload, offset)
    if not count then return nil, "failed parse children count: " .. (cerr or "") end
    offset = offset + 4
    for i = 1, count do
        local child, new_offset, derr = deserialize_string(res.payload, offset)
        if child == nil then
            return nil, "failed parse child string: " .. (derr or "")
        end
        table.insert(children, child)
        offset = new_offset
    end
    return children, nil
end

function _M.close(self)
    if self.session_state == SESSION_STATES.DISCONNECTED then return true, nil end
    local ok, err = pcall(function() return self.sock:close() end)
    if ok then
        self.session_state = SESSION_STATES.DISCONNECTED
        return true, nil
    else
        self.session_state = SESSION_STATES.DISCONNECTED
        return nil, "close failed: " .. tostring(err)
    end
end

function _M._debug(self)
    return {
        session_state = self.session_state,
        session_id = self.session_id,
        session_timeout = self.session_timeout,
        connect_string = self.connect_string,
        xid = self.xid,
        auth_set = self.auth and true or false,
    }
end

return _M