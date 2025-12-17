# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Test::More;

repeat_each(2);

plan tests => repeat_each() * (3 * blocks());

run_tests();

__DATA__

=== TEST 1: set and get
--- global_config eval: $::GlobalConfig
--- server_config
        content_by_lua '
            local redis = require "resty.redis"
            local red = redis:new()

            red:set_timeout(1000) -- 1 sec

            local ok, err = red:connect("127.0.0.1", $TEST_NGINX_REDIS_PORT)
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ok, err = red:select(1)
            if not ok then
                ngx.say("failed to select: ", err)
                return
            end

            local res, err = red:set("dog", "an animal")
            if not res then
                ngx.say("failed to set dog: ", err)
                return
            end

            ngx.say("set dog: ", res)

            for i = 1, 2 do
                local res, err = red:get("dog")
                if err then
                    ngx.say("failed to get dog: ", err)
                    return
                end

                if not res then
                    ngx.say("dog not found.")
                    return
                end

                ngx.say("dog: ", res)
            end

            red:close()
        ';
--- response_body
set dog: OK
dog: an animal
dog: an animal
--- no_error_log
[error]



