#!/bin/bash
# IPA 打包脚本 —— 供 GitHub Actions 调用
#
# 为什么不直接用 xcodebuild -exportArchive：
#   无签名场景下它会静默失败（ipa 目录为空但退出码为 0）。
#   所以改为从 .xcarchive 中取 .app，按 IPA 规范手工打包。
#
# 用法: ./make-ipa.sh <xcarchive路径> <输出目录>

set -euo pipefail

ARCHIVE_PATH="${1:-build/NetaL.xcarchive}"
OUTPUT_DIR="${2:-.}"

echo "[1/4] Archive（无签名）"
xcodebuild \
  -project NetaL.xcodeproj \
  -scheme NetaL \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  archive > archive-log.txt 2>&1 || {
    echo "Archive 失败:"
    grep -E "error:" archive-log.txt | head -30
    exit 1
  }

echo "[2/4] 定位 .app"
APP_PATH=$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -name "*.app" | head -1)
if [ -z "$APP_PATH" ]; then
  echo "未找到 .app，目录结构:"
  find "$ARCHIVE_PATH/Products" -maxdepth 3 | head -20
  exit 1
fi
echo "  APP: $APP_PATH"

echo "[3/4] 构造 Payload 结构"
rm -rf "$OUTPUT_DIR/unsigned-ipa"
mkdir -p "$OUTPUT_DIR/unsigned-ipa/Payload"
cp -R "$APP_PATH" "$OUTPUT_DIR/unsigned-ipa/Payload/"

echo "[4/4] 打包为 IPA"
cd "$OUTPUT_DIR/unsigned-ipa"
zip -qry "../NetaL-unsigned.ipa" Payload
cd ..
rm -rf "$OUTPUT_DIR/unsigned-ipa"

ls -lh "$OUTPUT_DIR/NetaL-unsigned.ipa"
echo "IPA 内容:"
unzip -l "$OUTPUT_DIR/NetaL-unsigned.ipa" | head -20
