# abhi.document: Claude PiP 🪟

**Picture-in-picture for Claude Code.** Keep your Claude Code session in a small floating window that stays on top of every app, like a PiP video. Work in Figma, Chrome, Premiere or anything else and still:

- 👀 **watch** what Claude is doing, live
- ✅ **approve / decline** permission requests with one click
- 💬 **send new instructions** without switching back to the terminal

Works with Claude Code in the terminal and in VS Code. **macOS only** (Apple Silicon and Intel, macOS 12+).

---

## Install (1 minute)

Open Claude Code and type these two commands:

```
/plugin marketplace add Abhi-document/claude-pip
/plugin install abhi.document@abhi.document
```

Then **restart Claude Code** (quit and open it again).

## Use it

In any Claude Code session, type:

```
/pip
```

A floating window appears in the bottom-right corner of your screen. Drag it anywhere and resize it however you like.

| In the window | What it does |
|---|---|
| **● status** | `working`, `needs approval` (plays a sound), or `waiting for instruction` |
| **Approve / Decline** | Answers Claude's permission request. Type a reason in the box before clicking Decline and Claude sees it |
| **Stop** (or **Esc**) | Stops the current task right away, including a running command (also cancels a pending approval). Then type your next instruction in the window |
| **Message box** | **Enter** sends, **Shift+Enter** adds a new line. The box grows as you type |

### 🐣 Notch mode

Click **Notch** in the window (or open it with `/pip notch`) to hide it and move into your MacBook's notch instead. A tiny agent lives there:

- 👀 it has **expressive, human-like eyes** with brows, blinking and glances, animated with Pixar-style principles:
  - 🧐 **focused** while Claude works, scanning like it's reading
  - 😲 **surprised** (wide eyes, pinpoint pupils) when Claude needs your OK, staring right at you
  - 😊 **happy** (smiling eyes, blush) when Claude is done
  - 😟 **worried** (droopy eyes, sweat drop) when you press Stop
  - 😴 **dozes off** and sleeps when idle. **Double-click** it to wake it up
- 🖱️ **hover over the notch** to open it: status, what Claude just did, Approve / Decline / Stop, and a **chat box** to send instructions
- 👻 move over the pill beside the notch and it turns see-through, so the menu bar items under it stay clickable
- 💬 when Claude finishes, it **tells you the answer** in a speech bubble. Long answers come in pages: click the right side for the next page, the left side to go back
- 💖 **click the agent** and it reacts (blush, big happy eyes, a heart)
- click **Window** to go back to the floating window

No notch? It still works: the agent sits at the top center of your screen.

**To go back to normal:** close the window. Claude Code works exactly as before.

## Good to know

- While the window is open, Claude waits for your next instruction **from the window**. Close the window to type in the terminal again.
- **Stop** ends a running command immediately. If Claude is in the middle of writing a reply, it finishes that reply, then stops. The window always tells you what Stop did. To cut a reply off mid-sentence, press Esc in the Claude panel itself.
- It follows one session at a time: whichever session was active most recently.
- Questions Claude asks you (multiple choice) still appear in the terminal.

## Uninstall

```
/plugin uninstall abhi.document@abhi.document
```

---

### For developers

`src/pip.swift` is the whole app: the floating window, `ClaudePiP open` (used by the `/pip` skill), plus `ClaudePiP hook`, which Claude Code runs on `PermissionRequest`, `PreToolUse`, `PostToolUse`, `Stop` and `UserPromptSubmit`. The two talk through small files in `~/.claude/pip/`. Rebuild the universal binary with `./build.sh` (needs Xcode command line tools).
