# amber-glycin

One [glycin](https://gitlab.gnome.org/GNOME/glycin) 2.x build for the
[Amber Linux](https://amberlinux.org) applications, installed to `/usr/lib/amber-glycin` and
reached only through those applications' RUNPATH. glycin is GNOME's image-loading library: it
decodes each image in a separate, sandboxed loader process. The bundle holds `libglycin-2`,
`libglycin-gtk4-2` and the loaders. It is a runtime bundle, not a development package.

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

## What the package contains

| path | what |
|---|---|
| `/usr/lib/amber-glycin/libglycin-2.so.0` | the C API, stripped |
| `/usr/lib/amber-glycin/libglycin-gtk4-2.so.0` | `GdkTexture` from a frame; needs GTK 4.16 |
| `/usr/lib/amber-glycin/libexec/glycin-loaders/2+/` | the loaders: `glycin-image-rs` and `glycin-svg` |
| `/usr/lib/amber-glycin/share/glycin-loaders/2+/conf.d/` | one config per loader |
| `/usr/share/doc/amber-glycin/` | copyright and changelog |

No headers, no pkg-config files, no thumbnailer. `/usr/lib/amber-glycin` is deliberately not
on the `ldconfig` path or in `XDG_DATA_DIRS`: only a binary whose RUNPATH names it picks the
libraries up, so installing it changes nothing for any other program on the system.

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
glycin looks at, which is the point of keeping the private path.

## Three properties the build enforces

**It resolves against the distro's stock stack, and amber-gtk4, and nothing else.**
`scripts/check-no-cascade` passes only when every library the bundle and each loader need
resolves to a file some dpkg package owns.

**It carries no path from the machine that built it.** The loader configs record a prefix,
and Rust compiles source paths into panic messages; `strip` touches neither. The build is
configured with `--prefix=/usr` and staged through `DESTDIR`, and `RUSTFLAGS` remaps the build
directory away. `scripts/check-no-buildpaths` fails on the builder's home, the repo, or a
staging directory, in the staged tree and again in the package.

**Every loader config names a loader the bundle contains.** `scripts/check-loader-paths`
fails when an `Exec=` is outside `/usr/lib/amber-glycin` or points at a file that is not
there.

## Building

```sh
make deps     # build dependencies and git hooks (sudo apt)
make glycin   # fetch, verify, patch and build into build/glycin/stage
make smoke    # decode images through the staged loaders, in the sandbox
make ci       # the checks, lint and the .deb
make help     # every target
```

The tarball is checked against the sum GNOME publishes beside it. `make deb` writes
`dist/amber-glycin_<version>-<revision>_amd64.deb`; `make deb-path` prints where.

The tarball does not vendor its Rust crates: cargo fetches them from crates.io, pinned by the
tarball's `Cargo.lock`, so the build needs the network and `rustc` 1.93 or later from
[rustup](https://rustup.rs). The crates land in the build tree, not in `~/.cargo`.

`libglycin-gtk4` is built against GTK 4.16 headers, which Mint does not have. If
`../amber-gtk4` has built its stage, that is used; otherwise `make gtk-sdk` builds one from
the same tarball into `build/gtk-sdk/stage`.

The staged headers in `build/glycin/stage/usr/include/glycin-2` and the `.pc` files beside
the libraries are what odin-glycin generates its bindings from.

## Licence

MPL-2.0 OR LGPL-2.1-or-later, the licence of glycin; the packaging is under the same terms.
See [LICENSE](LICENSE) and [packaging/debian/copyright](packaging/debian/copyright).
