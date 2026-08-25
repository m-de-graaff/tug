# DR-007: Theme slot schema

**Status:** accepted
**Date:** 2026-08-25
**Phase:** 9

## Context

Phase 4 built a renderer whose whole notion of style is three attribute bits —
bold, dim, italic — and left a comment in `markdown.zig` saying so on purpose:
"There is no colour anywhere in Phase 4: colour is a theme slot, themes are
Phase 9, and a renderer that hardcodes colours now is a renderer Phase 9 has to
unpick." Phase 7 parsed a `theme` key, carried it with its provenance, and gave
it to nobody. This is the phase that has to make both of those true at once.

The pressure is that tug renders into **normal scrollback on somebody else's
terminal**. It does not own the background, cannot read it, and cannot repaint
what it has already printed. Every question below follows from that:

- What is the unit a theme colours — a block, a line, a token?
- What does a theme say about text tug has no opinion about?
- What happens on a terminal with 256 colours, and on one with none?
- How does a colour scheme avoid being the thing that makes an interface
  unreadable for the people it is supposed to help?
- Where do a theme file's warnings live, given `DR-013` named "a third warning
  list" as the trigger to build a shared diagnostic type?

## Options

**What the renderer names.**

*Raw colours in the renderer, themes as a lookup table of overrides.* Smallest
diff — `baseStyle` returns an `Rgb` and a theme replaces some of them. It is
also the thing Phase 4's comment refuses by name, and for a reason that survives
inspection: a renderer that knows `#dcdcaa` cannot be asked what a notice looks
like at 256 colours, or with no colour, without knowing about tiers too.

*Semantic slots.* The renderer names `notice`; a theme says what `notice` looks
like; `styleBytes` resolves the pair at the moment it writes. The spec asks for
this and it is what shipped.

**What a slot's colour can be.**

*Always an RGB triple.* One rule, no optionality, and every paragraph of the
model's prose then costs 19 bytes of escape per row and is painted a grey the
theme author picked rather than the one the user picked for their terminal.

*RGB, or the literal `default`.* `default` means the terminal's own foreground
and renders as no bytes. It costs a tagged union and one branch.

**Where the ninth slot goes.** The spec lists nine slots and one of them —
`code_bg` — is a background. Nine values need four bits; `md.Style` is one byte
and carries two attribute bits, and every style comparison in the wrapper is a
`@bitCast(u8)`.

*Nine-value enum, `Style` grows to two bytes.* Uniform, and it doubles the
comparison in the hottest loop in the renderer for one value that is not a
foreground anyway.

*Eight-value foreground enum plus a `code_bg: bool`.* Eight values fit `u3`
exactly; `Style` stays one byte with two bits spare.

**The colourless tier.** The spec calls `NO_COLOR` "a first-class tier with its
own golden, not an afterthought", which rules out "emit nothing and hope". The
question is what replaces the colour.

*Nothing.* A notice, a user's echoed words and a code block all render as plain
prose. This is the WCAG 2.2 failure "meaning carried by colour alone", arrived
at by subtraction rather than on purpose.

*A per-slot fallback attribute.* Each slot names what it degrades to. Costs an
eight-arm switch.

## Decision

**Semantic slots, `default` as a colour, eight foreground slots plus a
background flag, and a per-slot monochrome fallback.**

```zig
pub const Slot = enum(u3) {
    fg, dim, accent, user_block, assistant_block, notice, @"error", prompt,
};
pub const Color = union(enum) { default, rgb: Rgb };
pub const Style = packed struct(u8) {
    bold: bool, italic: bool, code_bg: bool, slot: Slot, _padding: u2,
};
```

**`default` is the load-bearing idea, and it is worth stating plainly: it is not
black and not "unset", it is the terminal's own foreground, and it renders as no
bytes at all.** Three separate things in this phase turn out to be that one
mechanism seen from different sides:

1. a theme deliberately leaving a slot to the terminal — both built-ins do this
   for `fg` and `assistant_block`, so tug never repaints the colour a user chose
   for their prose;
2. `Theme.fallback`, every slot `default`, which is what a `Renderer` holds
   before any config has been read and therefore what the first paint uses;
3. the whole `none` colour tier.

One branch in `styleBytes` serves all three. None of them is a special case, and
that is why the twenty-one goldens written before this phase are byte-identical
after it rather than twenty-one files somebody had to regenerate and squint at.

**The monochrome fallback table is the accessibility rule with a type.**

| Slot | Fallback | Why |
|---|---|---|
| `dim`, `notice` | SGR 2 | These *are* the dim ones; the attribute is what Phase 4 used |
| `user_block` | SGR 1 | The user's echoed words were bold before colour existed |
| `code_bg` (flag) | SGR 2 | A code block that is neither shaded nor dimmed is prose |
| `fg`, `assistant_block`, `accent`, `prompt`, `error` | none | Decoration: an accent on a heading that is already bold, a prompt already behind a `>` |

That table is what makes "no meaning carried by colour alone" mechanical rather
than aspirational, and it is checked two ways: the existing goldens are all
rendered at `.color = .none` and must not move, and `theme-dark-none.txt` must
be byte-identical to `theme-light-none.txt` — at the `none` tier a theme has
nothing left to say, because every distinction in the scene is drawn by an
attribute.

**Contrast is a test.** Every non-`default` slot in both built-ins clears
WCAG 2.2 AA's 4.5:1 against a reference background *and* against `code_bg`, both
as written and after 256-colour quantization. The quantized check is the one
that matters and the one that is easy to skip: the colour an `ansi256` terminal
actually paints is not the colour in the file.

```
dark   (ref #1e1e1e, code_bg #2d2d2d)      truecolor      ansi256
  dim              #9a9a9a   -> 247          5.92 / 4.89   6.36 / 4.93
  accent           #4ec9b0   ->  79          8.18 / 6.76   9.60 / 7.43
  user_block       #9cdcfe   -> 153         11.18 / 9.24  11.35 / 8.79
  notice           #dcdcaa   -> 187         11.80 / 9.75  11.55 / 8.94
  error            #f48771   -> 209          6.79 / 5.61   7.21 / 5.58
  prompt           #4ec9b0   ->  79          8.18 / 6.76   9.60 / 7.43

light  (ref #f5f5f5, code_bg #e6e6e6)      truecolor      ansi256
  dim              #595959   -> 240          6.42 / 5.61   6.13 / 5.60
  accent           #0d6560   ->  23          6.32 / 5.52   6.46 / 5.89
  user_block       #1d4ed8   ->  26          6.15 / 5.37   5.00 / 4.56
  notice           #854d0e   ->  94          6.28 / 5.49   4.94 / 4.50
  error            #b91c1c   -> 124          5.93 / 5.18   6.41 / 5.85
  prompt           #0d6560   ->  23          6.32 / 5.52   6.46 / 5.89
```

The tightest pair in the set is light `notice` on `code_bg` at `ansi256`:
**4.50:1**, which passes with nothing to spare. Anyone editing that colour finds
out from `registry.zig` rather than from a user.

**The reference background lives in the test, not in the theme file.** tug does
not paint a background, so a `background = "#1e1e1e"` key would be a key nothing
reads except the test that checks it — a key that lies about what it does. The
test knows dark's reference and light's, and the theme file is only colours.

**Why two built-ins when both leave prose to the terminal.** With `fg` and
`assistant_block` at `default`, dark and light are identical for the model's
answer. They diverge on the six slots that must be legible against a background
of known lightness, and on `code_bg` — the one background tug does paint, and
therefore the one place it has to know which way round the screen is. That is
the whole justification, and it is also why a third built-in would need a reason
better than "another palette".

**Quantization** considers the 6×6×6 cube and the 24-step grey ramp and takes
the nearer by squared RGB distance, ties to the cube. Considering only the cube
would band every near-grey onto six coarse levels, which is exactly the range a
terminal theme is made of; the perceptual non-uniformity of RGB distance does
not matter here because the contrast gate is what guarantees legibility and this
only has to pick the closest of 256 stops.

**`DR-013`'s trigger was checked and did not fire.** That record named a third
warning list as the point at which a shared `Diagnostic` type would pay for
itself. A theme file turns out not to need a third *shape*: its problems are a
scanner refusal, an unknown key, a wrong type and a duplicate — every one
already a `config.Note.Kind` — plus `bad_color`, which is genuinely new and fits
the existing shape unchanged. Two kinds joined the enum; nothing else moved.

What a theme does **not** have is a layer. It is one file, not a stack, so
`Result.writeNotes` takes a single origin and passes it to `Note.write`, which
has always taken an origin as a parameter. Six lines.

So: **the trigger for a shared `Diagnostic` is now a warning list that needs a
field `Note` does not have**, not merely a third list. `keymap.Problem` is the
existing example — it names two actions and two layers where `Note` has one of
each. A second type in that position would be the signal.

**`/theme` the command is Phase 10's; its mechanism is here.** `Renderer.setTheme`
works and is golden-tested; the command registry does not exist until Phase 10,
and building one here would be building Phase 10. This is the precedent Phase 8
set and wrote down for `/keys`. The user-facing switch that does land is
`--theme <name>`, which the phase TODO already assigned to this phase.

## Consequences

**Easy now.** Adding a slot is an enum value, a fallback-table row, and a line in
each built-in. Adding a theme is a `.toml` file in a directory. A tier that is
not truecolor or 256 would be one arm of `encode`. `/theme` in Phase 10 is three
lines that call `setTheme`.

**Two things this makes visibly imperfect, both deliberate.**

*`code_bg` does not extend to the row edge.* A shaded code line is as wide as its
text, so the right edge is ragged. Padding to `cols` is where the row arithmetic
breaks — a row written to exactly the terminal's width may auto-wrap, and a
wrapped row that was counted as one is the class of bug the whole renderer is
built to avoid. The upgrade path is the same prerequisite tab expansion has:
padding becomes safe once the renderer tracks absolute columns through a soft
wrap.

*Committed scrollback keeps its old colours across a theme switch.* tug does not
move the cursor back over scrollback, so it cannot recolour it, so it does not
pretend to. `theme-switch.txt` shows this as bytes. This is the append-only
principle the renderer is built on, and it is documented behaviour rather than a
limitation with an apology attached.

**`error` ships with no consumer.** `BlockKind` is `user | assistant | notice`;
there is no error block in v0.1, and the mock provider's mid-stream error
surfaces as a notice. The slot ships because the schema is the contract a theme
author writes against, and inventing an error block to justify it would be
building v0.2's error taxonomy a version early. It is on the `--debug-config`
table so it is discoverable, which is the treatment Phase 8 gave `quit`.

**A user theme's contrast is not checked.** The gate covers the built-ins, where
a reference background is a design decision somebody made. A user theme with
2:1 text loads silently, because warning about it would require a reference
background tug does not have. The honest fix is a `tug doctor` check in v0.8,
which can ask the terminal what its background is.

**No suggestion on an unknown slot or an unknown theme.** `core.nearest` exists
and would turn `acent` into "did you mean 'accent'?", but `config.Note` has no
suggestion field and adding one is a change to Phase 7's type. It is about eight
lines — a `suggestion: []const u8 = ""` and one `if` in `Note.write` — and it
would improve config warnings and theme warnings together. Worth doing when
somebody is annoyed by it; not worth doing speculatively in the phase that
noticed it.

**What would make this decision wrong.** A slot list that outgrows eight
foregrounds. Syntax highlighting (v0.7, budget-gated) is the candidate: it wants
per-token colours and would not fit `u3`. If that lands in core rather than as a
plugin, `Style` grows past a byte and the packing argument above has to be made
again with the new numbers — at which point per-token styling probably wants its
own representation rather than a wider `Style`.
