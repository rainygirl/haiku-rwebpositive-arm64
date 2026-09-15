#!/bin/bash
#
# Package Noto Sans CJK for the RENKU arm64 image, so Korean, Japanese and
# Chinese text is drawn with real glyphs instead of empty boxes.
#
# Why not HaikuPorts' noto_sans_cjk_jp: that package ships
# NotoSansCJKjp-VF.otf, an OpenType *variable* font. The arm64 bootstrap
# repository's freetype is 2.6.3 (2015), which predates variable-font support
# entirely, so app_server silently never loads it -- the package installs, the
# file is in data/fonts/otfonts, and `listfont` still shows five families.
# The static OTFs below are plain CFF OpenType, which that freetype reads.
#
# The KR variant is the default because this image is used with a Korean
# desktop. All four language variants of Noto Sans CJK carry the *same* glyph
# complement (Hangul, kana and Han); they differ only in which shape is chosen
# for Han codepoints that are drawn differently in each language.
#
# Runs inside the haiku-builder container. Expects the .otf files and the
# licence in $WK/cjkfont (see the README for where they come from).
#
set -eu

WK="${WK:-/root/wk}"
G="${RENKU_GEN:-/root/gen-arm64-kd2}"
TREE="${RENKU_TREE:-/root/haiku-renku}"
SRC="${CJK_SRC:-$WK/cjkfont}"
OUTDIR="${1:-$WK/packages}"
VER=2.004
REV=1
PKG=$(find "$G/objects/linux" /root/gen-arm64/objects/linux -name package -type f -perm -u+x 2>/dev/null | head -1)
[ -n "$PKG" ] || { echo "no package tool" >&2; exit 1; }
for f in NotoSansCJKkr-Regular.otf NotoSansCJKkr-Bold.otf LICENSE; do
	[ -f "$SRC/$f" ] || { echo "missing $SRC/$f" >&2; exit 1; }
done

B=$WK/pkg/noto_sans_cjk_kr
rm -rf "$B"
# app_server scans every subdirectory of data/fonts; otfonts is where Haiku
# keeps OpenType faces.
mkdir -p "$B/data/fonts/otfonts" "$B/data/licenses"
cp "$SRC/NotoSansCJKkr-Regular.otf" "$SRC/NotoSansCJKkr-Bold.otf" "$B/data/fonts/otfonts/"
cp "$SRC/LICENSE" "$B/data/licenses/SIL Open Font License v1.1"

cat > "$B/.PackageInfo" <<EOF
name			noto_sans_cjk_kr
version			$VER-$REV
architecture		any
summary			"Noto Sans CJK: Korean, Japanese and Chinese glyphs"
description		"The static Regular and Bold faces of Noto Sans CJK KR. Without a
CJK font every Korean, Japanese and Chinese character is drawn as an empty box.
HaikuPorts' noto_sans_cjk_jp package cannot be used here: it ships a variable
font, and the arm64 bootstrap freetype (2.6.3) has no variable-font support, so
it is installed but never loaded. All language variants of Noto Sans CJK share
one glyph set, so this covers Japanese and Chinese as well."
packager		"The RENKU project"
vendor			"Haiku Project"
licenses {
	"SIL Open Font License v1.1"
}
copyrights {
	"2014-2021 Adobe, Google and the Noto Project Authors"
}
provides {
	noto_sans_cjk_kr = $VER
}
requires {
	haiku
}
urls {
	"https://github.com/notofonts/noto-cjk"
}
EOF

mkdir -p "$OUTDIR"
OUT=$OUTDIR/noto_sans_cjk_kr-$VER-$REV-any.hpkg
rm -f "$OUT"
( cd "$B" && "$PKG" create -q "$OUT" )
ls -la "$OUT"
