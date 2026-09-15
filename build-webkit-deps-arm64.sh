#!/bin/bash
#
# Cross-build the third-party libraries HaikuWebKit needs that the arm64
# bootstrap repository does not provide, and install them into the cross
# sysroot so WebKit's CMake finds them.
#
# Runs inside the haiku-builder container. Expects the source tarballs in
# $DEPS_SRC (see the list at the bottom) and the sysroot assembled by
# /root/pybuild/make-sysroot.sh.
#
# Libraries are installed with Haiku's layout: shared objects in
# boot/system/lib, a symlink per library plus .a/.pc files in
# boot/system/develop/lib, headers in boot/system/develop/headers. That is
# both what the cross gcc searches and what the .hpkg later ships.
#
# A second copy of every install goes to $STAGE/<lib>, which is what the
# packaging script turns into .hpkg files.
#
set -eu

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOST=aarch64-unknown-haiku
CROSS_BIN="${HAIKU_CROSS_BIN:-/root/gen-arm64/cross-tools-arm64/bin}"
SYSROOT="${HAIKU_SYSROOT:-/root/pybuild/sysroot}"
SR=$SYSROOT/boot/system
WK="${WK:-/root/wk}"
DEPS_SRC="${DEPS_SRC:-$WK/deps-tarballs}"
BUILD=$WK/deps-build
STAGE=$WK/deps-stage
JOBS="${JOBS:-8}"
TOOLCHAIN="${TOOLCHAIN:-$HERE/haiku-arm64.toolchain.cmake}"

export PATH=$CROSS_BIN:$PATH
export CC=$HOST-gcc CXX=$HOST-g++ AR=$HOST-ar RANLIB=$HOST-ranlib STRIP=$HOST-strip
export PKG_CONFIG_LIBDIR=$SR/develop/lib/pkgconfig
export PKG_CONFIG_PATH=
# Haiku hides the BSD/GNU extras (memrchr, strchrnul, ...) unless asked.
export CFLAGS="-O2 -D_DEFAULT_SOURCE" CXXFLAGS="-O2 -D_DEFAULT_SOURCE"

mkdir -p "$BUILD" "$STAGE" "$SR/develop/lib/pkgconfig"

# The bootstrap packages' .pc files carry the prefix they were built with,
# /packages/<name>/.self, which exists only on a running Haiku. gcc does not
# care (the sysroot is on its default search path), but CMake copies the
# include path into an imported target and then refuses to generate because
# the directory does not exist. Point them at the sysroot.
for pc in "$SR"/develop/lib/pkgconfig/*.pc; do
	grep -q "^prefix *= */packages/" "$pc" || continue
	sed -i -e "s|^\(prefix *= *\)/packages/[^/]*/\.self|\1$SR|" \
	       -e "s|/packages/[^/]*/\.self/lib|$SR/lib|g" \
	       -e "s|/packages/[^/]*/\.self/develop/headers|$SR/develop/headers|g" \
	       -e "s|/packages/[^/]*/\.self|$SR|g" "$pc"
done

# Autotools-style prefix: libraries straight into lib/, headers into
# develop/headers. develop/lib gets its symlinks afterwards.
CONF_PREFIX="--prefix=$SR --libdir=$SR/lib --includedir=$SR/develop/headers"

# After an install: mirror the Haiku package layout in the sysroot.
#  - lib/*.so* get a symlink from develop/lib (that is where haiku_devel's
#    own symlinks live, and what the cross gcc searches first)
#  - .pc and .a files move from lib/ to develop/lib/
#  - .la files are deleted: libtool's absolute host paths in them break later
#    cross links.
fixup_layout() {
	local root="$1"
	local lib="$root/lib" dev="$root/develop/lib"
	mkdir -p "$dev/pkgconfig"
	if [ -d "$lib/pkgconfig" ]; then
		cp -a "$lib/pkgconfig/." "$dev/pkgconfig/" && rm -rf "$lib/pkgconfig"
	fi
	for f in "$lib"/*.a; do [ -e "$f" ] && mv -f "$f" "$dev/"; done
	rm -f "$lib"/*.la "$dev"/*.la
	for f in "$lib"/*.so*; do
		[ -e "$f" ] || continue
		local n; n=$(basename "$f")
		[ -e "$dev/$n" ] || ln -s "../../lib/$n" "$dev/$n"
	done
	# cmake config files land in lib/cmake; leave them, cmake looks there.
}

# Install both into the sysroot and into a per-library staging tree.
do_install() {
	local name="$1"; shift
	"$@"
	"$@" DESTDIR="$STAGE/$name"
	fixup_layout "$SR"
	fixup_layout "$STAGE/$name$SR"
}

unpack() {
	local tarball="$1" dir="$2"
	rm -rf "$BUILD/$dir"
	tar xf "$DEPS_SRC/$tarball" -C "$BUILD"
	[ -d "$BUILD/$dir" ] || { echo "unpack: $dir not found after extracting $tarball" >&2; exit 1; }
}

done_marker() { [ -f "$STAGE/$1.done" ]; }
mark_done()   { touch "$STAGE/$1.done"; echo "=== $1 done"; }

# ---------------------------------------------------------------- libexecinfo
# WTF's StackTrace includes <execinfo.h> and every Haiku target links
# -lexecinfo. Haiku has no execinfo; HaikuPorts uses the FreeBSD one with a
# small patch, built by hand as its recipe does.
if ! done_marker libexecinfo; then
	echo "=== libexecinfo"
	unpack libexecinfo-1.1.tar.bz2 libexecinfo-1.1
	cd "$BUILD/libexecinfo-1.1"
	patch -p1 < "$DEPS_SRC/libexecinfo-1.1.patchset"
	$CC $CFLAGS -fPIC -c -o execinfo.o execinfo.c
	$CC $CFLAGS -fPIC -c -o stacktraverse.o stacktraverse.c
	$CC -shared -Wl,-soname,libexecinfo.so.1.1 -o libexecinfo.so.1.1 execinfo.o stacktraverse.o
	for root in "$SR" "$STAGE/libexecinfo$SR"; do
		mkdir -p "$root/lib" "$root/develop/headers"
		cp libexecinfo.so.1.1 "$root/lib/"
		ln -sf libexecinfo.so.1.1 "$root/lib/libexecinfo.so"
		cp execinfo.h "$root/develop/headers/"
		fixup_layout "$root"
	done
	mark_done libexecinfo
fi

# --------------------------------------------------------------------- libpng
if ! done_marker libpng; then
	echo "=== libpng"
	unpack libpng-1.6.50.tar.xz libpng-1.6.50
	cd "$BUILD/libpng-1.6.50"
	./configure --host=$HOST $CONF_PREFIX --disable-static --enable-shared \
		--with-zlib-prefix="$SR" > configure.log 2>&1
	make -j"$JOBS" > make.log 2>&1
	do_install libpng make install
	mark_done libpng
fi

# --------------------------------------------------------------- libjpeg-turbo
if ! done_marker libjpeg; then
	echo "=== libjpeg-turbo"
	unpack libjpeg-turbo-3.1.1.tar.gz libjpeg-turbo-3.1.1
	mkdir -p "$BUILD/libjpeg-turbo-3.1.1/b" && cd "$BUILD/libjpeg-turbo-3.1.1/b"
	cmake .. -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$SR" -DCMAKE_INSTALL_LIBDIR=lib \
		-DCMAKE_INSTALL_INCLUDEDIR=develop/headers \
		-DENABLE_STATIC=OFF -DENABLE_SHARED=ON -DWITH_TURBOJPEG=OFF \
		-DWITH_SIMD=ON > cmake.log 2>&1
	make -j"$JOBS" > make.log 2>&1
	do_install libjpeg make install
	mark_done libjpeg
fi

# -------------------------------------------------------------------- libwebp
if ! done_marker libwebp; then
	echo "=== libwebp"
	unpack libwebp-1.5.0.tar.gz libwebp-1.5.0
	cd "$BUILD/libwebp-1.5.0"
	# The image-format switches only affect the example tools, and their
	# checks would find the host's libpng-config; keep them off.
	./configure --host=$HOST $CONF_PREFIX --disable-static --enable-shared \
		--enable-libwebpdemux --enable-libwebpmux --disable-libwebpdecoder \
		--disable-gl --disable-png --disable-jpeg --disable-tiff --disable-gif \
		--disable-sdl --disable-wic > configure.log 2>&1
	make -j"$JOBS" > make.log 2>&1
	do_install libwebp make install
	mark_done libwebp
fi

# -------------------------------------------------------------------- libxml2
if ! done_marker libxml2; then
	echo "=== libxml2"
	unpack libxml2-2.13.8.tar.xz libxml2-2.13.8
	cd "$BUILD/libxml2-2.13.8"
	./configure --host=$HOST $CONF_PREFIX --disable-static --enable-shared \
		--without-python --without-lzma --with-zlib --without-icu \
		--with-iconv=no > configure.log 2>&1
	make -j"$JOBS" > make.log 2>&1
	do_install libxml2 make install
	mark_done libxml2
fi

# -------------------------------------------------------------------- libxslt
if ! done_marker libxslt; then
	echo "=== libxslt"
	unpack libxslt-1.1.43.tar.xz libxslt-1.1.43
	cd "$BUILD/libxslt-1.1.43"
	./configure --host=$HOST $CONF_PREFIX --disable-static --enable-shared \
		--without-python --without-crypto --without-plugins \
		--with-libxml-prefix="$SR" > configure.log 2>&1
	make -j"$JOBS" > make.log 2>&1
	do_install libxslt make install
	mark_done libxslt
fi

# --------------------------------------------------------------------- libpsl
# Public suffix list, used by WebCore's cookie handling under USE_CURL.
# ICU is in the sysroot, so it does the IDNA work; the list itself is built
# in (the DAFSA is generated by a host python script).
if ! done_marker libpsl; then
	echo "=== libpsl"
	unpack libpsl-0.21.5.tar.gz libpsl-0.21.5
	cd "$BUILD/libpsl-0.21.5"
	./configure --host=$HOST $CONF_PREFIX --disable-static --enable-shared \
		--enable-runtime=libicu --enable-builtin \
		--disable-man --disable-gtk-doc > configure.log 2>&1
	make -j"$JOBS" > make.log 2>&1
	do_install libpsl make install
	mark_done libpsl
fi

# -------------------------------------------------------------------- nghttp2
# HTTP/2. WebKit only turns HTTP/2 on when libcurl reports the feature
# (CurlContext checks curl_version_info), so without this every request falls
# back to HTTP/1.1 -- six connections per host, a TLS handshake on each, no
# multiplexing. On a portal that pulls several hundred images from one host
# that is the difference between one connection and dozens.
if ! done_marker nghttp2; then
	echo "=== nghttp2"
	unpack nghttp2-1.70.0.tar.xz nghttp2-1.70.0
	cd "$BUILD/nghttp2-1.70.0"
	# --enable-lib-only: only libnghttp2 is wanted; the tools need libev,
	# c-ares and a C++ compiler pointed at a full sysroot.
	./configure --host=$HOST $CONF_PREFIX --disable-static --enable-shared \
		--enable-lib-only > configure.log 2>&1
	make -j"$JOBS" > make.log 2>&1
	do_install nghttp2 make install
	mark_done nghttp2
fi

# ----------------------------------------------------------------------- curl
# The bootstrap curl package has no TLS. WebCore's network layer is curl
# (USE_CURL in OptionsHaiku.cmake), so this one is built against the OpenSSL
# already in the sysroot (found through pkg-config; a --with-openssl=<dir>
# form wants <dir>/include, which Haiku's layout has not got). The CA bundle
# path is where Haiku's ca_root_certificates package puts it.
if ! done_marker curl; then
	echo "=== curl"
	unpack curl-8.19.0.tar.xz curl-8.19.0
	cd "$BUILD/curl-8.19.0"
	./configure --host=$HOST $CONF_PREFIX --disable-static --enable-shared \
		--with-openssl --with-zlib --with-libpsl --with-nghttp2 \
		--without-libidn2 --without-brotli --without-zstd \
		--disable-ldap --disable-ldaps --disable-rtsp --disable-manual \
		--disable-docs --without-libgsasl \
		--with-ca-bundle=/boot/system/data/ssl/CARootCertificates.pem \
		> configure.log 2>&1
	make -j"$JOBS" > make.log 2>&1
	do_install curl make install
	mark_done curl
fi

# -------------------------------------------------------------- brotli, woff2
# WOFF2 web fonts. woff2 needs brotli's decoder.
if ! done_marker brotli; then
	echo "=== brotli"
	unpack brotli-1.1.0.tar.gz brotli-1.1.0
	mkdir -p "$BUILD/brotli-1.1.0/b" && cd "$BUILD/brotli-1.1.0/b"
	cmake .. -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$SR" -DCMAKE_INSTALL_LIBDIR=lib \
		-DCMAKE_INSTALL_INCLUDEDIR=develop/headers \
		-DBUILD_SHARED_LIBS=ON -DBROTLI_DISABLE_TESTS=ON > cmake.log 2>&1
	make -j"$JOBS" > make.log 2>&1
	do_install brotli make install
	mark_done brotli
fi

if ! done_marker woff2; then
	echo "=== woff2"
	unpack woff2-1.0.2.tar.gz woff2-1.0.2
	mkdir -p "$BUILD/woff2-1.0.2/b" && cd "$BUILD/woff2-1.0.2/b"
	cmake .. -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$SR" -DCMAKE_INSTALL_LIBDIR=lib \
		-DCMAKE_INSTALL_INCLUDEDIR=develop/headers \
		-DBUILD_SHARED_LIBS=ON -DCANONICAL_PREFIXES=ON -DNOISY_LOGGING=OFF \
		-DBROTLIDEC_INCLUDE_DIRS="$SR/develop/headers" \
		-DBROTLIDEC_LIBRARIES="$SR/lib/libbrotlidec.so" \
		-DBROTLIENC_INCLUDE_DIRS="$SR/develop/headers" \
		-DBROTLIENC_LIBRARIES="$SR/lib/libbrotlienc.so" > cmake.log 2>&1
	make -j"$JOBS" > make.log 2>&1
	do_install woff2 make install
	mark_done woff2
fi

# ---------------------------------------------------------------------- lcms2
# Colour management for tagged images (USE_LCMS).
if ! done_marker lcms2; then
	echo "=== lcms2"
	unpack lcms2-2.16.tar.gz lcms2-2.16
	cd "$BUILD/lcms2-2.16"
	./configure --host=$HOST $CONF_PREFIX --disable-static --enable-shared \
		--without-jpeg --without-tiff > configure.log 2>&1
	make -j"$JOBS" > make.log 2>&1
	do_install lcms2 make install
	mark_done lcms2
fi

# ---------------------------------------------------------------------- dav1d
# The AV1 decoder libavif needs. HaikuPorts' libavif pulls in dav1d, rav1e and
# sharpyuv; only the decoder is needed for a browser, so rav1e -- a Rust build
# -- is left out and libavif is configured decode-only below.
#
# dav1d is the one meson build here. meson will not take the cross compiler
# from the environment the way autotools and cmake do, so it gets a machine
# file. The aarch64 assembly is .S handed to the C compiler, so unlike x86
# there is no nasm involved.
if ! done_marker dav1d; then
	echo "=== dav1d"
	unpack dav1d-1.4.3.tar.gz dav1d-1.4.3
	cat > "$BUILD/haiku-arm64.cross" <<EOF
[binaries]
c = '$CROSS_BIN/$HOST-gcc'
cpp = '$CROSS_BIN/$HOST-g++'
ar = '$CROSS_BIN/$HOST-ar'
strip = '$CROSS_BIN/$HOST-strip'

[host_machine]
system = 'haiku'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
	cd "$BUILD/dav1d-1.4.3"
	meson setup b --cross-file "$BUILD/haiku-arm64.cross" \
		--default-library=shared --buildtype=release \
		-Denable_tools=false -Denable_tests=false \
		--prefix="$SR" --libdir=lib --includedir=develop/headers > meson.log 2>&1
	ninja -C b -j"$JOBS" > ninja.log 2>&1
	do_install dav1d meson install -C b
	mark_done dav1d
fi

# -------------------------------------------------------------------- libavif
# AVIF images (USE_AVIF). Decode only: AVIF_CODEC_DAV1D=SYSTEM gives the
# decoder, and no encoder is configured, so nothing here needs rav1e or aom.
# The soname is libavif.so.16, the same one HaikuPorts' x86 package provides.
if ! done_marker libavif; then
	echo "=== libavif"
	unpack libavif-1.1.1.tar.gz libavif-1.1.1
	mkdir -p "$BUILD/libavif-1.1.1/b" && cd "$BUILD/libavif-1.1.1/b"
	cmake .. -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$SR" -DCMAKE_INSTALL_LIBDIR=lib \
		-DCMAKE_INSTALL_INCLUDEDIR=develop/headers \
		-DBUILD_SHARED_LIBS=ON -DAVIF_CODEC_DAV1D=SYSTEM -DAVIF_LIBYUV=OFF \
		-DAVIF_BUILD_APPS=OFF -DAVIF_BUILD_TESTS=OFF \
		-DAVIF_BUILD_EXAMPLES=OFF > cmake.log 2>&1
	make -j"$JOBS" > make.log 2>&1
	do_install libavif make install
	mark_done libavif
fi

echo
echo "sysroot pkg-config now knows:"
ls "$SR/develop/lib/pkgconfig"
