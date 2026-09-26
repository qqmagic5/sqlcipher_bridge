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
readonly LIBRARY_EXTENSION=so

readonly SRC_DIR="$PROJECT_ROOT/external"
readonly PREBUILT_DIR="$PROJECT_ROOT/prebuilt"

readonly TARGET_OS=linux

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
echo ""
echo "DEFINES:"
printf '  %s\n' "${DEFINES[@]}"

step "Detecting target architecture..."
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64)
    TARGET_ARCH="x64"
    ;;
  aarch64|arm64)
    TARGET_ARCH="arm64"
    ;;
  *)
    echo "Error: unsupported architecture '$HOST_ARCH'." >&2
    exit 1
    ;;
esac
readonly TARGET_ARCH
echo "TARGET_ARCH: $TARGET_ARCH"

step "Prepare temporary directory..."
TMP_DIR="$(mktemp -d -t "${OUTPUT_LIBRARY_NAME}_XXXXXX")"
readonly TMP_DIR
trap 'rm -rf "$TMP_DIR"' EXIT

step "Changing directory to $TMP_DIR..."
cd "$TMP_DIR"

# Поиск скомпилированной библиотеки openssl в prebuilt каталоге пакета
# openssl_bridge.
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
CFLAGS="$OPTIMIZATION_FLAG"
CC=gcc
echo "CC: $CC"
echo "CFLAGS: $CFLAGS"

# Для возможности применения скомпилированных библиотек из пакетов при
# сборке других библиотек используется следующий принцип. Библиотека при
# сборке определяет SONAME имя такое, чтобы случайно вместо библиотеки
# из пакета не была загружена системная библиотека. Это имя для удобства
# формируется на основе имени пакета. Имя файла и SONAME имя делаются
# одинаковыми. При компиляции библиотеки зависимая библиотека привязывается
# на основе SONAME. Поэтому при компиляции выполняется поиск требуемой
# библиотеки, чтобы получить SONAME. Путь к найденной библиотеке и имя файла
# указываются через LDFLAGS. Когда программе потребуется наличие библиотеки
# при выполнении, то поиск будет выполняться по SONAME требуемой библиотеки,
# которое записывается при сборке в динамическую секцию библиотеки. Для удобства
# имя файла и SONAME имя делаются одинаковыми. Кодировать версию в SONAME
# не требуется, т.к. версия библиотеки определяется версией пакета,
# из которого берется скомпилированная библиотеки.
CC="$CC" \
CFLAGS="${DEFINES[*]} ${CFLAGS[*]} -I${OPENSSL_INCLUDE_DIR}" \
LDFLAGS="-L${OPENSSL_PREBUILT_DIR} -l$OPENSSL_LIBRARY_NAME" \
  "$SRC_DIR/configure" \
  --disable-tcl \
  > /dev/null

step "Building library..."
make -j"$(nproc)" libsqlite3.so > /dev/null

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

# Настройка поиска зависимых библиотек в том же каталоге, в котором
# находится текущая библиотека.
patchelf --set-rpath "\$ORIGIN" "$OUT_LIBRARY_PATH"

# Изменение SONAME для возможности привязки библиотеки к другим проектам.
OUT_LIBRARY_SONAME=$OUT_LIBRARY_FILE
patchelf --set-soname "$OUT_LIBRARY_SONAME" "$OUT_LIBRARY_PATH"

step "$OUTPUT_LIBRARY_NAME build completed."
echo "Output: $OUT_LIBRARY_PATH"
