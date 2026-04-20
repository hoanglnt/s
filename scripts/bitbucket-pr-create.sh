#!/usr/bin/env bash
# Create a Bitbucket Cloud pull request via REST API; print only the PR web URL on success.
# Requires: BB_EMAIL + BB_API_TOKEN (Bitbucket API token), git repo with bitbucket.org remote.
# Usage: bitbucket-pr-create.sh <destination-branch> [--remote <name>]
# Example: bitbucket-pr-create.sh release/qc

set -euo pipefail

REMOTE_NAME="origin"
DEST_BRANCH=""

usage() {
  echo "Usage: $(basename "$0") <destination-branch> [--remote <name>]" >&2
  echo "  destination-branch  Target branch (e.g. release/qc)" >&2
  echo "  --remote            Git remote (default: origin)" >&2
  echo "  Env: BB_EMAIL, BB_API_TOKEN" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      [[ $# -ge 2 ]] || usage
      REMOTE_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [[ -n "$DEST_BRANCH" ]]; then
        echo "Error: unexpected argument: $1" >&2
        usage
      fi
      DEST_BRANCH="$1"
      shift
      ;;
  esac
done

if [[ -z "$DEST_BRANCH" ]]; then
  usage
fi

if [[ -z "${BB_EMAIL:-}" || -z "${BB_API_TOKEN:-}" ]]; then
  echo "Error: set BB_EMAIL and BB_API_TOKEN (Bitbucket API token)." >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not inside a git repository." >&2
  exit 1
fi

REMOTE_URL="$(git remote get-url "$REMOTE_NAME" 2>/dev/null)" || {
  echo "Error: remote '$REMOTE_NAME' not found." >&2
  exit 1
}

parse_bitbucket_path() {
  local url="$1"
  local path=""
  if [[ "$url" =~ ^git@bitbucket\.org:([^/]+)/(.+)$ ]]; then
    path="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  elif [[ "$url" =~ bitbucket\.org[:/](.+)$ ]]; then
    path="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  path="${path%.git}"
  path="${path%/}"
  echo "$path"
}

BB_PATH="$(parse_bitbucket_path "$REMOTE_URL")" || {
  echo "Error: remote URL does not look like Bitbucket: $REMOTE_URL" >&2
  exit 1
}

WORKSPACE="${BB_PATH%%/*}"
REPO="${BB_PATH#*/}"

if [[ -z "$WORKSPACE" || -z "$REPO" || "$WORKSPACE" == "$BB_PATH" ]]; then
  echo "Error: could not parse workspace/repo from: $REMOTE_URL" >&2
  exit 1
fi

SOURCE_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || {
  echo "Error: could not determine current branch." >&2
  exit 1
}

if [[ "$SOURCE_BRANCH" == "HEAD" ]]; then
  echo "Error: detached HEAD; checkout a branch first." >&2
  exit 1
fi

TITLE="${SOURCE_BRANCH} → ${DEST_BRANCH}"
PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"title":sys.argv[1],"source":{"branch":{"name":sys.argv[2]}},"destination":{"branch":{"name":sys.argv[3]}}}))' \
  "$TITLE" "$SOURCE_BRANCH" "$DEST_BRANCH")"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

HTTP_CODE="$(
  curl -sS -o "$TMP" -w "%{http_code}" \
    -u "$BB_EMAIL:$BB_API_TOKEN" \
    -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    "https://api.bitbucket.org/2.0/repositories/${WORKSPACE}/${REPO}/pullrequests" \
    -d "$PAYLOAD"
)"

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
  python3 -c '
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
url = d.get("links", {}).get("html", {}).get("href")
if not url:
    print("Error: unexpected API response (no PR link).", file=sys.stderr)
    sys.exit(1)
print(url)
' "$TMP"
  exit 0
fi

echo "Error: HTTP $HTTP_CODE" >&2
python3 -c '
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
    err = d.get("error") or {}
    msg = err.get("message") if isinstance(err, dict) else None
    if msg:
        print(msg, file=sys.stderr)
    else:
        print(d, file=sys.stderr)
except Exception:
    with open(path) as f:
        sys.stderr.write(f.read())
    sys.stderr.write("\n")
' "$TMP" 2>&1 || true
exit 1
