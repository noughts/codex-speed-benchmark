# The result usage is cumulative. Never sum partial assistant/message usage.
def nonnegative_number: type == "number" and isfinite and . >= 0;
def token_count: nonnegative_number and floor == .;
def empty_array: type == "array" and length == 0;

. as $events
| [ .[] | select(.type == "system" and .subtype == "init") ] as $inits
| [ .[] | select(.type == "result") ] as $results
| [ .[] | select(.type == "stream_event") | .event ] as $stream
| if ($inits | length) != 1 or ($results | length) != 1 then
    error("expected one init and one result") else . end
| $inits[0] as $init
| $results[0] as $turn
| $turn.usage as $usage
| $usage.output_tokens_details.thinking_tokens as $thinking_tokens
| (if $tier == "fast" then "fast" else "standard" end) as $speed
| if $turn.subtype != "success" or $turn.is_error != false
    or $turn.num_turns != 1 or $turn.stop_reason != "end_turn" then
    error("Claude did not complete exactly one successful turn")
  elif any($events[]; .type == "error" or
    (.type == "system" and (.subtype | IN(
      "api_retry", "model_refusal_fallback", "hook_started", "hook_response", "hook_progress"
    )))) then error("error, retry, fallback, or hook event detected")
  elif any($events[] | .. | objects; .type? | IN("tool_use", "server_tool_use", "tool_result"))
    or ($usage.server_tool_use.web_search_requests // 0) != 0
    or ($usage.server_tool_use.web_fetch_requests // 0) != 0
    or ($turn.subagent_stats.spawned // 0) != 0 then error("tool or subagent use detected")
  elif ([$init.tools, $init.mcp_servers, $init.skills] | all(.[]; empty_array) | not) then
    error("tools, MCP servers, or skills are not disabled")
  elif ($init.plugins | type) != "array" then error("plugin metadata missing")
  elif any($init.plugins[];
    .path != "builtin" or (.name | IN("agents-md", "telemetry") | not)
    or .source != (.name + "@builtin")) then error("unexpected plugin loaded")
  elif ($init.model | type) != "string" or $init.model == "" then error("model missing")
  elif ($requested_model | startswith("claude-")) and $requested_model != $init.model then
    error("requested model was changed")
  elif ($turn.modelUsage | type) != "object" then error("model usage missing")
  elif ($turn.modelUsage | keys) != [$init.model] then error("model changed or multiple models used")
  elif $turn.modelUsage[$init.model].provider != "firstParty" then error("unexpected provider")
  elif any($events[] | select(.type == "assistant"); .message.model != $init.model) then
    error("assistant model changed")
  elif any($stream[] | select(.type == "message_start"); .message.model != $init.model) then
    error("stream model changed")
  elif $usage.speed != $speed then error("actual speed missing or different from requested speed")
  elif any($stream[] | select(.type == "message_start");
    .message.usage.speed != null and .message.usage.speed != $speed) then
    error("speed changed during the response")
  elif ([$stream[] | select(.type == "message_start")] | length) != 1
    or ([$stream[] | select(.type == "message_stop")] | length) != 1 then
    error("expected one complete streamed response")
  elif (any($stream[]; .type == "content_block_delta" and .delta.type == "text_delta"
    and (.delta.text | type) == "string" and (.delta.text | length) > 0) | not) then
    error("no streamed response text")
  elif ($usage.output_tokens | token_count | not) or $usage.output_tokens == 0 then
    error("invalid output token count")
  elif $thinking_tokens != null and
    (($thinking_tokens | token_count | not)
      or $thinking_tokens > $usage.output_tokens) then
    error("invalid thinking token count")
  elif ($turn.ttft_stream_ms | nonnegative_number | not)
    or ($turn.duration_ms | nonnegative_number | not) then
    error("streaming timing missing or invalid; Claude Code 2.1.281 or later is required")
  else . end
| ($turn.duration_ms - $turn.ttft_stream_ms) as $generation_ms
| if $generation_ms <= 0 then error("generation duration must be positive") else . end
| {
    ttft_ms: $turn.ttft_stream_ms,
    total_tps: ($usage.output_tokens * 1000 / $generation_ms),
    visible_tps: (if $thinking_tokens == null then null
      else ($usage.output_tokens - $thinking_tokens) * 1000 / $generation_ms end),
    model: $init.model,
    speed: $usage.speed,
    thinking_tokens: $thinking_tokens,
    builtin_plugins: ([$init.plugins[].name] | sort)
  }
