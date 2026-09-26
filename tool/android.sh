#!/usr/bin/env bash

set -euo pipefail

readonly ANDROID_MIN_API_LEVEL=21
readonly OPTIMIZATION_FLAG="-O3"

DEFINES=(
  -DSQLITE_THREADSAFE=1
  -DSQLITE_ENABLE_FTS5
  -DSQLITE_ENABLE_RTREE
  -DSQLITE_ENABLE_COLUMN_METADATA
  -DSQLITE_ENABLE_MATH_FUNCTIONS
  -DSQLITE_ENABLE_UPDATE_DELETE_LIMIT
  -DSQLITE_DEFAULT_FOREIGN_KEYS=1

  #sqlcipher
  -DSQLITE_HAS_CODEC=1
  -DSQLITE_TEMP_STORE=2
  -DSQLITE_EXTRA_INIT=sqlcipher_extra_init
  -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown
)
readonly DEFINES

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly PROJECT_ROOT

readonly OUTPUT_LIBRARY_NAME=sqlcipher_bridge
readonly VENDOR_LIBRARY_NAME=sqlite3
readonly LIBRARY_EXTENSION=so

readonly SRC_DIR="$PROJECT_ROOT/external"
readonly PREBUILT_DIR="$PROJECT_ROOT/prebuilt"

readonly TARGET_OS=android

# shellcheck source=/dev/null
source "$PROJECT_ROOT/tool/_utils.sh"

step "Build options"
echo "PROJECT_ROOT: $PROJECT_ROOT"
echo ""
echo "SRC_DIR: $SRC_DIR"
echo "PREBUILT_DIR: $PREBUILT_DIR"
echo ""
echo "OUTPUT_LIBRARY_NAME: $OUTPUT_LIBRARY_NAME"
echo "VENDOR_LIBRARY_NAME: $VENDOR_LIBRARY_NAME"
echo "LIBRARY_EXTENSION: $LIBRARY_EXTENSION"
echo ""
echo "TARGET_OS: $TARGET_OS"
echo ""
echo "OPTIMIZATION_FLAG: $OPTIMIZATION_FLAG"
echo "ANDROID_MIN_API_LEVEL: $ANDROID_MIN_API_LEVEL"
echo ""
echo "DEFINES:"
printf '  %s\n' "${DEFINES[@]}"

if [[ $# -ne 1 ]]; then
  echo "Error: architecture is required. Use: arm64, arm32, x64." >&2
  exit 1
fi
TARGET_ARCH="$1"
case "$TARGET_ARCH" in
  arm64)
    TRIPLET="aarch64-linux-android"
    ;;
  arm32)
    TRIPLET="armv7a-linux-androideabi"
    ;;
  x64)
    TRIPLET="x86_64-linux-android"
    ;;
  *)
    echo "Unsupported architecture: $TARGET_ARCH" >&2
    exit 1
    ;;
esac
echo "TARGET_ARCH: $TARGET_ARCH"

if [[ -z "${ANDROID_NDK_ROOT:-}" ]]; then
  echo "Error: ANDROID_NDK_ROOT is not set." >&2
  exit 1
fi
echo "NDK: $ANDROID_NDK_ROOT"

# Android toolchain хранит каталоги с компилятором внутри папок,
# в пути к которым есть секция HOST_TAG, обозначающая платформу,
# на которой запускается компилятор. Значение HOST_TAG зависит
# от ОС и от архитектуры процессора.
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

echo "HOST_OS: $HOST_OS"
echo "HOST_ARCH: $HOST_ARCH"

# В текущий момент используется сборка только на linux, при необходимости
# могут быть добавлены другие платформы сборки.
case "$HOST_OS" in
  Linux)
    case "$HOST_ARCH" in
      x86_64)  HOST_TAG="linux-x86_64" ;;
      aarch64) HOST_TAG="linux-aarch64" ;;
      *)       
        echo "Error: Unsupported Linux architecture: $HOST_ARCH. Supported: x86_64, aarch64." >&2
        exit 1 
        ;;
    esac
    ;;
  *)
    echo "Unsupported host OS: $HOST_OS" >&2
    exit 1
    ;;
esac
echo "HOST_TAG: $HOST_TAG"

TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG"
if [ ! -d "$TOOLCHAIN" ]; then
  echo "Error: NDK toolchain not found for host $HOST_OS/$HOST_ARCH:" >&2
  echo "  $TOOLCHAIN" >&2
  exit 1
fi
echo "TOOLCHAIN: $TOOLCHAIN"

case "$TARGET_ARCH" in
  arm64)
    CC="$TOOLCHAIN/bin/aarch64-linux-android${ANDROID_MIN_API_LEVEL}-clang"
    ;;
  arm32)
    CC="$TOOLCHAIN/bin/armv7a-linux-androideabi${ANDROID_MIN_API_LEVEL}-clang"
    ;;
  x64)
    CC="$TOOLCHAIN/bin/x86_64-linux-android${ANDROID_MIN_API_LEVEL}-clang"
    ;;
esac

if [ ! -x "$CC" ]; then
  echo "Error: Clang not found in the NDK toolchain: $CC" >&2
  exit 1
fi

step "Prepare temporary directory..."
TMP_DIR="$(mktemp -d -t "${OUTPUT_LIBRARY_NAME}_XXXXXX")"
readonly TMP_DIR
trap 'rm -rf "$TMP_DIR"' EXIT

step "Changing directory to $TMP_DIR..."
cd "$TMP_DIR"

# Поиск скомпилированной библиотеки openssl в prebuilt каталоге пакета
# openssl_bridge. Должно быть выполнено требование:
# openssl_bridge.ANDROID_MIN_API_LEVEL <= sqlcipher_bridge.ANDROID_MIN_API_LEVEL.
OPENSSL_LIBRARY_NAME=openssl_bridge
OPENSSL_LIBRARY_FILE=lib$OPENSSL_LIBRARY_NAME.$LIBRARY_EXTENSION
step "Locating $OPENSSL_LIBRARY_NAME..."
OPENSSL_ROOT_DIR="$(get_dart_package_path $OPENSSL_LIBRARY_NAME "$PROJECT_ROOT")"
echo "Found $OPENSSL_LIBRARY_NAME at: $OPENSSL_ROOT_DIR"
readonly OPENSSL_PREBUILT_DIR="$OPENSSL_ROOT_DIR/prebuilt/$TARGET_OS/$TARGET_ARCH/"
if [ ! -f "$OPENSSL_PREBUILT_DIR/$OPENSSL_LIBRARY_FILE" ]; then
  echo "Error: $OPENSSL_LIBRARY_FILE not found at $OPENSSL_PREBUILT_DIR" >&2
  exit 1
fi
OPENSSL_INCLUDE_DIR="$OPENSSL_PREBUILT_DIR/include"

step "Configuring library..."
CFLAGS=(
  "$OPTIMIZATION_FLAG"
  "-I${OPENSSL_INCLUDE_DIR}"
  "--target=${TRIPLET}${ANDROID_MIN_API_LEVEL}"
)
echo "CFLAGS: ${CFLAGS[*]}"
LDFLAGS=(
  "-L${OPENSSL_PREBUILT_DIR}"
  "-l${OPENSSL_LIBRARY_NAME}"
  "-llog"
)
echo "LDFLAGS: ${LDFLAGS[*]}"
echo "CC: $CC"

CC="$CC" \
CFLAGS="${DEFINES[*]} ${CFLAGS[*]}" \
LDFLAGS="${LDFLAGS[*]}" \
  "$SRC_DIR/configure" \
  --host="$TRIPLET" \
  --disable-tcl \
  > /dev/null

step "Building library..."
make -j"$(nproc)" > /dev/null

step "Creating output directory..."
readonly OUT_DIR="$PREBUILT_DIR/$TARGET_OS/$TARGET_ARCH"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

step "Copying files to output directory..."
readonly OUT_LIBRARY_FILE=lib$OUTPUT_LIBRARY_NAME.$LIBRARY_EXTENSION
readonly OUT_LIBRARY_PATH="$OUT_DIR/$OUT_LIBRARY_FILE"
cp -L "$TMP_DIR/lib$VENDOR_LIBRARY_NAME.$LIBRARY_EXTENSION" "$OUT_LIBRARY_PATH"
mkdir -p "$OUT_DIR/include"
cp "$TMP_DIR/sqlite3.h" "$OUT_DIR/include/"
if ! test -s "$OUT_LIBRARY_PATH"; then
  echo "Error: output library is missing or empty: $OUT_LIBRARY_PATH" >&2
  exit 1
fi
if ! test -s "$OUT_DIR/include/sqlite3.h"; then
  echo "Error: output library is missing or empty: $OUT_LIBRARY_PATH" >&2
  exit 1
fi

patchelf --set-rpath "\$ORIGIN" "$OUT_LIBRARY_PATH"

OUT_LIBRARY_SONAME=$OUT_LIBRARY_FILE
patchelf --set-soname "$OUT_LIBRARY_SONAME" "$OUT_LIBRARY_PATH"

step "$OUTPUT_LIBRARY_NAME build completed."
echo "Output: $OUT_LIBRARY_PATH"
