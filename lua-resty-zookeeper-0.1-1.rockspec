package = "lua-resty-zookeeper"
version = "0.1-1"
source = {
  url = "none",
  tag = "none"
}
description = {
  summary = "Minimal ZooKeeper client for OpenResty / ngx_lua (example)",
  detailed = "A minimal synchronous ZooKeeper client illustrating handshake and basic ops.",
  homepage = "https://example.com",
  license = "MIT"
}
dependencies = {
  "lua >= 5.1",
  -- optional runtime deps: luasocket for plain-lua test
}
build = {
  type = "none",
}
