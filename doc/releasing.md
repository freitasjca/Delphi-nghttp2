# Releasing Delphi-nghttp2

Every step here exists because skipping it cost something. The reasons are kept
inline — a checklist without them gets shortened by the next person in a hurry.

---

## 1 · Both toolchains, before anything else

```bash
# Linux / WSL
cd Delphi-nghttp2/tests
bash build-codec-fpc.sh 2>&1 | grep -nE "FAIL|Fatal:|Error:" | head
```

```cmd
REM Windows
cd C:\lang\Repo\Delphi-nghttp2\tests
run-tests.bat
```

Note the capital **E** in `Error:` — FPC capitalises it, and a lowercase
`error:` pattern matches only the `Fatal: There were 1 errors` summary line
while hiding the message that says what was actually wrong.

Both must be clean. `run-tests.bat` ends with a plain `ALL STAGES PASSED`
banner; **`build-codec-fpc.sh` has no such banner** — it ends on whatever the
last stage printed, so a mid-run `FAIL` looks like success if you only read the
tail. Hence the grep. And never pipe it through `tail` alone: a pipe discards
the exit status too, so a failing build looks green twice over.

> **1.13.0 shipped without a Windows run.** It passed later, but the risk was
> real: `Boolean` is `tkEnumeration` on Delphi and `tkBool` on FPC, and several
> features sit on that seam. Green on one compiler is not evidence for the
> other.

### If the generator changed

```bash
bash tools/protogen/corpus-check.sh      # parse + emit, ~99.5% of 7301 schemas
bash tools/protogen/compile-check.sh --all   # 0 emitter defects (~2h45m)
```

`--all`, not the default sample: a 10% sample once reported four defect classes
and the full sweep found three more.

**Read the right column.** `3019/3019 must compile` stood here until 1.16.0 and
was wrong in the way that matters: 3019 was every schema the generator *did not
refuse*, so a perfect score excluded 59% of the corpus and got better every
time the generator refused more. The denominator is 7301 — every schema — and
the three numbers to read are COMPILED, DID NOT COMPILE (emitter defects) and
`compiler crashed`, which is FPC falling over rather than our output being
rejected and once overstated the defect count by 3.5x.

**Quote COMPILED and `compiler crashed` with the `--unit-prefix` that produced
them.** The prefix is a term in every mangled symbol, and FPC's crashes move
with it — in both directions. Measured over the full corpus on 2026-09-11:

| | `Corpus.S<N>` (default) | `C<N>` |
|---|---|---|
| COMPILED | **7,230** | 7,192 |
| compiler crashed | **50** | 88 |
| DID NOT COMPILE | 0 | 0 |
| refused | 21 | 21 |

The short prefix was adopted briefly on the strength of re-running only the 50
crashing schemas, where it looked like a 43-schema win. **That sample was
selected on the outcome** — it could not contain a schema that started crashing
— and the full sweep found 81 new failures. Reverted.

So: **DID NOT COMPILE and refused are trustworthy figures; `compiler crashed` is
a joint property of the generator and the harness.** Never tune the prefix
against the crashing subset.

Two debugging tools exist for that bucket, both built 2026-09-11:

```bash
# re-run only named schemas (accepts crashes.txt verbatim) -- ~1 min, not ~2h45m
bash tools/protogen/compile-check.sh --only .compile-out/crashes.txt

# ablate + delta-debug one crashing unit down to a minimal reproducer
bash tools/protogen/crash-reduce.sh .compile-out/g/<N>/<Unit>.pas

# is it name length? sweep the unit name, all else identical
bash tools/protogen/crash-namelen.sh <minimal-crash-*.pas>
```

`--only` preserves each schema's ORIGINAL corpus index, because the index feeds
`--unit-prefix` and renumbering would change name lengths — letting a crash
vanish for the wrong reason.

Skip the sweep only when `git diff --name-only <last-swept-commit>..HEAD --
tools/protogen/` is empty, and say which commit that was.

---

## 2 · Choose the number

- **patch** (1.15.0 → 1.15.1) — a fix with no change to generated output or API.
- **minor** (1.15.0 → 1.16.0) — anything additive: new accepted constructs, new
  units, changed generated identifiers. Generated output changing is a minor
  even when nothing breaks, because downstream sees different code.
- **major** — a removal or a wire-format change. Has not happened yet.

---

## 3 · Bump, commit, push

```bash
sed -i 's/"version": "1.15.0"/"version": "1.16.0"/' boss.json
git commit -am "chore(release): 1.16.0"
git push origin main
```

`boss.json` alone. Boss resolves dependency floors from **git tags**, so the
tag is what actually publishes the release; the version field is documentation.

> **Never use backticks in `git commit -m "..."`.** zsh executes them as
> command substitution and the words vanish silently — this ate `bytes` and
> `none` from a commit message, leaving two nonsense sentences. Use
> `git commit -F-` with a quoted heredoc:
>
> ```bash
> git commit -F- <<'EOF'
> subject line
>
> body with `backticks` that survive
> EOF
> ```

---

## 4 · Tag

```bash
git fetch origin
git tag 1.16.0 origin/main
git push origin 1.16.0
```

Three things, each load-bearing:

- **`git fetch` first.** Tagging `origin/main` without it tags a stale ref.
  Once, a typo (`git fetch origi`) made the fetch fail and the tag still landed
  correctly — only because a push seconds earlier had already advanced the ref.
  Do not conclude the fetch is optional.
- **Tag `origin/main`, not `HEAD`.** They are the same when everything is
  pushed and silently different when it is not.
- **Push the tag explicitly.** `git push origin main` does **not** carry it,
  and neither does `--follow-tags` for a lightweight tag. The push output looks
  identical either way. This has bitten twice.

---

## 5 · Verify at the published artefact

```bash
curl -s https://raw.githubusercontent.com/freitasjca/Delphi-nghttp2/1.16.0/boss.json | grep version
curl -s https://raw.githubusercontent.com/freitasjca/Delphi-nghttp2/1.16.0/src/SomeUnit.pas | grep -c SomeIdentifier
```

Fetch **at the tag**, not at `main`, and grep for **the change's own
identifier** rather than the version string — a version string proves the bump
committed, not that the code shipped. Both times the tag failed to push, this
step is what noticed: the curl returned empty while every other output looked
fine.

---

## 5b · Create the GitHub Release

A git tag is what Boss resolves, so installs work without this — which is
exactly why it gets forgotten. It is also why nobody sees what changed.

```bash
gh release create 1.16.0 --verify-tag --title "1.16.0 — short summary" -F- <<'EOF'
notes here, `backticks` survive a quoted heredoc
EOF
gh release list --limit 5
```

`--verify-tag` fails rather than silently creating a tag, so a typo cannot
invent one. `-F-` with a **quoted** heredoc for the same reason as the commit
message: backticks in a `--notes "..."` argument are executed by the shell.

> Four consecutive releases (1.13.0 through 1.15.0) shipped as tags with no
> Release, while every version back to 1.3.0 had one. Every verification step
> passed — the tag resolved, the artefact carried the change — because each
> checked what it was designed to check. None asked whether that was the whole
> job. `gh release list` is the check that would have.

---

## 6 · The provider floor — usually leave it

`horse-provider-nghttp2` declares `"github.com/freitasjca/Delphi-nghttp2": ">=1.10.0"`.
A floor is a **minimum**, so a new library release is picked up without
touching it. Raise it only when the provider actually calls the new code.
Raising it gratuitously forces downstream upgrades for no benefit.

If both repos release together, **tag the lower repo first** — the provider's
floor must be satisfiable at the moment its own tag appears.

---

## 7 · Release notes

Say what changed and who is affected. Two things worth stating explicitly:

- **Whether generated output moves.** "Generated enum values change only where
  they previously produced code that did not compile" tells a user their
  working build is safe. Without it they must diff to find out.
- **Which layer a number describes.** "99.5% of schemas" meant *parsing* for a
  month while being quoted as evidence the *generator* worked. Say
  "parses and emits" or "generates code that compiles" — never just "accepts".

---

## Quick reference

```bash
# 1  gates, both toolchains
bash tests/build-codec-fpc.sh 2>&1 | grep -nE "FAIL|Fatal:|Error:" | head
run-tests.bat                                    # on Windows

# 2  generator only
bash tools/protogen/corpus-check.sh
bash tools/protogen/compile-check.sh --all

# 3  bump + push
sed -i 's/"version": "X"/"version": "Y"/' boss.json
git commit -am "chore(release): Y" && git push origin main

# 4  tag
git fetch origin && git tag Y origin/main && git push origin Y

# 5  verify AT THE TAG, by the change's own identifier
curl -s https://raw.githubusercontent.com/freitasjca/Delphi-nghttp2/Y/boss.json | grep version

# 6  the GitHub Release — a tag alone leaves the Releases page silent
gh release create Y --verify-tag --title "Y — summary" -F- <<'EOF'
notes
EOF
gh release list --limit 5
```
