#!/usr/bin/env bash
# Sets up a made-up user for demo recordings (README movie): target folders, favorites, rename rules,
# one learned invoice, and files to drop in DIR/Downloads. Then starts the built app on it.
# Usage: scripts/make-demo-home.sh DIR     (DIR must not exist yet; after ./build.sh)
# Quit any other running Drop Sorter first, or two shelves show.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR="${1:?usage: scripts/make-demo-home.sh DIR}"
[[ -e "$DIR" ]] && { echo "error: $DIR exists" >&2; exit 1; }
[[ -x build/dropsorter ]] || { echo "error: run ./build.sh first" >&2; exit 1; }
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd -P)"
SUPPORT="$DIR/Support"

for f in "Work/Clients/Acme/Contracts" "Work/Clients/Acme/Invoices" "Work/Clients/Globex/Invoices" \
         "Work/Clients/Globex/Meeting Notes" "Work/Projects/Annual Report 2026" "Work/Projects/Website Relaunch" \
         "Work/Taxes/2025" "Work/Taxes/2026" "Personal/Car" "Personal/Health" "Personal/Home/Insurance" \
         "Personal/Receipts" "Personal/Travel/2026 Lisbon" "Backup/Receipts" "Downloads" "Support"; do
  mkdir -p "$DIR/$f"
done

cat > "$SUPPORT/config.yaml" <<EOF
targets:
  - path: $DIR/Work
  - path: $DIR/Personal
renameRules:
  $DIR/Work/Clients:
    pattern: "{date}_{name}{ext}"
  $DIR/Personal/Receipts:
    pattern: "{date}_{time}_{name}{ext}"
favorites:
  - folder: $DIR/Personal/Receipts
  - folder: $DIR/Work/Taxes/2026
shelf:
  showOnDesktop: true
  hideDelayMs: 400
  trash: true
menuBarIcon: true
EOF

pdf() { printf '%%PDF-1.4 %s\n' "$1" > "$DIR/Downloads/$1"; }
# One earlier invoice teaches Drop Sorter where Acme invoices go, so the next one is a clear match.
pdf "Acme invoice September.pdf"
DROPSORTER_HOME="$SUPPORT" build/dropsorter move --to "$DIR/Work/Clients/Acme/Invoices" "$DIR/Downloads/Acme invoice September.pdf" >/dev/null
pdf "Acme invoice October.pdf"
pdf "Globex invoice 2026-10.pdf"
pdf "Tax statement 2026.pdf"
pdf "Pharmacy receipt.pdf"

echo "demo home: $DIR (files to drop in $DIR/Downloads)"
open -n --env DROPSORTER_HOME="$SUPPORT" "build/Drop Sorter.app"
open "$DIR/Downloads"
