# ollama-bench

A lightweight benchmarking tool for comparing Ollama model performance across different prompts and configurations. It generates detailed JSON statistics and professional Markdown reports comparing models side-by-side through ranked leaderboards and minimal Mermaid.js charts.

## Usage

```bash
# Run all benchmarks against one or more models
./bench.sh qwen3.5:35b-a3b qwen3.5:35b-a3b-coding-nvfp4

# Run against a remote Ollama server
./bench.sh --host 192.168.1.100:11434 qwen3.5:35b-a3b

# Run a specific benchmark for 5 iterations
./bench.sh -b fastapi-endpoint -n 5 qwen3.5:35b-a3b

# List available benchmarks
./bench.sh --list

# Generate a global Markdown report from cached JSON files (skipping inference)
./bench.sh --report all
```

## Features

- **Professional Markdown Reports**: Generates highly polished, timestamped Markdown summaries containing ranked leaderboards, relative performance metrics, data-dense tables, and native `xychart-beta` bar charts to cleanly visualize tokens-per-second.
- **Extensive Metadata Extraction**: Automatically queries Ollama's API to embed critical metadata in results (parameter size, quantization format, architecture, context length, and supported features).
- **Graceful VRAM Cleanup**: Catches `Ctrl+C` interrupts (via bash traps) to forcefully unload models from VRAM on early termination, rather than holding memory hostage.
- **Fail-Fast Validation**: Instantly verifies model availability before initiating runs to prevent mid-benchmark exceptions.
- **Remote Host Support**: Fully supports standard `OLLAMA_HOST` env vars or the `--host` flag for evaluating network instances.

## How It Works

1. **Pre-flight** — Identifies system specs, connects to Ollama, and validates local/remote model availability.
2. **Warmup** — Loads the model into VRAM (`keep_alive: 5m`) ensuring timing strictly captures token generation.
3. **Timed runs** — Executes N iterations (default 3) aggregating exact internal metric streams.
4. **Unload** — Frees VRAM completely (`keep_alive: 0s`) before queuing the next model.
5. **Reporting** — Computes min/median/mean/max data bounds and renders Markdown representations locally.

## Adding a Benchmark

Create a new folder under `benchmarks/` with a `prompt.txt`:

```text
benchmarks/
└── my-new-bench/
    ├── prompt.txt          # Required: the prompt to send
    └── config.json         # Optional: override default options
```

Optional `config.json` (any field can be omitted to use defaults):

```json
{
  "seed": 42,
  "temperature": 0,
  "num_predict": 600,
  "num_ctx": 8192
}
```

## Results

Results are saved to dynamically timestamped reports and static JSON caches locally:

```text
results/
├── report-fastapi-endpoint_20260403_040127.md
└── fastapi-endpoint/
    └── qwen3.5_35b-a3b/
        ├── run_1.json
        ├── run_2.json
        ├── run_3.json
        └── summary.json
```

## Requirements

- [Ollama](https://ollama.com) (locally, or remotely)
- `jq` for advanced JSON metric aggregations
- `curl`
