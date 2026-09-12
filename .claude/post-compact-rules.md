## Critical Rules (re-injected after context compaction)
- Strict incremental TDD: each phase must compile and pass tests before proceeding
- No speculative behavior: if uncertain, document with TODO, do not guess
- Bubilator88Core is pure Swift, no platform APIs
- BIOS files at `~/Library/Application Support/Bubilator88/` — never bundle them
- The core is a separate repo cloned at `../Bubilator88Core`; run
  `cd ../Bubilator88Core && swift test` for unit tests and commit core changes there
- Run `python3 scripts/regression_compare.py` for pixel regression (the
  single source of truth; 15 scenarios, pixel-exact with per-scenario
  tolerance)
- Architecture details: see docs/develop/ARCHITECTURE.md
- Known pitfalls: see docs/develop/KNOWN_PITFALLS.md
