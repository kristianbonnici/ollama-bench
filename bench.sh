#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Defaults ───────────────────────────────────────────────────
OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
DEFAULT_SEED=42
DEFAULT_TEMPERATURE=0
DEFAULT_NUM_PREDICT=600
DEFAULT_NUM_CTX=8192
DEFAULT_ITERATIONS=3

BENCHMARKS_DIR="$SCRIPT_DIR/benchmarks"
RESULTS_DIR="$SCRIPT_DIR/results"

# ── Usage / List ───────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $0 [options] <model> [model2 ...]

Options:
      --host <url>         Ollama host (default: 127.0.0.1:11434, respects OLLAMA_HOST).
  -b, --bench <name>       Run a specific benchmark (folder name under benchmarks/).
                            If omitted, all benchmarks are run.
  -n, --iterations <N>     Number of timed runs per model (default: $DEFAULT_ITERATIONS).
      --no-warmup          Skip the warmup run (not recommended).
  -l, --list               List available benchmarks and exit.
  -h, --help               Show this help message.

Examples:
  $0 qwen3.5:35b-a3b
  $0 -n 5 qwen3.5:35b-a3b qwen3.5:35b-a3b-coding-nvfp4
  $0 -b fastapi-endpoint qwen3.5:35b-a3b
  $0 --list
EOF
  exit "${1:-0}"
}

list_benchmarks() {
  echo "Available benchmarks:"
  for dir in "$BENCHMARKS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name preview
    name="$(basename "$dir")"
    preview="$(head -c 80 "$dir/prompt.txt" 2>/dev/null)" || preview="(no prompt.txt)"
    echo "  • $name  —  ${preview}…"
  done
  exit 0
}

# ── System Info ────────────────────────────────────────────────

get_system_info() {
  local chip mem_bytes mem_gb os_ver ollama_ver hostname_str

  if [[ "$(uname)" == "Darwin" ]]; then
    chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")"
    mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo "0")"
    mem_gb="$(( mem_bytes / 1073741824 ))"  # bytes → GB
    os_ver="macOS $(sw_vers -productVersion 2>/dev/null || echo "?")"
  else
    chip="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "unknown")"
    mem_bytes="$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2 * 1024}' || echo "0")"
    mem_gb="$(( mem_bytes / 1073741824 ))"
    os_ver="$(uname -sr)"
  fi

  # Use a safe default for hostname to prevent leaking MAC addresses or personal info
  hostname_str="${BENCH_HOST:-local-machine}"
  ollama_ver="$(ollama --version 2>/dev/null | awk '{print $NF}' || echo "unknown")"

  SYSTEM_INFO_JSON="$(jq -n \
    --arg chip "$chip" \
    --argjson mem_gb "$mem_gb" \
    --arg os "$os_ver" \
    --arg ollama "$ollama_ver" \
    --arg hostname "$hostname_str" \
    '{
      chip: $chip,
      memory_gb: $mem_gb,
      os: $os,
      ollama_version: $ollama,
      hostname: $hostname
    }'
  )"
}

print_system_info() {
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│  System Info                                                      │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│  %-66s│\n" "Chip:    $(echo "$SYSTEM_INFO_JSON" | jq -r '.chip')"
  printf "│  %-66s│\n" "Memory:  $(echo "$SYSTEM_INFO_JSON" | jq -r '.memory_gb')GB"
  printf "│  %-66s│\n" "OS:      $(echo "$SYSTEM_INFO_JSON" | jq -r '.os')"
  printf "│  %-66s│\n" "Ollama:  $(echo "$SYSTEM_INFO_JSON" | jq -r '.ollama_version')"
  printf "│  %-66s│\n" "Host:    $(echo "$SYSTEM_INFO_JSON" | jq -r '.hostname')"
  echo "└─────────────────────────────────────────────────────────────────────┘"
}

# ── Helpers ────────────────────────────────────────────────────

setup_ollama_urls() {
  if [[ "$OLLAMA_HOST" != http* ]]; then
    OLLAMA_BASE_URL="http://${OLLAMA_HOST}/api"
  else
    OLLAMA_BASE_URL="${OLLAMA_HOST}/api"
  fi
  OLLAMA_CHAT_URL="${OLLAMA_BASE_URL}/chat"
  OLLAMA_TAGS_URL="${OLLAMA_BASE_URL}/tags"
  OLLAMA_SHOW_URL="${OLLAMA_BASE_URL}/show"
}

validate_models() {
  echo "  📡 Connecting to Ollama at $OLLAMA_HOST..."
  local tags_response available_models
  
  if ! tags_response="$(curl -s -m 5 "$OLLAMA_TAGS_URL" 2>/dev/null)"; then
    echo "  ✗ Error: Could not connect to Ollama at $OLLAMA_HOST"
    exit 1
  fi

  available_models="$(echo "$tags_response" | jq -r '.models[].name' 2>/dev/null || true)"

  for m in "${MODELS[@]}"; do
    # Check exact match or match with :latest
    if ! echo "$available_models" | grep -F -x -q "$m" && ! echo "$available_models" | grep -F -x -q "${m}:latest"; then
      echo "  ✗ Error: Model '$m' not found on Ollama server. Run: ollama pull $m"
      exit 1
    fi
  done
  echo "  ✓ All requested models are available locally."
  echo ""
}

CURRENT_MODEL=""

cleanup() {
  echo ""
  echo "🚨 Script interrupted. Cleaning up..."
  if [[ -n "${CURRENT_MODEL:-}" ]]; then
    echo "    ⏏ Emergency unload: $CURRENT_MODEL"
    unload_model "$CURRENT_MODEL"
  fi
  exit 1
}

trap cleanup INT TERM

get_model_metadata() {
  local model="$1"
  local show_response
  show_response="$(curl -s -m 5 "$OLLAMA_SHOW_URL" -H "Content-Type: application/json" -d "$(jq -n --arg name "$model" '{name: $name}')" 2>/dev/null)"
  
  # Ensure we have valid JSON back, defaulting to "unknown" on failure
  MODEL_META_JSON="$(echo "$show_response" | jq '{
    parameter_size: (.details.parameter_size // "unknown"),
    quantization_level: (.details.quantization_level // "unknown"),
    family: (.details.family // "unknown"),
    format: (.details.format // "unknown"),
    context_length: (
      if has("model_info") and (.model_info | type == "object") then
        [(.model_info | to_entries[]? | select(.key | endswith(".context_length")) | .value)][0] // "unknown"
      else "unknown" end
    ),
    capabilities: (.capabilities // [])
  }' 2>/dev/null || echo '{
    "parameter_size": "unknown", 
    "quantization_level": "unknown", 
    "family": "unknown", 
    "format": "unknown", 
    "context_length": "unknown", 
    "capabilities": []
  }')"
}

warmup_model() {
  local model="$1"
  echo "    ⏳ Warming up (loading model into memory)..."
  local response
  response="$(curl -s "$OLLAMA_CHAT_URL" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg model "$model" '{
      model: $model,
      messages: [{ role: "user", content: "hi" }],
      stream: false,
      keep_alive: "5m",
      options: { num_predict: 1 }
    }')")"

  if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
    echo "    ✗ Warmup failed: $(echo "$response" | jq -r '.error')"
    return 1
  fi
  echo "    ✓ Model loaded"
}

unload_model() {
  local model="$1"
  curl -s "$OLLAMA_CHAT_URL" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg model "$model" '{
      model: $model,
      messages: [{ role: "user", content: "." }],
      stream: false,
      keep_alive: "0s",
      options: { num_predict: 1 }
    }')" > /dev/null 2>&1 || true
}

run_bench() {
  local model="$1" prompt="$2" output="$3"
  local seed="$4" temp="$5" predict="$6" ctx="$7"

  curl -s "$OLLAMA_CHAT_URL" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg model "$model" \
      --arg prompt "$prompt" \
      --argjson seed "$seed" \
      --argjson temp "$temp" \
      --argjson predict "$predict" \
      --argjson ctx "$ctx" \
      '{
        model: $model,
        messages: [{ role: "user", content: $prompt }],
        stream: false,
        think: false,
        keep_alive: "5m",
        options: {
          seed: $seed,
          temperature: $temp,
          num_predict: $predict,
          num_ctx: $ctx
        }
      }')" > "$output"
}

compute_summary() {
  local out_dir="$1"
  local meta_json="$2"

  jq -s --argjson sys "$SYSTEM_INFO_JSON" --argjson meta "$meta_json" '
    def stats(f):
      [.[] | f] | sort | {
        min:    .[0],
        max:    .[-1],
        mean:   (add / length),
        median: (
          if length == 1 then .[0]
          elif length % 2 == 0
            then (.[length/2 - 1] + .[length/2]) / 2
            else .[((length - 1) / 2)]
          end
        )
      };

    {
      system:                  $sys,
      model_info:              $meta,
      iterations:              length,
      eval_tokens_per_sec:     stats(.eval_count / (.eval_duration / 1e9)),
      prompt_eval_tokens_per_sec: stats(.prompt_eval_count / (.prompt_eval_duration / 1e9)),
      eval_duration_sec:       stats(.eval_duration / 1e9),
      prompt_eval_duration_sec: stats(.prompt_eval_duration / 1e9),
      load_duration_sec:       stats(.load_duration / 1e9),
      total_duration_sec:      stats(.total_duration / 1e9),
      avg_eval_count:          ([.[] | .eval_count] | add / length),
      avg_prompt_eval_count:   ([.[] | .prompt_eval_count] | add / length)
    }
  ' "$out_dir"/run_*.json > "$out_dir/summary.json"
}

print_summary() {
  local summary="$1"

  echo ""
  echo "    ┌────────────────────────┬────────────┬────────────┬────────────┬────────────┐"
  echo "    │ Metric                 │        Min │     Median │       Mean │        Max │"
  echo "    ├────────────────────────┼────────────┼────────────┼────────────┼────────────┤"

  jq -r '
    def fmt: . * 100 | round / 100;
    def row(lbl; obj):
      "    │ \(lbl)│ \(obj.min | fmt | tostring | ("          " + .)[-10:]) │ \(obj.median | fmt | tostring | ("          " + .)[-10:]) │ \(obj.mean | fmt | tostring | ("          " + .)[-10:]) │ \(obj.max | fmt | tostring | ("          " + .)[-10:]) │";

    row("Eval tok/s              "; .eval_tokens_per_sec),
    row("Prompt eval tok/s       "; .prompt_eval_tokens_per_sec),
    row("Eval time (s)           "; .eval_duration_sec),
    row("Prompt eval time (s)    "; .prompt_eval_duration_sec),
    row("Load time (s)           "; .load_duration_sec),
    row("Total time (s)          "; .total_duration_sec)
  ' "$summary"

  echo "    └────────────────────────┴────────────┴────────────┴────────────┴────────────┘"
  echo ""
}

# ── Parse arguments ────────────────────────────────────────────
BENCH_FILTER=""
ITERATIONS="$DEFAULT_ITERATIONS"
DO_WARMUP=true
MODELS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)          OLLAMA_HOST="$2"; shift 2 ;;
    -b|--bench)      BENCH_FILTER="$2"; shift 2 ;;
    -n|--iterations) ITERATIONS="$2"; shift 2 ;;
    --no-warmup)     DO_WARMUP=false; shift ;;
    -l|--list)       list_benchmarks ;;
    -h|--help)       usage 0 ;;
    -*)              echo "Unknown option: $1"; usage 1 ;;
    *)               MODELS+=("$1"); shift ;;
  esac
done

[[ ${#MODELS[@]} -eq 0 ]] && { echo "Error: no model(s) specified."; usage 1; }

# ── Collect benchmarks to run ──────────────────────────────────
BENCHMARKS=()
if [[ -n "$BENCH_FILTER" ]]; then
  bdir="$BENCHMARKS_DIR/$BENCH_FILTER"
  [[ -d "$bdir" ]] || { echo "Error: benchmark '$BENCH_FILTER' not found."; exit 1; }
  BENCHMARKS+=("$bdir")
else
  for dir in "$BENCHMARKS_DIR"/*/; do
    [[ -d "$dir" ]] && BENCHMARKS+=("$dir")
  done
fi

[[ ${#BENCHMARKS[@]} -eq 0 ]] && { echo "No benchmarks found in $BENCHMARKS_DIR/"; exit 1; }

setup_ollama_urls
validate_models

# ── Detect system ──────────────────────────────────────────────
get_system_info
echo ""
print_system_info

# ── Run ────────────────────────────────────────────────────────
for BENCH_DIR in "${BENCHMARKS[@]}"; do
  BENCH_NAME="$(basename "$BENCH_DIR")"
  PROMPT_FILE="$BENCH_DIR/prompt.txt"

  [[ -f "$PROMPT_FILE" ]] || { echo "⚠  Skipping '$BENCH_NAME': no prompt.txt"; continue; }

  # Reset to defaults, then apply per-benchmark overrides
  SEED="$DEFAULT_SEED"
  TEMPERATURE="$DEFAULT_TEMPERATURE"
  NUM_PREDICT="$DEFAULT_NUM_PREDICT"
  NUM_CTX="$DEFAULT_NUM_CTX"

  CONFIG_FILE="$BENCH_DIR/config.json"
  if [[ -f "$CONFIG_FILE" ]]; then
    val="$(jq -r '.seed // empty' "$CONFIG_FILE" 2>/dev/null)";       [[ -n "$val" ]] && SEED="$val"
    val="$(jq -r '.temperature // empty' "$CONFIG_FILE" 2>/dev/null)"; [[ -n "$val" ]] && TEMPERATURE="$val"
    val="$(jq -r '.num_predict // empty' "$CONFIG_FILE" 2>/dev/null)"; [[ -n "$val" ]] && NUM_PREDICT="$val"
    val="$(jq -r '.num_ctx // empty' "$CONFIG_FILE" 2>/dev/null)";     [[ -n "$val" ]] && NUM_CTX="$val"
  fi

  PROMPT="$(cat "$PROMPT_FILE")"

  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo "  Benchmark : $BENCH_NAME"
  echo "  Iterations: $ITERATIONS  (warmup: $DO_WARMUP)"
  echo "  Options   : seed=$SEED temp=$TEMPERATURE predict=$NUM_PREDICT ctx=$NUM_CTX"
  echo "═══════════════════════════════════════════════════════════════════════"

  for MODEL in "${MODELS[@]}"; do
    CURRENT_MODEL="$MODEL"
    SAFE_NAME="${MODEL//:/_}"
    SAFE_NAME="${SAFE_NAME//\//-}"
    OUT_DIR="$RESULTS_DIR/$BENCH_NAME/$SAFE_NAME"
    mkdir -p "$OUT_DIR"

    # Clean previous runs
    rm -f "$OUT_DIR"/run_*.json "$OUT_DIR/summary.json"

    echo ""
    echo "  ▸ $MODEL"
    get_model_metadata "$MODEL"
    
    size="$(echo "$MODEL_META_JSON" | jq -r '.parameter_size')"
    quant="$(echo "$MODEL_META_JSON" | jq -r '.quantization_level')"
    format="$(echo "$MODEL_META_JSON" | jq -r '.format')"
    family="$(echo "$MODEL_META_JSON" | jq -r '.family')"
    
    ctx_len="$(echo "$MODEL_META_JSON" | jq -r '.context_length')"
    if [[ "$ctx_len" =~ ^[0-9]+$ ]]; then
      ctx_len="$(( ctx_len / 1024 ))k"
    fi
    
    caps="$(echo "$MODEL_META_JSON" | jq -r 'if type == "object" and has("capabilities") and (.capabilities | length > 0) then .capabilities | join(", ") else "none" end')"
    
    echo "    Info: $size parameters, $quant quantization ($format)"
    echo "    Architecture: $family  │  Context: $ctx_len  │  Features: $caps"
    echo "  ──────────────────────────────────────────────"

    # Warmup: load model into VRAM before timed runs
    if [[ "$DO_WARMUP" == true ]]; then
      warmup_model "$MODEL"
    fi

    # Timed runs (model stays loaded via keep_alive: 5m)
    for i in $(seq 1 "$ITERATIONS"); do
      OUTPUT_FILE="$OUT_DIR/run_${i}.json"

      run_bench "$MODEL" "$PROMPT" "$OUTPUT_FILE" \
        "$SEED" "$TEMPERATURE" "$NUM_PREDICT" "$NUM_CTX"

      # Show per-run stats
      eval_tps="$(jq -r '.eval_count / (.eval_duration / 1e9) | . * 100 | round / 100' "$OUTPUT_FILE" 2>/dev/null || echo "?")"
      total_s="$(jq -r '.total_duration / 1e9 | . * 100 | round / 100' "$OUTPUT_FILE" 2>/dev/null || echo "?")"
      echo "    Run $i/$ITERATIONS  │  ${eval_tps} tok/s  │  ${total_s}s total"
    done

    # Unload model to free VRAM for the next one
    echo "    ⏏ Unloading model..."
    unload_model "$MODEL"
    CURRENT_MODEL=""

    # Compute & display summary
    compute_summary "$OUT_DIR" "$MODEL_META_JSON"
    print_summary "$OUT_DIR/summary.json"
  done
done

echo ""
echo "All results saved to $RESULTS_DIR/"
