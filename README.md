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

The optional service tier is `default` or `fast`; omitting it uses `default`. This is the requested tier because Codex CLI does not expose the tier that actually served the response.

The benchmark makes one warm-up request and five measured requests using GPT-5.6 Sol and low reasoning. It runs Codex with an isolated temporary home, disables every discovered system skill, and verifies that no personal MCP servers or plugins are installed. Each run has a 120-second timeout and one retry for transient timeouts. Temporary authentication and response data are deleted on exit.

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
