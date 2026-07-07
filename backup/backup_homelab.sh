#!/usr/bin/env bash
# Create an encrypted compressed archive of ~/storage/homelab and upload it to S3.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/backup.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/backup.env"
fi

# Use only API keys from the environment (e.g. backup.env above), not ~/.aws/credentials or named
# profiles, so another project's default profile is never picked up.
unset AWS_PROFILE AWS_DEFAULT_PROFILE
export AWS_SHARED_CREDENTIALS_FILE=/dev/null

# backup.env files often omit `export`; the aws CLI only sees exported variables.
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && export AWS_ACCESS_KEY_ID
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && export AWS_SECRET_ACCESS_KEY
[[ -n "${AWS_SESSION_TOKEN:-}" ]] && export AWS_SESSION_TOKEN
[[ -n "${AWS_DEFAULT_REGION:-}" ]] && export AWS_DEFAULT_REGION

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "error: set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in ${SCRIPT_DIR}/backup.env" >&2
  echo "This script does not use ~/.aws/credentials or AWS_PROFILE." >&2
  exit 1
fi

BACKUP_SOURCE="${BACKUP_SOURCE:-${HOME}/storage/homelab}"
# Optional ERE: when set, BACKUP_SOURCE is the parent directory and only immediate
# subdirectories whose names match this pattern are archived (see backup.example).
BACKUP_SOURCE_REGEX="${BACKUP_SOURCE_REGEX:-}"
S3_BUCKET="${S3_BUCKET:?Set S3_BUCKET in backup.env or the environment}"
BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:?Set BACKUP_PASSPHRASE in backup.env or the environment}"
S3_PREFIX="${S3_PREFIX:-}"
# Optional: where to build the encrypted archive (default: system temp via mktemp).
BACKUP_TMP_DIR="${BACKUP_TMP_DIR:-}"
# Set to 0/false to fail the run if any file cannot be read (default: skip unreadable files).
BACKUP_TAR_IGNORE_FAILED_READ="${BACKUP_TAR_IGNORE_FAILED_READ:-1}"

command -v tar >/dev/null 2>&1 || {
  echo "error: tar not found" >&2
  exit 1
}
command -v gpg >/dev/null 2>&1 || {
  echo "error: gpg not found" >&2
  exit 1
}
command -v aws >/dev/null 2>&1 || {
  echo "error: aws CLI not found" >&2
  exit 1
}

# Keep only this many newest homelab-*.tar.gz.gpg objects in the bucket (same prefix as uploads).
readonly KEEP_BACKUPS=2

# After upload, delete older homelab backups so at most KEEP_BACKUPS remain.
prune_old_backups() {
  local s3_uri lines delete_list
  if [[ -n "${S3_PREFIX}" ]]; then
    s3_uri="s3://${S3_BUCKET}/${S3_PREFIX%/}/"
  else
    s3_uri="s3://${S3_BUCKET}/homelab-"
  fi

  if ! lines=$(aws s3 ls "${s3_uri}" --recursive 2>/dev/null); then
    echo "warning: could not list ${s3_uri} for pruning; leaving existing objects as-is" >&2
    return 0
  fi

  lines=$(printf '%s\n' "${lines}" | grep -E 'homelab-[0-9]{8}T[0-9]{6}Z\.tar\.gz\.gpg$' || true)
  if [[ -z "${lines}" ]]; then
    return 0
  fi

  # Oldest first; drop the last KEEP_BACKUPS lines, delete the rest.
  delete_list=$(printf '%s\n' "${lines}" | sort -k1,2 | head -n "-${KEEP_BACKUPS}" |
    awk '{$1=$2=$3=""; sub(/^ +/, ""); print}')
  if [[ -z "${delete_list}" ]]; then
    return 0
  fi

  while IFS= read -r key; do
    [[ -z "${key}" ]] && continue
    echo "Deleting old backup: ${key}"
    aws s3 rm "s3://${S3_BUCKET}/${key}"
  done <<<"${delete_list}"
}

if [[ ! -d "${BACKUP_SOURCE}" ]]; then
  echo "error: backup source is not a directory: ${BACKUP_SOURCE}" >&2
  exit 1
fi

TAR_ARGS=()
if [[ -z "${BACKUP_SOURCE_REGEX}" ]]; then
  SRC_DIR="$(cd "$(dirname "${BACKUP_SOURCE}")" && pwd)"
  TAR_ARGS+=("$(basename "${BACKUP_SOURCE}")")
else
  SRC_DIR="$(cd "${BACKUP_SOURCE}" && pwd)"
  shopt -s nullglob
  for entry in "${SRC_DIR}"/*; do
    [[ -d "${entry}" ]] || continue
    base="$(basename "${entry}")"
    [[ "${base}" =~ ${BACKUP_SOURCE_REGEX} ]] || continue
    TAR_ARGS+=("${base}")
  done
  shopt -u nullglob
  if [[ ${#TAR_ARGS[@]} -eq 0 ]]; then
    echo "error: BACKUP_SOURCE_REGEX matched no immediate subdirectories of ${BACKUP_SOURCE}" >&2
    exit 1
  fi
  mapfile -t TAR_ARGS < <(printf '%s\n' "${TAR_ARGS[@]}" | sort -u)
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE_BASENAME="homelab-${TIMESTAMP}.tar.gz.gpg"

if [[ -n "${S3_PREFIX}" ]]; then
  S3_KEY="${S3_PREFIX%/}/${ARCHIVE_BASENAME}"
else
  S3_KEY="${ARCHIVE_BASENAME}"
fi

if [[ -n "${BACKUP_TMP_DIR}" ]]; then
  mkdir -p "${BACKUP_TMP_DIR}"
  if [[ ! -d "${BACKUP_TMP_DIR}" ]]; then
    echo "error: BACKUP_TMP_DIR is not a directory: ${BACKUP_TMP_DIR}" >&2
    exit 1
  fi
  BACKUP_TMP_DIR="$(cd "${BACKUP_TMP_DIR}" && pwd)"
  if [[ ! -w "${BACKUP_TMP_DIR}" ]]; then
    echo "error: BACKUP_TMP_DIR is not writable: ${BACKUP_TMP_DIR}" >&2
    exit 1
  fi
  TMPFILE="$(mktemp "${BACKUP_TMP_DIR}/homelab-backup.XXXXXX")"
else
  TMPFILE="$(mktemp)"
fi
trap 'rm -f "${TMPFILE}"' EXIT

if [[ -z "${BACKUP_SOURCE_REGEX}" ]]; then
  echo "Archiving and encrypting: ${BACKUP_SOURCE}"
else
  echo "Archiving and encrypting under ${BACKUP_SOURCE} (BACKUP_SOURCE_REGEX=${BACKUP_SOURCE_REGEX}): ${TAR_ARGS[*]}"
fi
echo "Scratch file (encrypted archive): ${TMPFILE}"
df -Ph "${TMPFILE}" | awk 'NR==2 {print "  Free on this filesystem: " $4 " (" $6 ")"}'
# tar compresses; gpg must not compress again (--compress-algo none).
# --ignore-failed-read: unreadable files (e.g. Postgres pg_stat_tmp while DB runs) do not abort the archive.
TAR_OPTS=(-C "${SRC_DIR}" -czf -)
if [[ "${BACKUP_TAR_IGNORE_FAILED_READ}" != "0" && "${BACKUP_TAR_IGNORE_FAILED_READ}" != "false" ]]; then
  TAR_OPTS=(--ignore-failed-read "${TAR_OPTS[@]}")
fi
tar "${TAR_OPTS[@]}" "${TAR_ARGS[@]}" | gpg --batch --yes --pinentry-mode loopback \
  --passphrase "${BACKUP_PASSPHRASE}" \
  --symmetric --cipher-algo AES256 --compress-algo none \
  -o "${TMPFILE}"

echo "Uploading to s3://${S3_BUCKET}/${S3_KEY}"
aws s3 cp "${TMPFILE}" "s3://${S3_BUCKET}/${S3_KEY}"

echo "Pruning old backups (keeping ${KEEP_BACKUPS} most recent)"
prune_old_backups

echo "Done: s3://${S3_BUCKET}/${S3_KEY}"
