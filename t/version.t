# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Test::More;

repeat_each(2);

plan tests => repeat_each() * (3 * blocks());

run_tests();

__DATA__

=== TEST 1: basic
--- config
    location /test_get_node {
        content_by_lua_block {
            local zk = require "resty.zookeeper"
            ngx.say(zk._VERSION)
        }
--- request
GET /test_get_node
--- response_body_like chop
^\d+\.\d+$
--- no_error_log
[error]
