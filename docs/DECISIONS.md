# Decisions: amber-glycin

What was weighed and settled, with the reasons that make each choice hold. An entry that stops
being true is rewritten, not appended to.

1. **Two packages from one build: amber-glycin and amber-glycin-dev.** The runtime package
   holds what a running app loads: the two libraries, the loaders and their configs. The -dev
   package holds the headers, the unversioned `.so` links and the `.pc` files, all under
   `/usr/lib/amber-glycin` (`include/`, `pkgconfig/`). The headers ship because the suite's
   Odin binding, odin-glycin, is generated from this bundle's 2.2 headers and builds and tests
   against the published archive, as amber-webkit-dev serves odin-webkit. The stage keeps
   meson's layout, the headers in `usr/include`, which odin-glycin's generator reads in a
   checkout beside this one; `make deb` copies them under `/usr/lib/amber-glycin/include` and
   rewrites the packaged `.pc` files' `includedir` to match, and `scripts/check-pc` checks
   `libdir` and `includedir` in the package. The -dev package depends on amber-glycin at its
   own version, on amber-gtk4-dev, since `glycin-gtk4-2.pc` requires `gtk4 >= 4.16` and only
   amber-gtk4 has it, and on the -dev packages of glib, fontconfig and libseccomp, which both
   `.pc` files require.

2. **The GTK `.pc` rewrite lives inside the `glycin` target and goes through
   `PKG_CONFIG_LIBDIR`.** amber-webkit makes its copies of amber-gtk4's `.pc` files in a
   target of their own, `gtk-pc`, moves only the `prefix` line, and hands them to cmake through
   `PKG_CONFIG_PATH`. That does not work here, for two reasons. glycin's meson build runs cargo
   for libglycin-gtk4 and sets cargo's `PKG_CONFIG_PATH` itself, to its own uninstalled
   libglycin, so a `PKG_CONFIG_PATH` from the Makefile never reaches cargo and the link finds
   Mint's GTK 4.14. `PKG_CONFIG_LIBDIR` is left alone, so the copies go there, ahead of the
   distro's own directories (`pkg-config --variable=pc_path pkg-config`), which are appended
   because `PKG_CONFIG_LIBDIR` replaces the default search path; `PC_EXTRA` adds a dev package
   unpacked without root. And the copies sit in `build/glycin/gtk4-pc`, which the `glycin`
   recipe removes with the rest of `build/glycin` before it extracts the tarball, so they are
   written in the same recipe, after that removal: a separate target made first would be
   deleted before meson reads it. The rewrite sets `libdir` and `includedir` to the stage as
   well as `prefix`, so the copies name the stage whether or not amber-gtk4 writes those lines
   from `${prefix}`; with its present files, where both follow `${prefix}`, the result is the
   same as a `prefix`-only rewrite.
