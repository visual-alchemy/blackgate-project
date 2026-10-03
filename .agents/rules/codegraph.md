---
trigger: always_on
description: Use codegraph MCP + LSP for Blackgate codebase intelligence instead of graphify.
---

## Codebase intelligence — codegraph + LSP

graphify is removed. Do NOT use graphify (no CLI, no MCP, no `graphify-out/`).

Use these instead to know the Blackgate codebase:

- **codegraph MCP** — `codegraph_explore` is the primary tool for "how does X work",
  "where is X", architecture questions, bug tracing, and before editing any symbol.
  It returns verbatim line-numbered source grouped by file, the call path among the
  symbols, and a blast-radius summary. Prefer it over grep/read loops; treat the
  returned source as already read. The index auto-syncs ~1s after edits.
- **LSP tools** — `lsp_diagnostics` (errors/warnings for a file), `lsp_goto_definition`,
  `lsp_find_references`, `lsp_symbols`, `lsp_rename` for compiler-accurate navigation
  and safe renames.

After editing files, re-run codegraph on the changed symbols and `lsp_diagnostics`
on the changed files before claiming the work done.

Specialists remain valid: `explore` for broad codebase grep, `librarian` for external
docs/OSS, `oracle` for hard debugging/architecture.
