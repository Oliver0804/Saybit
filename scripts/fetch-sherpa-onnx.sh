#!/usr/bin/env bash
# 下載 sherpa-onnx 預編譯靜態函式庫到 Vendor/sherpa-onnx/（已 gitignore）：
#   iOS   → sherpa-onnx.xcframework + onnxruntime.xcframework（HuggingFace csukuangfj/sherpa-onnx-libs）
#   macOS → macos/{include,lib}（GitHub release osx-universal2-static-no-tts）
# clone 後先跑一次這個腳本才能建置 macOS / iOS 版。
set -euo pipefail

#
# 這些靜態庫會被連結進出貨的二進位，所以每個 tarball 都要比對寫死的 SHA-256；
# iOS 來源釘在 HuggingFace 的特定 commit，而不是可變的 resolve/main。
# 升級版本時：更新 VERSION / HF_COMMIT / 兩個 SHA256，或用環境變數
#   SHERPA_ONNX_VERSION + SHERPA_ONNX_HF_COMMIT + SHERPA_ONNX_IOS_SHA256 + SHERPA_ONNX_MAC_SHA256 覆寫。
set -euo pipefail

DEFAULT_VERSION="1.12.21"
VERSION="${SHERPA_ONNX_VERSION:-$DEFAULT_VERSION}"
if [[ "$VERSION" == "$DEFAULT_VERSION" ]]; then
  # 2026-11-03 取得；iOS 與 HF x-linked-etag 一致，macOS 與 GitHub release asset digest 一致
  HF_COMMIT="${SHERPA_ONNX_HF_COMMIT:-da78432ea90a1fda33002e933825e3cbf3a5ac78}"
  IOS_SHA256="${SHERPA_ONNX_IOS_SHA256:-c3216b59d03f3157ccb8992e55f2f9a21c14195a4b0b5f408d1d4967f464779c}"
  MAC_SHA256="${SHERPA_ONNX_MAC_SHA256:-b403c87bf10bf55fab55f7a74bc1b37e8b5a487558ada4c85de21378f17c940a}"
else
  HF_COMMIT="${SHERPA_ONNX_HF_COMMIT:?版本 $VERSION 需設定 SHERPA_ONNX_HF_COMMIT}"
  IOS_SHA256="${SHERPA_ONNX_IOS_SHA256:?版本 $VERSION 需設定 SHERPA_ONNX_IOS_SHA256}"
  MAC_SHA256="${SHERPA_ONNX_MAC_SHA256:?版本 $VERSION 需設定 SHERPA_ONNX_MAC_SHA256}"
fi
MAC_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/sherpa-onnx-v${VERSION}-osx-universal2-static-no-tts.tar.bz2"
URL="https://huggingface.co/csukuangfj/sherpa-onnx-libs/resolve/${HF_COMMIT}/sherpa-onnx-v${VERSION}-ios-no-tts.tar.bz2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/sherpa-onnx"

if [[ -f "$DEST/VERSION" && "$(cat "$DEST/VERSION")" == "$VERSION" ]]; then
  echo "sherpa-onnx $VERSION 已存在：$DEST"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 比對 SHA-256，不符就中止
verify_sha256() {
  local file="$1" expected="$2"
  if ! echo "$expected  $file" | shasum -a 256 -c - >/dev/null; then
    echo "錯誤：$(basename "$file") SHA-256 不符" >&2
    echo "  預期 $expected" >&2
    echo "  實際 $(shasum -a 256 "$file" | cut -d' ' -f1)" >&2
    exit 1
  fi
}

# 解壓前檢查：拒絕絕對路徑、含 .. 的項目，以及指向絕對路徑或含 .. 的 symlink
check_tar_paths() {
  local archive="$1" bad
  bad="$(tar tjf "$archive" | awk '/^\// || /(^|\/)\.\.(\/|$)/')"
  if [[ -n "$bad" ]]; then
    echo "錯誤：$(basename "$archive") 含不安全路徑：" >&2
    echo "$bad" >&2
    exit 1
  fi
  bad="$(tar tvjf "$archive" | awk -F' -> ' 'NF > 1 { print $NF }' | awk '/^\// || /(^|\/)\.\.(\/|$)/')"
  if [[ -n "$bad" ]]; then
    echo "錯誤：$(basename "$archive") 含指向外部的 symlink：" >&2
    echo "$bad" >&2
    exit 1
  fi
}

echo "下載 sherpa-onnx v$VERSION (iOS, no-tts)…"
curl -fL --progress-bar -o "$TMP/ios.tar.bz2" "$URL"
verify_sha256 "$TMP/ios.tar.bz2" "$IOS_SHA256"
check_tar_paths "$TMP/ios.tar.bz2"
tar xjf "$TMP/ios.tar.bz2" -C "$TMP"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$TMP/build-ios-no-tts/sherpa-onnx.xcframework" "$DEST/"
# onnxruntime.xcframework 在壓縮檔裡是 symlink，-L 取實體
cp -RL "$TMP/build-ios-no-tts/ios-onnxruntime/onnxruntime.xcframework" "$DEST/"

echo "下載 sherpa-onnx v$VERSION (macOS universal2 static, ~360MB)…"
curl -fL --progress-bar -o "$TMP/mac.tar.bz2" "$MAC_URL"
verify_sha256 "$TMP/mac.tar.bz2" "$MAC_SHA256"
check_tar_paths "$TMP/mac.tar.bz2"
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
