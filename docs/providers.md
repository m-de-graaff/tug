# Providers

Seven presets, two API shapes, one implementation each. Copy-paste first.

## Setting a key

Four places, first hit wins (`DR-024`):

1. `--key` on the command line
2. The preset's environment variable
3. `provider.key` in a config file
4. `provider.key_cmd` in a config file

```sh
export ANTHROPIC_API_KEY=...     # anthropic
export OPENAI_API_KEY=...        # openai
export OPENROUTER_API_KEY=...    # openrouter
export GROQ_API_KEY=...          # groq
export VLLM_API_KEY=...          # vllm
# ollama and lmstudio need none
```

There is no `TUG_KEY`, deliberately. A second spelling for the same secret is a
second place to leak one from.

If a key is missing, tug prints the export line for the preset you asked for.
That is deliberate: an error message about credentials should be something you
can paste, not something you have to go and look up.

### Keeping the key out of a file

```toml
[provider]
key_cmd = "pass show anthropic"
```

Run once at first use and kept in memory for the process — not per turn, because
that means a passphrase prompt per turn. Anything that prints a key to stdout
works: `pass`, `gopass`, `age -d`, `op read`, `vault kv get -field=…`, or a shell
function of your own. tug knows nothing about any of them, which is the point.

The command is split on whitespace and run directly. It is a command, not a shell
script: no pipes, no globs, no `&&`. If you need those, put them in a script and
name the script.

If it fails, tug shows the command's own stderr — that is nearly always the
useful message ("gpg: decryption failed: No secret key") — with anything
key-shaped scrubbed out of it first.

`provider.key = "..."` also works and the documentation does not recommend it. It
is supported because a user who has decided to put a key in a file will do it
regardless, and a key in a shell profile is not an improvement over a key in a
config file.

**`/config` never prints the key.** It shows `<set>` or `<unset>` and which layer
set it. `key_cmd` *is* printed, because it is the instruction rather than the
secret and hiding it would make a broken `key_cmd` impossible to diagnose.

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

One escape hatch, and it is the whole configuration rather than per endpoint:

```toml
[provider]
insecure = true
```

Turning it on for one endpoint turns it on for all of them, which is why the
documentation says use a reverse proxy with TLS on it instead.

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

## When things fail

Every error tug shows names a class and says what to do about it:

| Class | What it means | What tug does |
|---|---|---|
| `auth` | 401 or 403 | Names the variable to export. **Never retried** — a wrong key is wrong on the fourth attempt too |
| `rate_limit` | 429 | Retried **only** when the provider sent a `Retry-After`. tug waits exactly as long as it was told |
| `server` | 5xx, and any other status a provider returned | Retried with jittered backoff |
| `transport` | The bytes stopped arriving | Retried |
| `decode` | The response was not what the API documents | **Never retried.** Bytes that failed to parse will not parse later, and this is worth reporting |

A 429 with no `Retry-After` is not retried. The provider declined to say when,
and guessing is how a client becomes part of the incident it is reacting to.

**Retries stop the moment any output has arrived.** If a stream dies at the
fortieth token, you keep those forty tokens and an error saying it ended early.
tug will not silently splice two model responses together and present them as
one — see `DR-019`.

## Tools

Parsed, not executed. If a model asks for a tool, tug says so once per turn and
the stream continues or stops as the API's stop reason says. Execution is v0.3.
