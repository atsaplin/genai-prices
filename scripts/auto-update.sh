#!/bin/bash
#
# Fetch latest prices, detect aliases, apply, build, and optionally open a PR.
#
# Usage:
#   ./auto-update.sh           # fetch, detect, apply, format, build — review the diff
#   ./auto-update.sh --pr      # commit current changes and open a PR (run without --pr first)
#

set -e

# ── --pr: commit existing changes and open a PR ──────────────────────
if [ "$1" = "--pr" ]; then
  if git diff --quiet -- prices/providers/ packages/ prices/data.json prices/data_slim.json prices/data.schema.json prices/data_slim.schema.json; then
    echo "No changes to commit. Run without --pr first."
    exit 1
  fi

  echo "==> Committing and creating PR..."
  git add prices/providers/ prices/data.json prices/data_slim.json packages/
  git add prices/data.schema.json prices/data_slim.schema.json
  git commit -m "feat: auto-update price aliases"
  git push
  gh pr create \
    --title "feat: auto-update price aliases" \
    --body "Auto-applied model name aliases from external price sources." \
    --label auto-update
  exit 0
fi

# ── Full pipeline: fetch, detect, apply, format, build ───────────────
REPORT_JSON=$(mktemp)
trap 'rm -f "$REPORT_JSON"' EXIT

echo "==> Fetching source prices..."
uv run -m prices get_openrouter_prices
uv run -m prices get_litellm_prices
uv run -m prices get_simonw_prices

echo "==> Detecting and applying aliases..."
uv run python -c "
import json
from prices.auto_update import detect_auto_updates, apply_auto_updates
report = detect_auto_updates()
with open('$REPORT_JSON', 'w') as f:
    json.dump(report.to_dict(), f, indent=2)
if not report.applied:
    print('No aliases to apply.')
    raise SystemExit(0)
print(f'Found {len(report.applied)} alias(es), applying...')
saved = apply_auto_updates(report)
print(f'Applied to {len(saved)} provider(s).')
"

# Exit early if nothing was applied
n_applied=$(jq '.applied | length' "$REPORT_JSON")
if [ "$n_applied" -eq 0 ]; then
  echo "Nothing to do."
  exit 0
fi

# ── Format + build (mirrors pre-commit hooks so commit is clean) ─────
echo "==> Formatting and building..."
uv run ruff format
uv run ruff check --fix --fix-only
uv sync --frozen --all-packages --all-extras
npm install
make collapse-models
make build
uv run -m prices inject_providers
npx prettier --write --ignore-unknown prices/providers/ packages/

echo "Done. Review the changes, then run with --pr to commit and open a PR."
