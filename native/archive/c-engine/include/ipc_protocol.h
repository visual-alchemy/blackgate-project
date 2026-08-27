#ifndef IPC_PROTOCOL_H
#define IPC_PROTOCOL_H

// Runtime command interface — dispatches stdin JSON commands to pipeline operations.

// Parses a JSON line and dispatches to the appropriate handler:
//   {"command":"switch-source","target":"primary|secondary"}
//   {"command":"join-secondary"}
//   {"command":"leave-secondary"}
void handle_command_line(const char *line);

// Switch the active source pad on the input-selector.
// target must be "primary" or "secondary".
// No-op if dual-ingest is not active.
void switch_source(const char *target);

// Set the secondary source element to PLAYING state and emit SECONDARY_JOINED.
// No-op if dual-ingest is not active or no secondary source configured.
void join_secondary(void);

// Set the secondary source element to NULL state and emit SECONDARY_LEFT.
// No-op if dual-ingest is not active or no secondary source configured.
void leave_secondary(void);

#endif
