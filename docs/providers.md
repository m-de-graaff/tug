# Providers

Seven presets, two API shapes, one implementation each. Copy-paste first.

## Setting a key

One environment variable per preset, and nothing else in v0.2. The config file,
`key_cmd = "pass show anthropic"`, and the flag → env → config → command
resolution chain all arrive in Phase 5; until then this is the whole story, and
saying so is better than implying otherwise.

```sh
export ANTHROPIC_API_KEY=...     # anthropic
export OPENAI_API_KEY=...        # openai
export OPENROUTER_API_KEY=...    # openrouter
export GROQ_API_KEY=...          # groq
export VLLM_API_KEY=...          # vllm
# ollama and lmstudio need none
```

If a key is missing, tug prints the export line for the preset you asked for.
That is deliberate: an error message about credentials should be something you
can paste, not something you have to go and look up.

## The table

| Preset | Shape | Base URL | Auth | Key from |
|---|---|---|---|---|
| `anthropic` | Messages API | `https://api.anthropic.com` | `x-api-key` | `ANTHROPIC_API_KEY` |
| `openai` | chat-completions | `https://api.openai.com` | Bearer | `OPENAI_API_KEY` |
| `openrouter` | chat-completions | `https://openrouter.ai/api` | Bearer | `OPENROUTER_API_KEY` |
| `groq` | chat-completions | `https://api.groq.com/openai` | Bearer | `GROQ_API_KEY` |
| `ollama` | chat-completions | `http://127.0.0.1:11434` | none | — |
| `lmstudio` | chat-completions | `http://127.0.0.1:1234` | none | — |
| `vllm` | chat-completions | `http://127.0.0.1:8000` | Bearer | `VLLM_API_KEY` |

vLLM is self-hosted, so the loopback default is a guess that is right on your own
machine and wrong on anyone else's.

## Plaintext

`http://` is allowed **to this machine only** — `localhost`, `::1`, and the whole
`127.0.0.0/8` block. Anywhere else it is refused before a socket is opened, and
the refusal is the feature: an API key sent over plaintext to a host on the
network is an API key somebody else now has.

The check is on the whole hostname, never a prefix. `localhost.example.com` is a
perfectly ordinary registrable name belonging to somebody else, and it is not
loopback.

There is one escape hatch, per endpoint, and it is not in the config schema until
Phase 6. If you need it before then, you need a reverse proxy with TLS on it.

**A proxy is not seen through.** If `https_proxy` routes your requests through a
plaintext hop, tug does not inspect that and does not warn about it. Documented
rather than half-checked — see `DR-017`.

## Redirects

Refused. An API does not redirect; a redirect is a captive portal, a corporate
proxy, or a base URL with a typo in it, and following one would send your key to
whoever answered. If you get a redirect error, look at the base URL first and the
network you are on second.

## Prompt caching

On, automatically, for Anthropic: a cache marker on the system prompt and one on
the last user turn, with no configuration (`DR-022`). You can see it working in
the usage line — the cached count is separate from the fresh input count because
they are priced an order of magnitude apart.

OpenAI-compatible servers get no markers, because there is nothing to send: that
side of the ecosystem caches server-side or not at all. Cached tokens are
reported when a server supplies the number and reported as zero when it does not.

## Streaming a turn today

There is no provider in the shell yet — Phase 7 is where the terminal frontend
gets a real spine. What exists in M2 is a debug-build subcommand, which is also
the first thing in tug shaped like the pipe frontend Phase 8 builds:

```sh
zig build -Doptimize=Debug
./zig-out/bin/tug dev stream --preset ollama --model llama3.1 "explain bollard pull"
```

Model text goes to stdout and every diagnostic to stderr, so `... | wc -c`
measures the answer. `--json` puts ndjson `StreamEvent`s on stdout instead —
byte for byte the vocabulary Phase 8's `--json` prints and v0.5's plugins speak.

## Tools

Parsed, not executed. If a model asks for a tool, tug says so once per turn and
the stream continues or stops as the API's stop reason says. Execution is v0.3.
