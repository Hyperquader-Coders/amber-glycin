# patches

Downstream fixes applied to the glycin tarball before `meson setup`. `make glycin` applies
every `*.patch` here with `patch -p1 -N` and stops the build if one fails, so a patch that no
longer applies to a new glycin is a build error rather than a bundle that silently ships
upstream's behaviour.

Each patch must carry, in its own header, what it fixes and how that was measured. Delete a
patch once upstream glycin has fixed what it works around.

## 0001: libglycin-gtk4 RUNPATH

Upstream sets no RUNPATH on `libglycin-gtk4-2.so.0`, so it finds neither `libglycin-2.so.0`
beside it nor GTK 4.16 in the amber-gtk4 bundle. The patch adds `$ORIGIN` and
`/usr/lib/amber-gtk4` in the crate's `build.rs`, which is what amber-vte does through its
link arguments.
