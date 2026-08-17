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
