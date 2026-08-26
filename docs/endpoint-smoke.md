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
2. The usage line on stderr has plausible numbers, and for Anthropic the cached
   count is nonzero on the *second* run of the same prompt (`DR-022`).
3. `Ctrl+C` mid-stream returns the prompt immediately and keeps the text that
   already arrived (`DR-018`).
4. `--debug-wire` shows the request head with the key redacted. Look at it. The
   canary tests assert this mechanically, and a human reading it once a version
   is the check the tests cannot be.

## Results

| Endpoint | Date | Transport | Result | Notes |
|---|---|---|---|---|
| api.anthropic.com | — | TLS 1.3 | ⬜ | outstanding |
| one hosted OpenAI-compat | — | TLS 1.3 | ⬜ | outstanding |
| Ollama (local) | — | http, loopback | ⬜ | outstanding — no Ollama on the development machine at M2 |

Three empty rows, and they are empty rather than absent on purpose. The offline
half of this version is complete and green — every fixture replays byte for byte
through the whole stack, at five chunk sizes, in a namespace with no network in
it — and none of that is evidence that a real endpoint answers. The two claims
are different claims and only one of them has been made.

`DR-023` (the std-TLS verdict) reads its evidence table from this one, which is
why it is still `proposed`.

## When a row is filled in

Copy the TLS observations into `DR-023`'s evidence table in the same commit.
A row here and no row there means the verdict is being written from memory.
