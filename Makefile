# Makefile for glaipnir (ai-agents-sandbox)
# Usage:
#   make                                generate build/ artefacts
#   make install                        install under /usr/local
#   make install PREFIX=$$(HOME)/.local user-local install (no sudo)
#   make install DESTDIR=/tmp/pkg       staged install for packaging
#   make install VERSION=1.2.3          override project version
#   make uninstall clean check dist

SHELL = /bin/sh

.DELETE_ON_ERROR:
.PHONY: all install uninstall clean check dist FORCE

PACKAGE = glaipnir

# Vesions managment
SCRIPT_VERSION := $(shell sed -n 's/^IMG_TAG="\(.*\)"/\1/p' $(PACKAGE).sh)
GIT_TAG        := $(shell git describe --tags --abbrev=0 2>/dev/null)
GIT_OFFSET     := $(shell git rev-list --count $(GIT_TAG)..HEAD 2>/dev/null)
GIT_SHA        := $(shell git rev-parse --short=7 HEAD 2>/dev/null)

ifeq ($(GIT_TAG),)
VERSION ?= $(SCRIPT_VERSION)
else ifeq ($(GIT_OFFSET),0)
VERSION ?= $(GIT_TAG)
else
VERSION ?= $(GIT_TAG).git$(GIT_OFFSET).$(GIT_SHA)
endif

# rpm forbids '-' in Version and sorts '~' below the release; OCI tags
# forbid '~'. Hence two spellings of the same version.
RPMVERSION = $(subst -,~,$(VERSION))
IMGVERSION = $(subst ~,-,$(VERSION))

# Installation dir
prefix      = /usr/local
exec_prefix = $(prefix)
bindir      = $(exec_prefix)/bin
datarootdir = $(prefix)/share
pkgdatadir  = $(datarootdir)/$(PACKAGE)

# Build variables
builddir = build

# Commands
INSTALL      	= install
INSTALL_PROGRAM = $(INSTALL)
INSTALL_DATA    = $(INSTALL) -m 644
MKDIR_P 		= mkdir -p
SHELLCHECK 		= shellcheck
TAR 			= tar

# Sourced or copied at run time, never exec'd, install 0644
DATA_TREES = image scripts launchd

SHELL_SOURCES = \
	$(PACKAGE).sh \
	printer.sh \
	scripts/macos-network-policy.sh \
	scripts/macos-sandbox.sh \
	scripts/macos-vpn-enforcer.sh \
	image/scripts/entrypoint.sh

all: $(builddir)/$(PACKAGE) $(builddir)/$(PACKAGE).sh

$(builddir):
	$(MKDIR_P) $@

# prefix and VERSION change what the generated files contain but touch no
# timestamp, so record them and re-stamp only on a real difference. This
# is what makes `make; make install prefix=/usr' bake the right path.
CONFIG_SIG = $(PACKAGE) $(VERSION) $(pkgdatadir)

$(builddir)/config.stamp: FORCE | $(builddir)
	@printf '%s\n' '$(CONFIG_SIG)' | cmp -s - $@ 2>/dev/null || \
	printf '%s\n' '$(CONFIG_SIG)' > $@

FORCE:

# The installed copy differs from the checkout in exactly three lines: the
# sandbox follows the caller's cwd and the config moves to the XDG dir.
conf_p = $${XDG_CONFIG_HOME:-$${HOME}/.config}/$(PACKAGE)/$(PACKAGE).conf

$(builddir)/$(PACKAGE).sh: $(PACKAGE).sh $(builddir)/config.stamp \
		| $(builddir)
	sed -e 's|^CONF_P=.*|CONF_P="$(conf_p)"|' \
		-e 's|^IMG_TAG=.*|IMG_TAG="$(IMGVERSION)"|' \
		$< > $@
	chmod 755 $@

# glaipnir.sh derives its data dir from $$0 without resolving symlinks, so
# bindir gets a wrapper that exec's the datadir copy, never a symlink.
$(builddir)/$(PACKAGE): $(builddir)/config.stamp | $(builddir)
	printf '#!/bin/sh\nexec %s/%s.sh "$$@"\n' \
		'$(pkgdatadir)' '$(PACKAGE)' > $@
	chmod 755 $@

install: all
	$(MKDIR_P) $(DESTDIR)$(bindir) $(DESTDIR)$(pkgdatadir)
	$(INSTALL_PROGRAM) $(builddir)/$(PACKAGE) \
		$(DESTDIR)$(bindir)/$(PACKAGE)
	$(INSTALL_PROGRAM) $(builddir)/$(PACKAGE).sh \
		$(DESTDIR)$(pkgdatadir)/$(PACKAGE).sh
	$(INSTALL_DATA) printer.sh $(DESTDIR)$(pkgdatadir)/printer.sh
	set -e; \
		find $(DATA_TREES) -type d | while IFS= read -r d; do \
			$(MKDIR_P) "$(DESTDIR)$(pkgdatadir)/$$d"; \
		done; \
		find $(DATA_TREES) -type f ! -name .gitkeep | \
		while IFS= read -r f; do \
			$(INSTALL_DATA) "$$f" "$(DESTDIR)$(pkgdatadir)/$$f"; \
		done

uninstall:
	rm -f $(DESTDIR)$(bindir)/$(PACKAGE)
	rm -f $(DESTDIR)$(pkgdatadir)/$(PACKAGE).sh
	rm -f $(DESTDIR)$(pkgdatadir)/printer.sh
	set -e; \
		find $(DATA_TREES) -type f ! -name .gitkeep | \
		while IFS= read -r f; do \
			rm -f "$(DESTDIR)$(pkgdatadir)/$$f"; \
		done; \
		find $(DATA_TREES) -depth -type d | while IFS= read -r d; do \
			rmdir "$(DESTDIR)$(pkgdatadir)/$$d" 2>/dev/null || :; \
		done
	-rmdir $(DESTDIR)$(pkgdatadir)

check: all
	$(SHELLCHECK) -x $(SHELL_SOURCES)
	sh -n $(builddir)/$(PACKAGE).sh
	sh -n $(builddir)/$(PACKAGE)

distdir    = $(PACKAGE)-$(RPMVERSION)
DIST_TREES = $(DATA_TREES) docs
DIST_FILES = AUTHORS CHANGELOG.md CONTRIBUTING.md LICENSE Makefile \
             README.md $(PACKAGE).sh printer.sh

dist: $(builddir)/$(distdir).tar.gz

# --transform prefixes every member with glaipnir-<version>/ so the tarball
# unpacks into a single directory, as rpm's Source0 requires. GNU tar only,
# which is a maintainer/OBS operation, never a user one.
$(builddir)/$(distdir).tar.gz: $(DIST_FILES) | $(builddir)
	$(TAR) czf $@ --transform 's,^,$(distdir)/,' \
		$(DIST_FILES) $(DIST_TREES)

clean:
	rm -rf $(builddir)
