#!/bin/bash
# 生成 GitHub Release 用的 tar.gz。
#
# 文件清单直接取 npm pack，不手工维护——手工列表漏过文件（mcp-bridge.js），
# 而那种漏法只有别人装完才会暴露，本地永远测不出来。

set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(node -p "require('./package.json').version")
# 资产名与包内顶层目录都不带版本号，是有意的。
# README 的安装命令用的是 releases/latest/download/<name>：latest 永远指向
# 最新一个已发布 release，而每版 release 里放的都是同一个资产名——于是这条
# 命令永久有效，不需要发版时改 README 里的版本号。
# 版本号曾经嵌在名字里（dsh-cua-1.14.0-macos-universal.tar.gz），后果是
# latest 指向 1.15.0 之后，那条命令去 1.15.0 的 release 里找 1.14.0 的文件，
# 直接 404。而且包内顶层目录带版本号时，README 里写的「解压出 dsh-cua/」
# 和后面的 cp -R dsh-cua 也全都是错的。
# 回溯旧版靠 tag：每个 release 各自带一份同名资产，指定 tag 下载即可。
NAME="dsh-cua"
OUT="dist/dsh-cua-macos-universal.tar.gz"

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
