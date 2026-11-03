#!/usr/bin/env bash
# 下載 sherpa-onnx 預編譯靜態函式庫到 Vendor/sherpa-onnx/（已 gitignore）：
#   iOS   → sherpa-onnx.xcframework + onnxruntime.xcframework（HuggingFace csukuangfj/sherpa-onnx-libs）
#   macOS → macos/{include,lib}（GitHub release osx-universal2-static-no-tts）
# clone 後先跑一次這個腳本才能建置 macOS / iOS 版。
set -euo pipefail

VERSION="${SHERPA_ONNX_VERSION:-1.12.21}"
MAC_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/sherpa-onnx-v${VERSION}-osx-universal2-static-no-tts.tar.bz2"
URL="https://huggingface.co/csukuangfj/sherpa-onnx-libs/resolve/main/sherpa-onnx-v${VERSION}-ios-no-tts.tar.bz2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/sherpa-onnx"

if [[ -f "$DEST/VERSION" && "$(cat "$DEST/VERSION")" == "$VERSION" ]]; then
  echo "sherpa-onnx $VERSION 已存在：$DEST"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "下載 sherpa-onnx v$VERSION (iOS, no-tts)…"
curl -fL --progress-bar -o "$TMP/ios.tar.bz2" "$URL"
tar xjf "$TMP/ios.tar.bz2" -C "$TMP"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$TMP/build-ios-no-tts/sherpa-onnx.xcframework" "$DEST/"
# onnxruntime.xcframework 在壓縮檔裡是 symlink，-L 取實體
cp -RL "$TMP/build-ios-no-tts/ios-onnxruntime/onnxruntime.xcframework" "$DEST/"

echo "下載 sherpa-onnx v$VERSION (macOS universal2 static, ~360MB)…"
curl -fL --progress-bar -o "$TMP/mac.tar.bz2" "$MAC_URL"
tar xjf "$TMP/mac.tar.bz2" -C "$TMP"
MAC_SRC="$TMP/sherpa-onnx-v${VERSION}-osx-universal2-static-no-tts"
mkdir -p "$DEST/macos/lib"
cp -R "$MAC_SRC/include" "$DEST/macos/"
for l in sherpa-onnx-c-api sherpa-onnx-core sherpa-onnx-fst sherpa-onnx-fstfar sherpa-onnx-kaldifst-core \
         kaldi-decoder-core kaldi-native-fbank-core kissfft-float ssentencepiece_core onnxruntime; do
  cp "$MAC_SRC/lib/lib$l.a" "$DEST/macos/lib/"
done

echo "$VERSION" > "$DEST/VERSION"
echo "完成：$DEST"
