# dotfiles-scripts

Personal utility scripts that don't belong under `bin/`, including an encrypted homelab backup/restore pair (`backup/backup_homelab.sh`, `backup/restore_homelab.sh` — tars a directory, encrypts with GPG symmetric AES256, and ships it to S3).

Part of the [dotfiles-arch](https://github.com/SaratAngajalaoffl/dotfiles-arch) multi-repo dotfiles system.

## Layout

- `bin/*` → `~/.local/bin/` (see `.links`)
- `backup` → `~/.config/scripts/backup`

## Setup

The backup scripts read config from a local `.env` (gitignored — `backup/backup.example` is the committed template) with your GPG passphrase and AWS credentials; see `.setup` for the one-time copy step.
