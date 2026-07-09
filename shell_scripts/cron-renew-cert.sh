#!/usr/bin/env bash
# Monthly cron entry: renew certificates and reload nginx.
# Self-locating: derives the repo root from its own path (no hardcoded user/dir).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
exec "$ROOT_DIR/orchestrator" renew
