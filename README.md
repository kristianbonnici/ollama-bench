# ollama-bench

A lightweight benchmarking tool for comparing Ollama model performance across different prompts and configurations.

## Usage

```bash
# Run all benchmarks against one or more models
./bench.sh qwen3.5:35b-a3b qwen3.5:35b-a3b-coding-nvfp4

# Run a specific benchmark
./bench.sh -b fastapi-endpoint qwen3.5:35b-a3b

# Run with 5 iterations for more reliable stats
./bench.sh -n 5 qwen3.5:35b-a3b

# List available benchmarks
./bench.sh --list
```

## How It Works

1. **Warmup** — loads the model into VRAM with a throwaway request
2. **Timed runs** — executes N iterations (default 3) with the model kept in memory
3. **Unload** — frees VRAM before the next model
4. **Summary** — computes min/median/mean/max for key metrics (tok/s, eval time, etc.)

## Adding a Benchmark

Create a new folder under `benchmarks/` with a `prompt.txt`:

```
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

Results are saved to `results/<benchmark>/<model>/` with per-run JSON files and a `summary.json`:

```
results/
└── fastapi-endpoint/
    └── qwen3.5_35b-a3b/
        ├── run_1.json
        ├── run_2.json
        ├── run_3.json
        └── summary.json
```

## Requirements

- [Ollama](https://ollama.com) running locally on port 11434
- `jq` for JSON processing
- `curl`
