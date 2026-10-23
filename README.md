# amber-glycin

One [glycin](https://gitlab.gnome.org/GNOME/glycin) 2.x build for the
[Amber Linux](https://amberlinux.org) applications, installed to `/usr/lib/amber-glycin` and
reached only through those applications' RUNPATH. glycin is GNOME's image-loading library: it
decodes each image in a separate, sandboxed loader process. The bundle holds `libglycin-2`,
`libglycin-gtk4-2` and the loaders; amber-glycin-dev carries their headers and pkg-config
files, which odin-glycin is generated from and builds against.

## Why it exists

Linux Mint 22 ships only `glycin-loaders` 1.0.1 (compat level "1+") and no `libglycin`.
libglycin 2.x reads loaders of compat level "2+", so the library and its loaders have to
arrive together, and from one build. The bindings
([odin-glycin](https://github.com/Hyperquader-Coders/odin-glycin)) test against this build.

## Install

From the suite's apt archive:

```sh
sudo curl -fsSL -o /usr/share/keyrings/amberlinux-archive-keyring.gpg \
  https://apt.amberlinux.org/amberlinux-archive-keyring.gpg

echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/amberlinux-archive-keyring.gpg] https://apt.amberlinux.org amber main' \
  | sudo tee /etc/apt/sources.list.d/amberlinux.list

sudo apt update
sudo apt install amber-glycin
```

Applications that need it declare `Depends: amber-glycin`, so installing one of them installs
this. It depends on [amber-gtk4](https://github.com/Hyperquader-Coders/amber-gtk4) and on
`bubblewrap`, which the sandbox runs through.

## What the packages contain

**amber-glycin**, the runtime:

| path | what |
|---|---|
| `/usr/lib/amber-glycin/libglycin-2.so.0` | the C API, stripped |
| `/usr/lib/amber-glycin/libglycin-gtk4-2.so.0` | `GdkTexture` from a frame; needs GTK 4.16 |
| `/usr/lib/amber-glycin/libexec/glycin-loaders/2+/` | the loaders: `glycin-image-rs` and `glycin-svg` |
| `/usr/lib/amber-glycin/share/glycin-loaders/2+/conf.d/` | one config per loader |
| `/usr/share/doc/amber-glycin/` | copyright and changelog |

**amber-glycin-dev**, for building against the bundle:

| path | what |
|---|---|
| `/usr/lib/amber-glycin/include/glycin-2/`, `include/glycin-gtk4-2/` | the headers |
| `/usr/lib/amber-glycin/pkgconfig/` | `glycin-2.pc`, `glycin-gtk4-2.pc` |
| `/usr/lib/amber-glycin/libglycin-2.so`, `libglycin-gtk4-2.so` | the links a linker looks for |

It depends on amber-glycin at the same version, on amber-gtk4-dev (`glycin-gtk4-2.pc`
requires `gtk4 >= 4.16`, which Mint's `libgtk-4-dev` is not), and on the -dev packages of
glib, fontconfig and libseccomp, which both `.pc` files require.

No thumbnailer. `/usr/lib/amber-glycin` is deliberately not on the `ldconfig` path or in
`XDG_DATA_DIRS`: only a binary whose RUNPATH names it picks the libraries up, so installing it
changes nothing for any other program on the system.

### Formats

`glycin-image-rs` covers the formats the Rust `image` stack decodes (JPEG, PNG, GIF, WebP,
TIFF, BMP, EXR and others, JPEG 2000 included) and `glycin-svg` renders SVG through the
distro's librsvg. HEIF, AVIF and JPEG XL are not here: their loaders need libheif 1.20 and
libjxl 0.11, and Mint ships neither. See [MoSCoW.md](MoSCoW.md).

## How an application uses it

glycin does not compile a loader directory into the library. It reads loader configs from
`<data-dir>/glycin-loaders/2+/conf.d/`, where the data directories come from
`XDG_DATA_DIRS`, or from the single directory in `GLYCIN_DATA_DIR`, and each config's `Exec=`
is the loader's absolute path. This package's configs say
`/usr/lib/amber-glycin/libexec/glycin-loaders/2+/<loader>`, because the build is configured
with `--prefix=/usr` and libexec and data directories under `lib/amber-glycin`.

So an application sets, before its first glycin call:

```sh
GLYCIN_DATA_DIR=/usr/lib/amber-glycin/share
```

and links with RUNPATH `/usr/lib/amber-glycin`. That makes the bundle's loaders the only ones
glycin looks at, which is the point of keeping the private path. Built against amber-glycin-dev
and amber-gtk4-dev:

```sh
export PKG_CONFIG_PATH=/usr/lib/amber-glycin/pkgconfig:/usr/lib/amber-gtk4/pkgconfig
cc app.c $(pkg-config --cflags --libs glycin-gtk4-2) \
  -Wl,--enable-new-dtags,-rpath,/usr/lib/amber-glycin:/usr/lib/amber-gtk4
```

## Three properties the build enforces

**It resolves against the distro's stock stack, and amber-gtk4, and nothing else.**
`scripts/check-no-cascade` passes only when every library the bundle and each loader need
resolves to a file some dpkg package owns.

**It carries no path from the machine that built it.** The loader configs record a prefix,
and Rust compiles source paths into panic messages; `strip` touches neither. The build is
configured with `--prefix=/usr` and staged through `DESTDIR`, and `RUSTFLAGS` remaps the build
directory away. `scripts/check-no-buildpaths` fails on the builder's home, the repo, or a
staging directory, in the staged tree and again in both packages. `scripts/check-pc`
asserts, in the packaged tree, that the `.pc` files' `libdir` and `includedir` are inside the
bundle.

**Every loader config names a loader the bundle contains.** `scripts/check-loader-paths`
fails when an `Exec=` is outside `/usr/lib/amber-glycin` or points at a file that is not
there.

## Building

```sh
make setup    # a fresh clone: the siblings, the system packages (sudo apt), the git hooks, a cargo check
make glycin   # fetch, verify, patch and build into build/glycin/stage
make smoke    # decode images through the staged loaders, in the sandbox
make lint     # shfmt, shellcheck, the agent-file guard and the source checks, with no build
make ci       # check, lint, the .debs and lintian on both; builds the bundle first when it is missing
make help     # every target
```

The tarball is checked against the sum GNOME publishes beside it. `make deb` writes
`dist/amber-glycin_<version>-<revision>_amd64.deb` and `dist/amber-glycin-dev_…`, again only
when the checked bundle or a packaging file changed; `make deb-path` prints where, one a line.
`make check-lintian` runs lintian over both.

The tarball does not vendor its Rust crates: cargo fetches them from crates.io, pinned by the
tarball's `Cargo.lock`, so the build needs the network and `rustc` 1.93 or later from
[rustup](https://rustup.rs). The crates land in the build tree, not in `~/.cargo`.

`libglycin-gtk4` is built against GTK 4.16 headers, which Mint does not have: amber-gtk4's
staged ones, from amber-gtk4 built beside this checkout. `siblings.txt` names the repositories
this one needs beside it, one a line with the root variable whose folder it goes in
(`AMBER_ROOT,https://github.com/Hyperquader-Coders/amber-gtk4`); `make setup`, or
`make init-siblings`, clones the missing ones there and leaves a checkout already there as it is.
`make -C "$AMBER_ROOT/amber-gtk4" build` builds its stage, once.

The staged headers in `build/glycin/stage/usr/include/glycin-2` and the `.pc` files beside
the libraries are what odin-glycin generates its bindings from in a checkout beside this one.

## Licence

MPL-2.0 OR LGPL-2.1-or-later, the licence of glycin; the packaging is under the same terms.
See [LICENSE](LICENSE) and [packaging/debian/copyright](packaging/debian/copyright).
