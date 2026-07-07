#!/usr/bin/env bash
# Read flat env JSON (stdin or clipboard), find all *.example files under SEARCH_ROOT
# (default: git repo root), and write paired *.env files (arr.example -> arr.env).
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

read_clipboard() {
  if command -v wl-paste >/dev/null 2>&1; then
    wl-paste --no-newline 2>/dev/null || wl-paste
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --output
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard -o
  elif command -v pbpaste >/dev/null 2>&1; then
    pbpaste
  else
    echo "error: no clipboard read tool found (wl-paste, xclip, xsel, or pbpaste)" >&2
    exit 1
  fi
}

load_json() {
  if [[ ! -t 0 ]]; then
    cat
  else
    read_clipboard
  fi
}

INPUT="$(load_json)"
if [[ -z "${INPUT//[[:space:]]/}" ]]; then
  echo "error: empty JSON (pipe JSON on stdin or place it on the clipboard)" >&2
  exit 1
fi

JSON_FILE="$(mktemp)"
trap 'rm -f "${JSON_FILE}"' EXIT
printf '%s' "${INPUT}" > "${JSON_FILE}"

export SEARCH_ROOT
export JSON_FILE
python3 - <<'PY'
import json
import os
import re
import sys
import pathlib

root = pathlib.Path(os.environ["SEARCH_ROOT"]).resolve()

try:
    with open(os.environ["JSON_FILE"], encoding="utf-8") as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f"error: invalid JSON: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print("error: JSON root must be an object with string keys and string values", file=sys.stderr)
    sys.exit(1)

flat: dict[str, str] = {}
for k, v in data.items():
    if not isinstance(k, str):
        print("error: JSON keys must be strings", file=sys.stderr)
        sys.exit(1)
    if isinstance(v, (dict, list)):
        print(
            f"error: expected flat key/value JSON; got nested value for {k!r}",
            file=sys.stderr,
        )
        sys.exit(1)
    if v is None:
        flat[k] = ""
    elif isinstance(v, bool):
        flat[k] = "true" if v else "false"
    elif isinstance(v, (int, float)):
        flat[k] = str(v)
    else:
        flat[k] = str(v)

skip_parts = {".git", "node_modules", ".venv", "venv"}


def is_skipped(p: pathlib.Path) -> bool:
    return any(part in skip_parts for part in p.parts)


def is_example_file(p: pathlib.Path) -> bool:
    """arr.example -> paired arr.env; skip names without stem."""
    if not p.is_file() or is_skipped(p):
        return False
    if p.suffix != ".example":
        return False
    if not p.stem:
        return False
    return True


# Assignment line (logical line — we only rewrite full-line assignments).
assign_re = re.compile(
    r"^([ \t]*)(export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)([ \t]*=[ \t]*)(.*)$"
)


def format_env_value(val: str) -> str:
    if val == "":
        return ""
    if re.fullmatch(r"[A-Za-z0-9_@%^+\-.,/:]+", val) and not val.startswith("#"):
        return val
    escaped = (
        val.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
    )
    return f'"{escaped}"'


def rewrite_example(text: str) -> str:
    out_lines = []
    for raw in text.splitlines(keepends=True):
        line = raw.rstrip("\r\n")
        end = raw[len(line) :]
        if not line.strip() or line.lstrip().startswith("#"):
            out_lines.append(raw)
            continue
        m = assign_re.match(line)
        if not m:
            out_lines.append(raw)
            continue
        lead, exp, key, eq, _rest = m.groups()
        if key not in flat:
            out_lines.append(raw)
            continue
        new_tail = format_env_value(flat[key])
        prefix = f"{lead}{exp or ''}{key}{eq}"
        out_lines.append(prefix + new_tail + end)
    return "".join(out_lines)


examples = sorted(
    p
    for p in root.rglob("*")
    if is_example_file(p)
)

if not examples:
    print(f"error: no *.example files under {root}", file=sys.stderr)
    sys.exit(1)

for ex in examples:
    out_path = ex.parent / f"{ex.stem}.env"
    try:
        body = ex.read_text(encoding="utf-8")
    except OSError as e:
        print(f"error: cannot read {ex}: {e}", file=sys.stderr)
        sys.exit(1)
    new_body = rewrite_example(body)
    try:
        out_path.write_text(new_body, encoding="utf-8", newline="\n")
    except OSError as e:
        print(f"error: cannot write {out_path}: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"wrote {out_path.relative_to(root)}")
PY
