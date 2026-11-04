# Decisions: amber-glycin

What was weighed and settled, with the reasons that make each choice hold. An entry that stops
being true is rewritten, not appended to.

1. **Two packages from one build: amber-glycin and amber-glycin-dev.** The runtime package
   holds what a running app loads: the two libraries, the loaders and their configs. The -dev
   package holds the headers, the unversioned `.so` links and the `.pc` files, all under
   `/usr/lib/amber-glycin` (`include/`, `pkgconfig/`). The headers ship because the suite's
   Odin binding, odin-glycin, is generated from this bundle's 2.2 headers and builds and tests
   against the published archive, as amber-webkit-dev serves odin-webkit. The build
   installs the headers under `/usr/lib/amber-glycin/include` and its `.pc` files name that
   `includedir`, in the stage and the package alike, and `scripts/check-pc` checks `libdir`
   and `includedir` in both. The -dev package depends on amber-glycin at its
   own version, on amber-gtk4-dev, since `glycin-gtk4-2.pc` requires `gtk4 >= 4.16` and only
   amber-gtk4 has it, and on the -dev packages of glib, fontconfig and libseccomp, which both
   `.pc` files require.

2. **amber-gtk4's `.pc` copies go to the build through `PKG_CONFIG_LIBDIR`.** The `gtk-pc`
   target copies amber-gtk4's staged `.pc` files to `build/gtk-pc` with only the `prefix` line
   moved to the stage, as amber-vte does; `libdir` and `includedir` follow `${prefix}`, so
   they name the stage's `/usr/lib/amber-gtk4` and `/usr/lib/amber-gtk4/include`. amber-vte
   hands its copies to meson through `PKG_CONFIG_PATH`. That does not work here: glycin's meson
   build runs cargo for libglycin-gtk4 and sets cargo's `PKG_CONFIG_PATH` itself, to its own
   uninstalled libglycin, so a `PKG_CONFIG_PATH` from the Makefile never reaches cargo and the
   link finds Mint's GTK 4.14. `PKG_CONFIG_LIBDIR` is left alone, so the copies go there, ahead
   of the distro's own directories (`pkg-config --variable=pc_path pkg-config`), which are
   appended because `PKG_CONFIG_LIBDIR` replaces the default search path; `PC_EXTRA` adds a dev
   package unpacked without root. `scripts/check-pc` and `scripts/smoke` find gtk4 the same way.
