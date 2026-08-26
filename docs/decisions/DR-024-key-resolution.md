# DR-024: Where an API key comes from, and where it never goes

**Status:** accepted
**Date:** 2026-08-26
**Phase:** 5 (v0.2)

## Context

tug needs a provider's API key and must not become a place where one leaks.
Those are two requirements and only the first is obvious.

`.artifacts/v0.2.md` § Phase 5 names the chain — flag, environment, config `key`,
config `key_cmd` — and its scope guard rejects keychain integration and
credential files with permission logic without saying why. This record says why,
because the rejections are the interesting half: they are the two things a
reviewer will suggest, and a scope guard that only says "no" gets argued with
every version.

## Options

**Environment variable only.** What M2 shipped, and it is genuinely most of the
answer: every provider's own documentation tells the user to export a variable,
so the mechanism is one nobody has to learn. It fails one real case — a user who
does not want a plaintext key sitting in a shell profile, which is a file that
gets backed up, committed to dotfiles repositories, and screen-shared.

**A keychain integration.** Three platforms, three APIs, two of them wanting a C
dependency in a build that has none. It also replaces one secret store with one
tug happens to know about, on a machine where the user may already be using a
different one.

**A credentials file with permission checks.** Refusing to read a file that is
not `0600` looks careful and is not: the check is meaningless on Windows, it is
bypassed by every backup tool, and its worst effect is the belief it creates —
that the file is now safe to keep a key in.

**A command that prints the key.** `key_cmd = "pass show anthropic"`. The
dependency inverts: tug learns nothing about secret storage, and every secret
store on earth already knows how to print to stdout.

## Decision

Four sources, first hit wins:

1. `--key` on the command line
2. The preset's environment variable (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …)
3. Config `provider.key`
4. Config `provider.key_cmd`

**The order is by immediacy, not by preference.** A flag is what the user typed
just now; a config file is what they set once, months ago. Documentation
discourages source 3 and recommends 4, and the schema supports 3 anyway: a user
who has decided to put a key in a file will do it with or without tug's blessing,
and forcing them back to a shell profile is not an improvement.

**`key_cmd` runs once and is cached for the process lifetime.** Not per request:
spawning `pass` per turn means a GPG passphrase prompt per turn, and a harness
that interrupts an answer to ask for a passphrase has broken the thing it was
for.

**A failing `key_cmd` surfaces the command's stderr, verbatim and scrubbed.** The
failure is nearly always the user's — a locked keychain, a typo'd entry name —
and the command's own words are the ones that help. Scrubbed because a secret
store's error message is exactly the kind of place a key gets printed by
accident, and `providers.redact` exists for exactly this.

**Trailing whitespace is trimmed.** Every secret store prints a newline. A key
with a newline on the end fails authentication with a message about the key being
wrong, which sends the user looking in precisely the wrong place.

**There is no `TUG_KEY`.** A second spelling for the same secret is a second
place to leak one from, and the preset's own variable is where every provider's
documentation already puts it.

**`/config` never prints the key.** It prints `<set>` or `<unset>` and the layer
that set it. `key_cmd` *is* printed, because it is the instruction for fetching a
secret rather than the secret, and hiding it would make a misconfigured `key_cmd`
undiagnosable. There is a canary test on the `/config` surface.

**The spawner is injected.** `auth.Spawner` is one function pointer, so every
test in this file runs with no subprocess and the real implementation is a thin
wrapper over `std.process.run` behind that seam. This is the same shape as the
transport seam and for the same reason.

## Consequences

Easy: a user with `pass`, `age`, `gopass`, `1password-cli`, `vault`, or a shell
function gets to keep using it. tug needs no code for any of them.

Hard: `key_cmd` is a command tug executes, which is a real capability and a real
trust decision. It is in a config file the user wrote, which is the same trust
level as the shell profile the alternative lives in — but it is worth saying out
loud rather than discovering.

Foreclosed: nothing. A keychain integration could still be added later as a
`key_cmd` default per platform, without changing this chain.

What would make this wrong: a provider moving to short-lived tokens that need
refreshing mid-session, which turns "resolve once" into "resolve repeatedly" and
makes the caching decision wrong rather than merely incomplete. OAuth is that
shape, and it has its own decision box in v0.7.
