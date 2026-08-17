#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS_DIR="$ROOT_DIR/docs"
OUT_DIR="$ROOT_DIR/docs-classified"
TMP_DIR="$(mktemp -d)"
OCR_JOBS="${OCR_JOBS:-4}"
trap 'rm -rf "$TMP_DIR"' EXIT

render_page_images() {
  local src="$1"
  local out_dir="$2"
  local dpi="${3:-150}"

  mkdir -p "$out_dir"
  pdftoppm -r "$dpi" -png "$src" "$out_dir/page" >/dev/null 2>&1
}

render_ocr_pdf() {
  local src="$1"
  local out="$2"
  local title="$3"
  local category="$4"
  local printed="$5"
  local diag_scope="$6"
  local notes="$7"
  local pages
  local figures_dir
  local ocr_dir="$TMP_DIR/ocr-text"
  local image
  local page_id
  local page_num
  local text_file

  mkdir -p "$(dirname "$out")"
  pages="$(pdfinfo "$src" | awk -F': *' '/^Pages:/ {print $2}')"
  figures_dir="${out%.md}/figures"
  mkdir -p "$ocr_dir"

  {
    printf '# %s\n\n' "$title"
    printf -- '- Source PDF: `%s`\n' "${src#$ROOT_DIR/}"
    printf -- '- Category: `%s`\n' "$category"
    printf -- '- Printed: `%s`\n' "$printed"
    printf -- '- Pages: `%s`\n' "$pages"
    printf -- '- Conversion: `pdftoppm` + `tesseract` OCR with per-page markers\n'
    printf -- '- Figures: `%s`\n' "${figures_dir#$ROOT_DIR/}"
    printf -- '- Diagnostic Scope: %s\n' "$diag_scope"
    printf -- '- Notes: %s\n\n' "$notes"
    printf '## Agent Notes\n\n'
    printf 'This manual is scan-heavy. Use the OCR text for search and rough citation, but verify equations, front-panel legends, pin numbers, thresholds, and timing references against the rendered page images when the wording looks suspicious.\n\n'
    printf '## Diagnostic Navigation\n\n'
    printf -- '- `Section I`: general information, safety, specifications, serial coverage\n'
    printf -- '- `Section II`: installation, power selection, and shipment guidance\n'
    printf -- '- `Section III`: operating information, self-test, and signature-analysis workflow\n'
    printf -- '- `Section IV`: performance tests\n'
    printf -- '- `Section V`: adjustments and service procedures\n'
    printf -- '- `Section VI`: replaceable parts, schematics, and board-level references\n\n'
    printf '## Cleanup Notes\n\n'
    printf 'This classifier uses the cleaned PDF with the Agilent errata frontmatter removed so the working content stays focused on the original HP manual.\n\n'
    printf '## Extracted Text\n\n'
  } > "$out"

  render_page_images "$src" "$figures_dir" 150

  for image in "$figures_dir"/page-*.png; do
    (
      page_id="$(basename "$image" .png | sed 's/^page-//')"
      tesseract "$image" stdout --psm 6 2>/dev/null > "$ocr_dir/$page_id.txt"
    ) &
    if (( $(jobs -r | wc -l) >= OCR_JOBS )); then
      wait -n
    fi
  done
  wait

  for text_file in "$ocr_dir"/*.txt; do
    [ -e "$text_file" ] || continue
    page_id="$(basename "$text_file" .txt)"
    page_num=$((10#$page_id))

    printf '## Page %s\n\n' "$page_num" >> "$out"
    cat "$text_file" >> "$out"
    printf '\n\n' >> "$out"
  done
}

write_index() {
  mkdir -p "$OUT_DIR"
  cat > "$OUT_DIR/index.md" <<'EOF'
# HP 5004A Document Classification Index

This folder is organized so an agent can answer HP 5004A usage, calibration, and repair questions without reopening the raw manual for every step. The emphasis is on operating workflow, signature-analysis practice, theory of operation, board-level troubleshooting, and service documentation.

## Document Registry

### HP 5004A Signature Analyzer Operating and Service Manual

- File: `docs-classified/service/05004-90001.md`
- Source PDF: `docs/05004-90001.pdf`
- Category: `signature-analyzer-operating-service-manual`
- Best for: operating instructions, signature-analysis setup, specification lookup, calibration guidance, circuit understanding, and repair/service context
- Fault domains:
  - unexpected signature readings or confusing analyzer setup
  - power, calibration, or measurement-threshold concerns
  - switch, display, or front-panel behavior questions
  - board-level troubleshooting and schematic lookup
  - part identification, disassembly, and service adjustments
- High-value sections:
  - `Section III`: operating instructions, self-test, and measurement workflow
  - `Section IV`: performance tests
  - `Section V`: adjustments and service checks
  - `Section VI`: parts, schematics, and reference drawings
- Figures: `docs-classified/service/05004-90001/figures/`

## Agent Usage Rules

- Start with `Section III` for normal operating questions and signature-analysis procedure.
- Switch to `Section IV` when you need to confirm whether the instrument itself is in tolerance.
- Use `Section V` when behavior suggests the analyzer itself needs adjustment or service.
- Use the page images when OCR text looks garbled around symbols, component values, or schematic references.
EOF
}

mkdir -p "$OUT_DIR/service"

render_ocr_pdf \
  "$DOCS_DIR/05004-90001.pdf" \
  "$OUT_DIR/service/05004-90001.md" \
  "HP 5004A Signature Analyzer Operating and Service Manual" \
  "signature-analyzer-operating-service-manual" \
  "March 1977" \
  "Primary source for HP 5004A operation, performance verification, circuit understanding, adjustment, and service troubleshooting." \
  'The manual is primarily scan-based, so OCR is provided for search while page images remain the source of truth for schematics, tables, symbols, and exact instrument legends.'

write_index

printf 'Wrote classified docs to %s\n' "$OUT_DIR"
