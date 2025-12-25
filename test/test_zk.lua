--   - Lua (5.1/5.2/5.3/5.4)
--   - LuaSocket (`luarocks install luasocket`)
--   - cjson (optional; module requires cjson.safe. If not present, the client may still work but will error on require)
--
-- Notes:
--   - Ensure a ZooKeeper server is running and reachable at the connect string.
--   - This test uses the 'zookeeper.lua' file in the project via require("zookeeper").

local zk_mod_name = "zookeeper"

local ok, zk = pcall(require, zk_mod_name)
if not ok then
    print(string.format("failed to require %s: %s", zk_mod_name, zk))
    os.exit(1)
end

local connect_string = arg[1] or "127.0.0.1:2181"
local test_path = arg[2] or "/"

local client, err = zk.new{
    timeout = 5000,
    connect_string = connect_string,
    session_timeout = 30000,
    debug = true, -- enable to print handshake payload hex for troubleshooting
}

if not client then
    print("zk.new failed:", err)
    os.exit(1)
end

print("Connecting to ZooKeeper at:", connect_string)
local ok, err = client:connect()
if not ok then
    print("connect failed:", err)
    os.exit(1)
end

print("Connected. session_id:", tostring(client.session_id))
print("session_timeout:", tostring(client.session_timeout))
print("session_passwd length:", tostring(#(client.session_passwd or "")))

-- Test exists on test_path
local exists, err = client:exists(test_path)
if err then
    print("exists error for path", test_path, ":", err)
else
    print("exists(", test_path, ") =>", tostring(exists))
end

-- Test get_data on test_path
local data, err = client:get_data(test_path)
if err then
    print("get_data error for path", test_path, ":", err)
else
    local preview = data or ""
    if #preview > 200 then
        preview = preview:sub(1, 200) .. "...(truncated, total " .. #data .. " bytes)"
    end
    print("get_data(", test_path, ") => length:", #data, "preview:", preview)
end

-- Create a sequential child under test_path
local parent = test_path
-- Ensure parent exists (if not, attempt to create as persistent)
local ex, err = client:exists(parent)
if ex == false then
    print("Parent", parent, "does not exist; attempting to create it as persistent")
    local created_parent, cerr = client:create(parent, "", "persistent", false)
    if not created_parent then
        print("failed to create parent:", cerr)
    else
        print("created parent:", created_parent)
    end
elseif err then
    print("error checking parent existence:", err)
end

local child_prefix = parent
if parent:sub(-1) ~= "/" then
    child_prefix = parent .. "/node"
else
    child_prefix = parent .. "node"
end

print("Creating sequential child with prefix:", child_prefix)
local created_path, cerr = client:create(child_prefix, "test-data", "persistent", true)
if not created_path then
    print("create failed:", cerr)
else
    print("create succeeded, created path:", created_path)
end

-- List children of parent
local children, err = client:get_children(parent)
if err then
    print("get_children error for", parent, ":", err)
else
    print("children of", parent, ":", table.concat(children, ", "))
end

-- Example: DELETE the created node (use version = -1 to ignore version)
if created_path then
    print("Attempt delete:", created_path)
    local ok, derr = client:delete(created_path, -1)
    if not ok then
        print("delete failed:", derr)
    else
        print("delete succeeded for", created_path)
    end
end

-- Example: WATCH usage
-- Note: watch blocks until an event is delivered. For reliable testing, trigger an event
-- from a separate client or process (e.g., create/delete under the watched path).
-- Here we demonstrate registering a watch on parent children and then (optionally)
-- prompting manual / external operations to trigger the event.
print("Registering children watch for:", parent)
local success, werr = client:get_children(parent) -- register without watch
if not success then
    print("get_children (for watch) failed:", werr)
else
    -- register watch via watch() helper (this will block until event arrives)
    print("Calling client:watch(", parent, ', "get_children") => waiting for event...')
    local evt, err = client:watch(parent, "get_children")
    if not evt then
        print("watch failed:", err)
    else
        print("watch event:", "type=", tostring(evt.type), "state=", tostring(evt.state), "path=", tostring(evt.path))
    end
end

-- Close
local ok, cerr = client:close()
if not ok then
    print("close failed:", cerr)
else
    print("connection closed")
end
