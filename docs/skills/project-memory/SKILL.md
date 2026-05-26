---
name: project-memory
description: Enforces persistent session memory and journaling for the blackgate-project repository.
---

# Project Memory and Context Journaling

This skill ensures that you never start a session cold and that you leave a clear trail of accomplishments, decisions, and system constraints for the next agent session.

## Checklist

You MUST follow these steps in every session:

1. **Read Previous Context**
   - Read the 3 most recent session log files in `docs/memory/01-LOGS/` (if any exist).
   - Read all files in `docs/memory/00-INBOX/` (where the user may have left specific notes/tasks/feedback).
2. **Acknowledge and Summarize**
   - Provide a brief 2-sentence summary in your first response outlining:
     - The current state of the codebase based on the logs.
     - What the user is currently working on or stuck on.
3. **Execute Task**
   - Proceed with the user's coding/development request following standard planning and execution skills.
4. **Log the Session**
   - Before completing your work and ending the session:
     - Write a new session log file: `docs/memory/01-LOGS/YYYY-MM-DD-session-X.md` (incrementing the session number `X` if multiple logs are written in one day).
     - In the log, include:
       - **Sprint Goal & Focus**
       - **What Was Accomplished** (summarize files created/modified, commands run, tests passed)
       - **Key Decisions & System Constraints Resolved**
       - **Current Codebase State**
       - **Pending Tasks & Next Milestones**
     - Clear the files in `docs/memory/00-INBOX/` that you have fully processed.
