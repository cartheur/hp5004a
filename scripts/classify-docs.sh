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

    function alpha_count(s, t) {
      t = s
      gsub(/[^A-Za-z]/, "", t)
      return length(t)
    }

    function digit_count(s, t) {
      t = s
      gsub(/[^0-9]/, "", t)
      return length(t)
    }

    function is_cover_page() {
      return page_nonempty <= 8 && seen_5004a && seen_signature && seen_analyzer
    }

    function is_navigation_page() {
      return saw_toc || saw_list_tables || saw_list_figures
    }

    function is_figure_only_page() {
      return saw_figure_caption && !saw_paragraph_ref && !saw_section_marker && !saw_table_caption && page_nonempty <= 14
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

    function is_obvious_ocr_garbage(line, compact, letters, digits) {
      compact = line
      gsub(/[[:space:]]+/, "", compact)
      letters = alpha_count(compact)
      digits = digit_count(compact)

      if (line ~ /^Figure [0-9-]+\./) return 0
      if (line ~ /^Table [0-9-]+\./) return 0
      if (line ~ /^## Page /) return 0
      if (line ~ /^### SECTION /) return 0
      if (line ~ /^[0-9]+-[0-9]+\./) return 0
      if (line ~ /^[A-Z][A-Z0-9 ,()\/.-]+:$/) return 0
      if (line ~ /^(WARNING|CAUTION|NOTE|GENERAL|OPERATION|SERVICE)$/) return 0
      if (line ~ /^(START|STOP|CLOCK|GATE|SELF-TEST|HOLD|LINE|PROBE)([[:space:][:punct:]].*)?$/) return 0

      if (compact == "") return 0
      if (compact ~ /^[[:punct:][:digit:]]+$/ && length(compact) <= 10) return 1
      if (line ~ /^[A-Za-z]?[[:space:]]*[_=-][[:space:]]*[A-Za-z]{0,4}$/) return 1
      if (line ~ /^[[:space:][:punct:]]*[A-Za-z]{1,3}[[:space:][:punct:]]*$/ && letters <= 3) return 1
      if (line ~ /[~_^|\\<>]/ && letters <= 6) return 1
      if (line ~ /[\/\\]/ && letters <= 4 && digits <= 2) return 1
      if (line ~ /[=|]/ && letters <= 5 && digits <= 3) return 1
      if (page_kind != "plain" && letters <= 5 && digits <= 3 && line !~ /[.:]/) return 1
      if (page_kind != "plain" && line ~ /^[[:space:][:punct:]A-Za-z0-9]+$/ && letters <= 3 && digits <= 2) return 1

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
      saw_figure_caption = 0
      saw_table_caption = 0
      saw_paragraph_ref = 0
      saw_section_marker = 0

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
        if (line ~ /^Figure [0-9-]+\./) saw_figure_caption = 1
        if (line ~ /^Table [0-9-]+\./) saw_table_caption = 1
        if (line ~ /^[0-9]+-[0-9]+\./) saw_paragraph_ref = 1
        if (line ~ /^SECTION [IVX]+$/) saw_section_marker = 1
      }

      if (is_cover_page()) {
        line_count = 0
        blank_count = 0
        return
      }

      print page_header
      print ""

      if (is_navigation_page()) {
        print "[table of contents and list pages omitted; use the Diagnostic Navigation summary above for fast access]"
        print ""
        line_count = 0
        blank_count = 0
        return
      }

      if (is_figure_only_page()) {
        detect_page_kind()
        emit_page_note()
        for (i = 1; i <= line_count; i++) {
          line = trim(page_lines[i])
          if (line ~ /^Figure [0-9-]+\./) {
            print line
            print ""
          }
        }
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

        if (is_obvious_ocr_garbage(line)) {
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
      page_header = $0
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
    printf '## Trusted Working Notes\n\n'
    printf 'These notes are curated for agent use and should be preferred over raw OCR when they cover the same material.\n\n'
    printf '### Instrument Model\n\n'
    printf -- '- The 5004A is a signature analyzer for compatible digital logic systems, not a general-purpose waveform viewer.\n'
    printf -- '- It observes a DUT data stream during a gated time window and compresses that stream into a 4-character signature.\n'
    printf -- '- Correct use requires known-good signatures from the DUT manual or service reference.\n'
    printf -- '- If the DUT is not designed for signature analysis, the 5004A cannot produce meaningful diagnostic answers by itself.\n\n'
    printf '### Self-Test Interpretation\n\n'
    printf -- '- SELF-TEST is the first trust gate: do not trust DUT diagnosis until the analyzer passes it.\n'
    printf -- '- In SELF-TEST, the pod START/STOP/CLOCK leads are looped to the front-panel test receptacles and the data probe is inserted into the `PROBE TEST` connector.\n'
    printf -- '- Expected behavior is a brief all-segments display followed by repeating known signatures; the OCR around exact glyphs is noisy, so verify exact displayed characters against the page image when needed.\n'
    printf -- '- If LEDs, the `GATE` lamp, the probe-tip lamp, or the 4-digit display do not behave as expected during SELF-TEST, troubleshoot the analyzer before touching a DUT.\n'
    printf -- '- The manual-change section corrects the troubleshooting flow entry conditions for SELF-TEST-driven diagnosis and should override older flowchart wording.\n\n'
    printf '### Diagnostic Workflow\n\n'
    printf -- '- First verify the analyzer itself with the built-in SELF-TEST before trusting any DUT result.\n'
    printf -- '- Then connect `START`, `STOP`, `CLOCK`, and `GND` from the gating pod to the DUT points named in the DUT manual.\n'
    printf -- '- Set the START/STOP/CLOCK edge-select switches to match the intended active edge from the DUT procedure.\n'
    printf -- '- Probe DUT signature nodes and compare displayed signatures against the known-good values from the DUT documentation.\n'
    printf -- '- If most or all signatures are wrong, suspect setup, gating polarity, clocking, or reference-signature mismatch before assuming multiple hardware faults.\n'
    printf -- '- When clocking is slow, ignore the first transient reading and trust repeated identical signatures.\n\n'
    printf '### Control Semantics\n\n'
    printf '| Control or Indicator | Practical Meaning |\n'
    printf '| --- | --- |\n'
    printf '| `SELF-TEST` | Verifies the analyzer itself using its built-in test path. Run this before DUT work. |\n'
    printf '| `HOLD` | Freezes a one-time signature so it can be read or compared. |\n'
    printf '| `START` / `STOP` / `CLOCK` switches | Select the active edge polarity for the three gating inputs. |\n'
    printf '| `GATE` lamp | Repetitive blinking usually means START/STOP gating is being recognized. |\n'
    printf '| `UNSTABLE SIGNATURE` lamp | Successive signatures differ; often indicates changing input data, timing issues, or an unstable condition. |\n'
    printf '| Probe-tip lamp | Bright=`high`, dim=`bad/mid-level`, off=`low`; short pulses are stretched so activity is visible. |\n\n'
    printf '### Internal Operation Summary\n\n'
    printf -- '- The gating pod receives DUT `START`, `STOP`, and `CLOCK` signals and converts them to high-speed internal levels.\n'
    printf -- '- Edge-selection switches decide whether rising or falling transitions are treated as active control events.\n'
    printf -- '- Gate-control logic opens a measurement window between START and STOP and drives the `GATE` indicator.\n'
    printf -- '- The data probe classifies the measured node as high, low, or bad-level, then hands that data to the main assembly.\n'
    printf -- '- A pseudo-random word generator reduces the captured bit stream to the displayed 4-character signature.\n'
    printf -- '- An internal comparator checks successive signatures and lights `UNSTABLE SIGNATURE` when they do not repeat consistently.\n\n'
    printf '### Repair Playbook\n\n'
    printf -- '- Begin with power, fuse, and SELF-TEST status.\n'
    printf -- '- If SELF-TEST fails broadly, use the built-in indicators first: power rails, `GATE`, display activity, and probe-tip lamp behavior.\n'
    printf -- '- Use the NORMAL/SERVICE switch and the corrected troubleshooting flow only after basic SELF-TEST observations are known.\n'
    printf -- '- Use Table 8-1 for major test-point direction-finding and Table 8-2 for deeper board-level checks, but treat both as image-verified sources because OCR is weak there.\n'
    printf -- '- For internal service, combine the service prose with component locator pages and the schematic image set; do not rely on OCR alone for connector IDs or pin numbers.\n\n'
    printf '### Manual-Change Overrides\n\n'
    printf -- '- Treat the `MANUAL CHANGES` section as authoritative when it conflicts with earlier pages.\n'
    printf -- '- Data-probe threshold corrections override the original specification and performance-test limits.\n'
    printf -- '- Troubleshooting flowchart entry conditions were corrected: `SELF-TEST` must be `IN`; `START`, `STOP`, `CLOCK`, and `HOLD` must be `OUT`.\n'
    printf -- '- Table 8-1 and Table 8-2 signature values contain known corrections; verify exact values against the corrected pages and the page images.\n'
    printf -- '- Connector and board reference corrections in the manual-changes pages matter when following schematic or parts references.\n\n'
    printf '### High-Value Manual Corrections\n\n'
    printf -- '- Corrected data-probe threshold: logic one `2.0 V +0.1/-0.4`; logic zero `0.8 V +0.4/-0.0`.\n'
    printf -- '- Corrected performance-test limits track that updated threshold and should be used instead of the original looser text.\n'
    printf -- '- Corrected troubleshooting flowchart entry: `SELF-TEST IN`, `START OUT`, `STOP OUT`, `CLOCK OUT`, `HOLD OUT`.\n'
    printf -- '- Corrected signature references include at least Table 8-1 test-point values and multiple Table 8-2 NORMAL/SERVICE entries.\n'
    printf -- '- Corrected connector references on the main board and pod matter when tracing wiring or comparing boards to the schematic.\n\n'
    printf '### Verified Tables\n\n'
    printf 'These tables were manually verified against the rendered page images and should be preferred over raw OCR when the same data appears below.\n\n'
    printf '#### Verified Core Specifications\n\n'
    printf '| Area | Verified Values |\n'
    printf '| --- | --- |\n'
    printf '| Display characters | `0 1 2 3 4 5 6 7 8 9 A C F H P U` |\n'
    printf '| Indicator stretch | `GATE` / `UNSTABLE SIGNATURE`: `100 ms`; probe pulse stretch: `50 ms`; minimum pulse width: `10 ns` |\n'
    printf '| Classification probability | Correct stream as correct: `100%%`; faulty stream as faulty: `99.998%%` |\n'
    printf '| Minimum gate timing | Minimum gate length: `1 clock cycle`; minimum timing from last `STOP` to next `START`: `1 clock cycle` |\n'
    printf '| Data probe input | Input impedance: `50 KΩ to 1.4 V`, nominal; shunted by `7 pF`, nominal |\n'
    printf '| Original data probe thresholds | Logic one: `2.0 V +0.2/-0.3`; logic zero: `0.8 V +0.3/-0.2` |\n'
    printf '| Data probe timing | Setup time: `15 ns` with `0.2 V` overdrive; hold time: `0 ns` |\n'
    printf '| START/STOP/CLOCK inputs | Input impedance: `50 KΩ to 1.4 V`, nominal; shunted by `7 pF`; threshold: `1.4 V ±0.6` with about `0.1 V` hysteresis |\n'
    printf '| START/STOP timing | Setup time: `25 ns`; hold time: `0 ns` |\n'
    printf '| Clock input | Maximum clock frequency: `10 MHz`; minimum high or low state time: `50 ns` |\n'
    printf '| Overload protection | All inputs: `±150 V continuous`, `±250 V intermittent`, `250 V ac for 1 minute` |\n'
    printf '| Operating environment | `0–55 °C`, `95%% RH at 40 °C`, altitude `4,600 m` |\n'
    printf '| Line power options | Option `100`: `100 V ac +5%%/-10%% 48–440 Hz`; Option `120`: `120 V ac +5%%/-10%% 48–440 Hz`; Option `220`: `220 V ac +5%%/-10%% 48–66 Hz`; Option `240`: `240 V ac +5%%/-10%% 48–66 Hz` |\n'
    printf '| Physical | Net weight `2.5 kg / 5.5 lb`; shipping `7.7 kg / 17 lb`; size `90 mm x 215 mm x 300 mm` excluding tilt bale, probes, and pouch |\n\n'
    printf '#### Verified Recommended Test Equipment\n\n'
    printf '| Instrument | Critical Specs | Recommended HP Model |\n'
    printf '| --- | --- | --- |\n'
    printf '| Pulse Generator | `5 ns–100 ns` delay | `8007B` |\n'
    printf '| Pulse Generator | `10 MHz`, `5 V` pulse | `8013B` |\n'
    printf '| Oscilloscope with dual-trace vertical amplifier | `100 MHz` | `182C`, `1805A/1825A` |\n'
    printf '| Power Supply | `5 V` | `6111A` |\n'
    printf '| Digital Voltmeter | `10 V` | `3476A` |\n'
    printf '| Resistor | `1000 Ω 5%% 1/4 W` | `0683-1025` |\n'
    printf '| Resistor | `50 Ω 5%% 2 W` | `0698-3311` |\n'
    printf '| Capacitor | `0.1 µF ±20%% 25 V` | `0170-0022` |\n'
    printf '| Capacitor | `10 µF +75/-10%% 25 V` | `0180-0059` |\n'
    printf '| Logic Probe | `TTL compatibility` | `545A` |\n'
    printf '| Logic Pulser | `TTL compatibility` | `546A` |\n'
    printf '| Logic Current Tracer | `1 mA–1 A range` | `547A` |\n\n'
    printf '#### Verified Corrected Threshold and Test Limits\n\n'
    printf '| Item | Verified Corrected Value |\n'
    printf '| --- | --- |\n'
    printf '| Data probe threshold, logic one | `2.0 V +0.1/-0.4 V` |\n'
    printf '| Data probe threshold, logic zero | `0.8 V +0.4/-0.0 V` |\n'
    printf '| Logic-level performance test, dim transition | `0.8 V +0.4/-0.0 V` |\n'
    printf '| Performance record, probe light dim | Min `+0.8 V`; Max `+1.2 V` |\n'
    printf '| Performance record, probe light bright | Min `+1.6 V`; Max `+2.1 V` |\n\n'
    printf '#### Verified Troubleshooting Corrections\n\n'
    printf '| Reference | Verified Correction |\n'
    printf '| --- | --- |\n'
    printf '| Flowchart preliminary step | `SELF-TEST IN`; `START OUT`; `STOP OUT`; `CLOCK OUT`; `HOLD OUT` |\n'
    printf '| Table 8-1 correction | Test Point `4`, `NORMAL` signature = `A446` |\n'
    printf '| Table 8-1 correction | Test Point `7`, `SERVICE` signature = `GP6F` |\n\n'
    printf '### Trust Policy\n\n'
    printf -- '- Trust prose paragraphs, operating steps, and high-level theory sections as generally usable OCR.\n'
    printf -- '- Be cautious with front-panel artwork, flowcharts, schematic pages, component locator pages, and signature tables.\n'
    printf -- '- Never quote an exact signature value, pin number, or locator label from a page that carries an OCR warning without checking the corresponding page image.\n'
    printf -- '- For repair work inside the instrument, combine the prose sections with the rendered figures rather than relying on OCR alone.\n\n'
    printf '## Diagnostic Navigation\n\n'
    printf -- '- `Section I`: general information, safety, specifications, serial coverage\n'
    printf -- '- `Section II`: installation, power selection, and shipment guidance\n'
    printf -- '- `Section III`: operating information, self-test, and signature-analysis workflow\n'
    printf -- '- `Section IV`: performance tests\n'
    printf -- '- `Section V`: adjustments and line-voltage configuration\n'
    printf -- '- `Section VI`: replaceable parts and ordering data\n'
    printf -- '- `Section VII`: manual changes and corrections that can override earlier pages\n'
    printf -- '- `Section VIII`: troubleshooting flow, signature tables, disassembly, theory, and schematics\n'
    printf -- '- `Pages 44-47`: manual-change corrections worth checking before precision diagnostic work\n'
    printf -- '- `Pages 59-62`: troubleshooting flow and signature tables; low OCR trust, high diagnostic value\n'
    printf -- '- `Pages 68-70`: gate-control theory, data path, pseudo-random word generator, and schematic notes\n\n'
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
  - `Section VII`: manual changes and verified corrections
  - `Section VIII`: troubleshooting, disassembly, theory, and schematics
  - `Verified Tables` near the top of the Markdown for fast trusted lookup
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
