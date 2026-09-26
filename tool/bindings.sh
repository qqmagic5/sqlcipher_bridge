#!/usr/bin/env bash

set -euo pipefail

DEFINES=(
  -DSQLITE_THREADSAFE=1
  -DSQLITE_ENABLE_FTS5
  -DSQLITE_ENABLE_RTREE
  -DSQLITE_ENABLE_COLUMN_METADATA
  -DSQLITE_ENABLE_MATH_FUNCTIONS
  -DSQLITE_ENABLE_UPDATE_DELETE_LIMIT
  -DSQLITE_DEFAULT_FOREIGN_KEYS=1
  
  # sqlcipher
  -DSQLITE_HAS_CODEC=1
  -DSQLITE_TEMP_STORE=2
  -DSQLITE_EXTRA_INIT=sqlcipher_extra_init
  -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown
)
readonly DEFINES

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly PROJECT_ROOT

readonly SRC_DIR="$PROJECT_ROOT/external"

readonly OUTPUT_LIBRARY_NAME=sqlcipher_bridge
readonly PACKAGE_NAME=sqlcipher_bridge
readonly API_FILE="$PROJECT_ROOT/lib/api.g.dart"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/tool/_utils.sh"

step "Prepare temporary directory..."
TMP_DIR="$(mktemp -d -t "${OUTPUT_LIBRARY_NAME}_XXXXXX")"
readonly TMP_DIR
trap 'rm -rf "$TMP_DIR"' EXIT

step "Changing directory to $TMP_DIR..."
cd "$TMP_DIR"

step "Configuring library..."
echo "DEFINES:"
printf '  %s\n' "${DEFINES[@]}"

CFLAGS="${DEFINES[*]}" "$SRC_DIR/configure" > /dev/null

step "Generating amalgamation files..."
make sqlite3.c > /dev/null
if [ ! -f "$TMP_DIR/sqlite3.c" ] || [ ! -f "$TMP_DIR/sqlite3.h" ]; then
  echo "Amalgamation generation failed" >&2
  exit 1
fi

step "Changing directory to $PROJECT_ROOT..."
cd "$PROJECT_ROOT"

ARGS=()

for define in "${DEFINES[@]}"; do
  ARGS+=(--cflag "$define")
done

ARGS+=(--header "$TMP_DIR/sqlite3.h")

step "Generating bindings..."
dart run libffigen:make \
  "${ARGS[@]}" \
  --asset-package $PACKAGE_NAME \
  --asset-id $OUTPUT_LIBRARY_NAME \
  --output "$API_FILE"
