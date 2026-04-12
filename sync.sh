#!/bin/bash
set -e

# ─── Config ───────────────────────────────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMIT_MSG="${1:-"sync: $(date '+%Y-%m-%d %H:%M:%S')"}"
# ──────────────────────────────────────────────────────────────────────────────

cd "$PROJECT_DIR"

echo "▶ Checking git status..."

if [ -z "$(git status --porcelain)" ]; then
    echo "✅ Nothing to sync — working tree is clean."
    exit 0
fi

echo "▶ Staging all changes..."
git add -A

echo "▶ Committing..."
git commit -m "$COMMIT_MSG"

echo "▶ Pushing to remote..."
git push

echo "✅ Synced: $(git remote get-url origin)"
