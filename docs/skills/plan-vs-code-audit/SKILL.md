---
name: plan-vs-code-audit
description: Use when asked whether a migration or plan is complete.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [audit, migration, plan, verification, handoff]
    related_skills: [gstreamer-pipeline-diagnostics, systematic-debugging]
---

# Auditing a plan's claims against the code

## When to Use

Triggers: "is the migration/port/refactor 100% done?", "what is still left?", "check the
codebase as a whole", a status document or completion plan claims PASS/complete and you must
decide whether to rely on it, or the work is about to be signed off or handed to another
machine.

## Always-on rules

- **A plan, a status document, and its "Last verified at commit X" stamp are CLAIMS, not
  evidence.** Verify each gate by running the command it names or reading the code it points
  at, and report it as verified / stale / unverifiable. Plan checkboxes prove nothing either
  way: they are usually a template nobody ticks, so an all-unchecked plan can describe work that
  is finished, while a status table can carry PASS rows from a commit that is no longer HEAD.
- **Audit the classes a plan cannot enumerate by construction.** A plan lists the work someone
  imagined; the gaps live in what nobody thought to list:
  - legacy or forbidden paths of the thing being replaced — run the repo's own guard, then grep
    every reference to the old artifact and classify each hit (build/config/runtime = real,
    docs/logs = historical);
  - artifacts still built but used by nothing — workspace members, Makefile targets, dependencies
    with no dependents; a thing should be built only if it ships or is exercised by tests. Fix by
    *moving*, not deleting: relocate it out of the built set (e.g. under `tools/` with its own
    standalone workspace marker so it still builds on demand), then prove with the build
    system's own metadata that only shipping crates remain and that the moved artifact still
    builds where it now lives;
  - test distribution per module — count tests per module and compare against where behaviour
    actually changes; the module with one test that every branch change touches is the finding;
  - cross-boundary contracts (next rule);
  - stale or duplicate top-level documents that contradict the current state;
  - generated artifacts committed to the repository.
- **Cross-check every contract in BOTH directions**, because the two ends are often written in
  shapes that do not resemble each other: extract the message/command/path strings one side
  emits and the dispatch table or route list the other declares, normalize both, and diff.
  Two traps, both of which produce a confident false finding: grepping for one spelling of a
  name (`join-secondary` is not `join` — read the dispatch table, never a single literal), and
  comparing absolute call sites against routes declared inside a prefix (`scope "/api"`), which
  makes a naive diff report EVERYTHING as missing. A mass-negative result means the extractor is
  wrong, not that the layer is absent — fix the normalization and re-run before reporting
  anything. `scripts/boundary_crosscheck.py` does this normalization and diff.
- **Separate FUNCTION from SAFEGUARD when reporting.** "No missing features" and "nothing
  protects this from regressing" are different verdicts with different risks: a codebase can be
  100% functional and fragile at the same time. Name which gaps are functional (usually none in
  a finished migration) and which are tests, hygiene, docs, or decisions.
- **Record the suspicions that turned out FALSE**, with the check that cleared them. An audit
  that only lists problems gets re-investigated; "checked X, no gap" is a result the next session
  can trust and skip.
- **Land the findings where work is planned**, not only in the reply: append a task to the plan
  with each item, its action and an acceptance criterion, so the audit changes what happens next.
  Leave the plan's own history intact — never restamp a verification document (counts, "last
  verified", a PASS row) without a full passing run behind it.
- **Distinguish a DECISION from a defect.** An immutable, manifest-verified oracle with a broken
  reader, or a gate that is meaningless for a metric, needs the user to choose between documenting
  the limitation and versioning the artifact. Present the choice and the trade-off, and leave the
  recorded evidence unchanged.

## Procedure

1. Read the plan and the status document; capture their stamps (commit, date, counts) so you can
   say which rows are stale.
2. Run the repo's own guards first — they encode the intended boundary, and their output is
   evidence you can quote verbatim.
3. Enumerate the legacy surface mechanically: every reference to the replaced artifact, each
   classified as a real path or as historical text.
4. Cross-check the boundaries: control plane to engine, UI to API, config producer to consumer.
5. Inventory what is built but unused, then count tests per module.
6. Scan the documentation tree for claims that contradict the current state, including files at
   the repository root that no other file references.
7. Classify each finding: functional / safeguard (tests) / hygiene (unused artifacts, generated
   files) / documentation / decision-needed.
8. Append them to the plan as a task with acceptance criteria and commit it together with the
   audit, including the suspicions that were cleared.
9. Report tallies, not adjectives: gates verified versus stale, modules covered by tests, and the
   explicit "checked and clean" list.

## Handing the verified state to another machine

The next machine inherits the repository, not the agent: anything living only in the profile
(skills, memory, session context) stops at the boundary. Before the hand-off, move what matters
into the repository and commit it:

- copy the project-derived skills out of the agent profile into the repo's docs/ tree (check for
  absolute home paths inside) and state in the runbook where to install them on the destination;
- write a runbook: prerequisites, the exact commands in order, what the result should look like,
  the baseline to compare against, and every pitfall that cost time on the source machine;
- commit the baseline evidence (aggregates suffice — summary plus per-workload comparisons) so
  the destination has something to diff against, and say which raw artifacts are deliberately not
  committed and how to regenerate them;
- read the reference build files (Dockerfile, Makefile, CI workflow) and fold their dependencies
  into the destination's install target, so the destination does not repeat workarounds the
  source machine improvised.

State plainly what does NOT travel and must be re-created: the state database (and any secret
someone typed into it), machine-specific sudo/config files, kernel or sysctl tuning, credentials.

When the remaining gate is performance evidence, say which resource it needs and why, in the
user's own terms: a shared, oversubscribed host cannot produce a stable measurement, so the
requirement is exclusivity and headroom, not preference.

## Pitfalls

- Never answer "is it complete?" from a task list or status table alone: both can be accurate
  about a commit that is no longer HEAD, and both omit every class in rule 2.
- Never report a gap found by a single grep pattern without reading the code the pattern points
  at. The two most expensive false findings in this class are a renamed contract name that is in
  fact handled, and a route table declared under a prefix.
- **A generated directory committed to the repository is a finding, not background detail:** it
  drifts from the code it describes and resurfaces in every later documentation sweep. Before
  deleting it, grep for a rule, config or script that *points at it* — an agent rule saying
  "query the graph at `<dir>/`" means the tool integration is intentional. In that case remove it
  from version control and gitignore it, but leave the files on disk.
- **When the audit's test-gap finding lands on code with no seam to test, the fix is a small
  extraction, not a heavy harness:** pull the decision into a pure function (a predicate, a
  parser, a size constant) and unit-test that. Pure functions also let you assert things a
  pipeline test cannot, e.g. a compile-time bound on a buffer budget. Without this, "the module
  with one test that every branch change touches" stays unfixable.
- Do not add a field to a config contract and default it OFF without checking the producer sends
  it — the safest-looking default silently disables a live feature; confirm the feature still
  runs end to end after the deploy, not just that the code compiles.
- Do not let the audit end as prose. If nothing was committed, the next session re-derives it.

## Support files

- `scripts/boundary_crosscheck.py` — extract literal call-site strings and declared route sets,
  normalize parameters and prefixes, and print the differences in both directions.
