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

**Append one line, and rewrite only when the cap bites.** Chosen first, and then
reversed — see below.

**Rewrite the file on every submission.** Chosen, in the end.

The first version appended: there is no append mode and no seek in this standard
library, so it was `file.length` followed by `writePositionalAll` at that
offset. It worked on Linux and failed on Windows, where the positional write
goes through `NtWriteFile` with an explicit byte offset and did not survive
contact with a handle opened the way `createFile` opens one.

Rather than special-case a platform, the append went away. The argument against
rewriting was O(n) per submission, and the n is worth saying out loud: the cap
is 1,000 entries of a line each, so a rewrite is tens of kilobytes, and it
happens once per **submission** rather than once per keystroke. A person cannot
submit fast enough for that to cost anything measurable. The append was buying
an optimization against a bound that is already small.

What it costs is atomicity, which the append did not have either: a crash
between the truncate and the write loses the file rather than one entry.
Write-to-temp-and-rename is the upgrade, and it is worth taking the moment
anything else in tug needs one.

Two tugs writing at once still clash, and now the loser overwrites rather than
interleaves. A file lock remains the fix, and remains not worth writing until
someone notices.

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
line. A session with no writable state directory behaves normally. Nothing is
read until `up` is pressed. One write path rather than two, on every platform.

**Hard:** a submission rewrites the file, so the write is not atomic and a
concurrent session overwrites rather than interleaves. And the escape format is
now a compatibility surface. v0.4's sessions
(`tugsession`, JSONL) are a different store for a different thing, and must not
quietly replace this one without a migration.

**Revisit at v0.4**, when sessions arrive and the question of whether a prompt
history is a degenerate session becomes real.
