package = "lua-resty-zookeeper"
version = "master"
source = {
  url = "git+https://github.com/kubeservice-stack/lua-resty-zookeeper.git",
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
  "luasocket >= 3.0"
  -- optional runtime deps: luasocket for plain-lua test
}
build = {
  type = "builtin",
    modules = {
        ["resty.zookeeper"] = "lib/resty/zookeeper.lua",
    },
}
