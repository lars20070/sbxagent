---
name: readme
description: Write, restructure, review or improve README.md files. Use whenever the user mentions a README, asks how to document a project, asks for a project description or "front page", is open-sourcing a repository or preparing a package for release, or wants a repo made approachable to new users and contributors — and also whenever you are about to create or substantially edit a README as part of some other task, even if the user never used the word "README".
---

A README is an evaluation document, not a manual. The reader's task in the
first thirty seconds is to work out whether to *disqualify* the project.
Structure for fast, honest disqualification, not for persuasion.

The failure mode of a generated README is not bad prose. It is fluent,
well-formatted and unverified. Weight verification at least as heavily as
composition.

## Grounding rules

These are constraints, not suggestions.

1. **Read before writing.** The manifest, the license file, the CI config, the
   tests, existing docs, and the current README if there is one. A README
   written without reading the repository is the defining artefact of the slop
   problem.
2. **Every claim traces to an artefact.** If you cannot point at the file that
   establishes a claim, the claim does not go in.
3. **Flag, do not fabricate.** Where a human must supply something the repo
   cannot provide — support channel, roadmap, maintainer contact, the
   motivation behind a design decision — leave a visible `<!-- TODO: … -->`
   marker and say so in your response. Silent invention is the failure;
   visible gaps are not.
4. **Preserve the author's voice.** When improving an existing README, make
   the smallest change that fixes the identified defect. Many good READMEs are
   idiosyncratic — humour, opinion, a personal register. Normalising them into
   template voice is a regression even when the structure improves.

## Workflow

1. **Classify the repository type.** Read `references/repo-types.md` and use
   only the section that applies. Applying library structure to a non-library
   project is the single biggest weakness of template-driven READMEs.
2. **Extract the facts.** Work through the facts table in
   `references/verification.md` before drafting a line. Almost everything a
   README asserts is derivable from manifests, workflow files and tests.
3. **Decide the mode.** Creating from scratch, or improving what is there? If
   improving, diagnose specific defects and make targeted edits. Do not
   rewrite a working README to impose a preferred shape.
4. **Draft the first screen first**, and iterate the one-line description
   explicitly. It is the highest-leverage sentence in the repository and the
   one most worth spending tokens on.
5. **Select sections by applicability**, not by template completeness. Prefer
   omitting a section to stubbing it. An empty heading is worse than no
   heading — it signals abandonment.
6. **Ground the examples.** Pull usage snippets from `examples/`, tests or
   doctests, ideally code that CI executes. Do not invent them.
7. **Verify** against the checklist in `references/verification.md`.
8. **Report** what you verified, what you assumed, and what the human must
   fill in.

Derive what you can. Ask at most **one** consolidated question — usually about
motivation, target audience or support channel — and `TODO`-flag the rest.
Interrupting the user twice costs more than it is worth.

## The first screen

Everything above roughly 25 rendered lines. It must answer: what is this, is
it for me, is it alive, can I use it legally.

1. **Title** — `# project-name`, matching the repository and published package
   name exactly. Explain any mismatch.
2. **One-line description** — under 120 characters, no heading, plain
   sentence. Name the *category* of thing it is ("a CLI for…", "a Rust library
   that…") and its distinguishing property. Use the same string in the README,
   the manifest `description` field and the repository description.
3. **Badges** — three to five, one line, each answering a question a user
   actually has at decision time. Never stack rows.
4. **Two to four sentences of context** — the *why*. What problem, for whom,
   and what the alternatives are. This is the most commonly missing element in
   real READMEs. Write it even when it feels obvious to you.
5. **Status, when the project is not stable** — alpha, beta, experimental,
   maintenance-only, archived — plus supported runtime versions. The second
   most commonly missing element, and the honest thing to do.
6. **Quick start** — the install command and a minimal working example that
   produces visible output, as one continuous block.

Test: a competent developer in the target ecosystem, reading only this, can
correctly decide to keep reading or leave, and would not feel misled either
way.

## Body and tail

Order by decreasing generality. Include only what applies.

1. Table of contents, if the file exceeds about 100 lines.
2. Features — short list, each item verifiable in the code. Cut anything
   aspirational.
3. Installation, expanded — prerequisites with version ranges, platform notes,
   alternative channels, and a verification step.
4. Usage — progressively fuller examples, each runnable as written, each
   showing expected output.
5. Configuration — options, environment variables, config schema.
6. API reference, or a link to one. Never paste generated API docs in.
7. How it works — a paragraph or a Mermaid diagram, for anything non-obvious.
8. Limitations and caveats. Rare, high-trust, cheap to write.
9. Comparison with alternatives — say honestly when to prefer them.
10. Roadmap or project status, if there is one.
11. Contributing — where to ask questions, whether pull requests are accepted,
    what is required. Only if contributions are genuinely accepted.
12. Support — the issue tracker, discussions or chat, with honest response
    expectations ("side project, replies may be slow").
13. Maintainers — who to ping, one contact route each.
14. Acknowledgements.
15. License — SPDX identifier, holder, link to the file. Last section.

## Settled questions

- **Install before usage, or after?** Neither. Use one combined quick start
  showing install and first successful use as a continuous block.
- **License placement.** Permissive (MIT, Apache-2.0, BSD, ISC) goes last plus
  a badge. Copyleft, source-available or commercial goes in the first screen —
  an incompatible license is the fastest possible disqualifier.
- **Length.** Not a word count. The README owns evaluation, first success, and
  where to go next. A section serving none of those three moves to `docs/` and
  gets a link. Most single-purpose libraries need 60–150 rendered lines, not
  400.

## What not to produce

These read as unreviewed generated output and cost the maintainer trust:

- An emoji on every `##` heading.
- The exact sequence Features → Installation → Usage → Contributing → License
  in neutral marketing voice, with no section that required reading the code.
- Badge rows that convey nothing a user needs.
- Feature tables generated from the directory listing, describing files rather
  than capabilities.
- "Blazingly fast", "production-ready", "enterprise-grade", "seamlessly" —
  where no benchmark, no deployment and no enterprise exist.
- A Contributing section on a repo with no `CONTRIBUTING.md`, no issue
  templates and no history of accepted pull requests.
- Sections of uniform length regardless of whether there is anything to say.
- Confident specifics that were never checked: version numbers, function
  signatures, config keys, CLI flags.
- Critical information carried only by a screenshot or GIF.

The goal is not output that *looks* good. It is output a maintainer would not
have to check.

## Scope

`README.md` is for humans evaluating or onboarding. Build incantations, test
invocations and lint rules belong in `AGENTS.md`; contribution detail belongs
in `CONTRIBUTING.md`. If that material starts accumulating in the README, say
so and suggest the move.
