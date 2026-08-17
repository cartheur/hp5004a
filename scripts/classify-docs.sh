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

normalize_ocr_text() {
  local src="$1"
  local out="$2"

  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }

    function rtrim(s) {
      sub(/[[:space:]]+$/, "", s)
      return s
    }

    function is_cover_page() {
      return page_nonempty <= 8 && seen_5004a && seen_signature && seen_analyzer
    }

    function is_navigation_page() {
      return saw_toc || saw_list_tables || saw_list_figures
    }

    function is_running_noise(line) {
      if (line == "Model 5004A") return 1
      if (line == "General Information") return 1
      if (line == "Safety Considerations") return 1
      if (line == "Operating Information") return 1
      if (line == "Manual Changes") return 1
      if (line == "List of Tables") return 1
      if (line == "List of Figures") return 1
      if (line ~ /^HP Model 5004A$/) return 1
      if (line ~ /^Page [0-9]+ HP Model 5004A$/) return 1
      if (line ~ /^[ivxlcdm]+\.?$/) return 1
      return 0
    }

    function detect_page_kind() {
      page_kind = "plain"
      for (k = 1; k <= line_count; k++) {
        probe = trim(page_lines[k])
        if (probe ~ /^Table 8-[12]\./ || probe ~ /^8-4[123]\./ || probe ~ /Troubleshooting Signatures/) {
          page_kind = "signature-table"
          return
        }
        if (probe ~ /^8-38\./ || probe ~ /Troubleshooting Flowchart/) {
          page_kind = "flowchart"
        } else if (probe ~ /^8-70\./ || probe ~ /^8-100\./ || probe ~ /Schematic Diagram/ || probe ~ /Input Signals Timing/) {
          page_kind = "figure-heavy"
        } else if (probe ~ /^MANUAL CHANGES MODEL 5004A$/) {
          page_kind = "manual-changes"
        }
      }
    }

    function emit_page_note() {
      if (page_kind == "signature-table") {
        print "> [!warning]"
        print "> OCR is weak on these troubleshooting signature tables. Use this text to find the right page and node names, then verify exact signature values against the matching page image before diagnosing a fault."
        print ""
      } else if (page_kind == "flowchart" || page_kind == "figure-heavy") {
        print "> [!note]"
        print "> This page is layout-sensitive. Use the text for search and context, then confirm flowchart branches, schematic labels, and timing details against the matching page image."
        print ""
      } else if (page_kind == "manual-changes") {
        print "> [!important]"
        print "> This page contains manual-change corrections that override earlier tables or procedures. Apply these changes before trusting older signature or specification values."
        print ""
      }
    }

    function flush_page(    i, j, line, next_line, joined, prev, title) {
      if (!in_page) {
        return
      }

      page_nonempty = 0
      seen_5004a = 0
      seen_signature = 0
      seen_analyzer = 0
      saw_toc = 0
      saw_list_tables = 0
      saw_list_figures = 0

      for (i = 1; i <= line_count; i++) {
        line = trim(page_lines[i])
        if (line == "") {
          continue
        }
        page_nonempty++
        if (line == "5004A") seen_5004a = 1
        if (line == "SIGNATURE") seen_signature = 1
        if (line == "ANALYZER") seen_analyzer = 1
        if (line == "TABLE OF CONTENTS" || line == "TABLE OF CONTENTS (Continued)") saw_toc = 1
        if (line == "LIST OF TABLES") saw_list_tables = 1
        if (line == "LIST OF FIGURES") saw_list_figures = 1
      }

      if (is_cover_page()) {
        line_count = 0
        blank_count = 0
        return
      }

      if (is_navigation_page()) {
        print "[table of contents and list pages omitted; use the Diagnostic Navigation summary above for fast access]"
        print ""
        line_count = 0
        blank_count = 0
        return
      }

      detect_page_kind()
      emit_page_note()

      for (i = 1; i <= line_count; i++) {
        line = trim(page_lines[i])

        if (line == "") {
          blank_count++
          if (blank_count <= 2) {
            print ""
          }
          continue
        }

        blank_count = 0

        if (is_running_noise(line)) {
          continue
        }

        if (line ~ /^SECTION [IVX]+$/) {
          title = ""
          for (j = i + 1; j <= line_count; j++) {
            next_line = trim(page_lines[j])
            if (next_line != "") {
              title = next_line
              break
            }
          }
          if (title != "" && title !~ /^## Page /) {
            print "### " line " - " title
            print ""
            i = j
            continue
          }
        }

        joined = rtrim(page_lines[i])
        while (joined ~ /-$/ && i < line_count) {
          next_line = trim(page_lines[i + 1])
          if (next_line ~ /^[a-z]/) {
            sub(/-$/, "", joined)
            joined = joined next_line
            i++
          } else {
            break
          }
        }

        if (joined ~ /^[0-9]+-[0-9]+$/) {
          continue
        }

        if (joined == "v" || joined == "vi") {
          continue
        }

        print joined
      }

      print ""
      line_count = 0
      blank_count = 0
    }

    /^## Page [0-9]+$/ {
      flush_page()
      in_page = 1
      print $0
      print ""
      next
    }

    {
      gsub(/\r/, "")
      page_lines[++line_count] = $0
    }

    END {
      flush_page()
    }
  ' "$src" > "$out"
}

render_ocr_pdf() {
  local src="$1"
  local out="$2"
  local text_out="${out%.md}.txt"
  local title="$3"
  local category="$4"
  local printed="$5"
  local diag_scope="$6"
  local notes="$7"
  local pages
  local figures_dir
  local ocr_dir="$TMP_DIR/ocr-text"
  local raw_text="$TMP_DIR/raw-ocr.txt"
  local cleaned_text="$TMP_DIR/cleaned-ocr.txt"
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

  {
    printf '%s\n\n' "$title"
    printf 'Source PDF: %s\n' "${src#$ROOT_DIR/}"
    printf 'Category: %s\n' "$category"
    printf 'Printed: %s\n' "$printed"
    printf 'Pages: %s\n' "$pages"
    printf 'Conversion: pdftoppm + tesseract OCR with page markers\n'
    printf 'Diagnostic Scope: %s\n' "$diag_scope"
    printf 'Notes: %s\n\n' "$notes"
  } > "$text_out"

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

  : > "$raw_text"
  for text_file in "$ocr_dir"/*.txt; do
    [ -e "$text_file" ] || continue
    page_id="$(basename "$text_file" .txt)"
    page_num=$((10#$page_id))
    printf '## Page %s\n\n' "$page_num" >> "$raw_text"
    cat "$text_file" >> "$raw_text"
    printf '\n\n' >> "$raw_text"
  done

  normalize_ocr_text "$raw_text" "$cleaned_text"
  cat "$cleaned_text" >> "$out"
  cat "$cleaned_text" >> "$text_out"
}

write_index() {
  mkdir -p "$OUT_DIR"
  cat > "$OUT_DIR/index.md" <<'EOF'
# HP 5004A Document Classification Index

This folder is organized so an agent can answer HP 5004A usage, calibration, and repair questions without reopening the raw manual for every step. The emphasis is on operating workflow, signature-analysis practice, theory of operation, board-level troubleshooting, and service documentation.

## Document Registry

### HP 5004A Signature Analyzer Operating and Service Manual

- File: `docs-classified/service/05004-90001.md`
- Text Export: `docs-classified/service/05004-90001.txt`
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
