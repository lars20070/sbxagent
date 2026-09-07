# Trim `skill-creator` down to a format guide

## Context

`.claude/skills/skill-creator/` is Anthropic's official skill, vendored whole. It
is 324K across 24 files, and most of it is machinery this repo will never use: an
eval harness, a grading pipeline, a benchmark aggregator, an HTML review viewer,
and three specialised sub-agent definitions.

What is actually wanted is much smaller: **a skill that teaches a coding agent to
write a new skill in the correct format.** Frontmatter, directory layout,
progressive disclosure, writing style. Nothing else.

The two halves are cleanly separated, so this is a delete job rather than a
rewrite. `SKILL.md` lines 1–160 are the format guide; lines 161–485 are the eval
loop. Keeping Anthropic's own wording for the part we retain is the whole point
of trimming rather than rewriting from scratch.

Outcome: `skill-creator` becomes 3 files — `SKILL.md` (~110–130 lines),
`LICENSE.txt`, and one validator script.

## Two facts that shape the plan

1. **`make lint` does not touch skills.** `Makefile:21` defines
   `NO_SKILLS := ':(exclude,glob)**/skills/**'` and both the markdownlint
   (`Makefile:38`) and cspell (`Makefile:45`) targets apply it. So no lint or
   spelling constraint applies to the trimmed file, and no new words need adding
   to `.cspell.json`.
2. **Everything is tracked in git.** `git ls-files .claude` lists all 18 files
   under `skill-creator/`, so every deletion is recoverable with
   `git checkout -- .claude/skills/skill-creator/`.

## Target shape

```text
.claude/skills/skill-creator/
├── SKILL.md            (~110–130 lines, down from 485)
├── LICENSE.txt         (unchanged — keep the attribution)
└── scripts/
    └── quick_validate.py   (106 lines, unchanged)
```

## Step 1 — Delete the benchmark machinery

Remove these tracked paths with `git rm -r`:

- `agents/` — `analyzer.md`, `comparator.md`, `grader.md`. All three exist only
  to be spawned as sub-agents during a grading run.
- `eval-viewer/` — `generate_review.py`, `viewer.html`. The HTML review UI.
- `assets/` — `eval_review.html`. Same UI, template copy.
- `references/schemas.md` — delete the whole file, and the now-empty
  `references/` directory. Every one of its 9 sections is an eval artefact:
  `evals.json`, `history.json`, `grading.json`, `metrics.json`, `timing.json`,
  `benchmark.json`, `comparison.json`, `analysis.json`. Nothing in it describes
  the SKILL.md format.
- `scripts/` — all except `quick_validate.py`. That is `__init__.py`,
  `aggregate_benchmark.py`, `generate_report.py`, `improve_description.py`,
  `package_skill.py`, `run_eval.py`, `run_loop.py`, `utils.py` — 1799 of the
  1905 script lines.

Also delete the untracked cruft (plain `rm`, these are not in git):
`.DS_Store`, `scripts/.DS_Store`, `eval-viewer/.DS_Store`, `scripts/__pycache__/`.

Confirm the emptied directories are gone too (`agents/`, `eval-viewer/`, `assets/`,
`references/`) — `find -type f` alone will not catch empty leftovers.

**Why `package_skill.py` goes:** it bundles a skill into a distributable
`.skill` file. Skills in this repo live in-tree under `.claude/skills/` and are
never packaged or shipped.

**Why `quick_validate.py` stays:** it is the one script on-mission. Self-contained
(no local imports; only needs PyYAML, which is preinstalled per the root
`CLAUDE.md`), and it encodes the real format rules — allowed frontmatter keys
(`name`, `description`, `license`, `allowed-tools`, `metadata`, `compatibility`),
kebab-case name, 64-char name cap, 1024-char description cap, no angle brackets
in the description.

## Step 2 — Rewrite `SKILL.md`

Cut from 485 lines to roughly 110–130 (kept body ≈ lines 45–139 minus cuts,
plus a short intro and validation section — not a hard budget).

**Frontmatter.** Rewrite `description:`. The current one advertises the removed
capabilities — "measure skill performance", "run evals to test a skill",
"benchmark skill performance with variance analysis", "optimize a skill's
description for better triggering accuracy". Use this replacement (deliberately
"pushy" about triggering, which is the advice the skill itself gives at line 68
and which the repo's own `.claude/skills/readme/SKILL.md` follows):

```yaml
description: Create new skills or edit existing ones under .claude/skills/. Use whenever the user wants to author a skill, capture a workflow as a skill, rewrite a SKILL.md, or asks about skill format, frontmatter, progressive disclosure, or skill structure — even if they do not say "skill-creator".
```

**Keep, lightly edited** (current line numbers):

| Section | Lines | Edit |
| --- | --- | --- |
| `## Creating a skill` → `### Capture Intent` | 45–54 | Drop question 4, which is entirely about whether to set up test cases |
| `### Interview and Research` | 56–60 | Drop the sub-agent/parallel-research sentence **and** the residual "Wait to write test prompts until you've got this part ironed out." (test prompts leave with Test Cases) |
| `### Write the SKILL.md` | 62–69 | Keep as-is |
| `#### Anatomy of a Skill` | 73–86 | Keep as-is |
| `#### Progressive Disclosure` | 88–110 | Keep as-is |
| `#### Principle of Lack of Surprise` | 112–114 | Keep as-is |
| `#### Writing Patterns` | 116–135 | Keep as-is |
| `### Writing Style` | 137–139 | Keep as-is |

**Rewrite the intro** (lines 6–30). Every word of it describes the
draft → test → benchmark → iterate loop. Replace with a few lines framing the
skill as: understand the intent, write the SKILL.md under
`.claude/skills/<name>/`, validate the format.

**Cut entirely:**

- `## Communicating with the user` (32–43) — guidance on explaining "JSON" and
  "assertion" to non-technical users. This repo is a shell-based CLI toolchain;
  the audience is a developer. Off-mission here.
- `### Test Cases` (141–161) — evals.json, test prompts, assertion drafting.
- `## Running and evaluating test cases` (163–290) — the whole 5-step eval
  sequence, sub-agent spawning, baseline runs, grading, the viewer.
- `## Improving the skill` (292–323) and `## Advanced: Blind comparison` (325–331).
- `## Description Optimization` (333–406) — depends on the deleted `run_loop.py`.
- `### Package and Present` (408–418) — depends on the deleted `package_skill.py`.
- `## Claude.ai-specific instructions` (420–443) and `## Cowork-Specific
  Instructions` (445–457) — platform notes for environments this repo is not
  used in, and both are mostly about how to adapt the eval loop.
- `## Reference files` (459–485) — indexes `agents/` and `references/`, both gone.
  The closing "core loop" recap and the Cowork TodoList plea go with it.

**Add one short section** replacing the deleted `## Reference files`: a
validation step pointing at the surviving script.

```bash
python3 .claude/skills/skill-creator/scripts/quick_validate.py <path/to/new-skill>
```

Note in the surrounding prose what it actually checks, so the agent knows the
constraints even without running it.

## Step 3 — Update `AGENTS.md`

`AGENTS.md:153-155` currently describes the skill as:

> `skill-creator` — create a new skill under `.claude/skills/`, or iterate on
> an existing one, with drafting, test evals, and a review loop with the user.

"test evals, and a review loop with the user" describes the machinery being
deleted. Reword to match the trimmed skill. This is the only place outside the
skill directory that mentions it — confirmed by grepping the repo for
`skill-creator` across `*.md`, `*.json`, `*.yaml`, `Makefile` and `*.sh`.

## Step 4 — Changelog

No entry. `AGENTS.md` says to skip changelog entries for "tests, formatting,
internal refactors, and documentation changes that do not affect users".
`.claude/skills/` is development tooling for agents working *on* this repo, not
shipped in any kit, so nothing user-facing changes.

## Verification

1. **Nothing dangles.** No reference to a deleted path survives:

   ```bash
   cd /Users/lars/Code/sbxagent
   rg -n "eval-viewer|generate_review|package_skill|run_loop|run_eval|aggregate_benchmark|improve_description|generate_report|schemas\.md|agents/grader|agents/comparator|agents/analyzer" .claude/skills/skill-creator/ AGENTS.md
   ```

   Expect no output.

2. **The kept script runs, and the trimmed skill passes its own validator:**

   ```bash
   python3 .claude/skills/skill-creator/scripts/quick_validate.py .claude/skills/skill-creator
   ```

   Expect `Skill is valid!`. Also run it against `.claude/skills/readme` and
   `.claude/skills/context7-docs` — both should pass, confirming the script
   works on skills it did not ship with.

3. **Repo checks still pass.** `make lint` excludes skills, so it should be
   unaffected — run it anyway to prove the trim changed nothing else:

   ```bash
   make lint
   ```

4. **Final shape is 3 files, no empty leftover dirs:**

   ```bash
   find .claude/skills/skill-creator -type f | sort
   find .claude/skills/skill-creator -type d | sort
   wc -l .claude/skills/skill-creator/SKILL.md
   ```

   Expect only `SKILL.md`, `LICENSE.txt`, `scripts/quick_validate.py`; directories
   only `skill-creator/` and `scripts/`; line count roughly 110–130.

5. **Read the result.** I will show you the trimmed `SKILL.md` in full before
   anything is committed.

## Rollback

Everything deleted is tracked, so one command restores it all:

```bash
git checkout -- .claude/skills/skill-creator/
```
