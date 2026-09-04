# Codex Speed Benchmark

A small macOS benchmark for comparing Codex text-generation speed under isolated, repeatable conditions.

## Requirements

- A logged-in Codex CLI installation
- `jq` (`brew install jq`)

## Run

```console
./benchmark.zsh
./benchmark.zsh --service-tier fast
./benchmark.zsh --model gpt-5.6-sol
./benchmark.zsh --model gpt-5.6-sol --service-tier fast
```

Running `sh benchmark.zsh` is also supported; the script automatically re-executes itself with macOS's `/bin/zsh`.

For OpenAI runs, `--service-tier` accepts `default` or `fast`; omitting it uses `default`. This is the requested tier because Codex CLI does not expose the tier that actually served the response. Amazon Bedrock runs do not send a service tier, even when specified. The former positional arguments `fast` and `default` are no longer supported.

Use `--model <ID>` to select a model. The ID is passed unchanged to Codex; for Amazon Bedrock, include the provider prefix, for example `./benchmark.zsh --model openai.gpt-5.6-sol`. Without `--model`, OpenAI uses `gpt-5.6-sol` and Amazon Bedrock uses `openai.gpt-5.6-sol`. Options may appear in either order and each may be specified once. Use a space between each option and its value; short options and `--option=value` are not supported.

The summary header records the host so pasted results are comparable: chip, hardware model, core count, memory, and the macOS version and build. Local hardware has little effect on generation speed, which is measured server-side, but it distinguishes runs on different machines and networks. The hostname is deliberately not reported.

The benchmark makes one warm-up request and five measured requests using the selected model and low reasoning. Model compatibility errors, including unsupported low reasoning, are reported by Codex. It detects whether Codex is configured to use OpenAI or Amazon Bedrock and reports the provider and authentication type. OpenAI runs report ChatGPT or API key authentication without exposing key fragments; Bedrock runs report AWS authentication.

Codex runs with isolated temporary state, every discovered system skill disabled, and no personal MCP servers or plugins installed. Bedrock runs retain access to the standard AWS credential chain. Each run has a 120-second timeout and one retry for transient timeouts. Temporary authentication and response data are deleted on exit.

The benchmark reads your existing Codex setup and never writes to it. `$CODEX_HOME/config.toml`, `~/.aws/config` and `~/.aws/credentials` are only read; every setting the benchmark needs is passed as a per-invocation `-c` override, and all session state is redirected to the temporary directory. A run leaves no rollout in your real `CODEX_HOME`.

### Amazon Bedrock region and profile

Isolation relies on `--ignore-user-config`, which also discards `[model_providers.amazon-bedrock.aws]` — the only place Codex is told which Bedrock region and AWS profile to use. The benchmark therefore reads `region` and `profile` back out of `$CODEX_HOME/config.toml` and re-supplies them as explicit overrides, and reports the region in the summary header.

The file takes precedence over `AWS_REGION` / `AWS_PROFILE` deliberately: it is what a normal Codex run uses. The GPT-5.x models are served from a different region than Claude Code's (`us-east-2` versus `us-west-2`), so preferring an inherited `AWS_REGION` would benchmark against a region where the model returns `404 The model does not exist`. Environment variables are used only when the file specifies nothing, and a run aborts before making requests if no region can be determined.

Because `--ignore-user-config` also drops the `[otel]` section, Bedrock benchmark runs emit no telemetry. The Bedrock spend is still real but is invisible to any Honeycomb-derived cost attribution.

Progress is written to stderr. The final stdout block can be pasted directly into Slack.

## Metrics

- **Total TPS** includes reasoning output tokens.
- **Visible TPS** excludes reasoning output tokens.
- **TTFT** is Codex's reported time to first token.

TPS uses the generation interval after TTFT rather than the entire turn duration.

## Test

```console
zsh -n benchmark.zsh tests/test.zsh
zsh tests/test.zsh
```
