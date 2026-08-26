# Endpoint smoke

The manual, pre-tag checklist. `.artifacts/ROADMAP.md` § v0.2 makes it an exit
criterion: *streams from three real endpoints including local Ollama over plain
HTTP*. CI never does this — no test tier in this project touches a network, by
design — so it is done by a human, and the evidence is a dated row below.

Run each one from a debug build:

```sh
zig build -Doptimize=Debug

# Anthropic, over TLS.
ANTHROPIC_API_KEY=... ./zig-out/bin/tug dev stream \
  --preset anthropic --model claude-sonnet-4-5 \
  "why is a tugboat rated in bollard pull"

# A hosted OpenAI-compatible service.
OPENROUTER_API_KEY=... ./zig-out/bin/tug dev stream \
  --preset openrouter --model meta-llama/llama-3.1-8b-instruct \
  "why is a tugboat rated in bollard pull"

# Local Ollama, plaintext loopback.
./zig-out/bin/tug dev stream \
  --preset ollama --model llama3.1 \
  "why is a tugboat rated in bollard pull"
```

What to look for, in order:

1. Text arrives **incrementally**, not in one lump at the end. A response that
   appears all at once means something above the transport is buffering, and the
   3 ms first-token budget in Phase 10 will not save you from noticing it later.
2. The usage line on stderr has plausible numbers. For Anthropic the cached
   count is nonzero on the *second* run of the same prompt — but only if the
   prompt is long enough to cache at all; see below.
3. `Ctrl+C` mid-stream returns the prompt immediately and keeps the text that
   already arrived (`DR-018`).
4. `--debug-wire` shows the request head with the key redacted. Look at it. The
   canary tests assert this mechanically, and a human reading it once a version
   is the check the tests cannot be.

**A short prompt will never show a cache hit.** Anthropic will not create a cache
entry below a minimum prefix length — around 1024 tokens for Sonnet and Opus,
more for Haiku — so a one-line question reports `0 cached` on every run however
many times it is repeated. That is the API declining to cache, not tug failing to
ask: the markers are on the request either way (`DR-022`). To watch caching work,
send a long system prompt and ask two questions.

## Results

| Endpoint | Date | Transport | Result | Notes |
|---|---|---|---|---|
| api.anthropic.com | 2026-08-26 | TLS 1.3 | ✅ | `claude-sonnet-5`, streamed incrementally, Windows and Linux. Handshake first try, no retries. Also verified: an invalid key returns a real 401, classified `auth`, exit 3, with the export line in the message. |
| one hosted OpenAI-compat | — | TLS 1.3 | ⬜ | outstanding |
| Ollama (local) | — | http, loopback | ⬜ | outstanding — no Ollama running on the development machine |

One of three. The first real request found three bugs that 655 passing tests did
not: a struct larger than the main thread stack, a DNS path that nests its frames
on the caller's stack when the `Io` is single-threaded, and a TLS handshake that
unwrapped a null because tug connected without the certificate-bundle scan the
standard library's own connect path performs. All three are fixed and each has a
test; none of them was reachable from a fixture, which is the argument for this
document existing.

The offline half of this version is complete and green — every fixture replays
byte for byte through the whole stack, at five chunk sizes, in a namespace with
no network in it. That was never evidence that a real endpoint answers, and the
gap between the two is exactly the size of those three bugs.

`DR-023` (the std-TLS verdict) reads its evidence table from this one, which is
why it is still `proposed`.

## When a row is filled in

Copy the TLS observations into `DR-023`'s evidence table in the same commit.
A row here and no row there means the verdict is being written from memory.
