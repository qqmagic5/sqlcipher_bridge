#!/usr/bin/env bash

set -euo pipefail

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
readonly LIBRARY_EXTENSION=dylib

readonly SRC_DIR="$PROJECT_ROOT/external"
readonly PREBUILT_DIR="$PROJECT_ROOT/prebuilt"

readonly TARGET_OS=ios
readonly IOS_MIN_VERSION=12.0
readonly TARGET_ARCH="arm64"

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
echo "TARGET_ARCH: $TARGET_ARCH"
echo ""
echo "OPTIMIZATION_FLAG: $OPTIMIZATION_FLAG"
echo "IOS_MIN_VERSION: $IOS_MIN_VERSION"
echo ""
echo "DEFINES:"
printf '  %s\n' "${DEFINES[@]}"

if [[ $# -ne 1 ]]; then
  echo "Error: platform are required. Use: <device|simulator>." >&2
  exit 1
fi
readonly TARGET_PLATFORM="$1"
echo "TARGET_PLATFORM: $TARGET_PLATFORM"

case "$TARGET_PLATFORM" in
  device)
    SDK_NAME="iphoneos"  
    MIN_VERSION_FLAG="-miphoneos-version-min=${IOS_MIN_VERSION}"
    ;;
  simulator)
    SDK_NAME="iphonesimulator"
    MIN_VERSION_FLAG="-mios-simulator-version-min=${IOS_MIN_VERSION}"
    ;;
  *)
    echo "Error: unsupported platform '$TARGET_PLATFORM'. Use: device or simulator." >&2
    exit 1
    ;;
esac

case "$TARGET_ARCH" in
  arm64)
    IOS_ARCH="arm64"
    ;;
  *)
    echo "Error: unsupported architecture '$TARGET_ARCH'. Use: arm64." >&2
    exit 1
    ;;
esac

HOST_TRIPLET="${IOS_ARCH}-apple-darwin"

SDK_PATH="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
if [[ -z "$SDK_PATH" || ! -d "$SDK_PATH" ]]; then
  echo "Error: SDK not found for $SDK_NAME." >&2
  exit 1
fi

step "Prepare temporary directory..."
TMP_DIR="$(mktemp -d -t "${OUTPUT_LIBRARY_NAME}_XXXXXX")"
readonly TMP_DIR
trap 'rm -rf "$TMP_DIR"' EXIT

step "Changing directory to $TMP_DIR..."
cd "$TMP_DIR"

OPENSSL_LIBRARY_NAME=openssl_bridge
OPENSSL_LIBRARY_FILE="lib${OPENSSL_LIBRARY_NAME}.${LIBRARY_EXTENSION}"
step "Locating $OPENSSL_LIBRARY_NAME..."
OPENSSL_ROOT_DIR="$(get_dart_package_path "$OPENSSL_LIBRARY_NAME" "$PROJECT_ROOT")"
readonly OPENSSL_PREBUILT_DIR="$OPENSSL_ROOT_DIR/prebuilt/$TARGET_OS/$TARGET_PLATFORM/$TARGET_ARCH"
if [ ! -f "$OPENSSL_PREBUILT_DIR/$OPENSSL_LIBRARY_FILE" ]; then
  echo "Error: $OPENSSL_LIBRARY_FILE not found at $OPENSSL_PREBUILT_DIR" >&2
  exit 1
fi
OPENSSL_INCLUDE_DIR="$OPENSSL_PREBUILT_DIR/include"

step "Configuring library..."
CFLAGS=(
  "$OPTIMIZATION_FLAG"
  "${DEFINES[*]}"
  "-I${OPENSSL_INCLUDE_DIR}"
  "-arch $IOS_ARCH"
  "-isysroot $SDK_PATH"
  "$MIN_VERSION_FLAG"
)
echo "CFLAGS: ${CFLAGS[*]}"
LDFLAGS=(
  "-Wl,-headerpad_max_install_names"
  "-L${OPENSSL_PREBUILT_DIR}"
  "-l${OPENSSL_LIBRARY_NAME}"
)
echo "LDFLAGS: ${LDFLAGS[*]}"
CC=clang
echo "CC: $CC"

CC="$CC" \
CFLAGS="${DEFINES[*]} ${CFLAGS[*]}" \
LDFLAGS="${LDFLAGS[*]}" \
  "$SRC_DIR/configure" \
  --host="$HOST_TRIPLET" \
  --disable-tcl \
  > /dev/null

step "Building library..."
make -j"$(sysctl -n hw.logicalcpu)" so > /dev/null

step "Creating output directory..."
readonly OUT_DIR="$PREBUILT_DIR/$TARGET_OS/$TARGET_PLATFORM/$TARGET_ARCH"
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

install_name_tool \
  -id "@rpath/lib${OUTPUT_LIBRARY_NAME}.${LIBRARY_EXTENSION}" \
  "$OUT_FILE"
install_name_tool \
  -add_rpath "@loader_path" \
  "$OUT_FILE"

step "$OUTPUT_LIBRARY_NAME build completed."
echo "Output: $OUT_FILE"
