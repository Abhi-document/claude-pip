---
description: Open this session in a floating picture-in-picture window
allowed-tools: Bash(pgrep:*), Bash(nohup:*)
---
!`pgrep -x ClaudePiP >/dev/null || nohup "${CLAUDE_PLUGIN_ROOT}/bin/ClaudePiP" >/dev/null 2>&1 &`

Reply only with: "PiP window open — approve/decline and send instructions from it. Close it to return control here."
