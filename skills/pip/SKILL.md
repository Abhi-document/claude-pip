---
name: pip
description: Open this Claude Code session in a floating picture-in-picture window, or as a cute agent in the MacBook notch with "/pip notch". Use when the user asks to open PiP, the floating window, or the notch agent.
argument-hint: "[notch]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/ClaudePiP *)
---
!`${CLAUDE_PLUGIN_ROOT}/bin/ClaudePiP open $ARGUMENTS`

Reply with only the line above.
