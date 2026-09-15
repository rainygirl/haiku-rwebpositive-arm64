#!/bin/sh
#
# Install WebPositive on a Haiku arm64 system that does not have it.
#
# The official arm64 build ships no browser: WebPositive is compiled only when
# the tree's "webkit" build feature is on, and that feature exists only when
# the repository carries haikuwebkit_devel, which the arm64 bootstrap package
# set does not. The arm64 HaikuPorts repository is empty, so pkgman cannot
# fetch it either. The browser and everything under it have to be copied in.
#
# RUN THIS ON THE HAIKU MACHINE, not on the build host.
#
#   ./install-webpositive-arm64.sh [-n] [package-directory]
#
# The package directory defaults to ./packages next to this script.
#
set -eu

# A stock Haiku arm64 image has bash and coreutils and very little else: no
# sed, no grep, no find, no awk. Everything below sticks to that.
usage() {
	cat <<'EOF'
Install WebPositive on a Haiku arm64 system that does not have it.

  install-webpositive-arm64.sh [-n] [package-directory]

  -n   dry run: say what would be installed, install nothing
  -h   this text

The package directory defaults to ./packages next to this script.
EOF
}

PKGDIR=""
DRYRUN=0
TARGET=/boot/system/packages

while [ $# -gt 0 ]; do
	case "$1" in
	-n) DRYRUN=1 ;;
	-h|--help) usage; exit 0 ;;
	-*) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
	*)  PKGDIR="$1" ;;
	esac
	shift
done

HERE=$(cd "$(dirname "$0")" && pwd)
[ -n "$PKGDIR" ] || PKGDIR="$HERE/packages"

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# What goes in, and why. The official arm64 images carry eleven packages --
# haiku, haiku_loader, haiku_datatranslators, bash, coreutils, freetype,
# gcc_syslibs, icu 67, ncurses6, noto and zlib -- and nothing else. Everything
# WebKit needs beyond that list is here.
#
#   dav1d          AV1 decoder, for libavif
#   libavif1.0     libavif.so.16; haikuwebkit requires lib:libavif
#   openssl3       libssl.so.3 and libcrypto.so.3; https
#   sqlite3        libsqlite3.so.3.50.4; cookies and web storage
#   icu74          libicuuc.so.74, libicui18n.so.74, libicudata.so.74. The
#                  stock image has ICU 67, and the 67 sonames do not satisfy
#                  a .so.74 DT_NEEDED, so this goes in alongside it.
#   icu74_bootstrap  the 30 MB icudt74l.dat locale bundle, under exactly that
#                  package name. NOT redundant next to icu74: the arm64 icu74
#                  is a bootstrap build whose libicudata is a 135 KB stub, and
#                  libicuuc has its data directory compiled in as
#                  /packages/icu74_bootstrap-74.1-1/.self/data/icu/74.1 -- a
#                  path that exists only while a package of exactly that name
#                  and version is active. Without it ICU has no data,
#                  ucal_openTimeZoneIDEnumeration returns null, WebKit checks
#                  that only with ASSERT, and JSC crashes constructing its VM
#                  before any window appears. See AGENTS.md.
#   haikuwebkit    the engine, and the third-party libraries it bundles
#   webpositive    the browser itself
#
# Optional, but shipped here:
#   ca_root_certificates  the arm64 images do not include it, and without it
#                  every https site fails to verify
#   noto_sans_cjk_kr  Korean, Japanese and Chinese glyphs; without it CJK text
#                  is empty boxes. The largest file here
# ---------------------------------------------------------------------------
REQUIRED="dav1d libavif1.0 openssl3 sqlite3 icu74 icu74_bootstrap haikuwebkit webpositive"
OPTIONAL="ca_root_certificates noto_sans_cjk_kr"

# Find the one file in PKGDIR whose package name is $1. Package file names are
# <name>-<version>-<arch>.hpkg, and the version is not known here. Matching on
# "<name>-" is already exact: package names use underscores, never a hyphen,
# so "icu74-*" cannot match "icu74_bootstrap-...". Do not require the version
# to start with a digit -- webpositive's is "r1~beta6_hrev99000_dirty-1".
find_pkg() {
	for f in "$PKGDIR"/"$1"-*.hpkg; do
		[ -e "$f" ] && { printf '%s\n' "$f"; return 0; }
	done
	return 1
}

installed() {
	for f in "$TARGET"/"$1"-*.hpkg; do
		[ -e "$f" ] && return 0
	done
	return 1
}

# ---------------------------------------------------------------------------
step "Checking the system"

[ -d "$TARGET" ] || die "$TARGET is not there -- this is not a Haiku system"

ARCH=$(uname -m 2>/dev/null || echo unknown)
case "$ARCH" in
aarch64|arm64) say "architecture: $ARCH" ;;
*)  die "this installs arm64 packages and this system is $ARCH" ;;
esac

[ -d "$PKGDIR" ] || die "no package directory at $PKGDIR"

# ---------------------------------------------------------------------------
step "Looking for the packages in $PKGDIR"

PLAN=""
MISSING=""
for name in $REQUIRED; do
	if installed "$name"; then
		say "already installed  $name"
		continue
	fi
	if f=$(find_pkg "$name"); then
		say "found              $(basename "$f")"
		PLAN="$PLAN $f"
	else
		say "MISSING            $name"
		MISSING="$MISSING $name"
	fi
done

for name in $OPTIONAL; do
	if installed "$name"; then
		say "already installed  $name (optional)"
	elif f=$(find_pkg "$name"); then
		say "found              $(basename "$f") (optional)"
		PLAN="$PLAN $f"
	else
		say "not found          $name (optional)"
	fi
done

[ -z "$MISSING" ] || die "missing required packages:$MISSING"

# ---------------------------------------------------------------------------
# packagefs on a stock arm64 build has no zstd: the build feature that compiles
# it in comes from a zstd_devel package the arm64 repository does not carry. A
# zstd-compressed hpkg then sits in the packages directory, is never
# activated, and nothing says so. Bytes 18-19 of the file hold the
# compression: 0001 zlib, 0002 zstd.
step "Checking compression"

ZSTD=""
for f in $PLAN; do
	c=$(od -A n -t x1 -j 18 -N 2 "$f" 2>/dev/null | tr -d ' ')
	if [ "$c" = "0002" ]; then
		say "zstd  $(basename "$f")"
		ZSTD="$ZSTD $f"
	fi
done
if [ -n "$ZSTD" ]; then
	say ""
	say "Those are zstd-compressed and this system may not be able to read"
	say "them. Re-create them with zlib on the build host first:"
	say ""
	say "    mkdir t && cd t && package extract <file> && package create -i .PackageInfo ../<file>"
	say ""
	die "refusing to install a package that may never activate"
fi
say "all zlib"

if [ -z "$PLAN" ]; then
	step "Installing"
	say "nothing to do"
	exit 0
fi

if [ "$DRYRUN" = 1 ]; then
	step "Would install"
	for f in $PLAN; do say "  $(basename "$f")"; done
	exit 0
fi

# ---------------------------------------------------------------------------
# How the packages go in matters, because package_daemon watches this
# directory. Every *.hpkg that appears there is queued, and the daemon acts
# once nothing new has arrived for half a second. Copying haikuwebkit takes
# far longer than that, so copying the packages straight in one by one makes
# the daemon judge each on its own -- and it rejects haikuwebkit, whose
# libavif has not been activated yet ("nothing provides lib:libavif").
#
# So: copy everything under a name without the .hpkg extension, which the
# daemon and packagefs both ignore, and only then rename the files, which is
# instant, so the daemon sees the whole set at once. A half-written file is
# never visible under its real name, and nothing is overwritten in place.
step "Copying"

STAGED=""
cleanup() {
	for s in $STAGED; do rm -f "$s"; done
}
trap cleanup EXIT

for f in $PLAN; do
	part="$TARGET/$(basename "$f").part"
	STAGED="$STAGED $part"
	cp "$f" "$part" || die "copying $(basename "$f") failed -- is /boot full?"
	say "copied $(basename "$f")"
done

step "Activating"

for f in $PLAN; do
	b=$(basename "$f")
	mv "$TARGET/$b.part" "$TARGET/$b"
done
STAGED=""
trap - EXIT
say "all packages are in $TARGET"

# ---------------------------------------------------------------------------
step "Waiting for the system to activate them"

# If package_daemon wants anything beyond what was added, it asks in a window
# first, and nothing is active until that window is answered.
say "(if a \"Package changes\" or \"Package problems\" window opens, see"
say " README.md -- nothing becomes active until it is answered)"

ICUDATA=/packages/icu74_bootstrap-74.1-1/.self/data/icu/74.1/icudt74l.dat
i=0
while [ $i -lt 45 ]; do
	if [ -e /system/apps/WebPositive ] \
		&& [ -e /system/lib/libWebKitLegacy.so.1 ] \
		&& [ -e "$ICUDATA" ]; then
		break
	fi
	i=$((i + 1))
	sleep 2
done

ok=1
if [ -e /system/apps/WebPositive ]; then
	say "WebPositive is at /system/apps/WebPositive"
else
	say "WebPositive is not active"; ok=0
fi

# The versioned name: the unversioned libWebKitLegacy.so symlink is in
# haikuwebkit_devel, which is not installed and not needed.
if [ -e /system/lib/libWebKitLegacy.so.1 ]; then
	say "the engine is active"
else
	say "libWebKitLegacy.so.1 is not active"; ok=0
fi

# Not /system/data/icu/74.1: icu74 puts a copy there too, and ICU never looks
# at it. This is the directory compiled into libicuuc.
if [ -e "$ICUDATA" ]; then
	say "ICU locale data is where ICU looks for it"
else
	say "ICU locale data is not at $ICUDATA"; ok=0
fi

if [ -e /system/data/ssl/CARootCertificates.pem ]; then
	say "certificate bundle is active; https will verify"
else
	say "no certificate bundle: https sites will fail to verify"
fi

say ""
if [ "$ok" = 1 ]; then
	say "Done. Deskbar -> Applications -> WebPositive."
else
	say "The packages are in $TARGET but not all of them are active yet."
	say "Answer any package window that is open and check again."
	say ""
	say "If there is no window: a reboot activates everything in $TARGET, but"
	say "only when $TARGET/administrative/activated-packages is absent -- that"
	say "file, written by package_daemon, pins the set the system boots with."
	if [ -e "$TARGET/administrative/activated-packages" ]; then
		say "It exists here, so remove it, then reboot:"
		say "    rm $TARGET/administrative/activated-packages"
	else
		say "It is absent here, so a reboot is enough."
	fi
	exit 1
fi
