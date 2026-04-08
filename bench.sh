#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

VERSION="0.2.1"

# ── Defaults ───────────────────────────────────────────────────
OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
DEFAULT_SEED=42
DEFAULT_TEMPERATURE=0
DEFAULT_NUM_PREDICT=600
DEFAULT_NUM_CTX=8192
DEFAULT_ITERATIONS=3

BENCHMARKS_DIR="$SCRIPT_DIR/benchmarks"
RESULTS_DIR="$SCRIPT_DIR/results"

UI_RESET=""
UI_BOLD=""
UI_DIM=""
UI_CYAN=""
UI_INFO=""
UI_OK=""
UI_WARN=""
UI_ERROR=""
UI_ACCENT=""
UI_RULE="-----------------------------------------------------------------------"
UI_TTY=false
SPINNER_PID=""
SPINNER_FRAMES=("   " ".  " ".. " "...")

init_ui() {
  if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    UI_TTY=true
    UI_RESET=$'\033[0m'
    UI_BOLD=$'\033[1m'
    UI_DIM=$'\033[2m'
    UI_CYAN=$'\033[38;5;39m'
    UI_INFO=$'\033[38;5;110m'
    UI_OK=$'\033[38;5;78m'
    UI_WARN=$'\033[38;5;221m'
    UI_ERROR=$'\033[38;5;203m'
    UI_ACCENT=$'\033[38;5;183m'
    UI_RULE="───────────────────────────────────────────────────────────────────────"
    SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  fi
}

ui_section() {
  local title="$1"
  printf "\n%b%s%b\n" "${UI_BOLD}${UI_ACCENT}" "$title" "$UI_RESET"
  printf "%b%s%b\n" "$UI_ACCENT" "$UI_RULE" "$UI_RESET"
}

ui_subsection() {
  local title="$1"
  printf "\n  %b>%b %b%s%b\n" "$UI_ACCENT" "$UI_RESET" "$UI_BOLD" "$title" "$UI_RESET"
}

ui_kv() {
  local label="$1" value="$2"
  printf "  %b%-12s%b %s\n" "$UI_DIM" "$label" "$UI_RESET" "$value"
}

ui_status() {
  local level="$1" message="$2"
  local label color="" stream=1

  case "$level" in
    info)  label="info";  color="$UI_INFO" ;;
    ok)    label="ok";    color="$UI_OK" ;;
    warn)  label="warn";  color="$UI_WARN";  stream=2 ;;
    error) label="error"; color="$UI_ERROR"; stream=2 ;;
    *)     label="$level" ;;
  esac

  printf "%b[%s]%b %s\n" "${UI_BOLD}${color}" "$label" "$UI_RESET" "$message" >&"$stream"
}

ui_run_result() {
  local run_label="$1" eval_tps="$2" total_s="$3"
  printf "  %brun %-7s%b %10s tok/s   %8ss total\n" "$UI_DIM" "$run_label" "$UI_RESET" "$eval_tps" "$total_s"
}

run_with_spinner() {
  local message="$1"
  shift

  if [[ "$UI_TTY" != true ]]; then
    "$@"
    return $?
  fi

  tput civis 2>/dev/null || true
  "$@" &
  local cmd_pid=$!
  local i=0
  local n=${#SPINNER_FRAMES[@]}

  while kill -0 "$cmd_pid" 2>/dev/null; do
    printf "\r  %b%s%b %s " "${UI_BOLD}${UI_CYAN}" "${SPINNER_FRAMES[$((i % n))]}" "$UI_RESET" "$message"
    i=$(( i + 1 ))
    sleep 0.08
  done

  local status=0
  wait "$cmd_pid" || status=$?
  printf "\r\033[2K"
  tput cnorm 2>/dev/null || true
  return "$status"
}

run_capture_with_spinner() {
  local __resultvar="$1"
  local message="$2"
  shift 2

  local tmp_file
  tmp_file="$(mktemp)"
  local status=0

  run_with_spinner "$message" "$@" > "$tmp_file" || status=$?

  printf -v "$__resultvar" '%s' "$(cat "$tmp_file")"
  rm -f "$tmp_file"
  return "$status"
}

ui_banner() {
  if [[ "$UI_TTY" != true ]]; then
    printf "ollama-bench — Local LLM benchmark runner\n"
    return
  fi

  local r="${UI_RESET}" b="${UI_BOLD}" d="${UI_DIM}"
  local white=$'\033[97m'
  local cyan=$'\033[38;5;39m'
  local purple=$'\033[38;5;183m'
  local sweep=("$white" "$cyan" "$purple")

  local logo_lines=()
  logo_lines+=('         _ _                          _                     _')
  logo_lines+=('   ___  | | | __ _ _ __ ___   __ _   | |__   ___ _ __   ___| |__')
  logo_lines+=('  / _ \ | | |/ _` | '"'"'_ ` _ \ / _` |  | '"'"'_ \ / _ \ '"'"'_ \ / __| '"'"'_ \')
  logo_lines+=(' | (_) || | | (_| | | | | | | (_| |  | |_) |  __/ | | | (__| | | |')
  logo_lines+=('  \___/ |_|_|\__,_|_| |_| |_|\__,_|  |_.__/ \___|_| |_|\___|_| |_|')

  local total=${#logo_lines[@]}

  # Gradient: white -> cool white -> light cyan -> cyan -> sky blue ->
  #           blue-purple -> lavender -> light purple -> theme purple
  local gradient=(
    $'\033[97m'
    $'\033[38;5;195m'
    $'\033[38;5;159m'
    $'\033[38;5;117m'
    $'\033[38;5;75m'
    $'\033[38;5;111m'
    $'\033[38;5;147m'
    $'\033[38;5;183m'
  )
  local ncolors=${#gradient[@]}

  tput civis 2>/dev/null || true
  printf "\n"

  # Phase 1: fast reveal in white (~0.3s)
  for (( i = 0; i < total; i++ )); do
    printf "%b%b%s%b\n" "$b" "$white" "${logo_lines[$i]}" "$r"
    sleep 0.05
  done
  sleep 0.1

  # Phase 2: cascading color wave (~1.8s)
  local -a line_color=()
  for (( i = 0; i < total; i++ )); do line_color[$i]=0; done

  local steps=$(( ncolors - 1 + total ))
  for (( step = 1; step <= steps; step++ )); do
    printf "\033[%dA" "$total"
    for (( i = 0; i < total; i++ )); do
      local target=$(( step - i ))
      if (( target > 0 && line_color[$i] < ncolors - 1 )); then
        line_color[$i]=$(( line_color[$i] + 1 ))
      fi
      printf "\r%b%b%s%b\033[K\n" "$b" "${gradient[${line_color[$i]}]}" "${logo_lines[$i]}" "$r"
    done
    sleep 0.1
  done
  sleep 0.15

  # Phase 3: shimmer pulse — briefly brightens back then returns (~0.8s)
  local shimmer_out=($'\033[38;5;189m' $'\033[38;5;195m' $'\033[97m')
  local shimmer_in=($'\033[38;5;195m' $'\033[38;5;189m' $'\033[38;5;183m')

  local sc
  for sc in "${shimmer_out[@]}" "${shimmer_in[@]}"; do
    printf "\033[%dA" "$total"
    for (( i = 0; i < total; i++ )); do
      printf "\r%b%b%s%b\033[K\n" "$b" "$sc" "${logo_lines[$i]}" "$r"
    done
    sleep 0.08
  done
  sleep 0.15

  # Phase 4: metadata fade-in (~0.4s)
  printf "\n"
  local bench_label="${BENCH_FILTER:-all}"
  local meta
  meta="$(printf "  Local LLM benchmark runner  host %s · bench %s · models %d · iter %d" \
    "$OLLAMA_HOST" "$bench_label" "${#MODELS[@]}" "$ITERATIONS")"

  printf "%b%s%b\n" "$d" "$meta" "$r"
  sleep 0.2
  printf "\033[1A\r"
  printf "  %b%s%b  %bhost%b %s · %bbench%b %s · %bmodels%b %d · %biter%b %d\033[K\n" \
    "$d" "Local LLM benchmark runner" "$r" \
    "$d" "$r" "$OLLAMA_HOST" \
    "$d" "$r" "$bench_label" \
    "$d" "$r" "${#MODELS[@]}" \
    "$d" "$r" "$ITERATIONS"
  printf "\n"

  tput cnorm 2>/dev/null || true
}

ui_progress_bar() {
  local current="$1" total="$2" width=20
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))
  local bar=""
  local i
  for (( i = 0; i < filled; i++ )); do bar+="█"; done
  for (( i = 0; i < empty; i++ )); do bar+="░"; done
  printf "%b%s%b %b%d/%d%b" "$UI_ACCENT" "$bar" "$UI_RESET" "$UI_DIM" "$current" "$total" "$UI_RESET"
}

run_with_progress() {
  local run_idx="$1" run_total="$2"
  shift 2

  local width=20
  local label
  label="$(printf "  %brun %d/%d%b " "$UI_DIM" "$run_idx" "$run_total" "$UI_RESET")"

  if [[ "$UI_TTY" != true ]]; then
    "$@"
    return $?
  fi

  tput civis 2>/dev/null || true

  "$@" &
  local cmd_pid=$!

  local target=$(( run_idx * width / run_total ))
  if (( target < 1 )); then target=1; fi

  # Wave colors: dim -> medium -> bright -> peak -> bright -> medium
  local -a wave_colors=(
    $'\033[38;5;96m'
    $'\033[38;5;133m'
    $'\033[38;5;177m'
    $'\033[38;5;219m'
    $'\033[38;5;177m'
    $'\033[38;5;133m'
  )
  local wlen=${#wave_colors[@]}
  local empty_color=$'\033[38;5;239m'
  local tick=0

  while kill -0 "$cmd_pid" 2>/dev/null; do
    local bar=""
    local i
    for (( i = 0; i < target; i++ )); do
      local ci=$(( (i + tick) % wlen ))
      bar+="${wave_colors[$ci]}█"
    done
    for (( i = target; i < width; i++ )); do
      bar+="${empty_color}░"
    done
    printf "\r%s%s%b" "$label" "$bar" "$UI_RESET"

    tick=$(( tick + 1 ))
    sleep 0.07
  done

  local status=0
  wait "$cmd_pid" || status=$?

  local bar="" i
  for (( i = 0; i < target; i++ )); do bar+="█"; done
  for (( i = target; i < width; i++ )); do bar+="░"; done
  printf "\r%s%b%s%b %b%d/%d%b" "$label" "$UI_ACCENT" "$bar" "$UI_RESET" \
    "$UI_DIM" "$run_idx" "$run_total" "$UI_RESET"

  tput cnorm 2>/dev/null || true
  return "$status"
}

# ── Usage / List ───────────────────────────────────────────────

usage() {
  cat <<EOF
${UI_BOLD}ollama-bench${UI_RESET}

Usage
  $0 [options] <model> [model2 ...]

Options
      --host <url>         Ollama host (default: 127.0.0.1:11434, respects OLLAMA_HOST)
  -b, --bench <name>       Run a specific benchmark folder under benchmarks/
  -n, --iterations <N>     Number of timed runs per model (default: $DEFAULT_ITERATIONS)
  -r, --report <target>    Generate a Markdown report from cached JSON results
      --no-warmup          Skip the warmup run
  -l, --list               List available benchmarks and exit
  -h, --help               Show this help message
  -v, --version            Show version information

Examples
  $0 qwen3.5:35b-a3b
  $0 -n 5 qwen3.5:35b-a3b qwen3.5:35b-a3b-coding-nvfp4
  $0 -b fastapi-endpoint qwen3.5:35b-a3b
  $0 --report all
  $0 --list
EOF
  exit "${1:-0}"
}

list_benchmarks() {
  ui_section "Available benchmarks"
  for dir in "$BENCHMARKS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name preview suffix
    name="$(basename "$dir")"
    suffix="..."
    preview="$(head -c 80 "$dir/prompt.txt" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/[[:space:]]*$//')" || {
      preview="(no prompt.txt)"
      suffix=""
    }
    printf "  %-20s %s%s\n" "$name" "$preview" "$suffix"
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
  local chip mem os ollama host_name
  chip="$(echo "$SYSTEM_INFO_JSON" | jq -r '.chip')"
  mem="$(echo "$SYSTEM_INFO_JSON" | jq -r '.memory_gb')GB"
  os="$(echo "$SYSTEM_INFO_JSON" | jq -r '.os')"
  ollama="$(echo "$SYSTEM_INFO_JSON" | jq -r '.ollama_version')"
  host_name="$(echo "$SYSTEM_INFO_JSON" | jq -r '.hostname')"

  local -a lines=(
    "$(printf "%-12s %s" "chip" "$chip")"
    "$(printf "%-12s %s" "memory" "$mem")"
    "$(printf "%-12s %s" "os" "$os")"
    "$(printf "%-12s %s" "ollama" "$ollama")"
    "$(printf "%-12s %s" "host" "$host_name")"
  )

  # Find the widest line
  local max_w=0
  for line in "${lines[@]}"; do
    local len=${#line}
    (( len > max_w )) && max_w=$len
  done

  local inner_w=$(( max_w + 4 ))
  local border_h border_row
  border_h=""
  for (( i = 0; i < inner_w; i++ )); do border_h+="─"; done

  printf "\n"

  if [[ "$UI_TTY" == true ]]; then
    printf "  %b╭%s╮%b\n" "$UI_ACCENT" "$border_h" "$UI_RESET"
    printf "  %b│%b  %b%-*s%b  %b│%b\n" "$UI_ACCENT" "$UI_RESET" \
      "${UI_BOLD}${UI_ACCENT}" "$max_w" "System" "$UI_RESET" "$UI_ACCENT" "$UI_RESET"
    printf "  %b│%b  %-*s  %b│%b\n" "$UI_ACCENT" "$UI_RESET" "$max_w" "" "$UI_ACCENT" "$UI_RESET"
    for line in "${lines[@]}"; do
      local lbl="${line:0:13}" val="${line:13}"
      printf "  %b│%b  %b%s%b%-*s  %b│%b\n" \
        "$UI_ACCENT" "$UI_RESET" \
        "$UI_DIM" "$lbl" "$UI_RESET" \
        "$(( max_w - 13 ))" "$val" \
        "$UI_ACCENT" "$UI_RESET"
    done
    printf "  %b╰%s╯%b\n" "$UI_ACCENT" "$border_h" "$UI_RESET"
  else
    printf "  System\n"
    for line in "${lines[@]}"; do
      printf "  %s\n" "$line"
    done
  fi
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
  ui_status info "Connecting to Ollama at $OLLAMA_HOST"
  local tags_response available_models
  
  if ! tags_response="$(curl -s -m 5 "$OLLAMA_TAGS_URL" 2>/dev/null)"; then
    ui_status error "Could not connect to Ollama at $OLLAMA_HOST"
    exit 1
  fi

  available_models="$(echo "$tags_response" | jq -r '.models[].name' 2>/dev/null || true)"

  for m in "${MODELS[@]}"; do
    # Check exact match or match with :latest
    if ! echo "$available_models" | grep -F -x -q "$m" && ! echo "$available_models" | grep -F -x -q "${m}:latest"; then
      ui_status error "Model '$m' not found on Ollama server. Run: ollama pull $m"
      exit 1
    fi
  done
  ui_status ok "All requested models are available locally"
}

CURRENT_MODEL=""

cleanup() {
  ui_status warn "Interrupted. Cleaning up"
  if [[ -n "${CURRENT_MODEL:-}" ]]; then
    ui_status info "Unloading model: $CURRENT_MODEL"
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
  local response
  run_capture_with_spinner response "Warming up ${UI_BOLD}${model}${UI_RESET}" \
    curl -s "$OLLAMA_CHAT_URL" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg model "$model" '{
        model: $model,
        messages: [{ role: "user", content: "hi" }],
        stream: false,
        keep_alive: "5m",
        options: { num_predict: 1 }
      }')"

  if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
    ui_status error "Warmup failed: $(echo "$response" | jq -r '.error')"
    return 1
  fi
  ui_status ok "Model loaded and ready"
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
      ttft_sec:                stats(.prompt_eval_duration / 1e9),
      load_duration_sec:       stats(.load_duration / 1e9),
      total_duration_sec:      stats(.total_duration / 1e9),
      avg_eval_count:          ([.[] | .eval_count] | add / length),
      avg_prompt_eval_count:   ([.[] | .prompt_eval_count] | add / length)
    }
  ' "$out_dir"/run_*.json > "$out_dir/summary.json"
}

print_summary() {
  local summary="$1"

  printf "\n  %b>%b %bSummary%b\n" "$UI_ACCENT" "$UI_RESET" "$UI_BOLD" "$UI_RESET"
  printf "  %b%-20s %10s %10s %10s %10s%b\n" "$UI_DIM" "metric" "min" "median" "mean" "max" "$UI_RESET"
  printf "  %b%-20s %10s %10s %10s %10s%b\n" "$UI_DIM" "--------------------" "----------" "----------" "----------" "----------" "$UI_RESET"

  jq -r '
    def fmt: (. * 100 | round / 100 | tostring | if startswith(".") then "0" + . else . end);
    [
      ["eval tok/s", .eval_tokens_per_sec],
      ["prompt tok/s", .prompt_eval_tokens_per_sec],
      ["eval time (s)", .eval_duration_sec],
      ["ttft (s)", .ttft_sec],
      ["load time (s)", .load_duration_sec],
      ["total time (s)", .total_duration_sec]
    ][]
    | [.[0], (.[1].min | fmt), (.[1].median | fmt), (.[1].mean | fmt), (.[1].max | fmt)]
    | @tsv
  ' "$summary" | while IFS=$'\t' read -r label min median mean max; do
    printf "  %-20s %b%10s%b %b%10s%b %10s %10s\n" "$label" "$UI_BOLD" "$min" "$UI_RESET" "${UI_BOLD}${UI_ACCENT}" "$median" "$UI_RESET" "$mean" "$max"
  done
  echo ""
}

generate_markdown_report() {
  local target_bench="$1"
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  local report_file
  
  if [[ "$target_bench" == "all" ]]; then
    report_file="$RESULTS_DIR/report-global-summary_${timestamp}.md"
    ui_status info "Generating global summary report at $report_file"
  else
    report_file="$RESULTS_DIR/report-${target_bench}_${timestamp}.md"
    ui_status info "Generating report for '$target_bench' at $report_file"
  fi

  # Find available summary files depending on mode
  local summary_files=()
  if [[ "$target_bench" == "all" ]]; then
    while IFS= read -r f; do [[ -n "$f" ]] && summary_files+=("$f"); done < <(find "$RESULTS_DIR" -maxdepth 3 -type f -name "summary.json" | sort)
  else
    while IFS= read -r f; do [[ -n "$f" ]] && summary_files+=("$f"); done < <(find "$RESULTS_DIR/$target_bench" -maxdepth 2 -type f -name "summary.json" 2>/dev/null | sort)
  fi

  if [[ ${#summary_files[@]} -eq 0 ]]; then
    ui_status warn "No summary.json files found to generate report"
    return 1
  fi

  # Get system info from the first file
  local sys_info chip memory_gb os_str ollama hostname_str
  sys_info="$(jq -r '.system' "${summary_files[0]}")"
  chip="$(echo "$sys_info" | jq -r '.chip')"
  memory_gb="$(echo "$sys_info" | jq -r '.memory_gb')"
  os_str="$(echo "$sys_info" | jq -r '.os')"
  ollama="$(echo "$sys_info" | jq -r '.ollama_version')"
  hostname_str="$(echo "$sys_info" | jq -r '.hostname')"
  local gen_date
  gen_date="$(date '+%Y-%m-%d %H:%M')"

  # Write Header
  cat <<EOF > "$report_file"
# Benchmark Report

> **Generated:** $gen_date
> **System:** $hostname_str • $chip • ${memory_gb}GB • $os_str • Ollama $ollama

EOF

  # If "all", get unique benchmark names
  local benches=()
  if [[ "$target_bench" == "all" ]]; then
    for f in "${summary_files[@]}"; do
      benches+=("$(basename "$(dirname "$(dirname "$f")")")")
    done
    local unique_benches=()
    while IFS= read -r b_name; do 
      [[ -n "$b_name" ]] && unique_benches+=("$b_name")
    done < <(printf "%s\n" "${benches[@]}" | sort -u)
    benches=("${unique_benches[@]}")
  else
    benches=("$target_bench")
  fi

  # ── Ranked Leaderboard (only for "all" or multiple models) ──
  if [[ "$target_bench" == "all" && ${#benches[@]} -gt 0 ]]; then
    # Collect unique models and compute avg tok/s and avg total time
    local all_models=()
    for f in "${summary_files[@]}"; do
      model_name="$(basename "$(dirname "$f")" | sed 's/_/:/g')"
      all_models+=("$model_name")
    done
    local unique_models=()
    while IFS= read -r m; do
      [[ -n "$m" ]] && unique_models+=("$m")
    done < <(printf "%s\n" "${all_models[@]}" | sort -u)

    # Build leaderboard data: model|params|quant|avg_toks|avg_time
    local leaderboard_lines=()
    for m in "${unique_models[@]}"; do
      safe_m="$(echo "$m" | sed 's/:/_/g' | sed 's/\//-/g')"
      tok_sum="0"
      time_sum="0"
      ttft_sum="0"

      count="0"
      m_params=""
      m_quant=""
      for f in "${summary_files[@]}"; do
        if [[ "$(basename "$(dirname "$f")")" == "$safe_m" ]]; then
          tok_val="$(jq -r '.eval_tokens_per_sec.median' "$f")"
          time_val="$(jq -r '.total_duration_sec.median' "$f")"
          tok_sum="$(echo "$tok_sum + $tok_val" | bc)"
          ttft_val="$(jq -r '.ttft_sec.median // 0' "$f")"
          ttft_sum="$(echo "$ttft_sum + $ttft_val" | bc)"

          time_sum="$(echo "$time_sum + $time_val" | bc)"
          count="$(( count + 1 ))"
          if [[ -z "$m_params" ]]; then
            m_params="$(jq -r '.model_info.parameter_size' "$f")"
            m_quant="$(jq -r '.model_info.quantization_level' "$f")"
          fi
        fi
      done
      if [[ "$count" -gt 0 ]]; then
        avg_tok="$(echo "scale=2; $tok_sum / $count" | bc)"
        avg_ttft="$(echo "scale=2; $ttft_sum / $count" | bc)"

        avg_time="$(echo "scale=2; $time_sum / $count" | bc)"
        leaderboard_lines+=("${avg_tok}|${m}|${m_params}|${m_quant}|${avg_tok}|${avg_ttft}|${avg_time}")
      fi
    done

    # Sort by avg tok/s descending
    local sorted_lines=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && sorted_lines+=("$line")
    done < <(printf "%s\n" "${leaderboard_lines[@]}" | sort -t'|' -k1 -rn)

    echo "## Results Summary

Metric definitions:
- **TTFT**: Time To First Token (responsiveness)
- **Eval tok/s**: Generation throughput speed
- **Total Time**: End-to-end execution time" >> "$report_file"
    echo "" >> "$report_file"
    echo "Ranked by median eval tokens/sec (averaged across all benchmarks)." >> "$report_file"
    echo "" >> "$report_file"
    echo "| Rank | Model | Params | Quant | Avg tok/s | Avg TTFT | Avg Total Time |" >> "$report_file"
    echo "|:---:|:---|---:|:---|---:|---:|---:|" >> "$report_file"

    rank=1
    fastest_tok=""
    slowest_tok=""
    fastest_name=""
    slowest_name=""
    for line in "${sorted_lines[@]}"; do
      IFS='|' read -r _ l_model l_params l_quant l_tok l_ttft l_time <<< "$line"
      l_ttft_fmt=$(echo "$l_ttft" | awk '{printf "%0.2f", $1}')
      echo "| $rank | \`$l_model\` | $l_params | $l_quant | $l_tok tok/s | ${l_ttft_fmt}s | ${l_time}s |" >> "$report_file"
      if [[ $rank -eq 1 ]]; then
        fastest_tok="$l_tok"
        fastest_name="$l_model"
      fi
      slowest_tok="$l_tok"
      slowest_name="$l_model"
      rank=$(( rank + 1 ))
    done

    
    # Sort by avg TTFT ascending for secondary leaderboard
    local sorted_ttft_lines=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && sorted_ttft_lines+=("$line")
    done < <(printf "%s\n" "${leaderboard_lines[@]}" | sort -t'|' -k6 -n)

    echo "### TTFT Leaderboard" >> "$report_file"
    echo "" >> "$report_file"
    echo "Ranked by median Time To First Token (TTFT), averaged across all benchmarks." >> "$report_file"
    echo "" >> "$report_file"
    echo "| Rank | Model | Params | Quant | Avg TTFT | Avg tok/s | Avg Total Time |" >> "$report_file"
    echo "|:---:|:---|---:|:---|---:|---:|---:|" >> "$report_file"

    rank=1
    fastest_ttft=""
    fastest_ttft_name=""
    for line in "${sorted_ttft_lines[@]}"; do
      IFS='|' read -r _ l_model l_params l_quant l_tok l_ttft l_time <<< "$line"
      l_ttft_fmt=$(echo "$l_ttft" | awk '{printf "%0.2f", $1}')
      echo "| $rank | \`$l_model\` | $l_params | $l_quant | ${l_ttft_fmt}s | $l_tok tok/s | ${l_time}s |" >> "$report_file"
      if [[ $rank -eq 1 ]]; then
        fastest_ttft="$l_ttft"
        fastest_ttft_name="$l_model"
      fi
      rank=$(( rank + 1 ))
    done

    echo "" >> "$report_file"
echo "" >> "$report_file"

    # Relative performance
    if [[ -n "$fastest_tok" && -n "$slowest_tok" && "$slowest_tok" != "0" && ${#sorted_lines[@]} -gt 1 ]]; then
      speedup="$(echo "scale=2; $fastest_tok / $slowest_tok" | bc)"
      echo "**Relative:** \`$fastest_name\` is **${speedup}x faster** than \`$slowest_name\` (avg eval tok/s)" >> "$report_file"
      echo "" >> "$report_file"
    fi

    echo "---" >> "$report_file"
    echo "" >> "$report_file"
  fi

  # ── Per-Benchmark Sections ──
  for b in "${benches[@]}"; do
    # Read config if available
    config_file="$BENCHMARKS_DIR/$b/config.json"
    config_str=""
    if [[ -f "$config_file" ]]; then
      c_seed="$(jq -r '.seed // empty' "$config_file" 2>/dev/null)"
      c_temp="$(jq -r '.temperature // empty' "$config_file" 2>/dev/null)"
      c_pred="$(jq -r '.num_predict // empty' "$config_file" 2>/dev/null)"
      c_ctx="$(jq -r '.num_ctx // empty' "$config_file" 2>/dev/null)"
      config_str="seed=${c_seed:-$DEFAULT_SEED} temp=${c_temp:-$DEFAULT_TEMPERATURE} predict=${c_pred:-$DEFAULT_NUM_PREDICT} ctx=${c_ctx:-$DEFAULT_NUM_CTX}"
    else
      config_str="seed=$DEFAULT_SEED temp=$DEFAULT_TEMPERATURE predict=$DEFAULT_NUM_PREDICT ctx=$DEFAULT_NUM_CTX"
    fi

    # Get iterations from first summary
    iters=""
    for f in "${summary_files[@]}"; do
      if [[ "$f" == *"/$b/"* ]]; then
        iters="$(jq -r '.iterations' "$f")"
        break
      fi
    done

    echo "## Benchmark: \`$b\`" >> "$report_file"
    echo "" >> "$report_file"
    echo "> \`$config_str\` • ${iters} iterations" >> "$report_file"
    echo "" >> "$report_file"
    
    echo "| Model | Eval tok/s | Prompt tok/s | TTFT | Eval Time | Total Time |" >> "$report_file"
    echo "|:---|---:|---:|---:|---:|---:|" >> "$report_file"
    
    local models=() toks_data=() time_data=()

    for f in "${summary_files[@]}"; do
      if [[ "$f" == *"/$b/"* ]]; then
        model_name="$(basename "$(dirname "$f")" | sed 's/_/:/g')"
        
        tok_s="$(jq -r '.eval_tokens_per_sec.median | . * 100 | round / 100' "$f")"
        prompt_tps="$(jq -r '.prompt_eval_tokens_per_sec.median | . * 100 | round / 100' "$f")"
        

        ttft_s="$(jq -r '.ttft_sec.median // 0 | . * 100 | round / 100 | tostring | if startswith(".") then "0" + . else . end' "$f")"

        eval_t="$(jq -r '.eval_duration_sec.median | . * 100 | round / 100' "$f")"
        total_t="$(jq -r '.total_duration_sec.median | . * 100 | round / 100' "$f")"
        
        echo "| \`$model_name\` | $tok_s | $prompt_tps | ${ttft_s}s | ${eval_t}s | ${total_t}s |" >> "$report_file"
        
        models+=("\"$model_name\"")
        toks_data+=("$tok_s")
        time_data+=("$total_t")
      fi
    done
    
    # Per-benchmark charts
    if [[ ${#models[@]} -gt 0 ]]; then
      pb_x_str="[$(IFS=, ; echo "${models[*]}")]"
      pb_toks_str="[$(IFS=, ; echo "${toks_data[*]}")]"

      # Compute y-axis upper bound (max + 20% headroom)
      max_tok="0"
      for v in "${toks_data[@]}"; do
        if (( $(echo "$v > $max_tok" | bc -l) )); then max_tok="$v"; fi
      done
      y_max="$(echo "scale=0; ($max_tok * 1.2 + 0.5) / 1" | bc)"

      echo "" >> "$report_file"
      echo '```mermaid' >> "$report_file"
      echo "xychart-beta" >> "$report_file"
      echo '  title "Eval Tokens per Second (Higher is Better)"' >> "$report_file"
      echo "  x-axis $pb_x_str" >> "$report_file"
      echo "  y-axis \"tok/s\" 0 --> $y_max" >> "$report_file"
      echo "  bar $pb_toks_str" >> "$report_file"
      echo '```' >> "$report_file"
    fi
    echo "" >> "$report_file"
  done
  
  ui_status ok "Report generated successfully: $report_file"
}

# ── Parse arguments ────────────────────────────────────────────
init_ui

BENCH_FILTER=""
ITERATIONS="$DEFAULT_ITERATIONS"
DO_WARMUP=true
MODELS=()
REPORT_ONLY=false
REPORT_TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)          OLLAMA_HOST="$2"; shift 2 ;;
    -b|--bench)      BENCH_FILTER="$2"; shift 2 ;;
    -n|--iterations) ITERATIONS="$2"; shift 2 ;;
    -r|--report)     REPORT_TARGET="$2"; REPORT_ONLY=true; shift 2 ;;
    --no-warmup)     DO_WARMUP=false; shift ;;
    -l|--list)       list_benchmarks ;;
    -v|--version)    echo "ollama-bench $VERSION"; exit 0 ;;
    -h|--help)       usage 0 ;;
    -*)              ui_status error "Unknown option: $1"; usage 1 ;;
    *)               MODELS+=("$1"); shift ;;
  esac
done

if [[ "$REPORT_ONLY" == true ]]; then
  [[ -z "$REPORT_TARGET" ]] && { ui_status error "--report requires 'all' or a benchmark name"; exit 1; }
  generate_markdown_report "$REPORT_TARGET"
  exit 0
fi

[[ ${#MODELS[@]} -eq 0 ]] && { ui_status error "No model(s) specified"; usage 1; }

# ── Collect benchmarks to run ──────────────────────────────────
BENCHMARKS=()
if [[ -n "$BENCH_FILTER" ]]; then
  bdir="$BENCHMARKS_DIR/$BENCH_FILTER"
  [[ -d "$bdir" ]] || { ui_status error "Benchmark '$BENCH_FILTER' not found"; exit 1; }
  BENCHMARKS+=("$bdir")
else
  for dir in "$BENCHMARKS_DIR"/*/; do
    [[ -d "$dir" ]] && BENCHMARKS+=("$dir")
  done
fi

[[ ${#BENCHMARKS[@]} -eq 0 ]] && { ui_status error "No benchmarks found in $BENCHMARKS_DIR/"; exit 1; }

ui_banner

setup_ollama_urls
validate_models

# ── Detect system ──────────────────────────────────────────────
get_system_info
print_system_info

# ── Run ────────────────────────────────────────────────────────
for BENCH_DIR in "${BENCHMARKS[@]}"; do
  BENCH_NAME="$(basename "$BENCH_DIR")"
  PROMPT_FILE="$BENCH_DIR/prompt.txt"

  [[ -f "$PROMPT_FILE" ]] || { ui_status warn "Skipping '$BENCH_NAME': no prompt.txt"; continue; }

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

  ui_section "Benchmark: $BENCH_NAME"
  ui_kv "iterations" "$ITERATIONS (warmup: $DO_WARMUP)"
  ui_kv "options" "seed=$SEED temp=$TEMPERATURE predict=$NUM_PREDICT ctx=$NUM_CTX"

  for MODEL in "${MODELS[@]}"; do
    CURRENT_MODEL="$MODEL"
    SAFE_NAME="${MODEL//:/_}"
    SAFE_NAME="${SAFE_NAME//\//-}"
    OUT_DIR="$RESULTS_DIR/$BENCH_NAME/$SAFE_NAME"
    mkdir -p "$OUT_DIR"

    # Clean previous runs
    rm -f "$OUT_DIR"/run_*.json "$OUT_DIR/summary.json"

    ui_subsection "Model: $MODEL"
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
    
    ui_kv "parameters" "$size"
    ui_kv "format" "$quant ($format)"
    ui_kv "family" "$family"
    ui_kv "context" "$ctx_len"
    ui_kv "features" "$caps"

    # Warmup: load model into VRAM before timed runs
    if [[ "$DO_WARMUP" == true ]]; then
      warmup_model "$MODEL"
    fi

    # Timed runs (model stays loaded via keep_alive: 5m)
    echo ""
    for i in $(seq 1 "$ITERATIONS"); do
      OUTPUT_FILE="$OUT_DIR/run_${i}.json"

      run_with_progress "$i" "$ITERATIONS" \
        run_bench "$MODEL" "$PROMPT" "$OUTPUT_FILE" \
        "$SEED" "$TEMPERATURE" "$NUM_PREDICT" "$NUM_CTX"

      eval_tps="$(jq -r '.eval_count / (.eval_duration / 1e9) | . * 100 | round / 100' "$OUTPUT_FILE" 2>/dev/null || echo "?")"
      total_s="$(jq -r '.total_duration / 1e9 | . * 100 | round / 100' "$OUTPUT_FILE" 2>/dev/null || echo "?")"
      printf "  %b%s tok/s%b  %b%ss%b\n" "$UI_BOLD" "$eval_tps" "$UI_RESET" "$UI_DIM" "$total_s" "$UI_RESET"
    done

    # Unload model to free VRAM for the next one
    run_with_spinner "Unloading ${UI_BOLD}${MODEL}${UI_RESET}" unload_model "$MODEL"
    CURRENT_MODEL=""

    # Compute & display summary
    compute_summary "$OUT_DIR" "$MODEL_META_JSON"
    print_summary "$OUT_DIR/summary.json"
  done
done

if [[ -n "$BENCH_FILTER" ]]; then
  generate_markdown_report "$BENCH_FILTER"
else
  generate_markdown_report "all"
fi

ui_status ok "Results saved to $RESULTS_DIR/"
