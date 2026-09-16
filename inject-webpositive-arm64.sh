#!/bin/sh
#
# Put WebPositive onto a Haiku arm64 disk image from the OUTSIDE: without
# ever booting Haiku. Writes straight into the image's boot partition using
# Haiku's own host tools for that, the same ones jam uses to populate a
# fresh image during a build.
#
# This is the fallback for install-webpositive-arm64.sh, which needs an
# attached CD-ROM/USB stick and a boot cycle: on a QEMU instance whose
# devices can't be changed while it is running (this port's xhci does not
# surface a hot-plugged USB disk, and AHCI refuses hot-plug outright -- see
# AGENTS.md), or on a disk you would rather not boot at all, write the
# packages in directly and let the *next* boot find them already there.
#
# Requires bfs_shell and fs_shell_command, Haiku's own host-side tools for
# reading and writing a BFS image without a kernel. They are host tool
# build products, not something you install separately: build a Haiku arm64
# tree once (this project already does, in the haiku-builder container --
# see AGENTS.md) and point BFS_SHELL / FS_SHELL_COMMAND at the pair under
# its generated.<arch>/objects/.../release/tools/{bfs_shell,fs_shell}/.
# There is no macOS build of either; run this on the Linux host or
# container that has them, not on the Mac directly.
#
#   BFS_SHELL=... FS_SHELL_COMMAND=... ./inject-webpositive-arm64.sh \
#       <disk-image> [package-directory]
#
# -m   also skip libmedia_bootstrap (see the comment on it below --
#      pass this only for an image you know already has libmedia.so)
#
set -eu

SKIP_LIBMEDIA=0
while [ $# -gt 0 ]; do
	case "$1" in
	-m) SKIP_LIBMEDIA=1; shift ;;
	--) shift; break ;;
	-*) printf 'unknown option: %s\n' "$1" >&2; exit 1 ;;
	*) break ;;
	esac
done

IMAGE="${1:?usage: inject-webpositive-arm64.sh [-m] <disk-image> [package-directory]}"
PKGDIR="${2:-$(cd "$(dirname "$0")" && pwd)/packages}"

BFS_SHELL="${BFS_SHELL:?set BFS_SHELL to the bfs_shell host tool built for this tree}"
FS_SHELL_COMMAND="${FS_SHELL_COMMAND:?set FS_SHELL_COMMAND to the matching fs_shell_command}"

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$IMAGE" ] || die "no such file: $IMAGE"
[ -d "$PKGDIR" ] || die "no package directory at $PKGDIR"
[ -x "$BFS_SHELL" ] || die "not executable: $BFS_SHELL"
[ -x "$FS_SHELL_COMMAND" ] || die "not executable: $FS_SHELL_COMMAND"

# Same package set install-webpositive-arm64.sh uses, and the same reasons;
# see the comment there.
#
# libmedia_bootstrap is always included unless -m is given. Every real
# arm64 nightly seen while building this project -- both the ones
# downloaded from download.haiku-os.org and the ones this project builds
# itself -- turned out to be a *minimum*-profile image (jam @minimum-mmc /
# @minimum-anyboot), which drops the whole Media Kit: no media_server, no
# libmedia.so, on any architecture, by design, not an arm64 gap. Only a
# *regular*/desktop-profile Haiku already has libmedia.so, bundled inside
# its own "haiku" package. There is no reliable way to tell which kind of
# image this is without booting it: /system/lib does not exist as a literal
# path on an unbooted BFS partition at all (it is packagefs's own virtual
# merge of every active package's files, which only exists once the kernel
# is running), so there is nothing on disk yet to check it against. Pass -m
# for an image you know is a regular/desktop build; installing
# libmedia_bootstrap on top of one would put two packages' files at the
# same path, which packagefs will refuse to boot with active.
REQUIRED="dav1d libavif1.0 openssl3 sqlite3 icu74 icu74_bootstrap haikuwebkit webpositive"
OPTIONAL="ca_root_certificates noto_sans_cjk_kr"
LIBMEDIA_PKG="libmedia_bootstrap"

find_pkg() {
	for f in "$PKGDIR"/"$1"-*.hpkg; do
		[ -e "$f" ] && { printf '%s\n' "$f"; return 0; }
	done
	return 1
}

# ---------------------------------------------------------------------------
step "Checking the packages"

PLAN=""
MISSING=""
for name in $REQUIRED; do
	if f=$(find_pkg "$name"); then
		say "found     $(basename "$f")"
		PLAN="$PLAN $f"
	else
		MISSING="$MISSING $name"
	fi
done
for name in $OPTIONAL; do
	if f=$(find_pkg "$name"); then
		say "found     $(basename "$f") (optional)"
		PLAN="$PLAN $f"
	else
		say "skipping  $name (optional, not found)"
	fi
done
if [ "$SKIP_LIBMEDIA" = 1 ]; then
	say "skipping  $LIBMEDIA_PKG (-m given)"
elif f=$(find_pkg "$LIBMEDIA_PKG"); then
	say "found     $(basename "$f")"
	PLAN="$PLAN $f"
else
	MISSING="$MISSING $LIBMEDIA_PKG"
fi
[ -z "$MISSING" ] || die "missing required packages:$MISSING"

# Bytes 18-19 of an hpkg are its heap compression: 0001 zlib, 0002 zstd. A
# stock arm64 packagefs has no zstd (see install-webpositive-arm64.sh); a
# zstd package written in this way installs and never activates, silently.
ZSTD=""
for f in $PLAN; do
	c=$(od -A n -t x1 -j 18 -N 2 "$f" 2>/dev/null | tr -d ' ')
	[ "$c" = "0002" ] && ZSTD="$ZSTD $(basename "$f")"
done
[ -z "$ZSTD" ] || die "zstd-compressed, will not activate:$ZSTD"

# ---------------------------------------------------------------------------
step "Finding the boot partition"

# MBR: a 4-entry partition table at offset 446, 16 bytes each; byte 4 of an
# entry is its type, bytes 8-11 its starting LBA (little-endian). Haiku's
# own partition type is 0xeb. This reads the primary table only -- enough
# for every image this project builds, all of which are a small EFI System
# Partition plus one BFS partition, no extended/logical partitions.
OFFSET=$(od -A n -t u1 -j 446 -N 64 "$IMAGE" | tr -s ' ' '\n' | grep -v '^$' | awk '
	{ b[NR-1]=$1 }
	END {
		for (e = 0; e < 4; e++) {
			base = e * 16
			type = b[base + 4]
			if (type == 235) {  # 0xeb
				lba = b[base+8] + b[base+9]*256 + b[base+10]*65536 + b[base+11]*16777216
				print lba * 512
				exit
			}
		}
	}')
[ -n "$OFFSET" ] || die "no Haiku (type 0xeb) partition found in $IMAGE"
say "BFS partition at byte offset $OFFSET"

# ---------------------------------------------------------------------------
step "Writing the packages in"

# The same two-process, four-FIFO protocol build/scripts/build_haiku_image
# uses: bfs_shell mounts the image and runs as a server, reading commands
# from fd 4 and replying on fd 6; fs_shell_command is the client, one
# process per command, writing to fd 4 and reading the reply on fd 3. This
# is the only way to reach a real host path from bfs_shell's own "cp" --
# handed the image's mounted files directly (no colon), it looks for them
# inside the image and fails; a ":"-prefixed path escapes to the real
# filesystem. See build_haiku_image's $sPrefix for the same convention.
#
# There is no reliable way to read bfs_shell's own command output back
# mid-session to check what is already on the disk: its stdout is fully
# block-buffered once redirected to a file (not a TTY), so a directory
# listing issued now can still be sitting in that buffer, invisible to
# anything reading the log file, when the *next* command's result is
# already due -- it only reliably lands once the process exits. So this
# does not try to detect what is already installed; it copies everything in
# $PLAN unconditionally, with "cp -f" to overwrite in place. That is exactly
# as safe here as it sounds: nothing is booted, nothing is running, and the
# one package already on every image this project has seen (icu74, part of
# the arm64 bootstrap set) is the same file byte for byte, so overwriting it
# with itself changes nothing.
FIFO_BASE="/tmp/inject-webpositive-$$"
TO_FIFO="$FIFO_BASE-to"
FROM_FIFO="$FIFO_BASE-from"
LOG="$FIFO_BASE.log"
rm -f "$TO_FIFO" "$FROM_FIFO"
mkfifo "$TO_FIFO" "$FROM_FIFO"

sleep 3<"$FROM_FIFO" 1 &
exec 6>"$FROM_FIFO" 3<"$FROM_FIFO"
sleep 5<"$TO_FIFO" 1 &
exec 4>"$TO_FIFO" 5<"$TO_FIFO"
rm -f "$TO_FIFO" "$FROM_FIFO"

"$BFS_SHELL" 3>&5 4<&6 5>&- 6>&- -n --start-offset "$OFFSET" "$IMAGE" > "$LOG" 2>&1 &
BFS_PID=$!
cleanup() {
	kill "$BFS_PID" 2>/dev/null || true
	rm -f "$LOG"
}
trap cleanup EXIT
sleep 1
kill -0 "$BFS_PID" 2>/dev/null || die "bfs_shell exited immediately -- see $LOG"

fscmd() { "$FS_SHELL_COMMAND" 3<&3 4>&4 5>&- 6>&- "$@"; }

fscmd cd /myfs || die "mounting $IMAGE failed -- see $LOG"
say "mounted"

for f in $PLAN; do
	b=$(basename "$f")
	fscmd cp -f ":$f" "/myfs/system/packages/$b"
	say "wrote     $b"
done

fscmd sync
fscmd quit
wait "$BFS_PID" 2>/dev/null || true
trap - EXIT
rm -f "$LOG"

say ""
say "Done. Boot $IMAGE normally; the new packages activate on that boot the"
say "same way any other newly-added package would."
