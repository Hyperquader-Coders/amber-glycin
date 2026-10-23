# amber-glycin: one glycin build for the whole amber suite.
#
# `make glycin` builds it, `make deb` packages it to /usr/lib/amber-glycin, and the apps
# point their RUNPATH there. See README.md for why it exists.
# check-packaging: upstream (glycin 2.2.1, rebuilt for the suite)
VERSION = 2.2.1
# The package revision, bumped when the packaging changes but the glycin version does not.
REVISION = 1
DEB = dist/amber-glycin_$(VERSION)-$(REVISION)_amd64.deb
DEV_DEB = dist/amber-glycin-dev_$(VERSION)-$(REVISION)_amd64.deb
DEBS = $(DEB) $(DEV_DEB)
BRANCH ?= main
REMOTE ?= origin
ROOT_COMMIT_MSG ?= Initial amber-glycin
# The siblings are found through the roots' variables, which mise sets on a development
# machine. AMBER_ROOT is the Amber tree, holding amber-gtk4 (siblings.txt). HOUSE_ROOT is the
# folder holding house-rules, whose check-narration and check-example-hosts `check-sources`
# runs where it is there; house-rules is private, so it is not in siblings.txt, and a clone
# outside the house and the public runner go without those two checks, saying so.
HOUSE_SCRIPTS = $(HOUSE_ROOT)/house-rules/scripts

# $(call require,VARIABLE,path,sibling,what to do): fail, naming the variable, when it is unset
# or the sibling's file is not there.
require = @test -n '$($(1))' || { \
	    echo '$@: $(1) is not set: it names the folder holding $(3) (mise sets it on a development machine)'; \
	    exit 2; }; \
	test -e '$(2)' || { \
	    echo '$@: $(2) not found ($(1)=$($(1))): $(4)'; \
	    exit 2; }

# targets: no test (upstream glycin, built with its tests off; check asserts the bundle's shipping properties and smoke decodes a real image through the staged loaders)

# Where the build lands, and where the deb installs it. Apps hardcode INSTALL_DIR in
# their release RUNPATH and set GLYCIN_DATA_DIR from it, so it is part of the contract
# with them.
#
# Configured with /usr and staged through DESTDIR: the loader config files record the
# loader's absolute path (prefix + libexecdir), so a build-tree prefix would ship the
# builder's home directory and a loader nothing could find. libdir, libexecdir and
# datadir all sit under lib/amber-glycin, so the bundle is one directory. `make check`
# asserts it.
INSTALL_DIR = /usr/lib/amber-glycin
CONF_PREFIX = /usr
CONF_LIBDIR = lib/amber-glycin
CONF_LIBEXECDIR = lib/amber-glycin/libexec
CONF_DATADIR = lib/amber-glycin/share
STAGE = build/glycin/stage
BUNDLE = $(STAGE)$(INSTALL_DIR)
# Written when make check passes against the staged bundle.
CHECKED = build/checked
# Loaders are versioned by compat level, not by release: libglycin 2.x reads "2+".
LOADER_DIR = libexec/glycin-loaders/2+
CONF_DIR = share/glycin-loaders/2+/conf.d
# The loaders to build. glycin-heif needs libheif >= 1.20 and glycin-jxl libjxl >= 0.11.1;
# Mint 22 (noble) ships 1.17 and 0.7, and bundling those is the cascade check-no-cascade
# refuses. See MoSCoW.md.
LOADERS = glycin-image-rs,glycin-svg

# libglycin-gtk4 needs GTK >= 4.16 headers (GdkMemoryTextureBuilder); Mint's are 4.14.
# It is built against amber-gtk4's stage, a sibling in siblings.txt. Its RUNPATH names the
# amber-gtk4 bundle (patches/0001), so it resolves libgtk-4.so.1 there and not to the
# distro's 4.14.
GTK_BUNDLE_DIR = /usr/lib/amber-gtk4
GTK_BUNDLE_MIN = 4.16.13
GTK_STAGE ?= $(AMBER_ROOT)/amber-gtk4/build/gtk/stage
GTK_PC = build/glycin/gtk4-pc
# Further pkg-config directories, each with a leading colon (for a dev package unpacked
# without root). Empty on a machine where `make init-packages` has run.
PC_EXTRA ?=

# The release tarball, verified against the sum GNOME publishes beside it
# (download.gnome.org/sources/glycin/<major.minor>/glycin-<version>.sha256sum). A fetched
# archive that does not match is deleted, so a wrong VERSION bump fails here and not
# after the build. Lives under build/, not /tmp: /tmp is shared and predictable.
TARBALL = build/glycin-$(VERSION).tar.xz
TARBALL_SHA256 = 937ae571d76c0de5e59db944d1194981360be37ee97875729781bc3816ddeafe
TARBALL_URL = https://download.gnome.org/sources/glycin/$(basename $(VERSION))/glycin-$(VERSION).tar.xz

# rustup's cargo ahead of a version manager's shims: a mise shim answers "No version is
# set for shim: cargo" anywhere outside the directory whose mise.toml sets one.
CARGO_PATH = $(HOME)/.cargo/bin

.PHONY: help setup init-packages init-modules init-workstation glycin build built stage check smoke ci deb deb-path deb-install deb-remove clean push force-push lint check-sources check-lintian hooks check-no-agent-files

# A target whose recipe fails or is interrupted is removed, so it is never taken as made.
.DELETE_ON_ERROR:

# The system packages a build and the checks need, in one list: a development machine and the
# CI install the same, the CI with `make init-packages APT_FLAGS=-y`. A package missing on the
# runner is added here, and a workflow names none.
# libgtk-4-1 is the stock GTK that check-no-cascade resolves libglycin-gtk4 against; at run
# time the amber-gtk4 RUNPATH reaches the bundle's 4.16 first. From sassc on, the list is
# what amber-gtk4's build of GTK needs, which CI runs as a sibling.
DEPS := meson ninja-build pkg-config gcc-14 shellcheck shfmt dpkg-dev binutils lintian \
	libglib2.0-dev libseccomp-dev libfontconfig-dev librsvg2-dev libcairo2-dev \
	libgdk-pixbuf-2.0-dev libgtk-4-1 bubblewrap gettext xvfb \
	sassc gperf libpango1.0-dev libgraphene-1.0-dev libepoxy-dev libxkbcommon-dev \
	libwayland-dev libx11-dev libxi-dev libxcursor-dev libxdamage-dev libxinerama-dev \
	libxrandr-dev libxext-dev libxfixes-dev libcairo-script-interpreter2 libjpeg-dev \
	libtiff-dev libharfbuzz-dev libfribidi-dev libdrm-dev
APT_FLAGS ?=

init-packages: ## install the system packages a build and the checks need (sudo apt)
	sudo apt-get install $(APT_FLAGS) --no-install-recommends $(DEPS)

# No language packages of its own: cargo fetches glycin's crates, pinned by its Cargo.lock, when
# `make glycin` builds. `ci` depends on it all the same, as in every repository.
init-modules: ## install the language packages from the lock: none here

# rustc and cargo are not apt's: they are reported, never installed.
init-workstation: hooks ## set up a desk: the git hooks, and a report when cargo is missing
	@command -v $(CARGO_PATH)/cargo >/dev/null || echo "init-workstation: rustc/cargo >= 1.93 is not installed; get it from https://rustup.rs"

help: ## this list
	@awk 'BEGIN {FS = ":.*## "} \
	    /^##@ / {printf "\n%s\n", substr($$0, 5)} \
	    /^[a-z][a-z0-9-]*:.*## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

$(TARBALL):
	@echo "fetching glycin $(VERSION)"
	mkdir -p build
	curl -fL -o $(TARBALL).part $(TARBALL_URL)
	@echo "$(TARBALL_SHA256)  $(TARBALL).part" | sha256sum -c - || { rm -f $(TARBALL).part; exit 1; }
	mv $(TARBALL).part $(TARBALL)

# Build glycin $(VERSION) for bundling. Mint ships glycin-loaders 1.0.1 (compat "1+") and
# no libglycin; libglycin 2.x reads loaders of compat "2+", so both are built here.
#
# The tarball does not vendor the Rust crates: cargo fetches them from crates.io, pinned
# by the tarball's Cargo.lock. meson points CARGO_HOME into the build tree itself, so
# nothing lands in ~/.cargo. RUSTFLAGS remaps the build directory out of the panic
# messages and file paths Rust compiles in, which `strip` does not touch; the remap
# target is /build, a path no check treats as the builder's.
#
# The libglycin-gtk4 link needs the GTK 4.16 headers, found through rewritten copies of
# the stage's .pc files whose prefix is the stage, not /usr (where 4.14 lives). They go
# through PKG_CONFIG_LIBDIR, not PKG_CONFIG_PATH: meson hands cargo its own
# PKG_CONFIG_PATH and drops the caller's, while LIBDIR it leaves alone. The distro's
# directories are appended to it, since LIBDIR replaces them.
glycin: $(TARBALL) ## fetch, patch and build glycin into build/glycin/stage (~5 min)
	$(call require,AMBER_ROOT,$(GTK_STAGE)$(GTK_BUNDLE_DIR)/pkgconfig/gtk4.pc,amber-gtk4,build amber-gtk4 first (make -C $(AMBER_ROOT)/amber-gtk4 build; make init-siblings clones it))
	@test -x $(CARGO_PATH)/cargo || { echo "no cargo at $(CARGO_PATH); install rustup"; exit 1; }
	rm -rf build/glycin
	mkdir -p build/glycin $(GTK_PC)
	tar xf $(TARBALL) -C build/glycin --strip-components=1
	# patches/ carries the downstream fixes. The extract above is unconditional, so a
	# patch that stops applying is a hard failure here rather than a bundle that quietly
	# ships upstream's behaviour: -N makes reapplication a no-op, not an error, and the
	# exit status is checked. See patches/README.md for what each one is for.
	@for p in patches/*.patch; do \
		test -e "$$p" || continue; \
		echo "applying $$p"; \
		patch -p1 -N -d build/glycin --no-backup-if-mismatch --input="$(CURDIR)/$$p" || exit 1; \
	done
	@stage=$$(cd $(GTK_STAGE) && pwd); \
	for f in $(GTK_STAGE)$(GTK_BUNDLE_DIR)/pkgconfig/*.pc; do \
		sed -e "s|^prefix=/usr|prefix=$$stage/usr|" \
			-e "s|^libdir=.*|libdir=$$stage$(GTK_BUNDLE_DIR)|" \
			-e "s|^includedir=.*|includedir=$$stage/usr/include|" \
			$$f > $(GTK_PC)/$$(basename $$f); \
	done
	PATH="$(CARGO_PATH):$$PATH" \
	PKG_CONFIG_LIBDIR="$(CURDIR)/$(GTK_PC)$(PC_EXTRA):$$(pkg-config --variable=pc_path pkg-config)" \
	RUSTFLAGS="--remap-path-prefix=$(CURDIR)=/build" \
	meson setup build/glycin/_build build/glycin --prefix=$(CONF_PREFIX) \
		--libdir=$(CONF_LIBDIR) --libexecdir=$(CONF_LIBEXECDIR) --datadir=$(CONF_DATADIR) \
		-Dglycin-loaders=true -Dloaders=$(LOADERS) -Dlibglycin=true -Dlibglycin-gtk4=true \
		-Dglycin-thumbnailer=false -Dintrospection=false -Dvapi=false -Dcapi_docs=false \
		-Dtests=false -Dpython_tests=false
	PATH="$(CARGO_PATH):$$PATH" \
	PKG_CONFIG_LIBDIR="$(CURDIR)/$(GTK_PC)$(PC_EXTRA):$$(pkg-config --variable=pc_path pkg-config)" \
	RUSTFLAGS="--remap-path-prefix=$(CURDIR)=/build" \
	DESTDIR=$$(pwd)/$(STAGE) ninja -C build/glycin/_build install
	# Strip in place, so `make check` sees exactly what `make deb` will ship.
	find $(BUNDLE) -type f \( -name '*.so*' -o -path '*/$(LOADER_DIR)/*' \) ! -name '*.conf' \
		-exec strip --strip-unneeded -R .comment {} +

# The standard name for the build; the one build there is.
build: glycin ## the same as glycin

# The checks need the bundle, so a checkout without one builds it here (`make glycin`, which
# needs amber-gtk4's GTK stage).
built: stage
	@test -e $(BUNDLE)/libglycin-2.so.0 || $(MAKE) glycin

# Re-stage whenever the meson build tree is newer than the staged bundle.
#
# `deb` packages $(BUNDLE), which only `ninja install` writes. Building the library on its
# own updates the build tree and leaves the stage untouched, so without this the deb ships
# the previous library without any error. ninja install is a no-op when the tree is
# already staged.
stage:
	@test -d build/glycin/_build || exit 0; \
	built=build/glycin/_build/cargo-target/release/libglycin.so; \
	staged=$(BUNDLE)/libglycin-2.so.0; \
	if [ -e "$$built" ] && { [ ! -e "$$staged" ] || [ "$$built" -nt "$$staged" ]; }; then \
		echo "re-staging: $$built is newer than the staged bundle"; \
		PATH="$(CARGO_PATH):$$PATH" DESTDIR=$$(pwd)/$(STAGE) ninja -C build/glycin/_build install >/dev/null || exit 1; \
		find $(BUNDLE) -type f \( -name '*.so*' -o -path '*/$(LOADER_DIR)/*' \) ! -name '*.conf' \
			-exec strip --strip-unneeded -R .comment {} + ; \
	fi

# Three properties make this bundle safe to ship, and the scripts below enforce them:
#   1. it resolves against the distro's stock stack and amber-gtk4, and pulls nothing else in
#   2. it carries no path from the machine that built it
#   3. every loader config names a loader the bundle contains, at its install path
# The checks pass once per staged bundle: CHECKED is newer than the libraries and the scripts
# only after all three pass, so check, deb and deb-install skip them until either changes.
check: built $(CHECKED) ## the bundle pulls in no newer stack, carries no build paths, finds its loaders

$(CHECKED): $(BUNDLE)/libglycin-2.so.0 $(BUNDLE)/libglycin-gtk4-2.so.0 scripts/check-no-cascade scripts/check-no-buildpaths scripts/check-loader-paths
	@scripts/check-no-cascade $(BUNDLE)/libglycin-2.so.0 $(BUNDLE)/libglycin-gtk4-2.so.0 \
		$(BUNDLE)/$(LOADER_DIR)/*
	@scripts/check-no-buildpaths $(BUNDLE)
	@scripts/check-loader-paths $(BUNDLE) $(INSTALL_DIR)
	@touch $@

# `built` makes the bundle before anything that names it is looked at; this rule is reached only
# when the stamp is asked for on its own.
$(BUNDLE)/libglycin-2.so.0 $(BUNDLE)/libglycin-gtk4-2.so.0:
	@echo "$@ is not there: make glycin first (~5 min)"; exit 2

# Decode a real image through the staged library and loaders, in a sandbox. See the
# script for what it needs and for the no-bubblewrap fallback.
smoke: built ## decode a PNG and a JPEG through the staged loaders (needs xvfb-run)
	@scripts/smoke $(BUNDLE) $(INSTALL_DIR) $(GTK_STAGE)

# What a push must pass. Unlike amber-webkit's, it builds: a glycin build is about 5 minutes,
# and CI keeps the GTK stage and the staged bundle in its cache, so the runner checks and
# packages the bundle and runs lintian over both packages.
ci: init-modules check lint check-lintian ## everything a push must pass: check, lint, and lintian on both packages
	@echo "CI OK: the bundle resolves against the stock stack, carries no build paths, finds its loaders, and packages; sources and packaging metadata check out"

# The checks that need no build: the shell scripts, the docs, the packaging metadata.
check-sources: ## shellcheck, the changelog and control templates, and house-rules' narration and example-host checks where it is there
	@if [ -n "$(HOUSE_ROOT)" ] && [ -x "$(HOUSE_SCRIPTS)/check-narration" ]; then \
		"$(HOUSE_SCRIPTS)/check-narration" && "$(HOUSE_SCRIPTS)/check-example-hosts" "$(CURDIR)" || exit 1; \
	else echo "house-rules not found (HOUSE_ROOT=$(HOUSE_ROOT)): check-narration and check-example-hosts skipped; house-rules is private"; fi
	@git ls-files | while read -r f; do \
		case "$$f" in *.sh|*.bash) echo "$$f";; \
		*) head -1 "$$f" 2>/dev/null | grep -q '^#!.*sh' && echo "$$f";; esac; \
	done | xargs -r shellcheck --severity=warning && echo "shellcheck OK"
	@dpkg-parsechangelog -l packaging/debian/changelog -S Version | grep -qx '$(VERSION)-$(REVISION)' || \
		{ echo "packaging/debian/changelog is not at $(VERSION)-$(REVISION)"; exit 1; }
	@test "$$(dpkg-parsechangelog -l packaging/debian/changelog -S Changes | grep -c '^  \*')" = 1 || \
		{ echo "packaging/debian/changelog has more than its one entry"; exit 1; }
	@for c in packaging/control.in packaging/control-dev.in; do \
		grep -q '^Package: ' $$c && grep -q '^Version: @VERSION@$$' $$c || { echo "$$c: no Package or Version line"; exit 1; }; \
	done
	@echo "check-sources OK"

# Two binary packages from the one build.
#   amber-glycin: the two libraries, the loaders and their config under /usr/lib/amber-glycin;
#     no thumbnailer.
#   amber-glycin-dev: the headers, the unversioned .so links and the .pc files, all under
#     /usr/lib/amber-glycin; odin-glycin is generated from these headers.
# The stage keeps meson's layout (headers in usr/include), which odin-glycin reads; the
# headers move under /usr/lib/amber-glycin in the -dev package, and its .pc files' includedir
# with them (scripts/check-pc checks them in the package, against the GTK stage's gtk4.pc).
DEBROOT = build/deb/amber-glycin
DEVROOT = build/deb/amber-glycin-dev
deb: built $(DEBS) ## package the bundle into dist/: amber-glycin and amber-glycin-dev

# Both packages come from one staging, so one rule makes them together, and only when the
# checked bundle or what goes into a package changed: an up-to-date pair is installed or
# ingested as it is. `built` runs first and re-stages a rebuilt library, so the bundle's time is
# the staged one. A recipe that fails or is interrupted deletes them (.DELETE_ON_ERROR), so a
# half-written package never counts as made.
$(DEBS) &: $(CHECKED) packaging/control.in packaging/control-dev.in packaging/debian/copyright packaging/debian/changelog $(wildcard packaging/lintian-overrides/*) scripts/check-no-buildpaths scripts/check-loader-paths scripts/check-pc Makefile
	rm -rf build/deb build/shlibwork
	install -d $(DEBROOT)$(INSTALL_DIR) $(DEVROOT)$(INSTALL_DIR)
	# Copy the real file and re-create the SONAME symlink, rather than copying a
	# dangling link into the package; the unversioned links belong to -dev.
	for l in libglycin-2 libglycin-gtk4-2; do \
		real=$$(basename $$(readlink -f $(BUNDLE)/$$l.so.0)); \
		install -D -m644 $$(readlink -f $(BUNDLE)/$$l.so.0) $(DEBROOT)$(INSTALL_DIR)/$$real; \
		test "$$real" = $$l.so.0 || ln -sf $$real $(DEBROOT)$(INSTALL_DIR)/$$l.so.0; \
	done
	install -d $(DEBROOT)$(INSTALL_DIR)/$(LOADER_DIR) $(DEBROOT)$(INSTALL_DIR)/$(CONF_DIR)
	install -m755 $(BUNDLE)/$(LOADER_DIR)/* $(DEBROOT)$(INSTALL_DIR)/$(LOADER_DIR)/
	install -m644 $(BUNDLE)/$(CONF_DIR)/*.conf $(DEBROOT)$(INSTALL_DIR)/$(CONF_DIR)/
	cp -a $(BUNDLE)/libglycin-2.so $(BUNDLE)/libglycin-gtk4-2.so $(BUNDLE)/pkgconfig $(DEVROOT)$(INSTALL_DIR)/
	cp -a $(STAGE)/usr/include $(DEVROOT)$(INSTALL_DIR)/
	sed -i 's|^includedir=.*|includedir=$${prefix}/lib/amber-glycin/include|' $(DEVROOT)$(INSTALL_DIR)/pkgconfig/*.pc
	# Assert on the packaged trees, both packages, the objects and the text beside them, not
	# only on the staged one: `make deb` must not be a way around `make check`.
	@scripts/check-no-buildpaths build/deb
	@scripts/check-loader-paths $(DEBROOT)$(INSTALL_DIR) $(INSTALL_DIR)
	@PKG_CONFIG_PATH=$(GTK_STAGE)$(GTK_BUNDLE_DIR)/pkgconfig scripts/check-pc $(DEVROOT)$(INSTALL_DIR)/pkgconfig $(INSTALL_DIR)
	@set -e; for p in amber-glycin amber-glycin-dev; do \
		root=build/deb/$$p; \
		install -D -m644 packaging/lintian-overrides/$$p $$root/usr/share/lintian/overrides/$$p; \
		install -D -m644 packaging/debian/copyright $$root/usr/share/doc/$$p/copyright; \
		gzip -9n < packaging/debian/changelog > $$root/usr/share/doc/$$p/changelog.Debian.gz; \
		chmod 644 $$root/usr/share/doc/$$p/changelog.Debian.gz; \
		find $$root -type d -exec chmod 755 {} +; \
		mkdir -p $$root/DEBIAN; \
		(cd $$root && find . -type f -not -path './DEBIAN/*' -printf '%P\n' | sort | xargs md5sum > DEBIAN/md5sums); \
	done
	# The bundle is deliberately NOT on the ldconfig path: only a binary whose RUNPATH
	# names $(INSTALL_DIR) picks it up, so installing this cannot change what any other
	# program on the system links against. No shlibs file either, for the same reason.
	mkdir -p build/shlibwork/debian
	printf 'Source: amber-glycin\n\nPackage: amber-glycin\nArchitecture: amd64\n' > build/shlibwork/debian/control
	# --ignore-missing-info: amber-gtk4 ships no shlibs file by design; control.in names
	# that dependency explicitly. shlibdeps resolves libgtk-4.so.1 to the archive's
	# libgtk-4-1, which is never loaded when the RUNPATH reaches amber-gtk4 first, so that
	# claim is dropped: the GTK dependency is amber-gtk4 and nothing else.
	cd build/shlibwork && dpkg-shlibdeps -O --ignore-missing-info \
		../../$(DEBROOT)$(INSTALL_DIR)/libglycin-2.so.0 ../../$(DEBROOT)$(INSTALL_DIR)/libglycin-gtk4-2.so.0 \
		$$(find ../../$(DEBROOT)$(INSTALL_DIR)/$(LOADER_DIR) -type f) > deps.txt
	sed -e 's/@VERSION@/$(VERSION)-$(REVISION)/' \
		-e 's/@GTK_MIN@/$(GTK_BUNDLE_MIN)/' \
		-e "s/@SIZE@/$$(du -sk $(DEBROOT) --exclude=DEBIAN | cut -f1)/" \
		-e "s|@DEPS@|$$(sed -e 's/^shlibs:Depends=//' -e 's/libgtk-4-1 ([^)]*)\(, \)\?//' build/shlibwork/deps.txt)|" \
		packaging/control.in > $(DEBROOT)/DEBIAN/control
	sed -e 's/@VERSION@/$(VERSION)-$(REVISION)/' \
		-e 's/@GTK_MIN@/$(GTK_BUNDLE_MIN)/' \
		-e "s/@SIZE@/$$(du -sk $(DEVROOT) --exclude=DEBIAN | cut -f1)/" \
		packaging/control-dev.in > $(DEVROOT)/DEBIAN/control
	mkdir -p dist
	dpkg-deb --build --root-owner-group $(DEBROOT) $(DEB)
	dpkg-deb --build --root-owner-group $(DEVROOT) $(DEV_DEB)

# Where `make deb` puts the packages: one absolute path a line, nothing else.
# amberlinux-apt ingests them through this.
deb-path: ## print the absolute paths of the two .debs, one a line
	@for d in $(DEBS); do echo "$(CURDIR)/$$d"; done

deb-install: deb ## install both .debs, packaging them first if the bundle changed (sudo)
	# --allow-downgrades: once the packages are published, the archive carries the same
	# version at a higher pin priority than a local file, so apt reads installing your own
	# build as a downgrade and refuses.
	sudo apt install --reinstall --allow-downgrades $(patsubst %,./%,$(DEBS))

deb-remove: ## remove the installed packages (sudo)
	sudo apt remove amber-glycin-dev amber-glycin

# build/ holds the glycin build as well: after a clean, `make glycin` compiles everything again.
clean: ## remove build/ and dist/, the glycin build included
	rm -rf build dist

push: ## git push to REMOTE BRANCH (origin main)
	git push "$(REMOTE)" "$(BRANCH)"

# Agent files are never published. Two ways they get in: already tracked, or
# present-and-unignored when `git add -A` below sweeps the whole tree. Both are
# checked here, because a squashed history shows no file being added: a stray
# path appears in the root commit like any other file.
check-no-agent-files: ## refuse agent files that are tracked or not ignored
	@bad=$$(git ls-files | grep -E '(^|/)(\.mcp\.json|\.claude/|\.claude-amber/|\.codex/|AGENTS\.md|CLAUDE\.md)' || true); \
	if [ -n "$$bad" ]; then \
		echo "agent files are tracked and must not be published:"; \
		printf '  %s\n' $$bad; \
		echo "fix: git rm -r --cached <path>, then add it to .gitignore"; \
		exit 2; \
	fi
	@for p in .mcp.json .claude .claude-amber .codex AGENTS.md CLAUDE.md; do \
		if [ -e "$$p" ] && ! git check-ignore -q "$$p"; then \
			echo "$$p exists and is not gitignored: 'git add -A' would publish it"; \
			echo "fix: add $$p to .gitignore"; \
			exit 2; \
		fi; \
	done
	@echo "no agent files staged for publication"

force-push: check check-no-agent-files ## squash history into one signed root commit and force-push
	@test -z "$$(git status --porcelain)" || { \
		echo "Working tree is dirty. Commit or revert changes first."; \
		exit 2; \
	}
	@set -e; \
	orig_branch="$$(git branch --show-current)"; \
	test -n "$$orig_branch" || { echo "force-push: detached HEAD, check out a branch first"; exit 1; }; \
	tmp_branch="root-squash-$$(date +%s)"; \
	step="starting"; ok=0; \
	trap 'if [ "$$ok" != 1 ]; then echo "force-push FAILED while: $$step. Local history is intact on $$orig_branch; $(REMOTE)/$(BRANCH) was not replaced." >&2; git checkout -f "$$orig_branch" >/dev/null 2>&1 || true; git branch -D "$$tmp_branch" >/dev/null 2>&1 || true; exit 1; fi' EXIT; \
	step="creating the orphan branch"; git checkout --orphan "$$tmp_branch"; \
	step="staging the tree"; git add -A; \
	step="signing the root commit"; git commit -S -m "$(ROOT_COMMIT_MSG)"; \
	step="pushing to $(REMOTE)/$(BRANCH) (refused or unreachable)"; git push --force "$(REMOTE)" "$$tmp_branch:$(BRANCH)"; \
	step="verifying $(REMOTE)/$(BRANCH) equals the new commit"; \
	remote_sha="$$(git ls-remote "$(REMOTE)" "refs/heads/$(BRANCH)" | cut -f1)"; \
	test -n "$$remote_sha" && test "$$remote_sha" = "$$(git rev-parse HEAD)"; \
	ok=1; \
	git branch -M "$$tmp_branch" "$(BRANCH)"; \
	git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null 2>&1 || { git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 && git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null; } || echo "warning: could not set upstream"; \
	echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."

# lint needs no build: the formatting, the agent-file guard and the source checks.
lint: check-fmt check-no-agent-files check-sources ## check-fmt, the agent-file guard and check-sources
	@test "$$(git config --get core.hooksPath)" = .githooks || echo "lint: hooks not installed, run 'make hooks'"

# lintian reads the packages, so it needs the build; ci runs it after check.
check-lintian: deb ## lintian on both packages (needs the build)
	@if command -v lintian >/dev/null; then \
		lintian --tag-display-limit 0 -L '>=pedantic' --fail-on error,warning $(DEBS) && echo "lintian OK"; \
	elif [ "$$GITHUB_ACTIONS" = true ]; then echo "lintian is not installed on this runner; make init-packages installs it"; exit 1; \
	else echo "lintian not installed: skipping (make init-packages installs it)"; fi

# A shipped hook does nothing until core.hooksPath points at it.
hooks: ## point core.hooksPath at .githooks
	@git config core.hooksPath .githooks && echo "hooks: core.hooksPath -> .githooks"

# Shell scripts are laid out by shfmt (sudo apt install shfmt), with tabs: every tracked file
# that is a shell script by its name or its first line.
# apt's shfmt, the one a CI runner has, before any other on the PATH: versions differ in layout.
SHFMT ?= $(firstword $(wildcard /usr/bin/shfmt) shfmt)
SHFMT_FLAGS = -i 0
SH_SOURCES = git ls-files -z --cached --others --exclude-standard -- . | xargs -0 -r $(SHFMT) -f
.PHONY: fmt check-fmt fmt-sh check-fmt-sh
fmt-sh: ## lay the shell scripts out in place
	@$(SH_SOURCES) | xargs -r -d '\n' $(SHFMT) $(SHFMT_FLAGS) -w

check-fmt-sh: ## fail when a shell script is not as make fmt-sh leaves it
	@if ! command -v $(SHFMT) >/dev/null; then \
		if [ "$$GITHUB_ACTIONS" = true ]; then echo "shfmt is not installed on this runner; make init-packages installs it"; exit 1; fi; \
		echo "shfmt not installed, skipping (sudo apt install shfmt)"; exit 0; \
	fi; \
	bad=$$($(SH_SOURCES) | xargs -r -d '\n' $(SHFMT) $(SHFMT_FLAGS) -l 2>&1) || true; \
	if [ -n "$$bad" ]; then echo "not formatted:"; echo "$$bad"; echo "fix: make fmt"; exit 1; fi; \
	echo "shfmt OK"

fmt: fmt-sh ## format the code in place: here, the shell scripts
check-fmt: check-fmt-sh ## fail on code that is not as make fmt leaves it

# --- siblings: house-rules scripts/binding/siblings.mk, the same in every repository with a siblings.txt ---
# siblings.txt names the repositories this one needs beside it, one a line, as
# `<ROOT_VARIABLE>,https://github.com/<owner>/<name>`; `#` starts a comment and blank lines are
# skipped. `make init-siblings` clones each one that is missing, from the URL as written, into
# `$(<ROOT_VARIABLE>)/<name>`, <name> being the URL's last part without `.git`. A checkout
# already there is left as it is: no pull, no reset, no checkout. Each variable is set in the
# environment or on the command line: mise at a desk, the workflow in CI, each to a folder above
# its workspace. It is part of `setup` (the rule below adds it, first, when this block stands
# above the `setup` rule) and never of `ci`.
SIBLING_ROOTS = $(foreach v,$(filter %_ROOT,$(.VARIABLES)),$(if $(filter environment% command%,$(origin $(v))),$(v)))
.PHONY: init-siblings
init-siblings: ## clone the repositories siblings.txt names that are missing from their roots; one already there is left as it is
	@sed 's/#.*//' siblings.txt | tr -d ' \t\r' | while IFS= read -r line; do \
		[ -n "$$line" ] || continue; \
		var=$${line%%,*}; url=$${line#*,}; \
		printf '%s\n' "$$var" | grep -Eqx '[A-Z_]+_ROOT' && [ "$$var" != "$$line" ] || \
			{ echo "init-siblings: '$$line' in siblings.txt does not start with a root variable and a comma (AMBER_ROOT,https://github.com/<owner>/<name>)" >&2; exit 2; }; \
		printf '%s\n' "$$url" | grep -Eqx 'https://github\.com/[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*' || \
			{ echo "init-siblings: '$$url' in siblings.txt is not https://github.com/<owner>/<name>" >&2; exit 2; }; \
		name=$${url##*/}; name=$${name%.git}; \
		case " $(SIBLING_ROOTS) " in *" $$var "*) ;; \
		*) echo "init-siblings: $$var is not set: it names the root $$name goes in (mise sets it at a desk; a workflow sets it to a folder above its workspace)" >&2; exit 2 ;; esac; \
		root=$$(printenv "$$var") || root=; root=$${root%/}; \
		[ -n "$$root" ] || { echo "init-siblings: $$var is empty" >&2; exit 2; }; \
		dest=$$root/$$name; \
		if [ -e "$$dest" ]; then echo "init-siblings: $$name is there, $$dest"; continue; fi; \
		echo "init-siblings: cloning $$name into $$dest"; \
		git clone -q "$$url" "$$dest" || exit 1; \
	done

setup: init-siblings

# The one command after a fresh clone, the same in every repository.
setup: init-packages init-modules init-workstation ## everything a fresh clone needs: siblings, packages (sudo apt), then hooks
