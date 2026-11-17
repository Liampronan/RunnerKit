#!/bin/bash
# Link (or unlink) bin/runnerkit into a user-writable bin directory without sudo.
# Compatible with /bin/bash 3.2 on macOS and Linux.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./install.sh [--bin-dir DIR]
  ./install.sh --uninstall [--bin-dir DIR]
EOF
}

SCRIPT_DIR=$(cd -P "$(dirname "$0")" && pwd)
SOURCE_BIN="${SCRIPT_DIR}/bin/runnerkit"

UNINSTALL=0
CUSTOM_BIN_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --uninstall|-u)
      UNINSTALL=1
      shift
      ;;
    --bin-dir)
      if [ "$#" -lt 2 ]; then
        printf 'install.sh: --bin-dir requires a directory path\n' >&2
        usage >&2
        exit 2
      fi
      CUSTOM_BIN_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'install.sh: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

choose_bin_dir() {
  if [ -n "$CUSTOM_BIN_DIR" ]; then
    printf '%s' "$CUSTOM_BIN_DIR"
    return 0
  fi
  local candidate
  for candidate in "/opt/homebrew/bin" "/usr/local/bin"; do
    if [ -d "$candidate" ] && [ -w "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  printf '%s/.local/bin' "$HOME"
}

if [ "$UNINSTALL" -eq 1 ]; then
  removed=0
  if [ -n "$CUSTOM_BIN_DIR" ]; then
    candidates=("${CUSTOM_BIN_DIR}/runnerkit")
  else
    candidates=(
      "/opt/homebrew/bin/runnerkit"
      "/usr/local/bin/runnerkit"
      "${HOME}/.local/bin/runnerkit"
    )
  fi
  for link_path in "${candidates[@]}"; do
    if [ -L "$link_path" ]; then
      target=$(readlink "$link_path" || true)
      if [ "$target" = "$SOURCE_BIN" ] || [ -n "$CUSTOM_BIN_DIR" ]; then
        rm -f "$link_path"
        printf 'removed %s\n' "$link_path"
        removed=1
      fi
    fi
  done
  if [ "$removed" -eq 0 ]; then
    printf 'runnerkit symlink not found (nothing to remove)\n'
  fi
  exit 0
fi

if [ ! -x "$SOURCE_BIN" ]; then
  chmod +x "$SOURCE_BIN"
fi

TARGET_DIR=$(choose_bin_dir)
mkdir -p "$TARGET_DIR"
LINK_PATH="${TARGET_DIR}/runnerkit"

ln -sfn "$SOURCE_BIN" "$LINK_PATH"
printf 'linked %s -> %s\n' "$LINK_PATH" "$SOURCE_BIN"

case ":${PATH}:" in
  *":${TARGET_DIR}:"*) ;;
  *)
    printf 'note: %s is not on your PATH; add:\n' "$TARGET_DIR"
    # shellcheck disable=SC2016
    printf '  export PATH="%s:$PATH"\n' "$TARGET_DIR"
    ;;
esac
