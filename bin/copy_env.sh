#!/usr/bin/env bash
# Discover all *.env files under SEARCH_ROOT (default: git repo root), merge assignments
# (later files override earlier keys on duplicate), emit one JSON object, copy to clipboard.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}/.." rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_ROOT}" ]]; then
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

SEARCH_ROOT="${1:-$REPO_ROOT}"
if [[ ! -d "${SEARCH_ROOT}" ]]; then
  echo "error: not a directory: ${SEARCH_ROOT}" >&2
  exit 1
fi
SEARCH_ROOT="$(cd "${SEARCH_ROOT}" && pwd)"

copy_to_clipboard() {
  if command -v wl-copy >/dev/null 2>&1; then
    wl-copy
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --input
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard
  elif command -v pbcopy >/dev/null 2>&1; then
    pbcopy
  else
    echo "error: no clipboard tool found (install wl-copy, xclip, xsel, or use macOS pbcopy)" >&2
    exit 1
  fi
}

export SEARCH_ROOT
COUNT_FILE="$(mktemp)"
trap 'rm -f "${COUNT_FILE}"' EXIT
export COUNT_FILE
OUT="$(
  SEARCH_ROOT="${SEARCH_ROOT}" COUNT_FILE="${COUNT_FILE}" python3 - <<'PY'
import json
import os
import re
import sys
import pathlib

root = pathlib.Path(os.environ["SEARCH_ROOT"]).resolve()
skip_parts = {".git", "node_modules", ".venv", "venv"}


def is_skipped(p: pathlib.Path) -> bool:
    return any(part in skip_parts for part in p.parts)


def is_env_file(p: pathlib.Path) -> bool:
    """service.env or legacy directory .env; not *.example."""
    if not p.is_file() or is_skipped(p):
        return False
    if p.name == ".env":
        return True
    return p.suffix == ".env"


paths = sorted(p for p in root.rglob("*") if is_env_file(p))
if not paths:
    print("error: no *.env files found", file=sys.stderr)
    sys.exit(1)

count_file = os.environ.get("COUNT_FILE")
if count_file:
    pathlib.Path(count_file).write_text(str(len(paths)), encoding="utf-8")

assign_re = re.compile(r"^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")


def unquote_double(s: str) -> str:
    out: list[str] = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n in '"\\':
                out.append(n)
                i += 2
                continue
            if n == "n":
                out.append("\n")
                i += 2
                continue
            if n == "r":
                out.append("\r")
                i += 2
                continue
            if n == "t":
                out.append("\t")
                i += 2
                continue
            out.append(n)
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def parse_value(raw_val: str) -> str:
    v = raw_val.strip()
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        return unquote_double(v[1:-1])
    if len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        return v[1:-1].replace("\\'", "'").replace("\\\\", "\\")
    return raw_val.rstrip()


def parse_env_text(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = assign_re.match(raw.rstrip("\n"))
        if not m:
            continue
        key, raw_val = m.group(1), m.group(2)
        out[key] = parse_value(raw_val)
    return out


merged: dict[str, str] = {}
for p in paths:
    try:
        data = p.read_text(encoding="utf-8")
    except OSError as e:
        print(f"error: cannot read {p}: {e}", file=sys.stderr)
        sys.exit(1)
    chunk = parse_env_text(data)
    overlap = set(merged) & set(chunk)
    if overlap:
        rel = p.relative_to(root)
        keys = ", ".join(sorted(overlap))
        print(
            f"warning: duplicate keys (later file wins): {keys} — in {rel}",
            file=sys.stderr,
        )
    merged.update(chunk)

print(json.dumps(merged, ensure_ascii=False, indent=2))
PY
)"

COUNT="$(cat "${COUNT_FILE}")"

printf '%s\n' "${OUT}" | copy_to_clipboard
printf 'Copied JSON for %s env file(s) to the clipboard (%s).\n' "${COUNT}" "${SEARCH_ROOT}"
