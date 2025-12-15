.PHONY: test

test:
	lua test/test_zk.lua 127.0.0.1:2181 /
