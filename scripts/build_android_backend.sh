#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$APP_ROOT/android/app/build/generated/backend-jniLibs}"
OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"
NDK_VERSION="r26b"
NDK_ARCHIVE="android-ndk-${NDK_VERSION}-linux.zip"
NDK_URL="https://dl.google.com/android/repository/${NDK_ARCHIVE}"
WEB_VERSION="3.63.0"
WEB_ARCHIVE="dist.tar.gz"
WEB_URL="https://github.com/AlistGo/alist-web/releases/download/${WEB_VERSION}/${WEB_ARCHIVE}"
WEB_SHA256="336f86ec867045c8b401a5d80a1e51af495d7d2487e23f48b925030bbebffe2e"
HOST_TAG="linux-x86_64"
ANDROID_API="24"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/alist"
CONFIGURED_NDK_ROOT="${ANDROID_NDK_ROOT:-${NDK_ROOT:-}}"
NDK_ROOT="${CONFIGURED_NDK_ROOT:-$CACHE_ROOT/android-ndk-${NDK_VERSION}}"
TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG"

for command_name in go curl tar unzip realpath sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
done

if [[ ! -f "$APP_ROOT/go.mod" || ! -f "$APP_ROOT/public/public.go" ]]; then
  printf 'script must run from an AList source tree: %s\n' "$APP_ROOT" >&2
  exit 1
fi

DOWNLOAD_DIR=""
WEB_WORK=""
WEB_STATE="none"
WEB_BACKUP=""
BUILD_OUTPUT=""

restore_web() {
  if [[ "$WEB_STATE" == "restore" ]]; then
    rm -rf "$APP_ROOT/public/dist"
    mkdir -p "$APP_ROOT/public/dist"
    cp -a "$WEB_BACKUP/." "$APP_ROOT/public/dist/"
  elif [[ "$WEB_STATE" == "created" ]]; then
    rm -rf "$APP_ROOT/public/dist"
  fi
}

cleanup() {
  restore_web
  if [[ -n "$DOWNLOAD_DIR" ]]; then
    rm -rf "$DOWNLOAD_DIR"
  fi
  if [[ -n "$WEB_WORK" ]]; then
    rm -rf "$WEB_WORK"
  fi
  if [[ -n "$BUILD_OUTPUT" ]]; then
    rm -rf "$BUILD_OUTPUT"
  fi
}
trap cleanup EXIT

prepare_ndk() {
  local compiler="$TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang"
  if [[ -x "$compiler" ]]; then
    return
  fi
  if [[ -n "$CONFIGURED_NDK_ROOT" ]]; then
    printf 'configured Android NDK is incomplete: %s\n' "$NDK_ROOT" >&2
    exit 1
  fi

  mkdir -p "$CACHE_ROOT"
  DOWNLOAD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/alist-android-ndk.XXXXXX")"
  local archive="$DOWNLOAD_DIR/$NDK_ARCHIVE"
  local extracted="$DOWNLOAD_DIR/extracted"
  printf 'downloading Android NDK %s\n' "$NDK_VERSION"
  curl -fL --retry 3 --retry-delay 2 "$NDK_URL" -o "$archive"
  mkdir -p "$extracted"
  unzip -q "$archive" -d "$extracted"
  if [[ ! -x "$extracted/android-ndk-${NDK_VERSION}/toolchains/llvm/prebuilt/$HOST_TAG/bin/aarch64-linux-android${ANDROID_API}-clang" ]]; then
    printf 'downloaded NDK does not contain the expected Linux toolchain\n' >&2
    exit 1
  fi
  rm -rf "$NDK_ROOT"
  mv "$extracted/android-ndk-${NDK_VERSION}" "$NDK_ROOT"
}

prepare_web() {
  if [[ -f "$APP_ROOT/public/dist/index.html" ]]; then
    return
  fi
  WEB_WORK="$(mktemp -d "${TMPDIR:-/tmp}/alist-android-web.XXXXXX")"
  if [[ -d "$APP_ROOT/public/dist" ]]; then
    WEB_STATE="restore"
    WEB_BACKUP="$WEB_WORK/original-dist"
    mkdir -p "$WEB_BACKUP"
    cp -a "$APP_ROOT/public/dist/." "$WEB_BACKUP/"
  else
    WEB_STATE="created"
  fi
  mkdir -p "$APP_ROOT/public/dist"
  local archive="$WEB_WORK/$WEB_ARCHIVE"
  printf 'downloading AList Web %s\n' "$WEB_VERSION"
  curl -fL --retry 3 --retry-delay 2 "$WEB_URL" -o "$archive"
  printf '%s  %s\n' "$WEB_SHA256" "$archive" | sha256sum -c -
  mkdir -p "$WEB_WORK/extracted"
  tar -xzf "$archive" -C "$WEB_WORK/extracted"
  if [[ -f "$WEB_WORK/extracted/dist/index.html" ]]; then
    cp -a "$WEB_WORK/extracted/dist/." "$APP_ROOT/public/dist/"
  elif [[ -f "$WEB_WORK/extracted/index.html" ]]; then
    cp -a "$WEB_WORK/extracted/." "$APP_ROOT/public/dist/"
  else
    printf 'AList Web archive does not contain dist/index.html\n' >&2
    exit 1
  fi
}

build_abi() {
  local abi="$1"
  local goarch="$2"
  local goarm="$3"
  local compiler="$4"
  local output="$BUILD_OUTPUT/$abi/libalist.so"
  mkdir -p "$(dirname "$output")"
  printf 'building Android %s shared library\n' "$abi"
  if [[ "$goarch" == "arm" ]]; then
    GOOS=android GOARCH="$goarch" GOARM="$goarm" CGO_ENABLED=1 CC="$compiler" \
      go build -buildmode=c-shared -o "$output" \
      -ldflags="-w -s -X github.com/alist-org/alist/v3/internal/conf.WebVersion=$WEB_VERSION" \
      -tags=jsoniter .
  else
    GOOS=android GOARCH="$goarch" CGO_ENABLED=1 CC="$compiler" \
      go build -buildmode=c-shared -o "$output" \
      -ldflags="-w -s -X github.com/alist-org/alist/v3/internal/conf.WebVersion=$WEB_VERSION" \
      -tags=jsoniter .
  fi
  rm -f "$BUILD_OUTPUT/$abi/libalist.h"
  "$TOOLCHAIN/bin/llvm-strip" "$output"
  chmod 0755 "$output"
  if [[ ! -s "$output" ]]; then
    printf 'Android %s shared library is empty\n' "$abi" >&2
    exit 1
  fi
  local symbols
  symbols="$("$TOOLCHAIN/bin/llvm-nm" -D --defined-only "$output" 2>/dev/null || true)"
  for symbol in Java_com_alist_android_NativeBridge_start Java_com_alist_android_NativeBridge_stop Java_com_alist_android_NativeBridge_lastError; do
    case "$symbols" in
      *"$symbol"*) ;;
      *)
        printf 'Android %s library is missing JNI symbol: %s\n' "$abi" "$symbol" >&2
        exit 1
        ;;
    esac
  done
}

prepare_ndk
prepare_web
BUILD_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/alist-android-output.XXXXXX")"
build_abi arm64-v8a arm64 "" "$TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang"
build_abi armeabi-v7a arm 7 "$TOOLCHAIN/bin/armv7a-linux-androideabi${ANDROID_API}-clang"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
cp -a "$BUILD_OUTPUT/." "$OUTPUT_DIR/"
printf 'Android JNI libraries written to %s\n' "$OUTPUT_DIR"
