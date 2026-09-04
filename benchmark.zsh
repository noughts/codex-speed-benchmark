#!/bin/zsh

if [ -z "${ZSH_VERSION:-}" ]; then
  if [ ! -x /bin/zsh ]; then
    echo "Error: this benchmark requires zsh." >&2
    exit 1
  fi
  exec /bin/zsh "$0" "$@"
fi

typeset -gr BENCHMARK_VERSION="5"
typeset -gr MODEL="gpt-5.6-sol"
typeset -gr BEDROCK_MODEL="openai.gpt-5.6-sol"
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
  | ([.[] | select(.type == "session_meta") | .payload.model_provider?
      | select(. != null)] | last) as $model_provider
  | if $turn == null then error("task_complete event missing")
    elif $usage == null then error("token_count event missing")
    elif $model_provider == null then error("model provider missing")
    elif $model_provider != $expected_provider then error(
      "expected provider \($expected_provider), got \($model_provider)"
    ) else null end
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
typeset REQUESTED_MODEL=""
typeset MODEL_PROVIDER=""
typeset AUTHENTICATION=""
typeset CODEX_RUNTIME_HOME=""
typeset AWS_BENCHMARK_REGION=""
typeset -ga BEDROCK_CONFIG_ARGS=()

fail() {
  print -u2 -- "Error: $1"
  return 1
}

usage_error() {
  fail "Usage: $0 [--model <ID>] [--service-tier <default|fast>]"
}

parse_option_pairs() {
  local tier=$1 model=$2
  shift 2
  (( $# )) || { print -rl -- "${tier:-default}" "$model"; return 0; }
  (( $# >= 2 )) && [[ -n $2 && $2 != -* ]] || { usage_error; return 1; }
  case $1 in
    --model)
      [[ -z $model ]] || { usage_error; return 1; }
      parse_option_pairs "$tier" "$2" "${@:3}"
      ;;
    --service-tier)
      [[ -z $tier && ( $2 == default || $2 == fast ) ]] || { usage_error; return 1; }
      parse_option_pairs "$2" "$model" "${@:3}"
      ;;
    *) usage_error ;;
  esac
}

parse_options() {
  parse_option_pairs '' '' "$@"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' was not found."
}

require_jq() {
  command -v jq >/dev/null 2>&1 \
    || fail "jq is required. Install it with: brew install jq"
}

parse_model_provider() {
  local report=$1

  jq -er '[.. | objects | select(.id? == "config.load")
    | .details["model provider"]] | first' <<< "$report"
}

detect_model_provider() {
  local report
  local provider

  report=$("$CODEX_BIN" doctor --json 2>/dev/null) || true
  provider=$(parse_model_provider "$report" 2>/dev/null) \
    || fail "Could not determine the active model provider."
  validate_model_provider "$provider"
}

validate_model_provider() {
  local provider=$1

  case $provider in
    openai|amazon-bedrock) print -r -- "$provider" ;;
    *) fail "Unsupported model provider: $provider" ;;
  esac
}

parse_authentication() {
  local login_status=$1

  case $login_status in
    *ChatGPT*) print "ChatGPT" ;;
    *"API key"*) print "API key" ;;
    *) print "Unknown" ;;
  esac
}

detect_authentication() {
  local provider=$1
  local login_status

  [[ $provider == amazon-bedrock ]] && { print "AWS"; return 0; }
  login_status=$("$CODEX_BIN" login status 2>&1) || { print "Unknown"; return 0; }
  parse_authentication "$login_status"
}

parse_bedrock_aws_setting() {
  local key=$1
  local config=$2

  awk -v key="$key" '
    /^[[:space:]]*\[/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      next
    }
    {
      line = $0
      sub(/#.*$/, "", line)
      if (section == "model_providers.amazon-bedrock.aws" \
        && match(line, "^[[:space:]]*" key "[[:space:]]*=")) value = line
      if (match(line, "^[[:space:]]*model_providers\\.amazon-bedrock\\.aws\\." key "[[:space:]]*=")) value = line
    }
    END {
      if (value == "") exit 1
      sub(/^[^=]*=[[:space:]]*/, "", value)
      gsub(/^["\047]|["\047][[:space:]]*$/, "", value)
      if (value == "") exit 1
      print value
    }
  ' <<< "$config"
}

# --ignore-user-config discards [model_providers.amazon-bedrock.aws], which is the
# only place Codex is told the Bedrock region and AWS profile. Re-inject them so an
# isolated run reaches the same endpoint as a normal one.
detect_bedrock_config_args() {
  local config=""
  local region=""
  local profile=""

  [[ -r "$ORIGINAL_CODEX_HOME/config.toml" ]] && config=$(<"$ORIGINAL_CODEX_HOME/config.toml")
  region=$(parse_bedrock_aws_setting region "$config" 2>/dev/null) || region=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
  profile=$(parse_bedrock_aws_setting profile "$config" 2>/dev/null) || profile=${AWS_PROFILE:-}
  [[ -n "$region" ]] || fail "Could not determine the Amazon Bedrock region. Set it in\
 $ORIGINAL_CODEX_HOME/config.toml under [model_providers.amazon-bedrock.aws] or export AWS_REGION."
  AWS_BENCHMARK_REGION=$region
  BEDROCK_CONFIG_ARGS=(-c "model_providers.amazon-bedrock.aws.region=\"$region\"")
  [[ -n "$profile" ]] \
    && BEDROCK_CONFIG_ARGS+=(-c "model_providers.amazon-bedrock.aws.profile=\"$profile\"")
  return 0
}

model_for_provider() {
  [[ -n ${2:-} ]] && { print -r -- "$2"; return 0; }
  [[ $1 == amazon-bedrock ]] && print "$BEDROCK_MODEL" || print "$MODEL"
}

provider_name() {
  [[ $1 == amazon-bedrock ]] && print "Amazon Bedrock" || print "OpenAI"
}

format_host() {
  local chip=$1
  local model=$2
  local cores=$3
  local memory_bytes=$4
  local memory="unknown"

  [[ $memory_bytes == <-> ]] && memory="$(( memory_bytes / 1024 ** 3 )) GB"
  print -r -- "${chip:-unknown} (${model:-unknown}), ${cores:-unknown} cores, $memory"
}

sysctl_value() {
  local value

  value=$(sysctl -n "$1" 2>/dev/null) || value=""
  print -r -- "$value"
}

detect_host() {
  format_host "$(sysctl_value machdep.cpu.brand_string)" "$(sysctl_value hw.model)" \
    "$(sysctl_value hw.ncpu)" "$(sysctl_value hw.memsize)"
}

detect_macos() {
  local version
  local build

  version=$(sw_vers -productVersion 2>/dev/null) || version=""
  build=$(sw_vers -buildVersion 2>/dev/null) || build=""
  print -r -- "${version:-unknown} (${build:-unknown})"
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
  local provider=$2

  mkdir -p "$isolated_root/home" "$isolated_root/codex"
  [[ $provider == amazon-bedrock ]] && return 0
  cp "$ORIGINAL_CODEX_HOME/auth.json" "$isolated_root/codex/auth.json"
  chmod 600 "$isolated_root/codex/auth.json"
}

run_isolated_codex() {
  HOME="$CODEX_RUNTIME_HOME" \
    CODEX_HOME="$ISOLATED_ROOT/codex" \
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
  run_isolated_codex mcp list "${ISOLATION_FLAGS[@]}" --json \
    | jq -e 'type == "array" and length == 0' >/dev/null \
    || fail "Could not verify that MCP servers are disabled."
  run_isolated_codex plugin list "${ISOLATION_FLAGS[@]}" --json \
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
  local expected_provider=$2

  jq -sce --arg expected_provider "$expected_provider" "$PARSE_RUN_FILTER" "$rollout_file"
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
  local model=$(model_for_provider "$MODEL_PROVIDER" "$REQUESTED_MODEL")
  local result
  local -a provider_args=(-c "model_provider=\"$MODEL_PROVIDER\"")

  if [[ $MODEL_PROVIDER == openai ]]; then
    provider_args+=(-c "service_tier=\"$SERVICE_TIER\"")
  else
    provider_args+=("${BEDROCK_CONFIG_ARGS[@]}")
  fi

  mkdir "$run_root"
  run_isolated_codex exec --json --ignore-user-config --skip-git-repo-check \
    --sandbox read-only --color never "${ISOLATION_FLAGS[@]}" -C "$run_root" -m "$model" \
    -c "$skill_config" \
    -c "model_reasoning_effort=\"$REASONING_EFFORT\"" "${provider_args[@]}" \
    "$PROMPT" > "$public_events" 2> "$error_log" &
  process_id=$!
  wait_with_timeout "$process_id" "$RUN_TIMEOUT_SECONDS" || exit_code=$?
  if (( exit_code == 124 )); then
    print -u2 -- "Codex timed out after $RUN_TIMEOUT_SECONDS seconds on run $run_number."
    return 124
  fi
  # ERR_EXIT is suppressed inside the `if` condition that calls this function, so every
  # failure must return explicitly or the run reports success with an empty result.
  (( exit_code == 0 )) || {
    fail "Codex failed on run $run_number. See details below:\n$(jq -sr '
      [.[] | select(.type == "error") | .message] | last // "no error event"' "$public_events")\n$(<"$error_log")"
    return 1
  }
  thread_id=$(jq -sr '[.[] | select(.type == "thread.started") | .thread_id] | last // empty' "$public_events")
  [[ -n "$thread_id" ]] || {
    fail "Codex did not report a thread ID on run $run_number."
    return 1
  }
  rollout_file=$(find_rollout "$ISOLATED_ROOT" "$thread_id") || return 1
  result=$(parse_run "$rollout_file" "$MODEL_PROVIDER") || {
    fail "Run $run_number did not produce a valid isolated benchmark result."
    return 1
  }
  print -r -- "$result"
}

run_with_retry() {
  local run_number=$1
  local skill_config=$2
  local attempt
  local result
  local exit_code

  for attempt in {1..$MAX_ATTEMPTS_PER_RUN}; do
    exit_code=0
    result=$(run_once "$run_number" "$attempt" "$skill_config") || exit_code=$?
    if (( exit_code == 0 )); then
      print -r -- "$result"
      return 0
    elif (( exit_code != 124 )); then
      return 1
    fi
    (( attempt < MAX_ATTEMPTS_PER_RUN )) \
      && print -u2 -- "Retrying run $run_number ($(( attempt + 1 ))/$MAX_ATTEMPTS_PER_RUN)..."
  done
  fail "Run $run_number timed out $MAX_ATTEMPTS_PER_RUN times."
}

prepare_benchmark_environment() {
  local total_runs=$(( WARMUP_RUNS + MEASURED_RUNS ))

  prepare_isolated_home "$ISOLATED_ROOT" "$MODEL_PROVIDER"
  verify_isolation
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
  local model=$(model_for_provider "$MODEL_PROVIDER" "$REQUESTED_MODEL")

  print "Codex Speed Benchmark v$BENCHMARK_VERSION"
  print "Date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  print "Host: $(detect_host)"
  print "macOS: $(detect_macos)"
  print "Isolation: MCP / Skills / Plugins / AGENTS disabled"
  print "Codex CLI: $codex_version"
  print "jq: $jq_version"
  print "Provider: $(provider_name "$MODEL_PROVIDER")"
  print "Authentication: $AUTHENTICATION"
  print "Model: $model"
  print "Reasoning: $REASONING_EFFORT"
  [[ $MODEL_PROVIDER == openai ]] && print "Requested service tier: $SERVICE_TIER"
  [[ $MODEL_PROVIDER == amazon-bedrock ]] && print "AWS region: $AWS_BENCHMARK_REGION"
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
  local -a options
  options=("${(@f)$(parse_options "$@")}") || return 1
  SERVICE_TIER=$options[1]
  REQUESTED_MODEL=${options[2]:-}
  require_command codex
  require_jq
  CODEX_BIN=$(command -v codex)
  ORIGINAL_CODEX_HOME=${CODEX_HOME:-$HOME/.codex}
  MODEL_PROVIDER=$(detect_model_provider)
  AUTHENTICATION=$(detect_authentication "$MODEL_PROVIDER")
  [[ $MODEL_PROVIDER == amazon-bedrock || -r "$ORIGINAL_CODEX_HOME/auth.json" ]] \
    || fail "Codex authentication was not found. Run: codex login"
  [[ $MODEL_PROVIDER == amazon-bedrock ]] && detect_bedrock_config_args
  BENCHMARK_ROOT=$(mktemp -d /tmp/codex-speed-benchmark.XXXXXX)
  ISOLATED_ROOT="$BENCHMARK_ROOT/environment"
  CODEX_RUNTIME_HOME="$ISOLATED_ROOT/home"
  [[ $MODEL_PROVIDER == amazon-bedrock ]] && CODEX_RUNTIME_HOME=$HOME
  return 0
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

  verify_isolation
  local recorded=0
  if [[ -f "$results_file" ]]; then
    recorded=$(jq -se 'length' "$results_file")
  fi
  (( recorded == MEASURED_RUNS )) \
    || fail "Expected $MEASURED_RUNS measured results but recorded $recorded."
  local summary=$(median_summary "$results_file")
  print_summary "$results_file" "$summary"
}

main() {
  initialize "$@"
  execute_benchmark
}

if [[ $ZSH_EVAL_CONTEXT == toplevel ]]; then
  # These must be installed here, not inside a function: zsh runs an EXIT trap when the
  # function that set it returns, so installing it in initialize() deleted the temporary
  # directory immediately and left the real one behind at exit. A top-level EXIT trap runs
  # once, at process exit, and is not inherited by command substitutions or background jobs.
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  main "$@"
fi
