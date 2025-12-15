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

local ngx = ngx
local socket = ngx and ngx.socket or require("socket") -- fallback for non-nginx Lua (not tested)
local cjson = require("cjson.safe")

local _M = {
    _VERSION = "0.2.0",
    ZOO_OPEN_ACL_UNSAFE = { { perms = 0x1f, scheme = "world", id = "anyone" } },
}

local mt = { __index = _M }

-- ZK opcodes (wire values are 32-bit signed ints)
local OP_CODES = {
    CONNECT = -100,  -- not used in wire header for initial handshake (special-case)
    CREATE = 1,
    DELETE = 2,
    EXISTS = 3,
    GET_DATA = 4,
    SET_DATA = 5,
    AUTH = 100,
    CLOSE = -1,
    PING = -101,
}

local SESSION_STATES = {
    DISCONNECTED = 0,
    CONNECTED = 1,
    EXPIRED = 2,
}

-- Utilities: pack/unpack big-endian integers (pure Lua, no ffi)
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

-- Pack two uint32s as 8-byte big-endian (useful for int64 fields)
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

-- Serialize a length-prefixed string (int32 length BE + bytes)
local function serialize_string(str)
    str = str or ""
    return uint32_to_be(#str) .. str
end

-- Deserialize length-prefixed string from s at offset, returns str, new_offset
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

-- Read a full ZK packet from socket:
--  - first read 4 bytes (length), then read that many bytes (payload)
-- Returns payload (without the 4-byte length) or nil, err
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

-- Serialize request header for normal requests (xid + opcode) and return header string
-- Note: length prefix (4 bytes) is added by caller as uint32_be(total_payload_len)
local function serialize_request_header(opcode, xid, payload_len)
    -- total payload for server = xid(4) + opcode(4) + payload_len
    local total_len = 4 + 4 + (payload_len or 0)
    local len_bin = uint32_to_be(total_len)
    -- xid/opcode are 32-bit signed integers on wire; we encode as uint32 bit pattern
    local xid_bin = uint32_to_be(xid)
    local opcode_bin = uint32_to_be(opcode)
    return len_bin .. xid_bin .. opcode_bin
end

-- Deserialize a normal response (payload from read_packet)
-- Response payload layout: xid(4) + zxid(8) + err(4) + payload...
-- Returns table { xid=..., zxid_hi=..., zxid_lo=..., err=..., payload=... }
local function deserialize_response(payload)
    if #payload < 16 then
        return nil, "response too short"
    end
    local xid, _ = be_to_uint32(payload, 1)
    local zxid_hi, zxid_lo = be_to_uint64_parts(payload, 5)
    local err_code, _ = be_to_uint32(payload, 13)
    local user_payload = payload:sub(17)
    return {
        xid = xid,
        zxid_hi = zxid_hi,
        zxid_lo = zxid_lo,
        err = err_code,
        payload = user_payload,
    }, nil
end

-- Deserialize connect handshake response (payload from read_packet)
-- Response layout: sessionId (8) + passwd(len+bytes) + timeout (4)
local function deserialize_connect_response(payload)
    -- Need at least sessionId(8) + passwdLen(4) + timeout(4) => 16 bytes minimum (passwd may be 0)
    if #payload < 16 then
        return nil, "connect response too short"
    end
    local sid_hi, sid_lo = be_to_uint64_parts(payload, 1)
    local offset = 9
    local passwd, new_offset, err = deserialize_string(payload, offset)
    if not passwd and passwd ~= "" then
        return nil, "failed parse passwd: " .. (err or "")
    end
    local timeout_off = new_offset
    if #payload < timeout_off + 3 then
        return nil, "connect response missing timeout"
    end
    local timeout = be_to_uint32(payload, timeout_off)
    -- Compute numeric session id where possible (may fit into Lua number)
    local session_id_num = nil
    -- session id = sid_hi * 2^32 + sid_lo; may exceed 53-bit precision for very large values
    local numeric = sid_hi * 4294967296 + sid_lo
    if numeric < 9007199254740992 then -- 2^53
        session_id_num = numeric
    end
    return {
        sid_hi = sid_hi,
        sid_lo = sid_lo,
        session_id = session_id_num, -- may be nil if too big
        session_id_raw = uint64_parts_to_be(sid_hi, sid_lo),
        passwd = passwd or "",
        timeout = timeout,
    }, nil
end

-- Internal send-request helper (synchronous)
-- Builds header with current xid, sends header+payload, waits for response, returns parsed response
local function send_request(self, opcode, payload)
    payload = payload or ""
    local xid = self.xid
    -- encode header
    local header = serialize_request_header(opcode, xid, #payload)
    local req = header .. payload
    -- send
    local bytes, err = self.sock:send(req)
    if not bytes then
        return nil, "send failed: " .. (err or "unknown")
    end
    -- increment xid for next request
    self.xid = (self.xid + 1) % 4294967296
    -- receive
    local raw_payload, err2 = read_packet(self.sock)
    if not raw_payload then
        return nil, "receive failed: " .. (err2 or "unknown")
    end
    local res, err3 = deserialize_response(raw_payload)
    if not res then
        return nil, "deserialize response failed: " .. (err3 or "unknown")
    end
    -- Optionally check xid match (server echoes xid)
    if res.xid ~= xid then
        -- xid can be interpreted as unsigned; we compare bit patterns via modulo 2^32
        -- best-effort warning, but continue returning result
        ngx.log and ngx.log(ngx.WARN, "zk: xid mismatch: sent=", xid, " got=", res.xid)
    end
    return res, nil
end

-- API: new()
function _M.new(opts)
    opts = opts or {}
    local sock, err
    if ngx and ngx.socket then
        sock = ngx.socket.tcp()
    else
        -- fallback for non-openresty (blocking socket from luasocket) -- not fully tested
        sock, err = socket.tcp()
        if not sock then
            return nil, "socket.tcp failed: " .. (err or "")
        end
    end

    local self = {
        sock = sock,
        timeout = opts.timeout or 3000, -- ms for ngx, seconds for luasocket fallback
        session_state = SESSION_STATES.DISCONNECTED,
        session_id = 0,
        session_passwd = "",
        connect_string = opts.connect_string or "127.0.0.1:2181",
        session_timeout = opts.session_timeout or 30000, -- ms
        xid = 1, -- start xid (0,1,2...). -1 used only for connect handshake (special-case)
        auth = nil,
    }

    -- set timeout on socket (ngx.socket.tcp uses milliseconds)
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

-- Connect to first node in connect_string (comma-separated host:port)
-- Performs proper ZooKeeper handshake (no xid/opcode header)
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
    if #nodes == 0 then
        return nil, "empty connect string"
    end

    local first = nodes[1]
    local parts = split(first, ":")
    local host = parts[1]
    local port = tonumber(parts[2]) or 2181
    if not host then
        return nil, "invalid node: " .. tostring(first)
    end

    local ok, err = self.sock:connect(host, port)
    if not ok then
        return nil, "connect failed: " .. (err or "unknown")
    end
    -- ensure timeout set
    if ngx and ngx.socket then
        self.sock:settimeout(self.timeout)
    else
        pcall(function() self.sock:settimeout(self.timeout / 1000) end)
    end

    -- Build handshake payload:
    -- protocolVersion(int32) + lastZxidSeen(int64) + timeout(int32) + sessionId(int64) + passwd(len+bytes)
    -- Protocol version: use 0 (legacy) or 28/29 for newer clients; 0 is widely accepted
    local protocol_version = 0
    local last_zxid_hi, last_zxid_lo = 0, 0
    local timeout_ms = self.session_timeout
    -- sessionId left as 0 for new session
    local sid_hi, sid_lo = 0, 0
    local passwd = ""

    local payload = {}
    table.insert(payload, uint32_to_be(protocol_version))
    table.insert(payload, uint64_parts_to_be(last_zxid_hi, last_zxid_lo))
    table.insert(payload, uint32_to_be(timeout_ms))
    table.insert(payload, uint64_parts_to_be(sid_hi, sid_lo))
    table.insert(payload, serialize_string(passwd))

    local payload_str = table.concat(payload)
    -- Prepend 4-byte length (of payload only) as BE uint32
    local req = uint32_to_be(#payload_str) .. payload_str

    local bytes, err = self.sock:send(req)
    if not bytes then
        pcall(function() self.sock:close() end)
        return nil, "send handshake failed: " .. (err or "unknown")
    end

    -- read handshake response payload
    local payload_recv, err = read_packet(self.sock)
    if not payload_recv then
        pcall(function() self.sock:close() end)
        return nil, "receive handshake failed: " .. (err or "unknown")
    end

    local conn_res, err = deserialize_connect_response(payload_recv)
    if not conn_res then
        pcall(function() self.sock:close() end)
        return nil, "invalid connect response: " .. (err or "unknown")
    end

    -- store session info
    if conn_res.session_id then
        self.session_id = conn_res.session_id
    else
        -- fallback to store raw parts as string
        self.session_id = conn_res.sid_hi .. ":" .. conn_res.sid_lo
    end
    self.session_passwd = conn_res.passwd or ""
    self.session_timeout = conn_res.timeout or self.session_timeout
    self.session_state = SESSION_STATES.CONNECTED

    return true, nil
end

-- add_auth(auth_scheme, creds)
function _M.add_auth(self, auth_type, creds)
    if self.session_state ~= SESSION_STATES.CONNECTED then
        return nil, "not connected"
    end
    local payload = serialize_string(auth_type) .. serialize_string(creds)
    local res, err = send_request(self, OP_CODES.AUTH, payload)
    if not res then
        return nil, err
    end
    if res.err ~= 0 then
        return nil, "auth failed, err=" .. tostring(res.err)
    end
    self.auth = { type = auth_type, creds = creds }
    return true, nil
end

-- exists(path) -> returns true/false or nil, err
function _M.exists(self, path)
    if self.session_state ~= SESSION_STATES.CONNECTED then
        return nil, "not connected"
    end
    -- exists payload: path(string) [watch(boolean) as int32]. We'll set watch=0
    local payload = serialize_string(path) .. uint32_to_be(0)
    local res, err = send_request(self, OP_CODES.EXISTS, payload)
    if not res then return nil, err end
    if res.err ~= 0 then
        -- ZooKeeper error codes: 2 = NoNode, etc. We just return false for NoNode (2).
        if res.err == 2 then
            return false, nil
        end
        return nil, "zk error code: " .. tostring(res.err)
    end
    -- payload contains stat structure; if non-empty node exists
    if res.payload and #res.payload > 0 then
        return true, nil
    end
    return false, nil
end

-- get_data(path) -> returns data_string or nil, err
function _M.get_data(self, path)
    if self.session_state ~= SESSION_STATES.CONNECTED then
        return nil, "not connected"
    end
    -- getData payload: path(string) + watch(int32) (we'll set 0)
    local payload = serialize_string(path) .. uint32_to_be(0)
    local res, err = send_request(self, OP_CODES.GET_DATA, payload)
    if not res then return nil, err end
    if res.err ~= 0 then
        if res.err == 2 then
            return nil, "node does not exist"
        end
        return nil, "zk error code: " .. tostring(res.err)
    end
    -- payload: data (string) + stat(...) ; we need to parse data string first
    local data, off, err = deserialize_string(res.payload, 1)
    if not data and data ~= "" then
        return nil, "failed parse data: " .. (err or "unknown")
    end
    return data, nil
end

-- close connection (cleanly)
function _M.close(self)
    if self.session_state == SESSION_STATES.DISCONNECTED then
        return true, nil
    end
    -- It's sufficient to close the socket to inform server
    local ok, err = pcall(function() return self.sock:close() end)
    -- pcall returns (true, result) on success; handle accordingly
    if ok then
        self.session_state = SESSION_STATES.DISCONNECTED
        return true, nil
    else
        -- ok==false, err is error message
        self.session_state = SESSION_STATES.DISCONNECTED
        return nil, "close failed: " .. tostring(err)
    end
end

-- Simple helper to pretty-print for debugging (careful with secrets)
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
