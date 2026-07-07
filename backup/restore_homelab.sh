#!/usr/bin/env bash
# Download an encrypted backup from S3, decrypt with GPG, and extract the tarball.
# Same backup.env as backup_homelab.sh (S3_BUCKET, S3_PREFIX, BACKUP_PASSPHRASE, AWS keys, BACKUP_TMP_DIR).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/backup.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/backup.env"
fi

unset AWS_PROFILE AWS_DEFAULT_PROFILE
export AWS_SHARED_CREDENTIALS_FILE=/dev/null

[[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && export AWS_ACCESS_KEY_ID
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && export AWS_SECRET_ACCESS_KEY
[[ -n "${AWS_SESSION_TOKEN:-}" ]] && export AWS_SESSION_TOKEN
[[ -n "${AWS_DEFAULT_REGION:-}" ]] && export AWS_DEFAULT_REGION

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "error: set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in ${SCRIPT_DIR}/backup.env" >&2
  echo "This script does not use ~/.aws/credentials or AWS_PROFILE." >&2
  exit 1
fi

S3_BUCKET="${S3_BUCKET:?Set S3_BUCKET in backup.env or the environment}"
BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:?Set BACKUP_PASSPHRASE in backup.env or the environment}"
S3_PREFIX="${S3_PREFIX:-}"
BACKUP_TMP_DIR="${BACKUP_TMP_DIR:-}"

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

usage_full() {
  cat >&2 <<'EOF'
Usage: restore_homelab.sh [options] <destination-directory>

  Download s3://$S3_BUCKET/<key>.tar.gz.gpg, decrypt with BACKUP_PASSPHRASE,
  extract gzip+tar into destination-directory (top-level paths are created inside it).

Options:
  -l, --list       List homelab backup objects under S3_PREFIX and exit
  -L, --latest     Use the newest backup object (default when --key is omitted)
  -k, --key KEY    S3 object key, e.g. automatic/homelab-20260418T112717Z.tar.gz.gpg
                   If KEY has no "/", it is combined with S3_PREFIX when set
  -h, --help       Show this help

Examples:
  restore_homelab.sh --list
  restore_homelab.sh --latest /mnt/restore/homelab
  restore_homelab.sh -k automatic/homelab-20260418T112717Z.tar.gz.gpg /mnt/restore/homelab
EOF
}

LIST_ONLY=0
S3_KEY_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l | --list)
      LIST_ONLY=1
      shift
      ;;
    -L | --latest)
      shift
      ;;
    -k | --key)
      if [[ $# -lt 2 ]]; then
        echo "error: --key requires a value" >&2
        exit 1
      fi
      S3_KEY_ARG="$2"
      shift 2
      ;;
    -h | --help)
      usage_full
      exit 0
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage_full
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

RESTORE_DEST="${1:-}"
if [[ $LIST_ONLY -eq 0 ]]; then
  if [[ -z "${RESTORE_DEST}" ]]; then
    echo "error: missing destination directory (or use --list)" >&2
    usage_full
    exit 1
  fi
  if [[ $# -gt 1 ]]; then
    echo "error: too many arguments" >&2
    exit 1
  fi
else
  if [[ -n "${RESTORE_DEST}" ]]; then
    echo "error: --list does not take a destination" >&2
    exit 1
  fi
fi

# Match backup script / prune pattern
readonly BACKUP_OBJECT_REGEX='homelab-[0-9]{8}T[0-9]{6}Z\.tar\.gz\.gpg$'

s3_ls_uri() {
  if [[ -n "${S3_PREFIX}" ]]; then
    echo "s3://${S3_BUCKET}/${S3_PREFIX%/}/"
  else
    echo "s3://${S3_BUCKET}/"
  fi
}

line_to_key() {
  awk '{$1=$2=$3=""; sub(/^ +/, ""); print}'
}

list_backup_objects() {
  aws s3 ls "$(s3_ls_uri)" --recursive | grep -E "${BACKUP_OBJECT_REGEX}" || true
}

resolve_object_key() {
  local raw="$1"
  if [[ "${raw}" == */* ]]; then
    printf '%s\n' "${raw}"
    return
  fi
  if [[ -n "${S3_PREFIX}" ]]; then
    printf '%s\n' "${S3_PREFIX%/}/${raw}"
  else
    printf '%s\n' "${raw}"
  fi
}

if [[ $LIST_ONLY -eq 1 ]]; then
  echo "Backups under $(s3_ls_uri) matching homelab-*.tar.gz.gpg:"
  list_backup_objects | while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    printf '  %s\n' "$(printf '%s\n' "${line}" | line_to_key)"
  done
  exit 0
fi

OBJECT_KEY=""
if [[ -n "${S3_KEY_ARG}" ]]; then
  OBJECT_KEY="$(resolve_object_key "${S3_KEY_ARG}")"
  echo "Using backup: ${OBJECT_KEY}"
else
  lines=$(list_backup_objects | sort -k1,2)
  if [[ -z "${lines}" ]]; then
    echo "error: no backup objects found under $(s3_ls_uri)" >&2
    exit 1
  fi
  last_line=$(printf '%s\n' "${lines}" | tail -n 1)
  OBJECT_KEY="$(printf '%s\n' "${last_line}" | line_to_key)"
  echo "Using newest backup: ${OBJECT_KEY}"
fi

mkdir -p "${RESTORE_DEST}"
if [[ ! -d "${RESTORE_DEST}" ]]; then
  echo "error: not a directory: ${RESTORE_DEST}" >&2
  exit 1
fi
RESTORE_DEST="$(cd "${RESTORE_DEST}" && pwd)"
if [[ ! -w "${RESTORE_DEST}" ]]; then
  echo "error: destination not writable: ${RESTORE_DEST}" >&2
  exit 1
fi

if [[ -n "${BACKUP_TMP_DIR}" ]]; then
  mkdir -p "${BACKUP_TMP_DIR}"
  BACKUP_TMP_DIR="$(cd "${BACKUP_TMP_DIR}" && pwd)"
  TMPFILE="$(mktemp "${BACKUP_TMP_DIR}/homelab-restore.XXXXXX")"
else
  TMPFILE="$(mktemp)"
fi
trap 'rm -f "${TMPFILE}"' EXIT

echo "Downloading s3://${S3_BUCKET}/${OBJECT_KEY}"
aws s3 cp "s3://${S3_BUCKET}/${OBJECT_KEY}" "${TMPFILE}"

echo "Decrypting and extracting to ${RESTORE_DEST}"
gpg --batch --yes --pinentry-mode loopback \
  --passphrase "${BACKUP_PASSPHRASE}" \
  -d "${TMPFILE}" | tar -xzf - -C "${RESTORE_DEST}"

echo "Done. Extracted under ${RESTORE_DEST}"
