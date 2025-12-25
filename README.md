# lua-resty-zookeeper

A minimal, synchronous ZooKeeper client for OpenResty / plain Lua with robust CONNECT handshake parsing and basic operations.

This repository provides:

- `lua/resty/zookeeper.lua` — core client implementation (handshake, signed error handling, create/get_children, exists, get_data, add_auth, close).
- `test/test_zk.lua` — extended test script (connect, exists, get_data, create, get_children, delete, watch).

Notable updates

- Robust CONNECT handshake parsing with heuristics to handle different server response layouts.
- Converts server 32-bit error codes to signed int32 for correct interpretation (e.g. ZNONODE = -101, ZNODEEXISTS = -110).
- Added API:
  - `client:create(path, data, mode, sequential)` — create nodes (supports persistent / ephemeral and sequential flags).
  - `client:get_children(path)` — list children (returns a Lua table).
  - `client:delete(path, version)` — delete a node (supports specifying version; default -1 means any version).
  - `client:watch(path, kind)` — register a watcher and block until the next watcher event for this session (synchronous/blocking).

## Quick start (plain Lua)

1. Optional dependency for JSON support:

   Using luarocks:

   ```
      luarocks install lua-cjson
   ```

2. Ensure the project `lua/` directory is on `package.path`.

3. Run the test script:
   - Linux / macOS (bash):

     ```
     export LUA_PATH="./lua/?.lua;./lua/?/init.lua;;"
     lua test/test_zk.lua 127.0.0.1:2181 /your_parent_path
     ```

   - Windows (PowerShell):

     ```
     $env:LUA_PATH = ".\lua\?.lua;.\lua\?\init.lua;;"
     lua test\test_zk.lua 127.0.0.1:2181 \your_parent_path
     ```

## Quick start (OpenResty)

1. Add the `lua/` directory to `lua_package_path` in `nginx.conf`:

   ```nginx
   lua_package_path "/path/to/project/lua/?.lua;/path/to/project/lua/?/init.lua;;";
   ```

2. Use in OpenResty Lua code:

   ```lua
   local zk = require("resty.zookeeper")
   local client, err = zk.new{
     connect_string = "127.0.0.1:2181",
     timeout = 3000,
     session_timeout = 30000,
     debug = false,
   }
   local ok, err = client:connect()
   ```

## API summary

- Create client

```lua
local zk = require("zk_connection") -- or require("resty.zookeeper") or require("zookeeper")
local client, err = zk.new{
  connect_string = "127.0.0.1:2181",
  timeout = 5000,        -- ms for ngx, best-effort otherwise
  session_timeout = 30000,
  debug = true,          -- print handshake payload hex when true
}
```

- Connect

```lua
local ok, err = client:connect()
if not ok then error(err) end
```

- Basic operations

```lua
-- exists
local exists, err = client:exists("/myapp")

-- get_data
local data, err = client:get_data("/myapp")

-- add auth (instance method)
local ok, err = client:add_auth("digest", "user:pass")
```

- create

```lua
-- create(path, data, mode, sequential)
-- mode: "persistent" (default) or "ephemeral"
-- sequential: boolean; if true the server appends a monotonically increasing sequence number
local created_path, err = client:create("/myapp/node", "payload", "persistent", true)
```

- get_children

```lua
local children, err = client:get_children("/myapp")
-- returns a Lua table, e.g. { "node0000000001", "node0000000002", ... }
```

- delete

```lua
-- delete(path, version)
-- version: signed int32; default -1 means match any version
local ok, err = client:delete("/myapp/node", -1)
if not ok then
  print("delete failed:", err)
end
```

- watch

```lua
-- watch(path, kind)
-- kind: "exists" (default), "get_data", or "get_children"
-- Blocks until a watcher event is delivered for this session.
local evt, err = client:watch("/myapp", "get_children")
if not evt then
  print("watch failed:", err)
else
  -- evt = { type = <int>, state = <int>, path = "<string>" }
  print("watch event:", evt.type, evt.state, evt.path)
end
```

## Error codes

- Server error codes are 32-bit signed integers. This implementation converts received error codes to signed int32 values and interprets common constants:
  - -101 (ZNONODE) : node does not exist
  - -110 (ZNODEEXISTS) : node already exists
  - -103 (ZBADVERSION) : version conflict on update/delete
- Client methods return friendly errors for these conditions (for example, `exists` returns `false, nil` when the node does not exist).

## Testing

- The test script `test/test_zk.lua` demonstrates:
  - connecting to a server
  - checking for and creating a parent node if necessary
  - creating a sequential child node
  - listing children via `get_children`
  - deleting a created node
  - registering a watch and waiting for an event

- Run the test with debug enabled to print handshake payload hex:

  ```
  export LUA_PATH="./lua/?.lua;./lua/?/init.lua;;"
  lua test/test_zk.lua 127.0.0.1:2181 /daaa
  ```

## Watcher testing notes

- Watchers in ZooKeeper are session-scoped and the server sends watcher events to the session that registered them.
- This library implements `watch` as a synchronous blocking call that waits for the next watcher event delivered to the session. Because it blocks, use a separate connection or coroutine for watchers if you need to perform other requests concurrently.
- For reliable testing of watchers, use two clients/processes:
  - Client A registers the watch (calls `client:watch(...)`).
  - Client B performs an operation (create/delete/set) that triggers the watch.
  - Client A should then receive the watcher event.

## Implementation notes

- `delete` encodes the provided version as a 32-bit integer. `version = -1` is encoded as `0xFFFFFFFF`, matching ZooKeeper's signed int32 representation for "any version".
- `watch` sends the corresponding request (exists/get_data/get_children) with the watch flag set to 1, then reads packets until a watcher event (xid == -1, unsigned 4294967295) arrives. Non-watcher packets received while waiting are ignored.
- This client is synchronous and designed for single-request-at-a-time usage per connection. If you require concurrent requests and watcher/event dispatching on a single connection, consider adding:
  - an internal packet dispatcher that reads incoming packets continuously,
  - routing responses by xid to waiting coroutines,
  - delivering watcher events to registered callbacks.

## Limitations and future work

- Current limitations:
  - synchronous (blocking) I/O model,
  - single-request-per-connection assumption,
  - simple watcher support (blocking wait for a single event),
  - limited operation coverage and stat parsing,
  - no automatic reconnection/session recovery logic,
  - limited tests and no CI.

- Potential enhancements:
  - add an event-driven dispatcher and non-blocking watcher callbacks,
  - implement reconnection and session recovery,
  - expand the supported ZooKeeper protocol operations (ACLs, multi, get_acl, set_acl, stat parsing),
  - add unit tests and CI workflow,
  - publish as a LuaRock.

## License

- BSD
