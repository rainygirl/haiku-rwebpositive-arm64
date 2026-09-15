# WebPositive for Haiku arm64

A working web browser on Haiku running on 64-bit ARM. WebPositive with
HaikuWebKit 1.10.0, cross-compiled for arm64.

The official Haiku arm64 images do not ship a browser, so there is an
installer here that puts one on them.

Korean version: [`README.ko.md`](README.ko.md).
Porting notes, measurements and open problems: [`AGENTS.md`](AGENTS.md).

![Naver News](screenshots/news-naver-arm64.png)

## Installing on a Haiku arm64 image

Haiku's own arm64 nightlies (`haiku-master-hrevNNNNN-arm64-mmc.zip` from
[download.haiku-os.org](https://download.haiku-os.org/nightly-images/arm64/))
have no WebPositive, and `pkgman install webpositive` cannot get you one: the
arm64 HaikuPorts repository is empty, and the 36-package bootstrap set Haiku
builds arm64 from carries no WebKit. The browser and its libraries have to be
copied in by hand.

That is what `install-webpositive-arm64.sh` does. Copy this repository's
`packages/` directory and the script onto the Haiku machine -- on real
hardware, a USB stick; in QEMU, an ISO attached as a CD-ROM on an AHCI
controller, which is the one carrier that reliably boots and mounts here:

```sh
hdiutil makehybrid -iso -joliet -o wpkg.iso <folder with the script and packages/>
qemu-system-aarch64 ... \
  -device ahci,id=ahci \
  -drive file=wpkg.iso,if=none,id=d1,format=raw,media=cdrom,readonly=on \
  -device ide-cd,bus=ahci.0,drive=d1
```

Then, in a Terminal on the Haiku machine (`mountvolume -all` first, if the
volume is not on the desktop yet):

```sh
./install-webpositive-arm64.sh
```

It checks the architecture, skips anything already installed, refuses any
package that would silently fail to activate, copies the rest into
`/boot/system/packages/`, and then checks that the browser actually appeared.

Use `-n` to see what it would do without touching anything, and `-u` to
remove everything it installed.

![The installer finishing on a system that had no browser](screenshots/install-webpositive-arm64.png)

Then **Deskbar** -> **Applications** -> **WebPositive**. If the entry is not
there yet, see "If it does not work" below.

### What gets installed

94 MB in ten packages, all in `packages/`. A stock arm64 image carries eleven
packages -- haiku, haiku_loader, haiku_datatranslators, bash, coreutils,
freetype, gcc_syslibs, icu 67, ncurses6, noto, zlib -- so nearly everything
WebKit links against has to come along:

| Package | Size | Why |
|---|---|---|
| `haikuwebkit` | 37.0 MB | The engine, with the third-party libraries it bundles |
| `webpositive` | 0.5 MB | The browser |
| `icu74` | 14.3 MB | `libicuuc.so.74` and friends; the image has ICU 67 |
| `icu74_bootstrap` | 11.8 MB | ICU's locale data, where ICU looks for it. **Required** |
| `openssl3` | 2.3 MB | `libssl.so.3`, `libcrypto.so.3` |
| `sqlite3` | 0.5 MB | Cookies and web storage |
| `dav1d` | 0.4 MB | AV1 decoder |
| `libavif1.0` | 0.1 MB | AVIF images |
| `ca_root_certificates` | 0.1 MB | https; the image has none |
| `noto_sans_cjk_kr` | 26.7 MB | Korean, Japanese and Chinese glyphs. Optional |

`icu74_bootstrap` looks redundant next to `icu74`, and is not. The arm64
`icu74` is a bootstrap build: its `libicudata` is a 135 KB stub, and
`libicuuc` has its data directory compiled in as
`/packages/icu74_bootstrap-74.1-1/.self/data/icu/74.1` -- a path that only
exists if a package of exactly that name and version is installed. Without it
ICU has no locale data, `ucal_openTimeZoneIDEnumeration` returns null, WebKit
checks that only with an `ASSERT`, and JSC crashes constructing its VM before
any window appears.

### If it does not work

- **A "Package changes" or "Package problems" window opened.** package_daemon
  runs a dependency check on what was added and asks before doing anything
  beyond that. Nothing is active until it is answered. "Package problems"
  naming `haikuwebkit` and `lib:libavif` means the packages arrived one by one
  (the daemon acts half a second after the last file) -- the installer avoids
  that by renaming them all at once; if you copied by hand, cancel, and see
  the next point.
- **Nothing in the Applications menu.** At boot, packagefs loads every
  `.hpkg` in `/boot/system/packages/` -- unless
  `administrative/activated-packages` exists there, in which case it loads
  exactly the set that file names. Stock images have no such file, so a
  reboot activates everything. If the file exists (package_daemon writes it
  the first time it commits a change), remove it and reboot.
- **The browser exits immediately.** `icu74_bootstrap` did not activate.
  Check that `/packages/icu74_bootstrap-74.1-1/.self/data/icu/74.1/icudt74l.dat`
  exists.
- **https fails.** `/system/data/ssl/CARootCertificates.pem` is missing, so
  `ca_root_certificates` did not activate.
- **A package sits in `/boot/system/packages/` doing nothing.** It is
  zstd-compressed and this packagefs has no zstd -- arm64 has no `zstd_devel`
  to build it with, so it cannot read those, and says nothing about it. Every
  package shipped here is zlib, and the installer refuses anything that is
  not. Bytes 18-19 of an `.hpkg` are `0001` for zlib, `0002` for zstd.

These packages are built against r1~beta6 plus the patches in `AGENTS.md`;
the arm64 nightlies are master. The stock hrev59628 nightly does not boot in
QEMU on this Mac (under hvf the loader faults at kernel entry; under TCG the
upstream xhci bug stops it finding its own disk), so the installer was tested
on an arm64 Haiku system with the browser stack removed, not on a stock
nightly. The
ABI against master is the one thing here that has not been verified.

## Running a Haiku arm64 image in QEMU

You need an Apple Silicon Mac or another arm64 machine, and
`qemu-system-aarch64` with EDK2 firmware (`brew install qemu`). With the
image in `haiku-arm64.image`:

```sh
qemu-system-aarch64 \
  -M virt -cpu host -accel hvf -smp 4 -m 2048 \
  -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
  -device qemu-xhci,id=usb \
  -drive file=haiku-arm64.image,if=none,id=drv0,format=raw \
  -device usb-storage,bus=usb.0,drive=drv0 \
  -device usb-kbd,bus=usb.0 -device usb-tablet,bus=usb.0 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device ramfb -display cocoa
```

Give it about a minute for the desktop.

On real hardware, write the same file to a USB stick or SD card and boot
from it:

```sh
sudo dd if=haiku-arm64.image of=/dev/rdiskN bs=4m
```

## Starting the browser

**Deskbar** (top right) -> **Applications** -> **WebPositive**.

![Deskbar Applications menu](screenshots/merged-image-applications-menu.png)

## What works

| | |
|---|---|
| Real sites | Korean news portals, article pages, link navigation |
| https | TLS with the system certificate bundle |
| JavaScript | Baseline and DFG JIT |
| Text | Korean, Japanese and Chinese, with Noto Sans CJK |
| Images | PNG, JPEG, WebP, AVIF |
| CSS | Including `opacity`, which needed two app_server fixes |

Full page loads of a heavy news portal take 6 to 18 seconds in a 2 GB guest;
the first paint is under a second. WebGL, WebAssembly and the FTL JIT tier
are off.

## More screenshots

| | |
|---|---|
| ![Article page](screenshots/news-naver-article-arm64.png) | A Naver News article, reached by clicking a headline |
| ![CSS opacity](screenshots/css-opacity-layers.png) | `opacity` 1, 0.99, 0.8 and 0.5 |
| ![AVIF](screenshots/avif-decode-arm64.png) | An AVIF image decoding |
| ![JavaScript](screenshots/webpositive-javascript-works.png) | JavaScript |
| ![Korean text](screenshots/webpositive-korean-google-news.png) | Korean text rendering |
| ![haiku-os.org](screenshots/webpositive-haiku-os-org.png) | haiku-os.org over https |
| ![Installed by the script](screenshots/installed-webpositive-naver-arm64.png) | Naver News, in a WebPositive the installer had just put onto a system that had none |

This program was written with Claude. The app_server patch in this
repository is AI-assisted work; the Haiku project does not accept such
contributions, and it has not been and should not be submitted upstream.
