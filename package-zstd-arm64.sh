#!/bin/bash
#
# Cross-build zstd 1.5.6 for arm64 and package it the way HaikuPorts does, so
# the tree's "zstd" build feature can be switched on for this architecture.
#
# Why it is needed: build/jam/BuildFeatures enables the feature from
# zstd_devel, and the arm64 bootstrap repository has no zstd at all. With the
# feature off, packagefs is compiled without ZstdCompressionAlgorithm and the
# kernel and boot loader without libzstd's decoder, so a zstd-compressed hpkg
# installs into /boot/system/packages, is never activated, and reports nothing.
# HaikuPorts' ca_root_certificates is one of those, which is why https worked
# everywhere except in applications that read the bundle through the system.
#
# Three packages come out, matching the names and versions the x86 repository
# uses so the repository entry is the ordinary one:
#
#   zstd-1.5.6-2-arm64.hpkg          lib/libzstd.so.1
#   zstd_devel-1.5.6-2-arm64.hpkg    headers and develop/lib symlinks
#   zstd_source-1.5.6-2-source.hpkg  the sources the kernel decoder is built from
#
# The source package is architecture "source" and byte-identical to the one
# HaikuPorts publishes, so it is copied rather than rebuilt: the kernel's
# src/system/kernel/lib/zstd/Jamfile compiles the .c files out of
# develop/sources/zstd-1.5.6-2/sources, and any tree laid out that way will do.
# Point ZSTD_SOURCE_HPKG at it.
#
# Runs in the arm64 builder container. The "package" tool has to be a host
# binary for the machine this runs on -- jam builds one with
# "jam -q '<build>package'" in a configured generated directory.
#
set -eu

WK="${WK:-/root/zstd-build}"
G="${RENKU_GEN:-/root/gen-a64tc}"
CROSS="${CROSS_TOOLS:-$G/cross-tools-arm64}"
OUTDIR="${1:-$WK/packages}"
VER=1.5.6
REV=2
SRC=$WK/zstd-$VER
ZSTD_SOURCE_HPKG="${ZSTD_SOURCE_HPKG:-$WK/zstd_source-$VER-$REV-source.hpkg}"

PKG=$(find "$G/objects/linux" -name package -type f -perm -u+x 2>/dev/null | head -1)
[ -n "$PKG" ] || { echo "no package tool under $G/objects/linux -- build it with: cd $G && jam -q '<build>package'" >&2; exit 1; }
[ -x "$CROSS/bin/aarch64-unknown-haiku-gcc" ] || { echo "no arm64 cross compiler at $CROSS" >&2; exit 1; }

mkdir -p "$WK"
if [ ! -d "$SRC" ]; then
	[ -f "$WK/zstd-$VER.tar.gz" ] \
		|| curl -sL -o "$WK/zstd-$VER.tar.gz" \
			"https://github.com/facebook/zstd/releases/download/v$VER/zstd-$VER.tar.gz"
	tar xzf "$WK/zstd-$VER.tar.gz" -C "$WK"
fi

export PATH="$CROSS/bin:$PATH"
# UNAME=Haiku stops the Makefile from taking the host's uname and deciding it is
# building for Linux. The -z cet-report warnings from ld are that flag being
# passed on an architecture that has no CET; they are harmless.
make -C "$SRC/lib" clean >/dev/null 2>&1 || true
make -C "$SRC/lib" -j"${JOBS:-8}" libzstd \
	CC=aarch64-unknown-haiku-gcc \
	AR=aarch64-unknown-haiku-ar \
	RANLIB=aarch64-unknown-haiku-ranlib \
	UNAME=Haiku >/dev/null
LIB=$(readlink -f "$SRC/lib/libzstd.so.1")
[ -f "$LIB" ] || { echo "libzstd did not build" >&2; exit 1; }
aarch64-unknown-haiku-readelf -h "$LIB" | grep -q AArch64 \
	|| { echo "$LIB is not an AArch64 object" >&2; exit 1; }

mkdir -p "$OUTDIR"

# ---- runtime --------------------------------------------------------------
B=$WK/pkg/zstd
rm -rf "$B"
mkdir -p "$B/lib" "$B/documentation/packages/zstd"
cp "$LIB" "$B/lib/libzstd.so.$VER"
ln -s "libzstd.so.$VER" "$B/lib/libzstd.so.1"
cp "$SRC/LICENSE" "$B/documentation/packages/zstd/LICENSE"
cat > "$B/.PackageInfo" <<EOF
name			zstd
version			$VER-$REV
architecture		arm64
summary			"Zstandard, a fast real-time compression algorithm"
description		"Zstd, short for Zstandard, is a fast lossless compression
algorithm targeting real-time compression scenarios at zlib-level and better
compression ratios. Cross-built for arm64 because the arm64 bootstrap
repository has no zstd, and without it packagefs cannot read a zstd-compressed
package."
packager		"The RENKU project"
vendor			"Haiku Project"
licenses {
	"BSD (2-clause)"
	"GNU GPL v2"
}
copyrights {
	"2016-2024 Facebook, Inc."
	"Meta Platforms, Inc. and affiliates"
}
provides {
	zstd = $VER
	lib:libzstd = $VER compat >= 1
}
requires {
	haiku
}
urls {
	"https://facebook.github.io/zstd/"
}
EOF

# ---- development ----------------------------------------------------------
# ExtractBuildFeatureArchives unpacks a package marked "depends: base" into the
# same directory as its base package, so develop/lib/libzstd.so.1.5.6 pointing
# at ../../lib/ resolves. Keep the three-step symlink chain: the build feature
# names develop/lib/libzstd.so.
D=$WK/pkg/zstd_devel
rm -rf "$D"
mkdir -p "$D/develop/headers" "$D/develop/lib/pkgconfig"
cp "$SRC/lib/zstd.h" "$SRC/lib/zdict.h" "$SRC/lib/zstd_errors.h" "$D/develop/headers/"
ln -s "libzstd.so.1" "$D/develop/lib/libzstd.so"
ln -s "libzstd.so.$VER" "$D/develop/lib/libzstd.so.1"
ln -s "../../lib/libzstd.so.$VER" "$D/develop/lib/libzstd.so.$VER"
cat > "$D/develop/lib/pkgconfig/libzstd.pc" <<EOF
prefix=/boot/system
exec_prefix=\${prefix}
includedir=\${prefix}/develop/headers
libdir=\${exec_prefix}/lib

Name: zstd
Description: fast lossless compression algorithm library
URL: https://facebook.github.io/zstd/
Version: $VER
Libs: -L\${libdir} -lzstd
Cflags: -I\${includedir}
EOF
cat > "$D/.PackageInfo" <<EOF
name			zstd_devel
version			$VER-$REV
architecture		arm64
summary			"Zstandard, a fast real-time compression algorithm (development files)"
description		"Headers and link libraries for the Zstandard compression
library. build/jam/BuildFeatures switches the tree's zstd build feature on when
this package is available for the architecture."
packager		"The RENKU project"
vendor			"Haiku Project"
licenses {
	"BSD (2-clause)"
	"GNU GPL v2"
}
copyrights {
	"2016-2024 Facebook, Inc."
	"Meta Platforms, Inc. and affiliates"
}
provides {
	zstd_devel = $VER
	devel:libzstd = $VER compat >= 1
}
requires {
	zstd == $VER-$REV base
}
urls {
	"https://facebook.github.io/zstd/"
}
EOF

rm -f "$OUTDIR/zstd-$VER-$REV-arm64.hpkg" "$OUTDIR/zstd_devel-$VER-$REV-arm64.hpkg"
( cd "$B" && "$PKG" create -q "$OUTDIR/zstd-$VER-$REV-arm64.hpkg" )
( cd "$D" && "$PKG" create -q "$OUTDIR/zstd_devel-$VER-$REV-arm64.hpkg" )

# ---- sources --------------------------------------------------------------
if [ -f "$ZSTD_SOURCE_HPKG" ]; then
	cp -f "$ZSTD_SOURCE_HPKG" "$OUTDIR/zstd_source-$VER-$REV-source.hpkg"
else
	echo "no zstd_source package at $ZSTD_SOURCE_HPKG" >&2
	echo "take zstd_source-$VER-$REV-source.hpkg from any architecture's HaikuPorts download directory -- it is architecture \"source\" and the same file everywhere" >&2
	exit 1
fi

ls -la "$OUTDIR"/zstd*.hpkg
