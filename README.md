# Codex Speed Benchmark

A small macOS benchmark for comparing Codex text-generation speed under isolated, repeatable conditions.

## Requirements

- A logged-in Codex CLI installation
- `jq` (`brew install jq`)

## Run

```console
./benchmark.zsh
./benchmark.zsh fast
```

Running `sh benchmark.zsh` is also supported; the script automatically re-executes itself with macOS's `/bin/zsh`.

For OpenAI runs, the optional service tier is `default` or `fast`; omitting it uses `default`. This is the requested tier because Codex CLI does not expose the tier that actually served the response. Amazon Bedrock runs do not send a service tier.

The benchmark makes one warm-up request and five measured requests using GPT-5.6 Sol and low reasoning. It detects whether Codex is configured to use OpenAI or Amazon Bedrock and reports the provider and authentication type. OpenAI runs report ChatGPT or API key authentication without exposing key fragments; Bedrock runs report AWS authentication.

Codex runs with isolated temporary state, every discovered system skill disabled, and no personal MCP servers or plugins installed. Bedrock runs retain access to the standard AWS credential chain. Each run has a 120-second timeout and one retry for transient timeouts. Temporary authentication and response data are deleted on exit.

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
