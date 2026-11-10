PREFIX ?= /usr/local

siri-say: main.swift
	swiftc -O -o $@ main.swift

install: siri-say
	install -m 755 siri-say $(PREFIX)/bin/siri-say

clean:
	rm -f siri-say

.PHONY: install clean
