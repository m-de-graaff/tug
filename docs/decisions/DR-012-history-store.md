# DR-012: Where the prompt history lives, and what shape it is in

**Status:** accepted
**Date:** 2026-08-24
**Phase:** 6

## Context

The prompt history has to survive a restart, hold entries containing newlines
(the editor makes multiline drafts trivially easy), be cheap to append to on
every submission, and be readable by a human with `cat`. It also must not cost
anything before the first time someone presses `up` — the cold-start budget is
10 ms and a file read nobody asked for is the easiest way to lose it.

None of that is hard. All of it is easy to get subtly wrong in a way nobody
notices until a v0.4 migration has to read files written by v0.1.

## Options for the location

**`~/.config/tug/`.** Rejected: history is state, not configuration. Mixing them
means a dotfile repo either syncs your typing history or has to exclude one file
from the middle of a directory it otherwise owns.

**`~/.local/share/`.** Rejected: `share` is for data a user would miss. Losing a
shell history is an inconvenience, not a loss.

**`~/.local/state/`, honouring `XDG_STATE_HOME`.** Chosen. This is exactly what
the XDG base directory spec means by state: data that persists between restarts
but is not important enough to back up.

Windows has no XDG and reading `HOME` there is a POSIX habit rather than a
Windows convention, so it gets `%LOCALAPPDATA%\tug\history`. The platform is a
parameter to `resolvePath` rather than a `builtin` check, so both branches are
tested on both platforms rather than only on the one running the tests.

A session where nothing in the environment names a directory gets no persistent
history and works normally. That is a supported configuration, not an error.

## Options for the format

**JSON lines.** Rejected: a parser and a dependency argument for a file with one
field per record.

**A length-prefixed binary format.** Rejected: not readable with `cat`, and a
corrupted length is unrecoverable where a corrupted line costs one entry.

**One entry per line, with `\` and newline escaped as `\\` and `\n`.** Chosen.
The invariant the whole file rests on is that *one entry is one line*, which is
what makes the reader a `splitScalar` rather than a state machine. An escape
sequence nothing wrote keeps both of its bytes rather than being dropped — a
history file is not a trust boundary, but it is not a place to lose a character
either.

## Options for the write

**Rewrite the file on every submission.** Rejected: O(n) per submission, for a
file that only ever grows at the end.

**Append one line, and rewrite only when the cap bites.** Chosen. The cap is
1,000 entries and it truncates from the front, which is the only truncation that
keeps what a person is likely to want; that case needs a rewrite anyway, so the
append rides along inside it.

There is no append mode and no seek in this standard library, so an append is
`file.length` followed by `writePositionalAll` at that offset. Two tugs writing
at once can therefore interleave, and the loser of that race loses one entry. A
file lock is the fix, and it is not worth writing until someone notices.

## Decision on failure

Every filesystem error is swallowed into a `write_failed` flag. A missing file
is an empty history. An unreadable one is an empty history. A directory that
cannot be created costs the session its persistence and nothing else.

A history file is not on the path between a user and a working shell, and a
shell that refused to start because `$HOME` was read-only would be much the
worse bug. Nothing reads `write_failed` yet; Phase 10's `/config` is its
intended consumer, and until then it exists so the failure is recorded rather
than invisible.

## Consequences

**Easy:** `cat ~/.local/state/tug/history` works and shows one submission per
line. Appends are O(1). A session with no writable state directory behaves
normally. Nothing is read until `up` is pressed.

**Hard:** the escape format is now a compatibility surface. v0.4's sessions
(`tugsession`, JSONL) are a different store for a different thing, and must not
quietly replace this one without a migration.

**Revisit at v0.4**, when sessions arrive and the question of whether a prompt
history is a degenerate session becomes real.
