# ollama-bench

[![License: MIT](https://img.shields.io/badge/License-MIT-d7afff.svg)](LICENSE)

`ollama-bench` is a lightweight benchmark harness for comparing Ollama models in terms that actually help you choose what to run day to day. Instead of only telling you that one model is "faster," it helps answer questions like:

- Is this model fast enough for interactive chat?
- Will this quant feel good for coding loops and code review prompts?
- How much latency am I buying when I increase context, size, or quality?
- Which model is the best fit for overnight batch jobs vs live agent workflows?

It runs realistic prompts, captures Ollama's internal timing metrics, and generates JSON summaries plus Markdown reports with leaderboards and charts.

## Why This Exists

A raw `tok/s` number is only useful if you know what it feels like in practice.

For local inference, the difference between `7 tok/s` and `25 tok/s` is the difference between "I can tolerate this" and "this feels fluid." The goal of this repo is to make model speed easier to interpret for actual usage: chat, coding, debugging, drafting, and automation.

This is not a universal benchmark suite and it does not claim lab-grade rigor. It is a practical comparison tool for your own hardware, your own prompts, and your own tradeoffs.

## What The Numbers Mean

The script records a few core metrics from Ollama's response payloads:

- `Eval tok/s`: Generation throughput for output tokens. This is the main number to watch for perceived responsiveness.
- `Prompt eval tok/s`: Prompt ingestion throughput. This matters more as prompts and context windows get larger.
- `Eval time`: Time spent generating the answer tokens.
- `Total time`: End-to-end request time, including load and prompt processing overhead.
- `Load time`: Model loading overhead for each run.

For most human-facing workflows, `eval tok/s` is the best primary comparison metric. Prompt speed and total latency still matter, especially for long-context tasks, RAG pipelines, or workflows that repeatedly resend large prompts.

The reports compute min, median, mean, and max. In practice, median is usually the most useful comparison number because it is less distorted by one-off slow runs.

## Usability Thresholds

These are rules of thumb, not hard guarantees. Different models can feel faster or slower than the same `tok/s` number suggests depending on prompt length, backend, hardware, and whether the model fully fits in VRAM.

| Speed (tok/s) | Experience Level    | Best Suited For                                                                                                  |
| :------------ | :------------------ | :--------------------------------------------------------------------------------------------------------------- |
| `< 5`         | Background          | Offline batch processing or running massive models overnight. Usually too slow for interactive use.              |
| `5 - 10`      | Bare Minimum        | Roughly around human reading speed. Usable, but you will feel the model thinking and wait for outputs to finish. |
| `15 - 30`     | Good / Comfortable  | Interactive chat, standard Q&A, and general reading. The model usually stays ahead of you.                       |
| `40 - 60`     | Very Fast           | Coding tasks, iterative drafting, debugging loops, and brainstorming where you want fast regenerate cycles.      |
| `100+`        | Agentic / Real-Time | Automated agents, RAG pipelines, and real-time voice or translation style workloads.                             |

Treat these bands as "how it tends to feel" rather than "how every model always behaves."

## What Affects Speed Most

- `GPU VRAM`: The biggest factor. If the model fits cleanly in VRAM, speed is usually much better. Spilling layers into system RAM hurts throughput hard.
- `Quantization`: Lower-bit quants like Q4 are often much faster than heavier quants like Q8, usually with a manageable quality tradeoff. Very aggressive quants can get fast but degrade output quality more noticeably.
- `Context length`: Longer contexts slow inference down. Even if generation speed stays decent, prompt ingestion and total latency can climb quickly.
- `Backend/runtime`: Ollama, `llama.cpp`, `vLLM`, and ExLlama-class backends can behave very differently on the same hardware and model family.
- `CPU vs GPU`: CPU inference can be fine for smaller models or background tasks, but larger models often become frustratingly slow for interactive use.
- `Model architecture`: Two models with similar parameter counts can still perform very differently because of architecture and implementation details.

## Installation

### Prerequisites

- [Ollama](https://ollama.com) running locally or on a reachable host
- `jq`, `curl`, and `bc` (pre-installed on most macOS/Linux systems)

### Setup

```bash
git clone https://github.com/kristianbonnici/ollama-bench.git
cd ollama-bench
chmod +x bench.sh
```

Verify it works:

```bash
./bench.sh --list
```

## Quick Start

### 1. Choose the models you want to compare

Pick candidates you would realistically use on your machine, for example different sizes or quants of the same model family.

### 2. Run one benchmark or all benchmarks

```bash
# Run all benchmarks against one or more models
./bench.sh qwen3.5:35b-a3b qwen3.5:35b-a3b-coding-nvfp4

# Run against a remote Ollama server
./bench.sh --host 192.168.1.100:11434 qwen3.5:35b-a3b

# Run a specific benchmark for 5 iterations
./bench.sh -b fastapi-endpoint -n 5 qwen3.5:35b-a3b

# List available benchmarks
./bench.sh --list

# Generate a Markdown report from cached JSON results without rerunning inference
./bench.sh --report all
```

### 3. Inspect the generated summaries

The script writes per-run JSON, per-model summaries, and timestamped Markdown reports under `results/`.

### 4. Compare across workloads, not just one score

A model that looks great on a short coding prompt may feel worse on long-context review tasks. Compare performance across prompts that resemble your real usage.

## How The Benchmark Works

1. It validates the requested models against the target Ollama server.
2. It captures system and Ollama version metadata for the run.
3. It optionally warms the model into memory so timed runs focus on inference rather than cold loading.
4. It runs each benchmark prompt multiple times and stores the raw Ollama JSON responses.
5. It computes summary statistics and generates Markdown reports with per-benchmark tables, leaderboards, and charts.
6. It unloads models between runs to avoid VRAM staying occupied unnecessarily.

The defaults are intentionally stable for comparison:

- `temperature=0`
- fixed `seed=42`
- `num_ctx=8192`
- `num_predict=600`
- `3` timed iterations by default

That setup is meant to reduce noise so model comparisons are fairer.

## How To Read Reports

The Markdown report is designed to answer two different questions:

- Which model is fastest overall across the available benchmarks?
- Which model is fastest for this specific workload?

When reading results:

- Start with median `Eval tok/s` for responsiveness.
- Check `Total time` to spot models that look decent on throughput but still feel slow overall.
- Check `Prompt eval tok/s` if your real tasks involve large prompts, codebases, or long chat history.
- Use multiple iterations because single-run results can be noisy.
- Compare models on the same benchmark settings and host, otherwise the numbers are not meaningfully comparable.

The global report ranks models by median `eval tok/s` averaged across benchmarks. That is useful for a quick leaderboard, but your own prompt mix should still be the final judge.

## Existing Benchmarks

The included benchmarks are small but intentional examples of real work:

- `fastapi-endpoint`: A concise code-generation task that favors practical coding throughput.
- `debug-async-cache`: A deeper debugging and code-review style prompt with a larger output budget.

They are starting points, not a complete benchmark philosophy. If your real work is long-context editing, RAG, SQL generation, summarization, or agent loops, create prompts that look like those tasks.

Synthetic prompts can be useful for stress tests, but they often fail to capture how a model feels in actual use.

## Adding Your Own Benchmark

Create a new folder under `benchmarks/` with a `prompt.txt`:

```text
benchmarks/
└── my-new-bench/
    ├── prompt.txt          # Required: prompt sent to Ollama
    └── config.json         # Optional: override default options
```

Optional `config.json`:

```json
{
  "seed": 42,
  "temperature": 0,
  "num_predict": 600,
  "num_ctx": 8192
}
```

Good benchmark prompts usually:

- resemble a real task you care about
- have a stable expected output shape
- avoid randomness when you want fair comparisons
- use an output budget large enough to expose throughput differences

Keeping `temperature=0` and a fixed `seed` makes comparisons more repeatable. If you do change prompt length, context, or output budget, treat that as a different workload and compare like with like.

## Results Layout

Results are saved as timestamped reports plus cached JSON files:

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

The JSON files are useful if you want to post-process or graph the numbers yourself later.

## Contributing

Contributions are welcome. To get started:

1. Fork the repository and create a feature branch.
2. Make your changes, keeping commits focused on a single logical change.
3. Use conventional commit messages (`feat:`, `fix:`, `docs:`).
4. Test by running the script against a live Ollama instance and verifying the generated JSON summaries and Markdown reports.
5. Open a pull request describing what changed and why.

## License

This project is licensed under the [MIT License](LICENSE).
