package = "lua-resty-zookeeper"
version = "master"
source = {
  url = "git://github.com/kubeservice-stack/lua-resty-zookeeper",
  tag = "master"
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
