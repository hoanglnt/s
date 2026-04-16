#!/usr/bin/env bash
# `sh ./this.sh` ignores the shebang and uses POSIX sh, which cannot parse < <(...).
# Re-exec once under real bash (also fixes macOS /bin/sh in POSIX mode).
if [ -z "${_GENPROTO_REEXEC:-}" ]; then
  export _GENPROTO_REEXEC=1
  command -v bash >/dev/null 2>&1 || { echo "genproto-changed: bash is required" >&2; exit 1; }
  exec bash "$0" ${1+"$@"}
fi
# Generate Go + gRPC (+ validate where applicable) only for .proto files that differ from Git.
# Mirrors fulfillment_planogram_be/Makefile (and background repo when detected).
#
# Usage:
#   genproto-changed                 # from repo root or any subdir; diff vs HEAD (staged+unstaged)
#   genproto-changed /path/to/repo
#   genproto-changed --base main     # files changed vs merge-base(main, HEAD)
#   genproto-changed --staged        # staged only
#
# zshrc (run from anywhere):
#   export PATH="$HOME/bin:$PATH"   # if you symlink/copy this script there as genproto-changed
#   # or:
#   genproto-changed() { bash /path/to/fulfillment_planogram_be/scripts/genproto-changed.sh "$@"; }

set -euo pipefail

usage_help() {
  sed -n '9,21p' "$0"
}

REPO=""
MODE="head" # head | staged | base
BASE_REF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage_help; exit 0 ;;
    --staged) MODE="staged"; shift ;;
    --base)
      MODE="base"
      BASE_REF="${2:?--base requires a ref}"
      shift 2
      ;;
    *)
      if [[ -n "$REPO" ]]; then
        echo "Unexpected argument: $1" >&2
        usage_help >&2
        exit 1
      fi
      REPO="$1"
      shift
      ;;
  esac
done

find_repo_root() {
  local dir="${1:-$PWD}"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/go.mod" && -d "$dir/proto" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

if [[ -z "$REPO" ]]; then
  REPO="$(find_repo_root "$PWD")" || {
    echo "genproto-changed: no go.mod+proto/ found walking up from $PWD" >&2
    exit 1
  }
fi
REPO="$(cd "$REPO" && pwd)"

cd "$REPO"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "genproto-changed: not a git repository: $REPO" >&2
  exit 1
fi

list_changed_protos() {
  case "$MODE" in
    head)
      git diff --name-only HEAD -- '*.proto'
      ;;
    staged)
      git diff --cached --name-only -- '*.proto'
      ;;
    base)
      git diff --name-only "${BASE_REF}...HEAD" -- '*.proto' 2>/dev/null || \
        git diff --name-only "${BASE_REF}" -- '*.proto'
      ;;
  esac
}

changed=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  changed+=("$f")
done < <(
  list_changed_protos | sed 's|^./||' | awk '!seen[$0]++' | while IFS= read -r f; do
    [[ "$f" == proto/* ]] || continue
    bn="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
    [[ "$bn" == "validate.proto" ]] && continue
    [[ -f "$REPO/$f" ]] || continue
    printf '%s\n' "$f"
  done | sort -u
)

if [[ ${#changed[@]} -eq 0 ]]; then
  echo "genproto-changed: no changed .proto files under proto/ (mode=$MODE)."
  exit 0
fi

GOPATH="$(go env GOPATH)"
VALIDATE_INC=""
for try in \
  "$(go list -m -f '{{.Dir}}' github.com/envoyproxy/protoc-gen-validate 2>/dev/null)" \
  "$GOPATH/src/github.com/bufbuild/protoc-gen-validate" \
  "$GOPATH/src/github.com/envoyproxy/protoc-gen-validate"
do
  [[ -n "$try" && -d "$try" && -f "$try/validate/validate.proto" ]] && VALIDATE_INC="$try" && break
done
if [[ -z "$VALIDATE_INC" ]]; then
  echo "genproto-changed: could not resolve protoc-gen-validate import dir (need validate/validate.proto)." >&2
  echo "  Hint: ensure github.com/envoyproxy/protoc-gen-validate is in go.mod and run: go mod download" >&2
  exit 1
fi

flavor=""
if grep -q 'proto/inventory/master_data/common' Makefile 2>/dev/null; then
  flavor="be_main"
elif grep -qF 'proto/common/*.proto' Makefile 2>/dev/null; then
  flavor="be_background"
else
  echo "genproto-changed: unsupported Makefile (expected planogram BE or background layout)." >&2
  exit 1
fi

MODULE_NAME="$(sed -n 's/^MODULE_NAME=//p' Makefile 2>/dev/null | head -1 | tr -d '\r')"
if [[ -z "$MODULE_NAME" ]]; then
  MODULE_NAME="$(head -1 go.mod | awk '{print $2}')"
fi

GO_OPT_FLAG=(--go_opt=module="${MODULE_NAME}")
GRPC_OPT_FLAG=(--go-grpc_opt=module="${MODULE_NAME}")

common_files=()
validate_files=()

for f in "${changed[@]}"; do
  if [[ "$flavor" == "be_main" && "$f" == proto/inventory/master_data/common/* ]]; then
    common_files+=("$f")
  elif [[ "$flavor" == "be_background" && "$f" == proto/common/* ]]; then
    common_files+=("$f")
  else
    validate_files+=("$f")
  fi
done

run_protoc() {
  echo "+ $*" >&2
  "$@"
}

if [[ ${#common_files[@]} -gt 0 ]]; then
  if [[ "$flavor" == "be_main" ]]; then
    # Match Makefile proto-common / refresh first line
    run_protoc protoc -I./proto \
      --go-grpc_out=require_unimplemented_servers=false:. "${GRPC_OPT_FLAG[@]}" \
      --go_out=. "${GO_OPT_FLAG[@]}" \
      proto/inventory/master_data/common/*.proto
  else
    # Background Makefile proto-common / refresh first line (--go_out=../.)
    run_protoc protoc -I./proto \
      --go-grpc_out=require_unimplemented_servers=false:. \
      --go_out=../. \
      proto/common/*.proto
  fi
fi

if [[ ${#validate_files[@]} -gt 0 ]]; then
  # Match Makefile refresh second line / proto-pla (no module go_out flags)
  run_protoc protoc -I./proto -I"$VALIDATE_INC" \
    --go-grpc_out=require_unimplemented_servers=false:. \
    --go_out=. \
    --validate_out=lang=go:. \
    "${validate_files[@]}"
fi

echo "genproto-changed: done (${#common_files[@]} common dir refresh, ${#validate_files[@]} validate file(s))."
