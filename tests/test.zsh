#!/bin/zsh

setopt errexit nounset pipefail

typeset -gr TEST_ROOT=${0:A:h}
typeset TEST_TEMP=""
typeset TEST_DIR=""
source "$TEST_ROOT/../benchmark.zsh"

cleanup_test() {
  [[ -n "$TEST_TEMP" && -f "$TEST_TEMP" ]] && unlink "$TEST_TEMP"
  [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
  return 0
}

trap cleanup_test EXIT

assert_equal() {
  local expected=$1
  local actual=$2
  local label=$3

  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

assert_json_field() {
  local expected=$1
  local field=$2
  local json=$3

  assert_equal "$expected" "$(jq -r ".$field" <<< "$json")" "$field"
}

test_parse_run() {
  local result=$(parse_run "$TEST_ROOT/fixtures/success.jsonl" openai)

  assert_json_field "50" "total_tps" "$result"
  assert_json_field "40" "visible_tps" "$result"
  assert_json_field "2000" "ttft_ms" "$result"
  ! parse_run "$TEST_ROOT/fixtures/success.jsonl" amazon-bedrock >/dev/null 2>&1 \
    || fail "provider mismatch should be rejected"
}

test_model_provider() {
  local report='{"checks":{"config.load":{"id":"config.load","details":{"model provider":"amazon-bedrock"}}}}'

  assert_equal "amazon-bedrock" "$(parse_model_provider "$report")" "model provider"
  assert_equal "gpt-5.6-sol" "$(model_for_provider openai)" "OpenAI model"
  assert_equal "openai.gpt-5.6-sol" "$(model_for_provider amazon-bedrock)" "Bedrock model"
  assert_equal "custom-model" "$(model_for_provider openai custom-model)" "requested OpenAI model"
  assert_equal "openai.custom-model" "$(model_for_provider amazon-bedrock openai.custom-model)" "requested Bedrock model"
  assert_equal "custom-model" "$(model_for_provider amazon-bedrock custom-model)" "model ID is unchanged"
  assert_equal "OpenAI" "$(provider_name openai)" "OpenAI provider name"
  assert_equal "Amazon Bedrock" "$(provider_name amazon-bedrock)" "Bedrock provider name"
  assert_equal "openai" "$(validate_model_provider openai)" "supported provider"
  ! validate_model_provider custom >/dev/null 2>&1 || fail "custom provider should be rejected"
}

test_bedrock_aws_setting() {
  local config=$'model_provider = "amazon-bedrock"\n\n[model_providers.amazon-bedrock.aws]\nregion = "us-east-2"\nprofile = "ClaudeCode"\n'
  local dotted=$'model_providers.amazon-bedrock.aws.region = "eu-west-1"  # inline comment\n'
  local other=$'[model_providers.other.aws]\nregion = "ap-south-1"\n'
  local region_only=$'[model_providers.amazon-bedrock.aws]\nregion = "us-east-2"\n'

  assert_equal "us-east-2" "$(parse_bedrock_aws_setting region "$config")" "bedrock region"
  assert_equal "ClaudeCode" "$(parse_bedrock_aws_setting profile "$config")" "bedrock profile"
  assert_equal "eu-west-1" "$(parse_bedrock_aws_setting region "$dotted")" "dotted bedrock region"
  ! parse_bedrock_aws_setting region "$other" >/dev/null 2>&1 \
    || fail "another provider's region should not be used"
  ! parse_bedrock_aws_setting profile "$region_only" >/dev/null 2>&1 \
    || fail "a missing profile should be reported as absent"
}

test_host_metadata() {
  assert_equal "Apple M5 Max (Mac17,6), 18 cores, 64 GB" \
    "$(format_host 'Apple M5 Max' Mac17,6 18 68719476736)" "host description"
  assert_equal "unknown (unknown), unknown cores, unknown" \
    "$(format_host '' '' '' '')" "host description without sysctl values"
  [[ "$(detect_host)" == *cores* ]] || fail "detect_host should report a core count"
  [[ "$(detect_macos)" == *"("* ]] || fail "detect_macos should report a build number"
}

test_authentication() {
  assert_equal "ChatGPT" "$(parse_authentication 'Logged in using ChatGPT')" "ChatGPT auth"
  assert_equal "API key" \
    "$(parse_authentication 'Logged in using an API key - sk-proj-***abcd')" "API key auth"
  assert_equal "Unknown" "$(parse_authentication 'Logged in another way')" "unknown auth"
  assert_equal "AWS" "$(detect_authentication amazon-bedrock)" "Bedrock auth"
  [[ "$(parse_authentication 'Logged in using an API key - sk-proj-***abcd')" != *abcd* ]] \
    || fail "authentication output should not contain API key fragments"
}

test_tool_rejection() {
  if parse_run "$TEST_ROOT/fixtures/tool-call.jsonl" openai >/dev/null 2>&1; then
    fail "tool call fixture should have been rejected"
  fi
}

test_missing_jq_message() {
  local message

  message=$(PATH=/nonexistent require_jq 2>&1) && fail "missing jq should have failed"
  [[ "$message" == *"brew install jq"* ]] || fail "missing jq message should include installation command"
}

assert_invalid_options() {
  local message

  message=$(/bin/zsh "$TEST_ROOT/../benchmark.zsh" "$@" 2>&1) \
    && { fail "invalid options should fail: $*"; return 1; }
  [[ "$message" == *"Usage:"* ]] || fail "invalid options should display usage: $*"
}

test_options() {
  assert_equal $'codex\ndefault' "$(parse_options)" "default options"
  assert_equal $'codex\ndefault' "$(parse_options --service-tier default)" "explicit default tier"
  assert_equal $'codex\nfast' "$(parse_options --service-tier fast)" "fast tier"
  assert_equal $'codex\ndefault\ncustom-model' "$(parse_options --model custom-model)" "model only"
  assert_equal $'codex\nfast\ncustom-model' \
    "$(parse_options --model custom-model --service-tier fast)" "model then tier"
  assert_equal $'codex\nfast\ncustom-model' \
    "$(parse_options --service-tier fast --model custom-model)" "tier then model"
  assert_equal $'claude\nfast\nclaude-opus-5-5' \
    "$(parse_options --model claude-opus-5-5 --cli claude --service-tier fast)" "Claude options"
  assert_equal $'codex\ndefault' "$(parse_options --cli codex)" "explicit Codex"
}

test_invalid_options() {
  assert_invalid_options fast
  assert_invalid_options default
  assert_invalid_options --unknown value
  assert_invalid_options --model
  assert_invalid_options --model ''
  assert_invalid_options --model --service-tier fast
  assert_invalid_options --model=-example
  assert_invalid_options --model -example
  assert_invalid_options --service-tier
  assert_invalid_options --service-tier ''
  assert_invalid_options --service-tier slow
  assert_invalid_options --service-tier default --service-tier fast
  assert_invalid_options --model first --model second
  assert_invalid_options --model example extra
  assert_invalid_options --cli
  assert_invalid_options --cli unknown
  assert_invalid_options --cli claude
  assert_invalid_options --cli codex --cli claude --model opus
  assert_invalid_options --cli=claude --model opus
}

test_sh_reexec() {
  local message

  message=$(PATH=/nonexistent /bin/sh "$TEST_ROOT/../benchmark.zsh" --model custom-model --service-tier fast 2>&1) \
    && fail "benchmark should fail without codex"
  [[ "$message" == *"Required command 'codex'"* ]] \
    || fail "sh should re-execute the benchmark with zsh"

  message=$(/bin/sh "$TEST_ROOT/../benchmark.zsh" invalid 2>&1) \
    && fail "sh should preserve an invalid service tier argument"
  [[ "$message" == *"Usage:"* ]] || fail "sh should preserve benchmark arguments"

  message=$(PATH=/nonexistent /bin/sh "$TEST_ROOT/../benchmark.zsh" --cli claude --model opus 2>&1) \
    && fail "benchmark should fail without claude"
  [[ "$message" == *"Required command 'claude'"* && "$message" != *"Required command 'codex'"* ]] \
    || fail "Claude should require only the selected CLI"
}

test_claude_requirements() {
  validate_claude_version '2.1.281 (Claude Code)'
  validate_claude_version '2.2.0 (Claude Code)'
  ! validate_claude_version '2.1.280 (Claude Code)' >/dev/null 2>&1 || fail "old Claude should fail"
  ! validate_claude_version 'unknown' >/dev/null 2>&1 || fail "unknown version should fail"
  validate_claude_authentication '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'
  local report
  for report in \
    '{"loggedIn":false,"authMethod":"claude.ai","apiProvider":"firstParty"}' \
    '{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty"}' \
    '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"bedrock"}'; do
    ! validate_claude_authentication "$report" >/dev/null 2>&1 || fail "unsupported Claude auth should fail"
  done
}

test_claude_parser() {
  local fixture="$TEST_ROOT/fixtures/claude-success.jsonl"
  local result=$(parse_claude_run "$fixture" fast claude-opus-5-5)
  assert_json_field 50 total_tps "$result"
  assert_json_field 40 visible_tps "$result"
  assert_json_field 2000 ttft_ms "$result"
  assert_json_field fast speed "$result"
  assert_json_field 100 thinking_tokens "$result"
  parse_claude_run "$fixture" fast opus >/dev/null
  ! parse_claude_run "$fixture" default opus >/dev/null 2>&1 || fail "speed mismatch should fail"
  ! parse_claude_run "$fixture" fast claude-sonnet-5 >/dev/null 2>&1 || fail "model mismatch should fail"

  TEST_DIR=$(mktemp -d /tmp/claude-benchmark-tests.XXXXXX)
  local changed="$TEST_DIR/events.jsonl"
  jq -c 'if .type == "result" then .usage.output_tokens_details.thinking_tokens = 0 else . end' "$fixture" > "$changed"
  result=$(parse_claude_run "$changed" fast opus)
  assert_json_field 50 visible_tps "$result"
  jq -c 'if .type == "result" then del(.usage.output_tokens_details) else . end' "$fixture" > "$changed"
  result=$(parse_claude_run "$changed" fast opus)
  assert_json_field null visible_tps "$result"
  print -r -- "$result" > "$TEST_DIR/results.jsonl"
  parse_claude_run "$fixture" fast opus >> "$TEST_DIR/results.jsonl"
  assert_json_field null visible_tps "$(median_summary "$TEST_DIR/results.jsonl")"
  [[ "$(print_run_table "$TEST_DIR/results.jsonl")" == *N/A* ]] || fail "missing visible TPS should display N/A"
  [[ "$(print_medians "$(median_summary "$TEST_DIR/results.jsonl")")" == *'Median Visible TPS: N/A'* ]] \
    || fail "missing median should display N/A"

  jq -c 'if .type == "result" then .usage.speed = "standard"
    elif .event.type? == "message_start" then del(.event.message.usage.speed) else . end' "$fixture" > "$changed"
  assert_json_field standard speed "$(parse_claude_run "$changed" default opus)"

  local filter
  for filter in \
    'select(.type != "result")' \
    'if .type == "result" then ., . else . end' \
    'select(.subtype != "init")' \
    'select(.event.type? != "message_stop")' \
    'select(.event.delta.type? != "text_delta")' \
    'if .subtype == "init" then .tools = ["Bash"] else . end' \
    'if .subtype == "init" then .mcp_servers = [{name:"custom"}] else . end' \
    'if .subtype == "init" then .skills = ["custom"] else . end' \
    'if .subtype == "init" then .plugins[0].path = "/custom" else . end' \
    'if .type == "assistant" then .message.content = [{type:"tool_use",name:"Bash"}] else . end' \
    'if .event.type? == "content_block_start" then .event.content_block.type = "tool_use" else . end' \
    'if .type == "assistant" then .message.model = "other" else . end' \
    'if .type == "result" then .modelUsage.other = {} else . end' \
    'if .type == "result" then .modelUsage["claude-opus-5-5"].provider = "bedrock" else . end' \
    'if .type == "result" then .is_error = true else . end' \
    'if .type == "result" then .stop_reason = "max_tokens" else . end' \
    'if .type == "result" then .num_turns = 2 else . end' \
    'if .type == "result" then .duration_ms = 2000 else . end' \
    'if .type == "result" then del(.ttft_stream_ms) else . end' \
    'if .type == "result" then .ttft_stream_ms = -1 else . end' \
    'if .type == "result" then .usage.output_tokens = "500" else . end' \
    'if .type == "result" then .usage.output_tokens = 0 else . end' \
    'if .type == "result" then .usage.output_tokens_details.thinking_tokens = 501 else . end' \
    'if .type == "result" then .usage.output_tokens_details.thinking_tokens = -1 else . end' \
    'if .type == "result" then .usage.output_tokens_details.thinking_tokens = "100" else . end' \
    'if .type == "result" then .usage.server_tool_use.web_search_requests = 1 else . end' \
    'if .type == "result" then .subagent_stats.spawned = 1 else . end' \
    'if .type == "result" then del(.usage.speed) else . end' \
    'if .event.type? == "message_start" then .event.message.usage.speed = "standard" else . end' \
    '., (if .type == "result" then {type:"system",subtype:"hook_started"} else empty end)'; do
    jq -c "$filter" "$fixture" > "$changed"
    ! parse_claude_run "$changed" fast opus >/dev/null 2>&1 || fail "invalid Claude result accepted: $filter"
  done
  rm -rf "$TEST_DIR"
  TEST_DIR=""
}

test_process_cleanup() {
  local root=$(mktemp -d /tmp/claude-cleanup-test.XXXXXX)
  mkdir "$root/run-1-attempt-1"
  sleep 30 &
  local process_id=$!
  print -r -- "$process_id" > "$root/run-1-attempt-1/process.pid"
  ( BENCHMARK_ROOT=$root; cleanup )
  wait "$process_id" 2>/dev/null || true
  [[ ! -d "$root" ]] || fail "cleanup should delete temporary data"
  ! kill -0 "$process_id" 2>/dev/null || fail "cleanup should terminate the active process"
}

test_cli_process_is_direct() (
  CODEX_BIN=/bin/sleep
  CODEX_RUNTIME_HOME=/tmp
  ISOLATED_ROOT=/tmp
  run_isolated_codex 30 &
  local worker=$! children
  sleep 0.1
  children=$(pgrep -P "$worker") || children=""
  terminate_process "$worker"
  wait "$worker" 2>/dev/null || true
  local child
  for child in "${(@f)children}"; do
    [[ -n "$child" ]] && terminate_process "$child"
  done
  [[ -z "$children" ]] || fail "launcher created an untracked child process"
)

test_interrupt_during_run() {
  local root=$(mktemp -d /tmp/benchmark-interrupt-test.XXXXXX)
  # Use a real slow process at the I/O boundary to test signal handling without API calls.
  /bin/zsh -c '
    source "$1"
    BENCHMARK_ROOT=$2
    trap cleanup EXIT
    trap "exit 143" TERM
    run_once() {
      mkdir "$BENCHMARK_ROOT/run-1-attempt-1"
      sleep 30 &
      local child=$!
      print -r -- "$child" > "$BENCHMARK_ROOT/run-1-attempt-1/process.pid"
      wait_with_timeout "$child" 60
    }
    run_with_retry 1 ""
  ' test "$TEST_ROOT/../benchmark.zsh" "$root" >/dev/null 2>&1 &
  local runner=$! child="" attempt exit_code=0
  for attempt in {1..50}; do
    if [[ -f "$root/run-1-attempt-1/process.pid" ]]; then
      child=$(<"$root/run-1-attempt-1/process.pid")
      break
    fi
    sleep 0.05
  done
  kill -TERM "$runner"
  wait_with_timeout "$runner" 5 || exit_code=$?
  if [[ -z "$child" ]] || kill -0 "$child" 2>/dev/null; then
    [[ -n "$child" ]] && terminate_process "$child"
    rm -rf "$root"
    fail "interrupted runner left its child alive or did not start"
    return 1
  fi
  assert_equal 143 "$exit_code" "interrupted runner exit code"
  [[ ! -d "$root" ]] || fail "interrupted runner left temporary data"
}

test_timeout() {
  local exit_code=0

  sleep 2 &
  local process_id=$!
  wait_with_timeout "$process_id" 0 || exit_code=$?
  assert_equal "124" "$exit_code" "timeout exit code"
  ! kill -0 "$process_id" 2>/dev/null || fail "timed out process should be stopped"
}

test_skill_config() {
  local config=$(build_skill_config imagegen openai-docs)

  assert_equal 'skills.config=[{name="imagegen",enabled=false},{name="openai-docs",enabled=false}]' \
    "$config" "skill config"
}

test_timeout_retry() {
  run_once() {
    (( $2 == 1 )) && return 124
    print '{"retried":true}'
  }

  local result=$(run_with_retry 1 'skills.config=[]' 2>/dev/null)
  assert_json_field "true" "retried" "$result"
}

test_median() {
  TEST_TEMP=$(mktemp /tmp/codex-speed-results.XXXXXX)
  print '{"total_tps":30,"visible_tps":20,"ttft_ms":3000}' >> "$TEST_TEMP"
  print '{"total_tps":10,"visible_tps":40,"ttft_ms":1000}' >> "$TEST_TEMP"
  print '{"total_tps":50,"visible_tps":30,"ttft_ms":2000}' >> "$TEST_TEMP"
  local result=$(median_summary "$TEST_TEMP")

  assert_json_field "30" "total_tps" "$result"
  assert_json_field "30" "visible_tps" "$result"
  assert_json_field "2000" "ttft_ms" "$result"
}

test_parse_run
test_model_provider
test_bedrock_aws_setting
test_host_metadata
test_authentication
test_tool_rejection
test_missing_jq_message
test_options
test_invalid_options
test_sh_reexec
test_claude_requirements
test_claude_parser
test_process_cleanup
test_cli_process_is_direct
test_interrupt_during_run
test_timeout
test_skill_config
test_median
test_timeout_retry
print "All tests passed."
