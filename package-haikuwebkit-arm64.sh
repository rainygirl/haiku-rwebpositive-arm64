#!/bin/bash
#
# Wrap the cross-built HaikuWebKit into two Haiku packages, the way the
# HaikuPorts recipe splits them:
#
#   haikuwebkit-1.10.0-2-arm64.hpkg        libWebKitLegacy, libJavaScriptCore,
#                                          jsc, the inspector data -- plus the
#                                          third-party libraries it links that
#                                          the arm64 repository has no package
#                                          for (png, jpeg, webp, xml2, xslt,
#                                          psl, nghttp2, curl, execinfo,
#                                          brotli, woff2, lcms2)
#   haikuwebkit_devel-1.10.0-2-arm64.hpkg  headers and link-time symlinks, so
#                                          the Haiku tree's "webkit" build
#                                          feature can build WebPositive
#
# The version "1.10.0-2" matches the entry in the Haiku tree's
# build/jam/repositories/HaikuPorts/x86_64, so the same line can go into the
# arm64 repository list and the file names will be what jam looks for.
#
# Runs inside the haiku-builder container after build-haikuwebkit-arm64.sh
# install.
#
set -eu

WK="${WK:-/root/wk}"
G="${RENKU_GEN:-/root/gen-kd}"
TREE="${RENKU_TREE:-/root/haiku-arm64}"
SYSROOT="${HAIKU_SYSROOT:-/root/pybuild/sysroot}"
CROSS_BIN="${HAIKU_CROSS_BIN:-/root/gen-arm64/cross-tools-arm64/bin}"
VER=1.10.0
REV=3
OUTDIR="${1:-$WK/packages}"
WEBKIT_STAGE=$WK/webkit-stage/boot/system
DEPS_STAGE=$WK/deps-stage
PKG=$(find "$G/objects/linux" -name package -type f -perm -u+x 2>/dev/null | head -1)
READELF=$CROSS_BIN/aarch64-unknown-haiku-readelf
[ -n "$PKG" ] || { echo "no package tool under $G/objects/linux" >&2; exit 1; }
[ -d "$WEBKIT_STAGE/lib" ] || { echo "no WebKit install at $WEBKIT_STAGE" >&2; exit 1; }

DEPS="libexecinfo libpng libjpeg libwebp libxml2 libxslt libpsl nghttp2 curl brotli woff2 lcms2"

BASE=$WK/pkg/haikuwebkit
DEVEL=$WK/pkg/haikuwebkit_devel
rm -rf "$BASE" "$DEVEL"
mkdir -p "$BASE/lib" "$BASE/bin" "$BASE/data/licenses" "$DEVEL/develop/lib" "$DEVEL/develop/headers"

# ---- runtime package -------------------------------------------------------
# WebKit's own shared objects and the jsc shell.
cp -a "$WEBKIT_STAGE"/lib/*.so* "$BASE/lib/"
[ -f "$WEBKIT_STAGE/bin/jsc" ] && cp -a "$WEBKIT_STAGE/bin/jsc" "$BASE/bin/"
# Web Inspector front end and whatever else went to data/.
[ -d "$WEBKIT_STAGE/data" ] && cp -a "$WEBKIT_STAGE/data/." "$BASE/data/"

# Which runtime libraries belong to which dependency. build-webkit-deps-arm64.sh
# leaves a staged install per library and that is what is used when it is there;
# this list is the fallback for a tree where the staging directories are gone
# but the sysroot still has the libraries. Moving the WebKit build to another
# machine leaves exactly that state, and without the fallback the packaging
# stops at "missing staged install for libexecinfo".
dep_libs() {
	case "$1" in
	libexecinfo) echo "libexecinfo.so.*" ;;
	libpng)      echo "libpng16.so.*" ;;
	libjpeg)     echo "libjpeg.so.*" ;;
	libwebp)     echo "libwebp.so.* libwebpdemux.so.* libwebpmux.so.* libsharpyuv.so.*" ;;
	libxml2)     echo "libxml2.so.*" ;;
	libxslt)     echo "libxslt.so.* libexslt.so.*" ;;
	libpsl)      echo "libpsl.so.*" ;;
	nghttp2)     echo "libnghttp2.so.*" ;;
	curl)        echo "libcurl.so.*" ;;
	brotli)      echo "libbrotlicommon.so.* libbrotlidec.so.* libbrotlienc.so.*" ;;
	woff2)       echo "libwoff2common.so.* libwoff2dec.so.* libwoff2enc.so.*" ;;
	lcms2)       echo "liblcms2.so.*" ;;
	esac
}

# dav1d and libavif are deliberately not in this list. They are packaged
# separately, as dav1d and libavif1.0, the names HaikuPorts uses and the ones
# build/jam/BuildFeatures looks for; haikuwebkit picks them up through
# lib:libavif in its requires, generated below from the DT_NEEDED entries.

# The third-party runtime libraries, from each dependency's staged install.
for d in $DEPS; do
	src=$DEPS_STAGE/$d$SYSROOT/boot/system/lib
	if [ -d "$src" ]; then
		for f in "$src"/*.so*; do
			[ -e "$f" ] || continue
			cp -a "$f" "$BASE/lib/"
		done
		continue
	fi
	pats=$(dep_libs "$d")
	[ -n "$pats" ] || { echo "no staged install and no library list for $d" >&2; exit 1; }
	found=0
	for pat in $pats; do
		for f in "$SYSROOT"/boot/system/lib/$pat; do
			[ -e "$f" ] || continue
			cp -a "$f" "$BASE/lib/"
			found=1
		done
	done
	[ "$found" = 1 ] || { echo "neither a staged install nor sysroot libraries for $d" >&2; exit 1; }
done
# Only the runtime objects belong here: strip out symlinks with no version
# (libfoo.so) -- those are the link-time names and go in the devel package.
find "$BASE/lib" -maxdepth 1 -name "*.so" -type l -delete
find "$BASE/lib" -name "*.la" -delete
$CROSS_BIN/aarch64-unknown-haiku-strip --strip-unneeded "$BASE"/lib/*.so.* "$BASE"/bin/* 2>/dev/null || true
# The sysroot's libsqlite3.so carries no SONAME, so the linker recorded its
# absolute host path as DT_NEEDED; Haiku's runtime_loader would look for
# exactly that path. Rewrite it to the bare name.
if command -v patchelf >/dev/null; then
	for f in "$BASE"/lib/*.so.* "$BASE"/bin/*; do
		[ -f "$f" ] && [ ! -L "$f" ] || continue
		for so in $($READELF -d "$f" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(\/.*\)\].*/\1/p'); do
			# Follow the sysroot's symlink one step so an unversioned
			# libfoo.so becomes the libfoo.so.N the image actually ships.
			n=$(basename "$so")
			if [ -L "$so" ]; then n=$(basename "$(readlink "$so")"); fi
			patchelf --replace-needed "$so" "$n" "$f"
			echo "fixed DT_NEEDED $so -> $n in $(basename "$f")"
		done
	done
fi

# ---- devel package ---------------------------------------------------------
cp -a "$WEBKIT_STAGE/develop/headers/." "$DEVEL/develop/headers/"
for f in "$BASE"/lib/libWebKitLegacy.so.* "$BASE"/lib/libJavaScriptCore.so.*; do
	n=$(basename "$f")
	base=${n%%.so.*}.so
	ln -sf "../../lib/$n" "$DEVEL/develop/lib/$base"
done

# ---- provides / requires ---------------------------------------------------
# lib:foo names come from the sonames actually shipped; requires from the
# DT_NEEDED entries of everything shipped, minus what the package itself
# provides and minus Haiku's own libraries (those come with the haiku
# package and are not declared as lib: entries).
libname() { local n=$1; n=${n%%.so*}; echo "$n"; }
libver() {
	# libpng16.so.16.50.0 -> 16.50.0 ; libfoo.so.1 -> 1 ; libfoo.so -> 0
	local n=$1; case "$n" in *.so.*) echo "${n#*.so.}";; *) echo 0;; esac
}
PROVIDES=""
declare -A OWN
for f in "$BASE"/lib/*.so.*; do
	[ -L "$f" ] && continue
	soname=$($READELF -d "$f" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p' | head -1)
	[ -n "$soname" ] || soname=$(basename "$f")
	n=$(libname "$soname"); v=$(libver "$(basename "$f")")
	OWN[$n]=1
	PROVIDES+="	lib:$n = $v
"
done
HAIKU_LIBS="libroot libbe libnetwork libbnetapi libbsd libgnu libtranslation libtracker libtextencoding libmedia libgame libdevice libdebug libmail libmidi libmidi2 libscreensaver libpackage libshared libcolumnlistview libnetservices libnetservices2 libstdc++ libgcc_s libsupc++ libatomic libgomp libssp"
NEEDED=$(for f in "$BASE"/lib/*.so.* "$BASE"/bin/*; do
	[ -f "$f" ] && [ ! -L "$f" ] && $READELF -d "$f" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p'
done | sort -u)
REQUIRES=""
for so in $NEEDED; do
	# A library in the sysroot without a SONAME gets recorded by its full
	# path, and that path is a host path that means nothing on the guest.
	# libsqlite3 from the python package build was one; the fix is to give it
	# a SONAME (patchelf --set-soname) and relink, not to rewrite the entry
	# afterwards. Never emit a path here.
	case "$so" in */*) echo "absolute DT_NEEDED left in a shipped file: $so" >&2; exit 1;; esac
	n=$(libname "$so")
	[ -n "${OWN[$n]:-}" ] && continue
	case " $HAIKU_LIBS " in *" $n "*) continue;; esac
	REQUIRES+="	lib:$n
"
done

# ---- licences --------------------------------------------------------------
# Every licence named in .PackageInfo has to be present inside the package
# or "package create" refuses. Haiku carries the common texts; reuse them.
HL=$TREE/data/system/data/licenses
LICENSES="GNU LGPL v2|GNU LGPL v2.1|MIT|BSD (2-clause)|BSD (3-clause)|LibPNG|LibJPEG|Apache v2|Zlib"
IFS='|' read -ra LIC <<< "$LICENSES"
LIC_BLOCK=""
for l in "${LIC[@]}"; do
	[ -f "$HL/$l" ] || { echo "no licence text named '$l' in $HL" >&2; exit 1; }
	cp "$HL/$l" "$BASE/data/licenses/$l"
	LIC_BLOCK+="	\"$l\"
"
done
# curl's licence is its own text.
CURL_LICENSE=$WK/deps-tarballs/curl-COPYING
[ -f "$CURL_LICENSE" ] || CURL_LICENSE=$WK/deps-build/curl-8.19.0/COPYING
if [ -f "$CURL_LICENSE" ]; then
	cp "$CURL_LICENSE" "$BASE/data/licenses/curl"
	LIC_BLOCK+="	\"curl\"
"
fi

cat > "$BASE/.PackageInfo" <<EOF
name			haikuwebkit
version			$VER-$REV
architecture		arm64
summary			"Open source web browser engine"
description		"WebKit is an open source web browser engine, here the Haiku port
(WebKitLegacy + JavaScriptCore), cross-compiled for Haiku arm64. JavaScript
runs on the ARM64 LLInt interpreter; the JIT is disabled. This package also
ships the third-party libraries WebKit links against that the arm64
repository has no packages for: libpng, libjpeg-turbo, libwebp, libxml2,
libxslt, libpsl, curl (with OpenSSL), libexecinfo, brotli, woff2 and lcms2."
# "Haiku Project" to match the repository this is added to (its repo.info
# says the same). It is not a requirement: package_repo has no vendor check,
# and a repository built with vendor "RENKU" and packages to match works.
packager		"The RENKU project"
vendor			"Haiku Project"
licenses {
$LIC_BLOCK}
copyrights {
	"1998-2026 Apple Inc., Google Inc., Sony, Samsung, Igalia, et al"
	"1995-2024 the libpng authors"
	"1991-2024 Thomas G. Lane, Guido Vollbeding, D. R. Commander (libjpeg-turbo)"
	"2010-2024 Google Inc. (libwebp, brotli, woff2)"
	"1998-2024 Daniel Veillard (libxml2, libxslt)"
	"2014-2024 Tim Ruehsen (libpsl)"
	"1996-2026 Daniel Stenberg (curl)"
	"2012-2025 Tatsuhiro Tsujikawa (nghttp2)"
	"2003 Maxim Sobolev (libexecinfo)"
	"1998-2024 Marti Maria Saguer (Little CMS)"
}
provides {
	haikuwebkit = $VER
	cmd:jsc
$PROVIDES}
requires {
	haiku
$REQUIRES}
urls {
	"https://www.webkit.org/"
}
EOF

cat > "$DEVEL/.PackageInfo" <<EOF
name			haikuwebkit_devel
version			$VER-$REV
architecture		arm64
summary			"Open source web browser engine (development files)"
description		"Headers and link-time symlinks for HaikuWebKit $VER on Haiku arm64."
packager		"The RENKU project"
vendor			"Haiku Project"
licenses {
	"GNU LGPL v2"
	"GNU LGPL v2.1"
	"MIT"
}
copyrights {
	"1998-2026 Apple Inc., Google Inc., Sony, Samsung, Igalia, et al"
}
provides {
	haikuwebkit_devel = $VER
	devel:libWebKitLegacy = $VER
	devel:libJavaScriptCore = $VER
}
requires {
	haikuwebkit == $VER base
}
EOF
mkdir -p "$DEVEL/data/licenses"
for l in "GNU LGPL v2" "GNU LGPL v2.1" "MIT"; do cp "$HL/$l" "$DEVEL/data/licenses/$l"; done

echo "--- haikuwebkit .PackageInfo"; cat "$BASE/.PackageInfo"

mkdir -p "$OUTDIR"
rm -f "$OUTDIR/haikuwebkit-$VER-$REV-arm64.hpkg" "$OUTDIR/haikuwebkit_devel-$VER-$REV-arm64.hpkg"
( cd "$BASE"  && "$PKG" create -q "$OUTDIR/haikuwebkit-$VER-$REV-arm64.hpkg" )
( cd "$DEVEL" && "$PKG" create -q "$OUTDIR/haikuwebkit_devel-$VER-$REV-arm64.hpkg" )
ls -la "$OUTDIR"/haikuwebkit*.hpkg
