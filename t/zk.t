# vim:set ft= ts=4 sw=4 et:


BEGIN {
    $ENV{TEST_NGINX_BINARY} = '/opt/homebrew/Cellar/openresty/1.27.1.2_1/nginx/sbin/nginx';
}

use Test::Nginx::Socket;
use Cwd qw(cwd);

repeat_each(2);
plan tests => repeat_each() * (3 * blocks());  # 确保只声明一次测试计划

my $pwd = cwd();
$ENV{TEST_NGINX_ZK_HOST} = "127.0.0.1:2181";
$ENV{TEST_NGINX_ZK_TEST_PATH} = "/test/nginx";  # 统一测试路径

no_shuffle();
run_tests();

__DATA__

=== TEST 1: Create ZK node (success)
--- config
    location /test_create_node {
        content_by_lua_block {
            local zk = require "resty.zookeeper"
            local client, err = zk.new{
                timeout = 5000,
                connect_string = os.getenv("TEST_NGINX_ZK_HOST"),
                session_timeout = 30000,
                debug = true,
            }
            if not client then
                ngx.say("error: ", err)
                return
            end

            local ok, err = client:connect()
            if not ok then
                ngx.say("error: ", err)
                return
            end

            local test_path = os.getenv("TEST_NGINX_ZK_TEST_PATH")
            -- 确保父节点存在
            local parent = "/"
            local ex, err = client:exists(parent)
            if ex == false then
                local created_parent, cerr = client:create(parent, "", "persistent", false)
                if not created_parent then
                    ngx.say("create parent error: ", cerr)
                    client:close()
                    return
                end
            elseif err then
                ngx.say("exists error: ", err)
                client:close()
                return
            end

            -- 创建测试节点
            local created_path, cerr = client:create(test_path, "nginx_zk_data", "persistent", false)
            if not created_path then
                ngx.say("create error: ", cerr)
            else
                ngx.say("create success: ", created_path)
            end

            client:close()
        }
    }
--- request
GET /test_create_node
--- response_body_like: create success: /test/nginx
--- no_error_log
[error]

=== TEST 2: Get ZK node data (success)
--- config
    location /test_get_node {
        content_by_lua_block {
            local zk = require "resty.zookeeper"
            local client, err = zk.new{
                timeout = 5000,
                connect_string = os.getenv("TEST_NGINX_ZK_HOST"),
                session_timeout = 30000,
                debug = true,
            }
            if not client then
                ngx.say("error: ", err)
                return
            end

            local ok, err = client:connect()
            if not ok then
                ngx.say("error: ", err)
                return
            end
            
            local test_path = os.getenv("TEST_NGINX_ZK_TEST_PATH")
            local data, err = client:get_data(test_path)
            if err then
                ngx.say("get_data error: ", err)
            else
                ngx.say("data: ", data)
            end

            client:close()
        }
    }
--- request
GET /test_get_node
--- response_body: data: nginx_zk_data
--- no_error_log
[error]

=== TEST 3: Check ZK node exists
--- config
    location /test_exists {
        content_by_lua_block {
            local zk = require "resty.zookeeper"
            local client, err = zk.new{
                timeout = 5000,
                connect_string = os.getenv("TEST_NGINX_ZK_HOST"),
                session_timeout = 30000,
                debug = true,
            }
            if not client then
                ngx.say("error: ", err)
                return
            end

            local ok, err = client:connect()
            if not ok then
                ngx.say("error: ", err)
                return
            end

            local test_path = os.getenv("TEST_NGINX_ZK_TEST_PATH")
            local exists, err = client:exists(test_path)
            if err then
                ngx.say("exists error: ", err)
            else
                ngx.say("node exists: ", tostring(exists))
            end

            client:close()
        }
    }
--- request
GET /test_exists
--- response_body: node exists: true
--- no_error_log
[error]
