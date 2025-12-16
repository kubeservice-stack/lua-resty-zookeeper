# lua-resty-zookeeper

A minimal, synchronous ZooKeeper client for OpenResty / plain Lua with robust CONNECT handshake parsing and basic operations.

This repository provides:

- `lua/zk_connection.lua` — core client implementation (handshake, signed error handling, create/get_children, exists, get_data, add_auth, close).
- `lua/resty/zookeeper.lua` — OpenResty-compatible wrapper (returns the core module).
- `lua/zookeeper.lua` — compatibility wrapper (so `require("zookeeper")` works).
- `test/test_zk.lua` — extended test script (connect, exists, get_data, create, get_children).
- helper scripts: `create_repo.sh` (creates project and zip).

Notable updates

- Robust CONNECT handshake parsing with heuristics to handle different server response layouts.
- Converts server 32-bit error codes to signed int32 for correct interpretation (e.g. ZNONODE = -101, ZNODEEXISTS = -110).
- Added API:
  - `client:create(path, data, mode, sequential)` — create nodes (supports persistent / ephemeral and sequential flags).
  - `client:get_children(path)` — list children (returns a Lua table).
- `add_auth` is an instance method: `client:add_auth(type, creds)`.

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
local zk = require("zk_connection") -- or require("resty.zookeeper")
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

- close

```lua
client:close()
```

## Error codes
- Server error codes are 32-bit signed integers. This implementation converts received error codes to signed int32 values and interprets common constants:
  - -101 (ZNONODE) : node does not exist
  - -110 (ZNODEEXISTS) : node already exists
- Client methods return friendly errors for these conditions (for example, `exists` returns `false, nil` when the node does not exist).

## Testing
- The test script `test/test_zk.lua` demonstrates:
  - connecting to a server
  - checking for and creating a parent node if necessary
  - creating a sequential child node
  - listing children via `get_children`
- Run the test with debug enabled to print handshake payload hex:

  ```
  export LUA_PATH="./lua/?.lua;./lua/?/init.lua;;"
  lua test/test_zk.lua 127.0.0.1:2181 /daaa
  ```

## Debugging tips
- Enable `debug = true` when creating the client to print handshake payload length and hex for troubleshooting.
- Use tcpdump or Wireshark to capture the handshake exchange and compare with the printed hex if deep inspection is needed.

## Limitations and future work
- This client is synchronous and designed for single-request-at-a-time usage per connection. It is not production-ready in terms of:
  - concurrent request handling on a single socket
  - watcher event handling
  - automatic reconnection and session recovery
  - comprehensive unit tests and CI
- Future enhancements could include async I/O integration, watcher support, reconnect/session recovery, and publishing as a rock.

## License
- BSD
