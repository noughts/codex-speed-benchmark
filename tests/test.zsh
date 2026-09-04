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
  assert_equal "default" "$(parse_options)" "default options"
  assert_equal "default" "$(parse_options --service-tier default)" "explicit default tier"
  assert_equal "fast" "$(parse_options --service-tier fast)" "fast tier"
  assert_equal $'default\ncustom-model' "$(parse_options --model custom-model)" "model only"
  assert_equal $'fast\ncustom-model' \
    "$(parse_options --model custom-model --service-tier fast)" "model then tier"
  assert_equal $'fast\ncustom-model' \
    "$(parse_options --service-tier fast --model custom-model)" "tier then model"
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
test_timeout
test_skill_config
test_median
test_timeout_retry
print "All tests passed."
