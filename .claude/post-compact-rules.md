## Critical Rules (re-injected after context compaction)
- Strict incremental TDD: each phase must compile and pass tests before proceeding
- No speculative behavior: if uncertain, document with TODO, do not guess
- EmulatorCore is pure Swift, no platform APIs
- BIOS files at `~/Library/Application Support/Bubilator88/` — never bundle them
- Run `cd Packages/EmulatorCore && swift test` for unit tests
- Run `python3 scripts/regression_compare.py` for pixel regression (the
  single source of truth; 15 scenarios, pixel-exact with per-scenario
  tolerance)
- Architecture details: see docs/ARCHITECTURE.md
- Known pitfalls: see docs/KNOWN_PITFALLS.md
