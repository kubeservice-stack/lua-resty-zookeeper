# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Test::More;

repeat_each(2);

plan tests => repeat_each() * (3 * blocks());

run_tests();

__DATA__

=== TEST 1: basic
--- global_config eval: $::GlobalConfig
--- server_config
        content_by_lua '
            local zk = require "resty.zookeeper"
            ngx.say(zk._VERSION)
        ';
--- response_body_like chop
^\d+\.\d+$
--- no_error_log
[error]
