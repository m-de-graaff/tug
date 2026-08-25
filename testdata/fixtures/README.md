# Response fixtures

Recorded HTTP responses, replayed through the fixture transport so CI can prove
real-API behaviour without a network. Four files per case, sharing a stem:

| File | Contents |
|---|---|
| `<case>.head` | Status line and response headers, verbatim, CRLF-terminated, trailing blank line |
| `<case>.sse` | The response body, verbatim — every byte, including the framing |
| `<case>.toml` | Metadata (below) |
| `<case>.ndjson` | The `StreamEvent` sequence the stack must emit, one per line |

The `.ndjson` file is the assertion. `.head` and `.sse` are what went in; that is
what has to come out, byte for byte, through the whole stack. A fixture without
one is a recording nobody is checking.

Directories are API shapes, not vendors: `anthropic/` and `openai/`. Every
OpenAI-compatible server — Ollama, OpenRouter, Groq, vLLM, LM Studio — records
into `openai/`, with the server named in the sidecar's `note`, because the point
of a compat fixture is exactly which server deviates and how.

## Metadata sidecar

```toml
endpoint = "https://api.anthropic.com/v1/messages"
model = "claude-sonnet-4-5"
capture = "2026-08-25"       # or "handwritten"
recorder = "tug dev record 0.2.0"  # or "handwritten"
sanitized = "no key material present; response side only"
note = "what this case is here to prove"
```

`sanitized` is an attestation, not a checkbox: it says what was checked and what
was found. `scripts/canary-grep.sh` enforces the floor — nothing key-shaped
anywhere under `testdata/` — and the attestation is what a human reviewing a
fixture diff reads. Some APIs echo request metadata into a response body, so the
floor and the attestation are not the same guarantee.

`capture = "handwritten"` marks a body written by hand rather than recorded. Such
a fixture proves the parser handles a shape; it does not prove any API produces
that shape. Phase 9 replaces the bodies without touching the layout.

## Requests are never recorded

Only the response side lands on disk. Request headers carry `x-api-key` and
`Authorization`, and the way to guarantee those never reach a fixture is to have
no code that could write them — `tug dev record` captures responses only, by
construction, rather than by remembering to scrub.

## Line endings

`.gitattributes` marks this directory `-text`, so git normalizes nothing here in
either direction. LF, CRLF and bare-CR bodies are all valid SSE framing and the
parser is tested against all three; a helpful line-ending rewrite on checkout
would quietly delete two of those tests.
