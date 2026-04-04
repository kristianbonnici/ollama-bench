# Repository Guidelines

## Project Structure

```text
ollama-bench/
├── bench.sh              # Main benchmark script (Bash)
├── benchmarks/           # Benchmark definitions
│   ├── fastapi-endpoint/ # Each benchmark has prompt.txt and optional config.json
│   └── debug-async-cache/
├── results/              # Generated output (JSON runs, summaries, Markdown reports)
└── README.md
```

- `benchmarks/<name>/prompt.txt` — required prompt sent to Ollama.
- `benchmarks/<name>/config.json` — optional overrides for seed, temperature, num_predict, num_ctx.
- `results/<bench>/<model>/run_N.json` — raw Ollama response per iteration.
- `results/<bench>/<model>/summary.json` — computed statistics.
- `results/report-*.md` — timestamped Markdown reports.

## Build & Development Commands

No build step. The project is a single Bash script with runtime dependencies: `ollama`, `jq`, `curl`, and `bc`.

```bash
# Run all benchmarks against one or more models
./bench.sh <model> [model2 ...]

# Run a specific benchmark
./bench.sh -b fastapi-endpoint <model>

# Generate a report from cached results (no inference)
./bench.sh --report all

# List available benchmarks
./bench.sh --list
```

## Coding Style & Conventions

- Bash with `set -euo pipefail` strict mode.
- Functions use `snake_case`. Local variables are declared with `local`.
- Constants and globals use `UPPER_SNAKE_CASE`.
- Use `jq` for all JSON construction and parsing — no hand-rolled JSON strings.
- Prefer `$(...)` over backticks for command substitution.
- Quote all variable expansions unless arithmetic context requires otherwise.

## Testing Guidelines

There is no automated test suite. Verify changes by running the script against a live Ollama instance and inspecting the generated JSON summaries and Markdown reports for correctness.

## Commit & Pull Request Guidelines

Commit messages follow the conventional commits style observed in this repo:

- `feat:` for new features (e.g., `feat: redesign markdown report`)
- `docs:` for documentation changes (e.g., `docs: format speed comparison table`)
- `fix:` for bug fixes

Keep commits focused on a single logical change. PR descriptions should explain what changed and why.
Do not add co-author trailers, bot attribution, or extra commit metadata unless the user explicitly asks for it.

## Adding a Benchmark

Create `benchmarks/<name>/prompt.txt` with the prompt text. Optionally add `config.json` to override defaults. Keep `temperature=0` and `seed=42` for reproducible comparisons.
