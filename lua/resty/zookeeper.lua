-- OpenResty-friendly wrapper to load the zk_connection module
-- Usage: local zk = require("resty.zookeeper")
--        local client, err = zk.new(opts)
local zk = require("zookeeper")
return zk
