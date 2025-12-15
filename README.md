# lua-resty-zookeeper

A minimal example ZooKeeper client for OpenResty / ngx_lua and plain Lua.  
This project provides:

- `lua/zookeeper.lua` — the core minimal client (handshake + basic ops).
- `lua/resty/zookeeper.lua` — wrapper for OpenResty (`require("resty.zookeeper")`).
- `test/test_zk.lua` — a simple test script runnable with Lua + LuaSocket.

Important notes
- This client is intentionally minimal and synchronous: it expects one request/response at a time per connection.
- It implements a correct CONNECT handshake and basic `exists` / `get_data` / `add_auth`.
- Not production-ready: lacks watchers handling, re-connection/session revalidation, fine-grained error mapping, concurrency protections, and extensive tests.
- Works in OpenResty (uses `ngx.socket.tcp`) and has a fallback to LuaSocket for quick testing (not exhaustively tested).

Quick start (plain Lua)
1. Install Lua and LuaSocket:
   luarocks install luasocket
2. From project root run:
   lua test/test_zk.lua 127.0.0.1:2181 /

Quick start (OpenResty)
1. Put `lua/zookeeper.lua` and `lua/resty/zookeeper.lua` on your `lua_package_path`.
2. In Lua code running in OpenResty:
   local zk = require("resty.zookeeper")
   local client, err = zk.new{ connect_string = "127.0.0.1:2181" }
   client:connect()
   local exists = client:exists("/")

Development & Tests
- The `test/test_zk.lua` is a minimal smoke test. For real testing, add unit tests and integration tests against a local ZK server.
- Use tcpdump / wireshark to validate wire format if needed.

License: MIT
