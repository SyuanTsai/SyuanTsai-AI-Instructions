#!/usr/bin/env bash
set -euo pipefail

FORCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      cat <<'HELP'
Usage: ./scripts/install-to-project.sh [--dry-run] [--force]
  --dry-run   Show actions without copying files
  --force     Overwrite files without confirmation
HELP
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_DIR/dist"
PARENT_DIR="$(cd "$REPO_DIR/.." && pwd)"

if [[ ! -d "$DIST_DIR" ]]; then
  echo "Error: dist directory not found at $DIST_DIR" >&2
  echo "Tip: switch to a tool/* branch that provides dist/." >&2
  exit 1
fi

mapfile -d '' FILES < <(find "$DIST_DIR" -type f -print0 | sort -z)
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No files found in dist/ to install."
  exit 0
fi

COPIED=0
SKIPPED=0
OVERWRITTEN=0

confirm_overwrite() {
  local target="$1"
  local answer
  while true; do
    read -r -p "Overwrite '$target'? [y/N] " answer
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO|"") return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

for source in "${FILES[@]}"; do
  rel="${source#"$DIST_DIR"/}"
  target="$PARENT_DIR/$rel"
  target_dir="$(dirname "$target")"

  if [[ "$DRY_RUN" == true ]]; then
    if [[ -f "$target" ]]; then
      if [[ "$FORCE" == true ]]; then
        echo "[DRY-RUN] overwrite: $rel"
      else
        echo "[DRY-RUN] prompt overwrite: $rel"
      fi
    else
      echo "[DRY-RUN] copy: $rel"
    fi
    continue
  fi

  mkdir -p "$target_dir"

  if [[ -f "$target" ]]; then
    if [[ "$FORCE" == true ]]; then
      cp "$source" "$target"
      OVERWRITTEN=$((OVERWRITTEN + 1))
    else
      if confirm_overwrite "$target"; then
        cp "$source" "$target"
        OVERWRITTEN=$((OVERWRITTEN + 1))
      else
        SKIPPED=$((SKIPPED + 1))
        continue
      fi
    fi
  else
    cp "$source" "$target"
    COPIED=$((COPIED + 1))
  fi
done

if [[ "$DRY_RUN" == true ]]; then
  echo
  echo "Summary (dry-run):"
  echo "  copied:      preview only"
  echo "  skipped:     preview only"
  echo "  overwritten: preview only"
else
  echo
  echo "Summary:"
  echo "  copied:      $COPIED"
  echo "  skipped:     $SKIPPED"
  echo "  overwritten: $OVERWRITTEN"
  echo "  project dir: $PARENT_DIR"
fi
