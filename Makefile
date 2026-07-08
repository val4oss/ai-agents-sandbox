# Makefile for ai-agents-sandbox
# Usage:
#   make build                          stage install tree into build/
#   sudo make install                   install to /usr/local (default)
#   make install PREFIX=$(HOME)/.local  user-local install (no sudo)
#   sudo make install PREFIX=/usr       system install
#   make install DESTDIR=/tmp/pkg-root  staged install for packaging
#   sudo make uninstall                 remove installed files
#   make clean                          remove build/
#   make check                          shellcheck all scripts

PRJ_NAME = ai-agents-sandbox

PREFIX  ?= /usr/local
DESTDIR ?=
BINDIR   = $(PREFIX)/bin
SHAREDIR = $(PREFIX)/share
DATADIR  = $(SHAREDIR)/$(PRJ_NAME)

BUILD_D   = build
BUILD_DAT = $(BUILD_D)/share/$(PRJ_NAME)

SHELL_SOURCES = \
	ai-agents-sandbox.sh \
	printer.sh \
	scripts/macos-network-policy.sh \
	scripts/macos-sandbox.sh \
	scripts/macos-vpn-enforcer.sh \
	image/scripts/entrypoint.sh

.PHONY: all build install uninstall clean check

all: build

build:
	mkdir -p "$(BUILD_DAT)"
	cp ai-agents-sandbox.sh printer.sh "$(BUILD_DAT)/"
	cp -r image scripts launchd "$(BUILD_DAT)/"
	sed -i \
		-e 's|^SANDBOX_D_DEFAULT=.*|SANDBOX_D_DEFAULT="$${PWD}"|' \
		-e 's|^CONF_P=.*|CONF_P="$${XDG_CONFIG_HOME:-$${HOME}/.config}/$(PRJ_NAME)/$(PRJ_NAME).conf"|' \
		"$(BUILD_DAT)/ai-agents-sandbox.sh"
	chmod +x "$(BUILD_DAT)/ai-agents-sandbox.sh"

install: build
	install -d "$(DESTDIR)$(BINDIR)"
	install -d "$(DESTDIR)$(DATADIR)"
	cp -r "$(BUILD_DAT)/." "$(DESTDIR)$(DATADIR)/"
	chmod +x "$(DESTDIR)$(DATADIR)/ai-agents-sandbox.sh"
	printf '#!/bin/sh\nexec %s/ai-agents-sandbox.sh "$$@"\n' \
		"$(DATADIR)" > "$(DESTDIR)$(BINDIR)/$(PRJ_NAME)"
	chmod +x "$(DESTDIR)$(BINDIR)/$(PRJ_NAME)"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/$(PRJ_NAME)"
	rm -rf "$(DESTDIR)$(DATADIR)"

clean:
	rm -rf "$(BUILD_D)"

check:
	shellcheck -x $(SHELL_SOURCES)
