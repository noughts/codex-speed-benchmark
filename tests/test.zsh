#!/bin/zsh

setopt errexit nounset pipefail

typeset -gr TEST_ROOT=${0:A:h}
typeset TEST_TEMP=""
source "$TEST_ROOT/../benchmark.zsh"

cleanup_test() {
  [[ -n "$TEST_TEMP" && -f "$TEST_TEMP" ]] && unlink "$TEST_TEMP"
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
  local result=$(parse_run "$TEST_ROOT/fixtures/success.jsonl")

  assert_json_field "50" "total_tps" "$result"
  assert_json_field "40" "visible_tps" "$result"
  assert_json_field "2000" "ttft_ms" "$result"
}

test_tool_rejection() {
  if parse_run "$TEST_ROOT/fixtures/tool-call.jsonl" >/dev/null 2>&1; then
    fail "tool call fixture should have been rejected"
  fi
}

test_missing_jq_message() {
  local message

  message=$(PATH=/nonexistent require_jq 2>&1) && fail "missing jq should have failed"
  [[ "$message" == *"brew install jq"* ]] || fail "missing jq message should include installation command"
}

test_service_tier() {
  assert_equal "default" "$(parse_service_tier)" "default service tier"
  assert_equal "default" "$(parse_service_tier default)" "explicit default service tier"
  assert_equal "fast" "$(parse_service_tier fast)" "fast service tier"
  ! parse_service_tier slow >/dev/null 2>&1 || fail "invalid service tier should fail"
  ! parse_service_tier default fast >/dev/null 2>&1 || fail "extra arguments should fail"
}

test_sh_reexec() {
  local message

  message=$(PATH=/nonexistent /bin/sh "$TEST_ROOT/../benchmark.zsh" fast 2>&1) \
    && fail "benchmark should fail without codex"
  [[ "$message" == *"Required command 'codex'"* ]] \
    || fail "sh should re-execute the benchmark with zsh"

  message=$(/bin/sh "$TEST_ROOT/../benchmark.zsh" invalid 2>&1) \
    && fail "sh should preserve an invalid service tier argument"
  [[ "$message" == *"Usage:"* ]] || fail "sh should preserve benchmark arguments"
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
test_tool_rejection
test_missing_jq_message
test_service_tier
test_sh_reexec
test_timeout
test_skill_config
test_median
test_timeout_retry
print "All tests passed."
