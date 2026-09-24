# Codex / Claude Code Speed Benchmark

A small macOS benchmark for comparing Codex and Claude Code text-generation speed under isolated, repeatable conditions.

## Requirements

- A logged-in Codex CLI, or Claude Code 2.1.281 or later with a direct Claude account login
- `jq` (`brew install jq`)

## Run

```console
./benchmark.zsh
./benchmark.zsh --service-tier fast
./benchmark.zsh --model gpt-5.6-sol
./benchmark.zsh --model gpt-5.6-sol --service-tier fast
./benchmark.zsh --cli claude --model claude-opus-5-5
./benchmark.zsh --cli claude --model claude-opus-5-5 --service-tier fast
```

Running `sh benchmark.zsh` is also supported; the script automatically re-executes itself with macOS's `/bin/zsh`.

`--cli` accepts `codex` or `claude` and defaults to `codex`. Only the selected CLI must be installed. Claude runs require an explicit `--model`; full IDs and aliases such as `opus` are accepted, and the actual model is recorded. Each option may appear once, in any order.

For OpenAI runs, `--service-tier` accepts `default` or `fast`; omitting it uses `default`. This is the requested tier because Codex CLI does not expose the tier that actually served the response. Amazon Bedrock runs do not send a service tier, even when specified. The former positional arguments `fast` and `default` are no longer supported.

Use `--model <ID>` to select a model. The ID is passed unchanged to the selected CLI; for Codex on Amazon Bedrock, include the provider prefix, for example `./benchmark.zsh --model openai.gpt-5.6-sol`. Without `--model`, OpenAI uses `gpt-5.6-sol` and Amazon Bedrock uses `openai.gpt-5.6-sol`. Use a space between each option and its value; short options and `--option=value` are not supported.

The summary header records the host so pasted results can be identified: chip, hardware model, core count, memory, and the macOS version and build. Timings are reported by the respective CLIs and can be affected by network and client overhead. The hostname is deliberately not reported.

The benchmark makes one warm-up request and five measured requests using the selected model and low reasoning. Model compatibility errors, including unsupported low reasoning, are reported by Codex. It detects whether Codex is configured to use OpenAI or Amazon Bedrock and reports the provider and authentication type. OpenAI runs report ChatGPT or API key authentication without exposing key fragments; Bedrock runs report AWS authentication.

Codex runs with isolated temporary state, every discovered system skill disabled, and no personal MCP servers or plugins installed. Bedrock runs retain access to the standard AWS credential chain. Each run has a 120-second timeout and one retry for transient timeouts. Temporary authentication and response data are deleted on exit.

The benchmark reads your existing Codex setup and never writes to it. `$CODEX_HOME/config.toml`, `~/.aws/config` and `~/.aws/credentials` are only read; every setting the benchmark needs is passed as a per-invocation `-c` override, and all session state is redirected to the temporary directory. A run leaves no rollout in your real `CODEX_HOME`.

### Amazon Bedrock region and profile

Isolation relies on `--ignore-user-config`, which also discards `[model_providers.amazon-bedrock.aws]` — the only place Codex is told which Bedrock region and AWS profile to use. The benchmark therefore reads `region` and `profile` back out of `$CODEX_HOME/config.toml` and re-supplies them as explicit overrides, and reports the region in the summary header.

The file takes precedence over `AWS_REGION` / `AWS_PROFILE` deliberately: it is what a normal Codex run uses. The GPT-5.x models are served from a different region than Claude Code's (`us-east-2` versus `us-west-2`), so preferring an inherited `AWS_REGION` would benchmark against a region where the model returns `404 The model does not exist`. Environment variables are used only when the file specifies nothing, and a run aborts before making requests if no region can be determined.

Because `--ignore-user-config` also drops the `[otel]` section, Bedrock benchmark runs emit no telemetry. The Bedrock spend is still real but is invisible to any Honeycomb-derived cost attribution.

Progress is written to stderr. The final stdout block can be pasted directly into Slack.

### Claude Code

Claude runs use the same prompt, one warm-up and five measured requests, with the same timeout and retry policy. `--service-tier default` explicitly disables fast mode; `--service-tier fast` enables it for that invocation. The benchmark checks the actual response's `usage.speed` (`standard` or `fast`), because `usage.service_tier` can be `standard` even during fast mode. Missing speed metadata, a speed mismatch, model switching, tool use, or an incomplete response fails the run. Fast mode requires a supported model and account access; it can consume separately billed usage credits. See the [fast mode documentation](https://code.claude.com/docs/en/fast-mode).

Thinking is requested off with `MAX_THINKING_TOKENS=0`, and effort is explicitly `low`. Models that require thinking, including Opus 5.5, retain adaptive thinking and are supported. The model may use zero or nonzero thinking tokens on each request. See [model configuration](https://code.claude.com/docs/en/model-config).

Claude starts in a temporary working directory with safe mode, user/project/local settings ignored, tools and MCP servers disabled, skills disabled, hooks disabled, and session persistence disabled. Every response's initialization metadata is checked. The built-in `agents-md` and `telemetry` plugins remain in Claude Code 2.1.281 and are listed in the summary; custom plugins are rejected. Administrative policy still applies.

Settings and caches are redirected to a temporary `CLAUDE_CONFIG_DIR`. `CLAUDE_SECURESTORAGE_CONFIG_DIR` points to the original credential store (preserving its existing override, or the original `CLAUDE_CONFIG_DIR`, when set). This behavior was verified on 2.1.281. The script does not extract tokens or edit your saved settings. Claude may refresh credentials in the original credential store. All benchmark temporary data is deleted on exit, and an active CLI process is terminated on interruption. This first version supports direct Claude account authentication; Claude API-key and third-party-provider configurations are rejected.

## Metrics

- **Total TPS** includes reasoning output tokens.
- **Visible TPS** excludes reasoning output tokens.
- **TTFT** uses Codex's reported time to first token, or Claude's `ttft_stream_ms` (stream start, including thinking).

TPS uses the generation interval after TTFT rather than the entire turn duration.

For Claude, the interval is `result.duration_ms - result.ttft_stream_ms`. Total TPS uses the final cumulative `usage.output_tokens`; Visible TPS subtracts `usage.output_tokens_details.thinking_tokens`. Both use the same interval, including time spent generating thinking. Partial-message usage is not summed. Claude's `result.ttft_ms` is not used: in testing it tracked completion of the first content block rather than the stream start.

If Claude omits the thinking token count, Visible TPS is `N/A`, and its median is also `N/A` if any measured run is missing that count. Missing streaming timing fails the run. The two CLIs have different timing boundaries, and different models have different tokenizers, so these figures are not an identical server-side measurement across models. The five measured Claude runs must use the same actual model, speed, and built-in plugins.

## Test

```console
zsh -n benchmark.zsh tests/test.zsh
zsh tests/test.zsh
```
