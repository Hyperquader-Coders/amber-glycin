# amber-glycin: one glycin build for the whole amber suite.
#
# `make glycin` builds it, `make deb` packages it to /usr/lib/amber-glycin, and the apps
# point their RUNPATH there. See README.md for why it exists.
VERSION = 2.2.1
# The package revision, bumped when the packaging changes but the glycin version does not.
REVISION = 1
DEB = dist/amber-glycin_$(VERSION)-$(REVISION)_amd64.deb
BRANCH ?= main
REMOTE ?= origin
ROOT_COMMIT_MSG ?= Initial amber-glycin

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
# Loaders are versioned by compat level, not by release: libglycin 2.x reads "2+".
LOADER_DIR = libexec/glycin-loaders/2+
CONF_DIR = share/glycin-loaders/2+/conf.d
# The loaders to build. glycin-heif needs libheif >= 1.20 and glycin-jxl libjxl >= 0.11.1;
# Mint 22 (noble) ships 1.17 and 0.7, and bundling those is the cascade check-no-cascade
# refuses. See MoSCoW.md.
LOADERS = glycin-image-rs,glycin-svg

# libglycin-gtk4 needs GTK >= 4.16 headers (GdkMemoryTextureBuilder); Mint's are 4.14.
# It is built against the amber-gtk4 stage when a sibling checkout has one, otherwise
# against one built here from the same tarball (`make gtk-sdk`, ~20 min, cached in CI).
# Its RUNPATH names the amber-gtk4 bundle (patches/0001), so it resolves libgtk-4.so.1
# there and not to the distro's 4.14.
GTK_BUNDLE_DIR = /usr/lib/amber-gtk4
GTK_BUNDLE_MIN = 4.16.13
GTK_VERSION = 4.16.13
GTK_TARBALL = build/gtk-$(GTK_VERSION).tar.xz
GTK_TARBALL_SHA256 = ddf3d9e12b848139a945d191d5ca56b78d0647f53b55b8bca5f9902b61624498
GTK_TARBALL_URL = https://download.gnome.org/sources/gtk/$(basename $(GTK_VERSION))/gtk-$(GTK_VERSION).tar.xz
SIBLING_GTK_STAGE = ../amber-gtk4/build/gtk/stage
GTK_STAGE ?= $(if $(wildcard $(SIBLING_GTK_STAGE)$(GTK_BUNDLE_DIR)/libgtk-4.so.1),$(SIBLING_GTK_STAGE),build/gtk-sdk/stage)
GTK_PC = build/glycin/gtk4-pc
# Further pkg-config directories, each with a leading colon (for a dev package unpacked
# without root). Empty on a machine where `make deps` has run.
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

.PHONY: deps help glycin gtk-sdk build built stage check smoke ci deb deb-path deb-install deb-remove clean push force-push lint hooks check-no-agent-files

deps: hooks ## install the build dependencies and git hooks
	sudo apt install meson ninja-build pkg-config gcc-14 shellcheck dpkg-dev binutils lintian \
		libglib2.0-dev libseccomp-dev libfontconfig-dev librsvg2-dev libcairo2-dev \
		libgdk-pixbuf-2.0-dev libgtk-4-1 bubblewrap gettext xvfb
	# libgtk-4-1 is the stock GTK that check-no-cascade resolves libglycin-gtk4 against; at
	# run time the amber-gtk4 RUNPATH reaches the bundle's 4.16 first.
	@command -v $(CARGO_PATH)/cargo >/dev/null || echo "deps: rustc/cargo >= 1.93 is not installed; get it from https://rustup.rs"

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

$(GTK_TARBALL):
	@echo "fetching gtk $(GTK_VERSION)"
	mkdir -p build
	curl -fL -o $(GTK_TARBALL).part $(GTK_TARBALL_URL)
	@echo "$(GTK_TARBALL_SHA256)  $(GTK_TARBALL).part" | sha256sum -c - || { rm -f $(GTK_TARBALL).part; exit 1; }
	mv $(GTK_TARBALL).part $(GTK_TARBALL)

# The GTK headers and pkg-config files libglycin-gtk4 builds against, when no sibling
# amber-gtk4 checkout has built them. Only the stage is used; nothing of it is shipped.
# Same configuration as amber-gtk4's, so the ABI is the one the apps run on.
gtk-sdk: $(GTK_TARBALL) ## build GTK $(GTK_VERSION) into build/gtk-sdk/stage (~20 min; only without ../amber-gtk4)
	rm -rf build/gtk-sdk
	mkdir -p build/gtk-sdk
	tar xf $(GTK_TARBALL) -C build/gtk-sdk --strip-components=1
	meson setup build/gtk-sdk/_build build/gtk-sdk --prefix=/usr --libdir=lib/amber-gtk4 \
		-Dintrospection=disabled -Ddocumentation=false -Dman-pages=false \
		-Dbuild-demos=false -Dbuild-testsuite=false -Dbuild-examples=false -Dbuild-tests=false \
		-Dmedia-gstreamer=disabled -Dvulkan=disabled -Dprint-cups=disabled \
		-Dcolord=disabled -Dsysprof=disabled -Dcloudproviders=disabled
	DESTDIR=$$(pwd)/build/gtk-sdk/stage ninja -C build/gtk-sdk/_build install

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
	@test -e $(GTK_STAGE)$(GTK_BUNDLE_DIR)/pkgconfig/gtk4.pc || \
		{ echo "no GTK $(GTK_VERSION) stage at $(GTK_STAGE) — run 'make gtk-sdk', or build ../amber-gtk4"; exit 1; }
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

built: stage
	@test -e $(BUNDLE)/libglycin-2.so.0 || \
		{ echo "no bundle at $(BUNDLE) — run 'make glycin'"; exit 1; }

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
check: built ## the bundle pulls in no newer stack, carries no build paths, finds its loaders
	@scripts/check-no-cascade $(BUNDLE)/libglycin-2.so.0 $(BUNDLE)/libglycin-gtk4-2.so.0 \
		$(BUNDLE)/$(LOADER_DIR)/*
	@scripts/check-no-buildpaths $(BUNDLE)
	@scripts/check-loader-paths $(BUNDLE) $(INSTALL_DIR)

# Decode a real image through the staged library and loaders, in a sandbox. See the
# script for what it needs and for the no-bubblewrap fallback.
smoke: built ## decode a PNG and a JPEG through the staged loaders (needs xvfb-run)
	@scripts/smoke $(BUNDLE) $(INSTALL_DIR) $(GTK_STAGE)

ci: check lint deb ## everything a push must pass
	@echo "CI OK — bundle resolves against the stock stack, carries no build paths, finds its loaders, and packages"

# Binary .deb. Ships the two libraries, the loaders and their config: no headers, no
# pkg-config, no thumbnailer. This is a runtime bundle for the amber apps, not a -dev
# package. The staged headers under build/glycin/stage/usr/include and the .pc files are
# what odin-glycin generates its bindings from.
deb: check ## package the bundle into dist/
	rm -rf build/deb build/shlibwork
	install -d build/deb$(INSTALL_DIR)
	# Copy the real file and re-create the SONAME symlink, rather than copying a
	# dangling link into the package.
	for l in libglycin-2 libglycin-gtk4-2; do \
		real=$$(basename $$(readlink -f $(BUNDLE)/$$l.so.0)); \
		install -D -m644 $$(readlink -f $(BUNDLE)/$$l.so.0) build/deb$(INSTALL_DIR)/$$real; \
		test "$$real" = $$l.so.0 || ln -sf $$real build/deb$(INSTALL_DIR)/$$l.so.0; \
	done
	install -d build/deb$(INSTALL_DIR)/$(LOADER_DIR) build/deb$(INSTALL_DIR)/$(CONF_DIR)
	install -m755 $(BUNDLE)/$(LOADER_DIR)/* build/deb$(INSTALL_DIR)/$(LOADER_DIR)/
	install -m644 $(BUNDLE)/$(CONF_DIR)/*.conf build/deb$(INSTALL_DIR)/$(CONF_DIR)/
	# Assert on the packaged tree, not only on the staged one: `make deb` must not be a
	# way around `make check`.
	@scripts/check-no-buildpaths build/deb
	@scripts/check-loader-paths build/deb$(INSTALL_DIR) $(INSTALL_DIR)
	install -D -m644 packaging/lintian-overrides build/deb/usr/share/lintian/overrides/amber-glycin
	install -D -m644 packaging/debian/copyright build/deb/usr/share/doc/amber-glycin/copyright
	gzip -9n < packaging/debian/changelog > build/deb/usr/share/doc/amber-glycin/changelog.Debian.gz
	chmod 644 build/deb/usr/share/doc/amber-glycin/changelog.Debian.gz
	mkdir -p build/deb/DEBIAN
	# The bundle is deliberately NOT on the ldconfig path: only a binary whose RUNPATH
	# names $(INSTALL_DIR) picks it up, so installing this cannot change what any other
	# program on the system links against. No shlibs file either, for the same reason.
	find build/deb -type d -exec chmod 755 {} +
	cd build/deb && find . -type f -not -path './DEBIAN/*' -printf '%P\n' | sort | xargs md5sum > DEBIAN/md5sums
	mkdir -p build/shlibwork/debian
	printf 'Source: amber-glycin\n\nPackage: amber-glycin\nArchitecture: amd64\n' > build/shlibwork/debian/control
	# --ignore-missing-info: amber-gtk4 ships no shlibs file by design; control.in names
	# that dependency explicitly. shlibdeps resolves libgtk-4.so.1 to the archive's
	# libgtk-4-1, which is never loaded when the RUNPATH reaches amber-gtk4 first, so that
	# claim is dropped: the GTK dependency is amber-gtk4 and nothing else.
	cd build/shlibwork && dpkg-shlibdeps -O --ignore-missing-info \
		../deb$(INSTALL_DIR)/libglycin-2.so.0 ../deb$(INSTALL_DIR)/libglycin-gtk4-2.so.0 \
		$$(find ../deb$(INSTALL_DIR)/$(LOADER_DIR) -type f) > deps.txt
	sed -e 's/@VERSION@/$(VERSION)-$(REVISION)/' \
		-e 's/@GTK_MIN@/$(GTK_BUNDLE_MIN)/' \
		-e "s/@SIZE@/$$(du -sk build/deb --exclude=DEBIAN | cut -f1)/" \
		-e "s|@DEPS@|$$(sed -e 's/^shlibs:Depends=//' -e 's/libgtk-4-1 ([^)]*)\(, \)\?//' build/shlibwork/deps.txt)|" \
		packaging/control.in > build/deb/DEBIAN/control
	mkdir -p dist
	dpkg-deb --build --root-owner-group build/deb $(DEB)

# Where `make deb` puts the package: one absolute path, nothing else.
# amberlinux-apt ingests it through this.
deb-path: ## print the absolute path of the .deb
	@echo "$(CURDIR)/$(DEB)"

deb-install: deb ## build and install the .deb (sudo)
	# --allow-downgrades: once the package is published, the archive carries the same
	# version at a higher pin priority than a local file, so apt reads installing your own
	# build as a downgrade and refuses.
	sudo apt install --reinstall --allow-downgrades ./$(DEB)

deb-remove: ## remove the installed package (sudo)
	sudo apt remove amber-glycin

clean: ## remove the deb staging and dist/ (keeps the glycin build)
	rm -rf build/deb build/shlibwork build/smoke dist

push: ## git push to REMOTE BRANCH (origin main)
	git push "$(REMOTE)" "$(BRANCH)"

# Agent files are never published. Two ways they get in: already tracked, or
# present-and-unignored when `git add -A` below sweeps the whole tree. Both are
# checked here, because a squashed history shows no file being added: a stray
# path appears in the root commit like any other file.
check-no-agent-files: ## refuse agent files that are tracked or not ignored
	@bad=$$(git ls-files | grep -E '(^|/)(\.mcp\.json|\.claude/|\.claude-amber/)' || true); \
	if [ -n "$$bad" ]; then \
		echo "agent files are tracked and must not be published:"; \
		printf '  %s\n' $$bad; \
		echo "fix: git rm -r --cached <path>, then add it to .gitignore"; \
		exit 2; \
	fi
	@for p in .mcp.json .claude .claude-amber; do \
		if [ -e "$$p" ] && ! git check-ignore -q "$$p"; then \
			echo "$$p exists and is not gitignored — 'git add -A' would publish it"; \
			echo "fix: add $$p to .gitignore"; \
			exit 2; \
		fi; \
	done
	@echo "no agent files staged for publication"

force-push: check check-no-agent-files ## squash history into one signed root commit and force-push
	@test -z "$$(git status --porcelain)" || { \
		echo "Working tree is dirty. Commit, stash, or revert changes first."; \
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

lint: deb check-no-agent-files ## shellcheck, lintian, hooks installed, agent-file guard
	@if command -v shellcheck >/dev/null; then \
		git ls-files | while read -r f; do \
			case "$$f" in *.sh|*.bash) echo "$$f";; \
			*) head -1 "$$f" 2>/dev/null | grep -q '^#!.*sh' && echo "$$f";; esac; \
		done | xargs -r shellcheck --severity=warning && echo "shellcheck OK"; \
	else echo "shellcheck not installed — skipping (apt install shellcheck)"; fi
	@test "$$(git config --get core.hooksPath)" = .githooks || echo "lint: hooks not installed — run 'make hooks'"
	@if command -v lintian >/dev/null; then lintian --no-tag-display-limit -L '>=pedantic' $(DEB); \
	else echo "lintian not installed — skipping (apt install lintian)"; fi

# A shipped hook does nothing until core.hooksPath points at it.
hooks: ## point core.hooksPath at .githooks
	@git config core.hooksPath .githooks && echo "hooks: core.hooksPath -> .githooks"
