# Design Spec: Obsidian Project Memory Integration

**Date:** 2026-05-26  
**Status:** Approved  

## Purpose
Enable persistent developer memory for the `blackgate-project` using the repository itself as an Obsidian vault. This ensures subsequent agent sessions have immediate context of past progress, decisions, and system constraints without requiring the user to re-explain context.

## Folder Structure
We will create a structured storage layout under `docs/memory/`:
- `docs/memory/00-INBOX/`: Where the user can write raw text files or notes with quick feedback/requests.
- `docs/memory/01-LOGS/`: Where the agent logs chronological, markdown-formatted summaries of each session.
- `docs/skills/project-memory/`: Holds the custom skill definition `SKILL.md` to run the memory sync.

## Custom Skill: `project-memory`
A custom Gemini skill located at `docs/skills/project-memory/SKILL.md`. It instructs the agent to:
1. Load context from `docs/memory/01-LOGS/` and `docs/memory/00-INBOX/` at the start of a session.
2. Maintain active progress tracking during the session.
3. Write a summary of files edited, commands run, and accomplishments back to a new log in `docs/memory/01-LOGS/YYYY-MM-DD-session-X.md` on completion.

## Global Integration
We link the skill using the Gemini CLI:
```bash
gemini skills link docs/skills/project-memory
```
And document the integration in `AGENTS.md` so that future agents are instructed to run the memory skill.
