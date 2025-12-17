package = "lua-resty-zookeeper"
version = "0.2-3"
source = {
  url = "git://github.com/kubeservice-stack/lua-resty-zookeeper",
  tag = "v0.2.3"
}
description = {
  summary = "Minimal ZooKeeper client for OpenResty / ngx_lua (example)",
  detailed = "A minimal synchronous ZooKeeper client illustrating handshake and basic ops.",
  homepage = "https://stack.kubeservice.cn/",
  license = "BSD"
}
dependencies = {
  "lua >= 5.1",
  "luasocket = 3.1.0-1",
  -- optional runtime deps: luasocket for plain-lua test
}
build = {
  type = "none",
}
