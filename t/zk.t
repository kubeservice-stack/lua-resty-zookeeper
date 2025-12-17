# vim:set ft= ts=4 sw=4 et:

BEGIN {
    $ENV{TEST_NGINX_BINARY} = '/opt/homebrew/Cellar/openresty-debug/1.27.1.2_1/nginx/sbin/nginx';
}

use Test::Nginx::Socket;
use Cwd qw(cwd);

repeat_each(2);
plan tests => repeat_each() * (3 * blocks());

my $pwd = cwd();
$ENV{TEST_NGINX_ZK_HOST} = "127.0.0.1:2181";
$ENV{TEST_NGINX_ZK_TEST_PATH} = "/test";

add_block_preprocessor(sub {
    my $block = shift;
    $block->set_value("http_config", <<_EOC_);
        lua_package_path "$pwd/?.lua;$pwd/lib/?.lua;$pwd/../lib/?.lua;;";
_EOC_
});

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
                ngx.print("error: ", err)
                return
            end

            local ok, err = client:connect()
            if not ok then
                ngx.print("error: ", err)
                return
            end

            local test_path = os.getenv("TEST_NGINX_ZK_TEST_PATH")
            -- 确保父节点存在
            local parent = "/"
            local ex, err = client:exists(parent)
            if ex == false then
                local created_parent, cerr = client:create(parent, "", "persistent", false)
                if not created_parent then
                    ngx.print("create parent error: ", cerr)
                    client:close()
                    return
                end
            elseif err then
                ngx.print("exists error: ", err)
                client:close()
                return
            end

            -- 创建测试节点
            local created_path, cerr = client:create(test_path, "", "persistent", true)
            if not created_path then
                ngx.print("create error: ", cerr)
            else
                ngx.print("create success: ", created_path)
            end

            client:close()
        }
    }
--- request
GET /test_create_node
--- response_body_like: create error: invalid path
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
                ngx.print("error: ", err)
                return
            end

            local ok, err = client:connect()
            if not ok then
                ngx.print("error: ", err)
                return
            end
            
            local test_path = os.getenv("TEST_NGINX_ZK_TEST_PATH")
            local data, err = client:get_data(test_path)
            if err then
                ngx.print("get_data error: ", err)
            else
                ngx.print("data:", data)
            end

            client:close()
        }
    }
--- request
GET /test_get_node
--- response_body: data:
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
                ngx.print("error: ", err)
                return
            end

            local ok, err = client:connect()
            if not ok then
                ngx.print("error: ", err)
                return
            end

            local test_path = os.getenv("TEST_NGINX_ZK_TEST_PATH")
            local exists, err = client:exists(test_path)
            if err then
                ngx.print("exists error: ", err)
            else
                ngx.print("node exists: ", tostring(exists))
            end

            client:close()
        }
    }
--- request
GET /test_exists
--- response_body: node exists: true
--- no_error_log
[error]