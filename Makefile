# amber-glycin: one glycin build for the whole amber suite, against amber-gtk4's GTK 4.16,
# packaged to /usr/lib/amber-glycin, where the apps' RUNPATH points. What every bundle does is in
# house/bundle.mk, a copy of house-rules' scripts/binding/bundle.mk: this repository is public,
# and its runner has no house-rules. project.toml names the release, its options, the siblings
# and the system packages; README.md says why the bundle exists and docs/DECISIONS.md the
# choices below.
include house/bundle.mk

.PHONY: gtk-pc cargo check-loaders smoke hooks

# The GTK side. libglycin-gtk4 compiles against amber-gtk4's staged 4.16 headers, not Mint's 4.14
# (GdkMemoryTextureBuilder); its RUNPATH names the amber-gtk4 bundle (patches/0001), so at run
# time it loads that GTK. A worktree of amber-gtk4 is named in local.mk (AMBER_GTK4_DIR = ...).
GTK_BUNDLE_DIR = /usr/lib/amber-gtk4
GTK_BUNDLE_MIN = 4.16.13
AMBER_GTK4_DIR ?= $(AMBER_ROOT)/amber-gtk4
GTK_STAGE ?= $(AMBER_GTK4_DIR)/build/stage
GTK_STAGE_PC = $(GTK_STAGE)$(GTK_BUNDLE_DIR)/pkgconfig
GTK_PC = build/gtk-pc
# Further pkg-config directories, each with a leading colon (for a dev package unpacked without
# root). Empty on a machine where `make init-packages` has run.
PC_EXTRA ?=

# amber-gtk4's .pc files name prefix=/usr, where the package installs; for the build they are
# copied with the prefix moved to its stage, so pkg-config hands the build the 4.16 headers and
# the staged libgtk-4.so to link. Only the prefix line changes.
gtk-pc:
	@[ -e '$(GTK_STAGE_PC)/gtk4.pc' ] || { echo '$@: $(GTK_STAGE_PC)/gtk4.pc not found: AMBER_ROOT names the folder holding amber-gtk4; build it first (make -C $(AMBER_GTK4_DIR) build; make init-siblings clones it)'; exit 2; }
	@rm -rf $(GTK_PC) && mkdir -p $(GTK_PC)
	@stage=$$(cd '$(GTK_STAGE)' && pwd); for f in $(GTK_STAGE_PC)/*.pc; do \
		sed "s|^prefix=/usr$$|prefix=$$stage/usr|" "$$f" > $(GTK_PC)/$${f##*/}; \
	done
	@v=$$(PKG_CONFIG_PATH=$(CURDIR)/$(GTK_PC) pkg-config --modversion gtk4); \
	[ "$$v" = "$(GTK_BUNDLE_MIN)" ] || { echo "$@: amber-gtk4's stage is GTK $$v, this build expects $(GTK_BUNDLE_MIN)"; exit 1; }

# rustup's cargo ahead of a version manager's shims: a mise shim answers "No version is set for
# shim: cargo" anywhere outside the folder whose mise.toml sets one. rustc and cargo are reported,
# never installed.
CARGO_PATH = $(HOME)/.cargo/bin
cargo:
	@[ -x '$(CARGO_PATH)/cargo' ] || { echo '$@: no cargo at $(CARGO_PATH): rustc and cargo 1.93 or later come from https://rustup.rs'; exit 2; }

# The tarball does not vendor its Rust crates: cargo fetches them from crates.io, pinned by its
# Cargo.lock, into the build tree (meson sets CARGO_HOME there), so the build needs the network.
# RUSTFLAGS maps the checkout out of the panic messages and file paths Rust compiles in, which
# strip does not touch, to /build, a path no check takes for the builder's.
#
# gtk4 comes from gtk-pc's copies through PKG_CONFIG_LIBDIR, ahead of the distro's folders: meson
# hands cargo a PKG_CONFIG_PATH of its own and drops the caller's, while it leaves
# PKG_CONFIG_LIBDIR alone (docs/DECISIONS.md, 2). check-pc resolves glycin-gtk4-2's gtk4 there
# too. The configure is order-only on gtk-pc, so writing the copies again never configures the
# build again.
$(OBJ)/build.ninja: | gtk-pc cargo
$(OBJ)/build.ninja build: export PATH := $(CARGO_PATH):$(PATH)
$(OBJ)/build.ninja build: export RUSTFLAGS = --remap-path-prefix=$(CURDIR)=/build
$(OBJ)/build.ninja build check deb smoke: export PKG_CONFIG_LIBDIR = $(CURDIR)/$(GTK_PC)$(PC_EXTRA):$(shell pkg-config --variable=pc_path pkg-config)

# The loaders, of compat level "2+", which libglycin-2 reads. check-no-cascade resolves each
# beside libglycin-2 (house/bundle.mk checks the shared objects alone), and check-loader-paths
# holds every loader config to a loader the bundle contains, at its install path.
LOADER_DIR = libexec/glycin-loaders/2+
check: check-loaders
check-loaders: build
	@scripts/check-no-cascade $(BUNDLE)/libglycin-2.so.0 $(BUNDLE)/$(LOADER_DIR)/*
	@scripts/check-loader-paths $(BUNDLE) $(INSTALL_DIR)

# Decode real images through the staged library and loaders, in glycin's sandbox; the script
# says what it needs, and how it runs without bubblewrap.
smoke: build ## decode a PNG, an SVG and a JPEG through the staged loaders (needs xvfb-run)
	@scripts/smoke $(BUNDLE) $(INSTALL_DIR) $(GTK_STAGE)

# A shipped hook does nothing until core.hooksPath points at it.
init-workstation: hooks
hooks: ## point core.hooksPath at .githooks
	@git config core.hooksPath .githooks && echo "hooks: core.hooksPath -> .githooks"
