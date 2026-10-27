#!/bin/bash
# 生成 GitHub Release 用的 tar.gz。
#
# 文件清单直接取 npm pack，不手工维护——手工列表漏过文件（mcp-bridge.js），
# 而那种漏法只有别人装完才会暴露，本地永远测不出来。

set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(node -p "require('./package.json').version")
NAME="dsh-cua-${VERSION}-macos-universal"
OUT="dist/${NAME}.tar.gz"

mkdir -p dist
rm -rf "dist/${NAME}" "$OUT"

TARBALL=$(npm pack --silent | tail -n 1)
if [ ! -f "$TARBALL" ]; then
  echo "错误: npm pack 没产出 tarball" >&2
  exit 1
fi
mkdir -p "dist/${NAME}"
tar xzf "$TARBALL" -C "dist/${NAME}" --strip-components=1
rm -f "$TARBALL"

# 装完就能跑的必备件，缺一个当场失败
for f in index.js client.js mcp-bridge.js cordis.patch.yml package.json \
         bin/cua-mcp bin/cua-live bin/cua-overlay; do
  if [ ! -e "dist/${NAME}/$f" ]; then
    echo "错误: 包里缺 $f" >&2
    exit 1
  fi
done

tar czf "$OUT" -C dist "$NAME"
rm -rf "dist/${NAME}"

echo "已生成 $OUT"
echo "--- 内容 ---"
tar tzf "$OUT"
