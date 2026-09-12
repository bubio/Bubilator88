#!/usr/bin/env bash
# Bubilator88C.def と CApi.swift の @_cdecl エクスポート一覧が一致するか検証する。
#
# なぜ必要か:
#   Swift の @_cdecl は C リンケージを与えるが __declspec(dllexport) は付けない。
#   そのため Windows では Sources/CApi/Bubilator88C.def の EXPORTS 節が
#   「DLL から何を公開するか」の唯一の定義になっている。
#   @_cdecl を足して .def に書き忘れても *ビルドは通る* — DLL からシンボルが
#   消えるだけで、C# 側の P/Invoke が実行時に落ちる。静かに壊れる典型なので
#   機械的に照合する。
#
# 使い方:
#   ./scripts/check-capi-exports.sh        # 差分があれば exit 1
#
# macOS / Linux / Git Bash (Windows) のいずれでも動く。
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# コアは別リポジトリ (bubio/Bubilator88Core)。既定では隣の clone を見る。
core_dir="${BUBILATOR88_CORE_DIR:-$repo_root/../Bubilator88Core}"
swift_src="$core_dir/Sources/CApi/CApi.swift"
def_file="$core_dir/Sources/CApi/Bubilator88C.def"

for f in "$swift_src" "$def_file"; do
    [ -f "$f" ] || { echo "error: $f が見つかりません" >&2; exit 2; }
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# CApi.swift の @_cdecl("name") からシンボル名を抽出
grep -o '@_cdecl("[^"]*")' "$swift_src" \
    | sed 's/@_cdecl("//; s/")$//' \
    | sort -u > "$tmp_dir/swift.txt"

# .def の EXPORTS 節（; はコメント行）からシンボル名を抽出
awk '
    /^[[:space:]]*;/ { next }
    /^[[:space:]]*EXPORTS[[:space:]]*$/ { in_exports = 1; next }
    in_exports && NF { print $1 }
' "$def_file" | sort -u > "$tmp_dir/def.txt"

swift_count=$(grep -c '' "$tmp_dir/swift.txt" || true)
def_count=$(grep -c '' "$tmp_dir/def.txt" || true)

if diff -u "$tmp_dir/def.txt" "$tmp_dir/swift.txt" > "$tmp_dir/diff.txt"; then
    echo "OK: @_cdecl と .def EXPORTS は一致しています ($swift_count symbols)"
    exit 0
fi

echo "NG: CApi.swift の @_cdecl と Bubilator88C.def の EXPORTS が食い違っています。" >&2
echo "  CApi.swift: $swift_count symbols / Bubilator88C.def: $def_count symbols" >&2
echo >&2

comm -13 "$tmp_dir/def.txt" "$tmp_dir/swift.txt" | while read -r sym; do
    [ -n "$sym" ] && echo "  + $sym  (@_cdecl にあるが .def に無い → DLL から公開されず P/Invoke が実行時に失敗する)" >&2
done
comm -23 "$tmp_dir/def.txt" "$tmp_dir/swift.txt" | while read -r sym; do
    [ -n "$sym" ] && echo "  - $sym  (.def にあるが @_cdecl に無い → Windows のリンクが失敗する)" >&2
done

exit 1
