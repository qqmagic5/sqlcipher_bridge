#!/usr/bin/env bash

set -euo pipefail

step() {
  echo "==> $*"
}

# Определяет на основе .dart_tool/package_config.json путь к требуемому
# пакету.
#
# Аргументы:
# 1: Имя требуемого пакета
# 2: Путь к корню текущего пакета
get_dart_package_path() {
  local package_name="$1"
  local project_root="$2"
  local package_config="$project_root/.dart_tool/package_config.json"

  if [ ! -f "$package_config" ]; then
    echo "Error: $package_config not found. Run 'dart pub get' first." >&2
    return 1
  fi

  local package_uri
  package_uri=$(python3 -c "
import json, sys
try:
    with open('$package_config') as f:
        data = json.load(f)
    for pkg in data.get('packages', []):
        if pkg['name'] == '$package_name':
            print(pkg['rootUri'])
            sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
")

  if [ -z "$package_uri" ]; then
    echo "Error: package '$package_name' not found in $package_config" >&2
    return 1
  fi

  if [[ "$package_uri" == file://* ]]; then
    echo "${package_uri#file://}"
  else
    echo "$project_root/.dart_tool/$package_uri"
  fi
}
