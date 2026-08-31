#!/bin/zsh

typeset -gr BENCHMARK_VERSION="1"
typeset -gr MODEL="gpt-5.6-sol"
typeset -gr REASONING_EFFORT="low"
typeset -gr SERVICE_TIER="fast"
typeset -gr MEASURED_RUNS=5
typeset -gr WARMUP_RUNS=1
typeset -gr PROMPT='You are running a text-generation speed benchmark. Do not call tools, use skills, browse, inspect files, or execute commands. Write an English essay of approximately 750 words explaining how packet switching works. Output only the essay body with no title, preamble, status update, or closing note.'
typeset -gr PARSE_RUN_FILTER='
  def event_type: (.payload.type? // "");
  def forbidden_tool:
    (.type == "response_item" and ((.payload.type? // "") | IN(
      "function_call", "custom_tool_call", "tool_search_call", "local_shell_call",
      "image_generation_call", "computer_call", "mcp_call"
    ))) or
    (.type == "event_msg" and (event_type | test(
      "^(mcp_tool_call|web_search|exec_command|patch_apply|dynamic_tool_call|image_generation|view_image)"
    )));
  if any(.[]; forbidden_tool) then error("tool call detected") else . end
  | ([.[] | select(.type == "event_msg" and event_type == "task_complete") | .payload] | last) as $turn
  | ([.[] | select(.type == "event_msg" and event_type == "token_count")
      | .payload.info.last_token_usage? | select(. != null)] | last) as $usage
  | if $turn == null then error("task_complete event missing")
    elif $usage == null then error("token_count event missing") else null end
  | ($turn.duration_ms - $turn.time_to_first_token_ms) as $generation_ms
  | ($usage.output_tokens - $usage.reasoning_output_tokens) as $visible_tokens
  | if $generation_ms <= 0 then error("generation duration must be positive")
    elif $visible_tokens < 0 then error("visible token count must not be negative") else null end
  | {
      ttft_ms: $turn.time_to_first_token_ms,
      total_tps: ($usage.output_tokens * 1000 / $generation_ms),
      visible_tps: ($visible_tokens * 1000 / $generation_ms)
    }
'

typeset BENCHMARK_ROOT=""
typeset ORIGINAL_CODEX_HOME=""
typeset CODEX_BIN=""

fail() {
  print -u2 -- "Error: $1"
  return 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' was not found."
}

cleanup() {
  [[ -n "$BENCHMARK_ROOT" && -d "$BENCHMARK_ROOT" ]] || return 0
  find "$BENCHMARK_ROOT" ! -type d -exec unlink {} \; 2>/dev/null
  find "$BENCHMARK_ROOT" -depth -type d -exec rmdir {} \; 2>/dev/null
}

prepare_isolated_home() {
  local isolated_root=$1

  mkdir -p "$isolated_root/home" "$isolated_root/codex" "$isolated_root/work"
  cp "$ORIGINAL_CODEX_HOME/auth.json" "$isolated_root/codex/auth.json"
  chmod 600 "$isolated_root/codex/auth.json"
}

run_isolated_codex() {
  local isolated_root=$1
  shift

  HOME="$isolated_root/home" \
    CODEX_HOME="$isolated_root/codex" \
    "$CODEX_BIN" "$@"
}

verify_isolation() {
  local isolated_root="$BENCHMARK_ROOT/preflight"

  prepare_isolated_home "$isolated_root"
  run_isolated_codex "$isolated_root" mcp list --json \
    | jq -e 'type == "array" and length == 0' >/dev/null \
    || fail "Could not verify that MCP servers are disabled."
  run_isolated_codex "$isolated_root" plugin list --json \
    | jq -e '(.installed // []) | length == 0' >/dev/null \
    || fail "Could not verify that plugins are disabled."
}

parse_run() {
  local rollout_file=$1

  jq -sce "$PARSE_RUN_FILTER" "$rollout_file"
}

find_rollout() {
  local isolated_root=$1
  local -a rollout_files

  rollout_files=("$isolated_root"/codex/sessions/**/*.jsonl(N))
  (( ${#rollout_files} == 1 )) || fail "Expected one Codex rollout, found ${#rollout_files}."
  print -r -- "$rollout_files[1]"
}

run_once() {
  local run_number=$1
  local isolated_root="$BENCHMARK_ROOT/run-$run_number"
  local error_log="$isolated_root/codex.stderr"
  local rollout_file

  prepare_isolated_home "$isolated_root"
  run_isolated_codex "$isolated_root" exec --json --ignore-user-config --skip-git-repo-check \
    --sandbox read-only --color never -C "$isolated_root/work" -m "$MODEL" \
    -c "model_reasoning_effort=\"$REASONING_EFFORT\"" -c "service_tier=\"$SERVICE_TIER\"" \
    "$PROMPT" > /dev/null 2> "$error_log" || fail "Codex failed on run $run_number. See stderr output below:\n$(<"$error_log")"
  rollout_file=$(find_rollout "$isolated_root") || return 1
  parse_run "$rollout_file" || fail "Run $run_number did not produce a valid isolated benchmark result."
}

median_summary() {
  local results_file=$1

  jq -sce '
    def median($field): map(.[$field]) | sort | .[length / 2 | floor];
    {
      total_tps: median("total_tps"),
      visible_tps: median("visible_tps"),
      ttft_ms: median("ttft_ms")
    }
  ' "$results_file"
}

print_run_table() {
  local results_file=$1

  print "Run   Total TPS   Visible TPS   TTFT"
  jq -sr 'to_entries[] | [.key + 1, .value.total_tps, .value.visible_tps, .value.ttft_ms] | @tsv' "$results_file" \
    | while IFS=$'\t' read -r run total visible ttft; do
        printf '%-4d %10.2f %13.2f %6.2fs\n' "$run" "$total" "$visible" "$(( ttft / 1000.0 ))"
      done
}

print_header() {
  local codex_version=$1
  local jq_version=$2

  print "Codex Speed Benchmark v$BENCHMARK_VERSION"
  print "Date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  print "Isolation: MCP / Skills / Plugins / AGENTS disabled"
  print "Codex CLI: $codex_version"
  print "jq: $jq_version"
  print "Model: $MODEL"
  print "Reasoning: $REASONING_EFFORT"
  print "Service tier: $SERVICE_TIER"
  print "Runs: $MEASURED_RUNS (+ $WARMUP_RUNS warm-up)"
}

print_medians() {
  local summary=$1
  local total visible ttft

  IFS=$'\t' read -r total visible ttft \
    <<< "$(jq -r '[.total_tps, .visible_tps, (.ttft_ms / 1000)] | @tsv' <<< "$summary")"
  printf 'Median Total TPS:   %.2f\n' "$total"
  printf 'Median Visible TPS: %.2f\n' "$visible"
  printf 'Median TTFT:        %.2fs\n' "$ttft"
}

print_summary() {
  local results_file=$1
  local summary=$2

  print_header "$($CODEX_BIN --version)" "$(jq --version)"
  print
  print_run_table "$results_file"
  print
  print_medians "$summary"
}

initialize() {
  setopt errexit nounset pipefail extendedglob
  umask 077
  require_command codex
  require_command jq || fail "Install jq with: brew install jq"
  CODEX_BIN=$(command -v codex)
  ORIGINAL_CODEX_HOME=${CODEX_HOME:-$HOME/.codex}
  [[ -r "$ORIGINAL_CODEX_HOME/auth.json" ]] || fail "Codex authentication was not found. Run: codex login"
  BENCHMARK_ROOT=$(mktemp -d /tmp/codex-speed-benchmark.XXXXXX)
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

execute_benchmark() {
  local results_file="$BENCHMARK_ROOT/results.jsonl"
  local total_runs=$(( WARMUP_RUNS + MEASURED_RUNS ))
  local result
  local run_number

  verify_isolation
  for run_number in {1..$total_runs}; do
    print -u2 -- "Running $run_number/$total_runs$([[ $run_number == 1 ]] && print ' (warm-up)')..."
    result=$(run_once "$run_number")
    (( run_number > WARMUP_RUNS )) && print -r -- "$result" >> "$results_file"
  done

  local summary=$(median_summary "$results_file")
  print_summary "$results_file" "$summary"
}

main() {
  initialize
  execute_benchmark
}

if [[ $ZSH_EVAL_CONTEXT == toplevel ]]; then
  main "$@"
fi
