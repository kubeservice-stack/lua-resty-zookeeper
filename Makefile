OPENRESTY_PREFIX=/opt/homebrew/Cellar/openresty-debug/1.27.1.2_1

PREFIX ?=          /usr/local
LUA_INCLUDE_DIR ?= $(PREFIX)/include
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

.PHONY: all test install

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)$(LUA_LIB_DIR)/resty
	$(INSTALL) lib/resty/*.lua $(DESTDIR)$(LUA_LIB_DIR)/resty

test: all
	git clone https://github.com/openresty/test-nginx.git || exit 0
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH TEST_NGINX_NO_NGINX_MANAGER=1 prove -I../test-nginx/lib -r t

### lint:             Lint Lua source code
.PHONY: lint
lint:
	luacheck -q lib
	lj-releng lib/resty/*.lua
