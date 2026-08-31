#!/bin/zsh

if [ -z "${ZSH_VERSION:-}" ]; then
  if [ ! -x /bin/zsh ]; then
    echo "Error: this benchmark requires zsh." >&2
    exit 1
  fi
  exec /bin/zsh "$0" "$@"
fi

typeset -gr BENCHMARK_VERSION="3"
typeset -gr MODEL="gpt-5.6-sol"
typeset -gr REASONING_EFFORT="low"
typeset -gr MEASURED_RUNS=5
typeset -gr WARMUP_RUNS=1
typeset -gr RUN_TIMEOUT_SECONDS=120
typeset -gr MAX_ATTEMPTS_PER_RUN=2
typeset -gr PROMPT='You are running a text-generation speed benchmark. Do not call tools, use skills, browse, inspect files, or execute commands. Write an English essay of approximately 750 words explaining how wheat is turned into bread. Output only the essay body with no title, preamble, status update, or closing note.'
typeset -gra ISOLATION_FLAGS=(
  --disable remote_plugin
  --disable plugin_sharing
  --disable apps
  --disable recommended_plugins
  --disable skill_search
  --disable skill_mcp_dependency_install
)
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
typeset ISOLATED_ROOT=""
typeset SERVICE_TIER=""

fail() {
  print -u2 -- "Error: $1"
  return 1
}

parse_service_tier() {
  if (( $# > 1 )); then
    fail "Usage: $0 [default|fast]"
    return 1
  fi
  local tier=${1:-default}

  case $tier in
    default|fast) print -r -- "$tier" ;;
    *) fail "Usage: $0 [default|fast]" ;;
  esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' was not found."
}

require_jq() {
  command -v jq >/dev/null 2>&1 \
    || fail "jq is required. Install it with: brew install jq"
}

cleanup() {
  [[ -n "$BENCHMARK_ROOT" && -d "$BENCHMARK_ROOT" ]] || return 0
  local attempt

  for attempt in {1..3}; do
    find "$BENCHMARK_ROOT" -depth -delete 2>/dev/null
    [[ ! -d "$BENCHMARK_ROOT" ]] && return 0
    sleep 0.2
  done
  print -u2 -- "Warning: temporary files remain at $BENCHMARK_ROOT"
}

prepare_isolated_home() {
  local isolated_root=$1

  mkdir -p "$isolated_root/home" "$isolated_root/codex"
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

terminate_process() {
  local process_id=$1
  local attempt

  kill -TERM "$process_id" 2>/dev/null || return 0
  for attempt in {1..10}; do
    kill -0 "$process_id" 2>/dev/null || return 0
    sleep 0.2
  done
  kill -KILL "$process_id" 2>/dev/null || true
}

wait_with_timeout() {
  local process_id=$1
  local timeout_seconds=$2
  local deadline=$(( SECONDS + timeout_seconds ))

  while kill -0 "$process_id" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      terminate_process "$process_id"
      wait "$process_id" 2>/dev/null || true
      return 124
    fi
    sleep 1
  done
  wait "$process_id"
}

verify_isolation() {
  local isolated_root=$1

  run_isolated_codex "$isolated_root" mcp list "${ISOLATION_FLAGS[@]}" --json \
    | jq -e 'type == "array" and length == 0' >/dev/null \
    || fail "Could not verify that MCP servers are disabled."
  run_isolated_codex "$isolated_root" plugin list "${ISOLATION_FLAGS[@]}" --json \
    | jq -e '(.installed // []) | length == 0' >/dev/null \
    || fail "Could not verify that plugins are disabled."
}

build_skill_config() {
  local -a names=("$@")
  local -a entries=()
  local name

  for name in "${names[@]}"; do
    entries+=("{name=\"$name\",enabled=false}")
  done
  print -r -- "skills.config=[${(j:,:)entries}]"
}

discover_skill_config() {
  local -a skill_files=("$ISOLATED_ROOT"/codex/skills/.system/*/SKILL.md(N))
  local -a names=("${skill_files[@]:A:h:t}")

  build_skill_config "${(u)names[@]}"
}

parse_run() {
  local rollout_file=$1

  jq -sce "$PARSE_RUN_FILTER" "$rollout_file"
}

find_rollout() {
  local isolated_root=$1
  local thread_id=$2
  local -a rollout_files=("$isolated_root"/codex/sessions/**/*"$thread_id"*.jsonl(N))

  (( ${#rollout_files} == 1 )) || fail "Expected one Codex rollout, found ${#rollout_files}."
  print -r -- "$rollout_files[1]"
}

run_once() {
  local run_number=$1
  local attempt=$2
  local skill_config=$3
  local run_root="$BENCHMARK_ROOT/run-$run_number-attempt-$attempt"
  local public_events="$run_root/events.jsonl"
  local error_log="$run_root/codex.stderr"
  local rollout_file
  local thread_id
  local process_id
  local exit_code=0

  mkdir "$run_root"
  run_isolated_codex "$ISOLATED_ROOT" exec --json --ignore-user-config --skip-git-repo-check \
    --sandbox read-only --color never "${ISOLATION_FLAGS[@]}" -C "$run_root" -m "$MODEL" \
    -c "$skill_config" \
    -c "model_reasoning_effort=\"$REASONING_EFFORT\"" -c "service_tier=\"$SERVICE_TIER\"" \
    "$PROMPT" > "$public_events" 2> "$error_log" &
  process_id=$!
  wait_with_timeout "$process_id" "$RUN_TIMEOUT_SECONDS" || exit_code=$?
  if (( exit_code == 124 )); then
    print -u2 -- "Codex timed out after $RUN_TIMEOUT_SECONDS seconds on run $run_number."
    return 124
  fi
  (( exit_code == 0 )) || fail "Codex failed on run $run_number. See stderr output below:\n$(<"$error_log")"
  thread_id=$(jq -sr '[.[] | select(.type == "thread.started") | .thread_id] | last // empty' "$public_events")
  [[ -n "$thread_id" ]] || fail "Codex did not report a thread ID on run $run_number."
  rollout_file=$(find_rollout "$ISOLATED_ROOT" "$thread_id") || return 1
  parse_run "$rollout_file" || fail "Run $run_number did not produce a valid isolated benchmark result."
}

run_with_retry() {
  local run_number=$1
  local skill_config=$2
  local attempt
  local result

  for attempt in {1..$MAX_ATTEMPTS_PER_RUN}; do
    if result=$(run_once "$run_number" "$attempt" "$skill_config"); then
      print -r -- "$result"
      return 0
    elif (( $? != 124 )); then
      return 1
    fi
    (( attempt < MAX_ATTEMPTS_PER_RUN )) \
      && print -u2 -- "Retrying run $run_number ($(( attempt + 1 ))/$MAX_ATTEMPTS_PER_RUN)..."
  done
  fail "Run $run_number timed out $MAX_ATTEMPTS_PER_RUN times."
}

prepare_benchmark_environment() {
  local total_runs=$(( WARMUP_RUNS + MEASURED_RUNS ))

  prepare_isolated_home "$ISOLATED_ROOT"
  verify_isolation "$ISOLATED_ROOT"
  print -u2 -- "Running 1/$total_runs (warm-up)..."
  run_with_retry 1 'skills.config=[]' >/dev/null
  discover_skill_config
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
  print "Requested service tier: $SERVICE_TIER"
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
  SERVICE_TIER=$(parse_service_tier "$@")
  require_command codex
  require_jq
  CODEX_BIN=$(command -v codex)
  ORIGINAL_CODEX_HOME=${CODEX_HOME:-$HOME/.codex}
  [[ -r "$ORIGINAL_CODEX_HOME/auth.json" ]] || fail "Codex authentication was not found. Run: codex login"
  BENCHMARK_ROOT=$(mktemp -d /tmp/codex-speed-benchmark.XXXXXX)
  ISOLATED_ROOT="$BENCHMARK_ROOT/environment"
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
  local skill_config

  skill_config=$(prepare_benchmark_environment)
  for (( run_number = WARMUP_RUNS + 1; run_number <= total_runs; run_number++ )); do
    print -u2 -- "Running $run_number/$total_runs..."
    result=$(run_with_retry "$run_number" "$skill_config")
    print -r -- "$result" >> "$results_file"
  done

  verify_isolation "$ISOLATED_ROOT"
  local summary=$(median_summary "$results_file")
  print_summary "$results_file" "$summary"
}

main() {
  initialize "$@"
  execute_benchmark
}

if [[ $ZSH_EVAL_CONTEXT == toplevel ]]; then
  main "$@"
fi
