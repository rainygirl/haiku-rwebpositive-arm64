#!/bin/bash
#
# Cross-build dav1d and libavif for arm64 and package them the way HaikuPorts
# names them, so AVIF images decode in WebPositive and the tree's "libavif"
# build feature can be switched on for this architecture.
#
# Four packages come out:
#
#   dav1d-1.4.3-1-arm64.hpkg            lib/libdav1d.so.7
#   dav1d_devel-1.4.3-1-arm64.hpkg      headers and develop/lib symlinks
#   libavif1.0-1.1.1-1-arm64.hpkg       lib/libavif.so.16
#   libavif1.0_devel-1.1.1-1-arm64.hpkg headers and develop/lib symlinks
#
# Decode only. HaikuPorts' libavif also links rav1e (an encoder written in
# Rust) and sharpyuv; a browser needs neither, so AVIF_CODEC_DAV1D=SYSTEM is
# the only codec configured and the package requires just lib:libdav1d. The
# package names are HaikuPorts' own -- build/jam/BuildFeatures looks for
# libavif1.0_devel by that exact name -- while the versions are what is built
# here.
#
# The libraries themselves come from build-webkit-deps-arm64.sh, which
# installs them into the cross sysroot and leaves a staged copy per library in
# $WK/deps-stage. This script packages those staged copies.
#
# Runs in the arm64 builder container. The "package" tool has to be a host
# binary; jam builds one with "jam -q '<build>package'" in a configured
# generated directory.
#
set -eu

WK="${WK:-/root/wk}"
G="${RENKU_GEN:-/root/gen-a64tc}"
STAGE="${DEPS_STAGE:-$WK/deps-stage}"
OUTDIR="${1:-$WK/packages}"
DAV1D_VER=1.4.3
DAV1D_REV=1
AVIF_VER=1.1.1
AVIF_REV=1

# package_repo rejects a package whose vendor is not the repository's own
# ("package 'dav1d' has unexpected vendor 'VideoLAN'"), and that failure stops
# the image build, so every package here says "Haiku Project" regardless of who
# wrote the software. The copyrights field is where the authors are named.
PKG=$(find "$G/objects/linux" -name package -type f -perm -u+x 2>/dev/null | head -1)
[ -n "$PKG" ] || { echo "no package tool under $G/objects/linux -- build it with: cd $G && jam -q '<build>package'" >&2; exit 1; }

# Lay out one package directory from a staged install.
#  $1 staged tree root (the .../boot/system of a deps-stage entry)
#  $2 output directory
#  $3... the lib/ files to take (the runtime copy), or "devel" markers
mkpkgdir() { rm -rf "$1"; mkdir -p "$1"; }

mkdir -p "$OUTDIR"

# ---- dav1d ----------------------------------------------------------------
S=$STAGE/dav1d/boot/system
[ -f "$S/lib/libdav1d.so.7.0.0" ] || { echo "no staged dav1d at $S -- run build-webkit-deps-arm64.sh first" >&2; exit 1; }

B=$WK/pkg/dav1d
mkpkgdir "$B"
mkdir -p "$B/lib" "$B/documentation/packages/dav1d"
cp "$S/lib/libdav1d.so.7.0.0" "$B/lib/"
ln -s libdav1d.so.7.0.0 "$B/lib/libdav1d.so.7"
cat > "$B/.PackageInfo" <<EOF
name			dav1d
version			$DAV1D_VER-$DAV1D_REV
architecture		arm64
summary			"A new AV1 cross-platform decoder"
description		"dav1d is an AV1 decoder. libavif uses it to decode AVIF
images; it is cross-built here because the arm64 bootstrap repository has
neither."
packager		"The RENKU project"
vendor			"Haiku Project"
licenses {
	"BSD (2-clause)"
}
copyrights {
	"2018-2026, VideoLAN and dav1d authors"
}
provides {
	dav1d = $DAV1D_VER
	lib:libdav1d = 7.0.0 compat >= 7
}
requires {
	haiku
}
urls {
	"https://code.videolan.org/videolan/dav1d"
}
EOF

D=$WK/pkg/dav1d_devel
mkpkgdir "$D"
mkdir -p "$D/develop/headers" "$D/develop/lib/pkgconfig"
cp -r "$S/develop/headers/dav1d" "$D/develop/headers/"
ln -s ../../lib/libdav1d.so.7 "$D/develop/lib/libdav1d.so"
cp "$S/develop/lib/pkgconfig/dav1d.pc" "$D/develop/lib/pkgconfig/" 2>/dev/null || true
sed -i -e "s|^prefix=.*|prefix=/boot/system|" "$D/develop/lib/pkgconfig/dav1d.pc"
cat > "$D/.PackageInfo" <<EOF
name			dav1d_devel
version			$DAV1D_VER-$DAV1D_REV
architecture		arm64
summary			"A new AV1 cross-platform decoder (development files)"
description		"Headers and link library for dav1d."
packager		"The RENKU project"
vendor			"Haiku Project"
licenses {
	"BSD (2-clause)"
}
copyrights {
	"2018-2026, VideoLAN and dav1d authors"
}
provides {
	dav1d_devel = $DAV1D_VER
	devel:libdav1d = 7.0.0 compat >= 7
}
requires {
	dav1d == $DAV1D_VER-$DAV1D_REV base
}
urls {
	"https://code.videolan.org/videolan/dav1d"
}
EOF

# ---- libavif --------------------------------------------------------------
S=$STAGE/libavif/boot/system
[ -f "$S/lib/libavif.so.16.1.1" ] || { echo "no staged libavif at $S -- run build-webkit-deps-arm64.sh first" >&2; exit 1; }

A=$WK/pkg/libavif
mkpkgdir "$A"
mkdir -p "$A/lib"
cp "$S/lib/libavif.so.16.1.1" "$A/lib/"
ln -s libavif.so.16.1.1 "$A/lib/libavif.so.16"
cat > "$A/.PackageInfo" <<EOF
name			libavif1.0
version			$AVIF_VER-$AVIF_REV
architecture		arm64
summary			"Library for encoding and decoding .avif files"
description		"libavif reads and writes AVIF images. This build decodes
only: dav1d is the configured codec and no encoder is linked, so it does not
need rav1e. The package name is the one HaikuPorts uses, which is what
build/jam/BuildFeatures looks for."
packager		"The RENKU project"
vendor			"Haiku Project"
licenses {
	"BSD (2-clause)"
}
copyrights {
	"2019 Joe Drago and the libavif contributors"
}
provides {
	libavif1.0 = $AVIF_VER
	lib:libavif = 16.1.1 compat >= 16
}
requires {
	haiku
	lib:libdav1d >= 7.0.0
}
urls {
	"https://github.com/AOMediaCodec/libavif"
}
EOF

AD=$WK/pkg/libavif_devel
mkpkgdir "$AD"
mkdir -p "$AD/develop/headers/avif" "$AD/develop/lib/pkgconfig"
cp "$S/develop/headers/avif/"*.h "$AD/develop/headers/avif/"
ln -s ../../lib/libavif.so.16 "$AD/develop/lib/libavif.so"
cp "$S/develop/lib/pkgconfig/libavif.pc" "$AD/develop/lib/pkgconfig/" 2>/dev/null || true
sed -i -e "s|^prefix=.*|prefix=/boot/system|" "$AD/develop/lib/pkgconfig/libavif.pc"
cat > "$AD/.PackageInfo" <<EOF
name			libavif1.0_devel
version			$AVIF_VER-$AVIF_REV
architecture		arm64
summary			"Library for encoding and decoding .avif files (development files)"
description		"Headers and link library for libavif. The tree switches its
libavif build feature on when this package is available for the architecture."
packager		"The RENKU project"
vendor			"Haiku Project"
licenses {
	"BSD (2-clause)"
}
copyrights {
	"2019 Joe Drago and the libavif contributors"
}
provides {
	libavif1.0_devel = $AVIF_VER
	devel:libavif = 16.1.1 compat >= 16
}
requires {
	libavif1.0 == $AVIF_VER-$AVIF_REV base
}
urls {
	"https://github.com/AOMediaCodec/libavif"
}
EOF

for spec in \
	"$B:dav1d-$DAV1D_VER-$DAV1D_REV-arm64.hpkg" \
	"$D:dav1d_devel-$DAV1D_VER-$DAV1D_REV-arm64.hpkg" \
	"$A:libavif1.0-$AVIF_VER-$AVIF_REV-arm64.hpkg" \
	"$AD:libavif1.0_devel-$AVIF_VER-$AVIF_REV-arm64.hpkg" ; do
	dir=${spec%%:*}; name=${spec#*:}
	rm -f "$OUTDIR/$name"
	( cd "$dir" && "$PKG" create -q "$OUTDIR/$name" )
done

ls -la "$OUTDIR"/dav1d*.hpkg "$OUTDIR"/libavif*.hpkg
