# Matisse Remote Control - Key Features Guide

This guide covers the major new features added in the remote-control branch.

## Quick Start

```elisp
;; Enable global keybindings for remote control
(matisse-global-mode 1)

;; Start Matisse from anywhere
C-c m m  ; or M-x matisse
```

## Global Keybindings (matisse-global-mode)

When `matisse-global-mode` is enabled, these keybindings work from any buffer:

| Key | Command | Description |
|-----|---------|-------------|
| `C-c m m` | `matisse` | Start new session in current directory |
| `C-c m d` | `matisse-start-in-directory` | Start in selected directory |
| `C-c m c` | `matisse-continue` | Continue from last session |
| `C-c m r` | `matisse-resume` | Resume specific session |
| `C-c m t` | `matisse-transient` | Open transient menu |
| `C-c m s` | `matisse-shell-switch` | Switch between sessions |
| `C-c m l` | `matisse-list-sessions` | List all sessions |
| `C-c m p` | `matisse-cycle-permission-mode` | Cycle permission modes |
| `C-c m i` | `matisse-interrupt` | Interrupt current operation |
| `C-c m R` | `matisse-restart` | Restart Claude process |
| `C-c m h` | `matisse-history-search` | Interactive history search |
| `C-c m @` | `matisse-add-file-reference` | Add file reference |
| `C-c m #` | `matisse-add-file-reference-with-lines` | Add file with lines |

## File Reference System

### Auto-completion in Prompts

Type `@` in the Matisse prompt to trigger file path completion:

```
@src/main.rs<TAB>    # Complete file paths
@config.json#L5-L10  # Reference specific lines
```

### Commands

**Add file reference at cursor position:**
```elisp
M-x matisse-add-file-reference  ; or C-c m @
```

**Add file with line range:**
```elisp
M-x matisse-add-file-reference-with-lines  ; or C-c m #
```

**Add from selection:**
1. Select text in any file buffer
2. Press `C-c m @`
3. The selection is added as `@file#LX:Y-LZ:W` format

### Examples

```
# Reference entire file
Can you review @src/config.rs?

# Reference specific lines
Fix the bug in @main.rs#L45-L60

# Selected text gets added automatically
@/Users/steve/repos/matisse/matisse.el#L528:15-L538:20
```

## Permission Modes

### Cycling Modes

Press `C-c m p` to cycle through:

1. **default** - Prompt for each tool (y/n/always)
2. **bypassPermissions** - Allow all tools automatically
3. **acceptEdits** - Auto-allow file edits only
4. **plan** - Planning mode (auto-exits with ExitPlanMode)
5. **yolo** - Dynamic mode that learns from your choices

### Yolo Mode

The "yolo" mode is smart:
- Starts by asking for permission
- If you say "yes", it remembers and auto-allows similar tools
- If you say "no", it keeps asking
- Resets when you restart Matisse

Great for workflows where you want some automation but not complete bypass.

### Mode Display

The current mode appears in your mode-line:
```
[DEFAULT]  [BYPASS]  [ACCEPT]  [PLAN]  [YOLO]
```

## Context Management

### Auto-Compact

Matisse automatically compacts the conversation when approaching token limits:

```elisp
;; Configure threshold (0.0 to 1.0, default: 0.85)
(setq matisse-auto-compact-threshold 0.85)

;; Disable auto-compact
(setq matisse-auto-compact-enabled nil)
```

When auto-compact triggers, you'll see:
```
⚠️  Context at 87% - auto-compacting to preserve important messages...
✅ Compacted 15 older messages, freed 45,231 tokens
```

### Manual Compact

Type `/compact` in the Matisse prompt to manually compact:
```
/compact
```

### Context Breakdown

View detailed token usage:
```
/matisse:context
```

Output shows:
- Total conversation size
- User vs Claude token split
- Cache usage
- Memory files and MCP servers
- Individual message sizes

## Session Management

### List Sessions

```elisp
M-x matisse-list-sessions  ; or C-c m l
```

Shows all sessions with status icons:
- ✓ Completed sessions
- ⚠ Active/recent sessions
- ✗ Error sessions

Press `RET` on a session to resume it.

### Switch Sessions

```elisp
M-x matisse-shell-switch  ; or C-c m s
```

Quickly switch between active Matisse buffers.

### Resume vs Continue

**Continue** (`C-c m c`): Continue from your last conversation (any session)

**Resume** (`C-c m r`): Resume a specific session by ID

## History Search

Interactive search through your command history:

```elisp
M-x matisse-history-search  ; or C-c m h
```

- Type to filter matches in real-time
- Use arrow keys to navigate
- Press `RET` to select
- Press `ESC` to cancel

History is automatically populated when resuming sessions.

## Transient Menu

Press `C-c m t` to open the full transient menu:

```
Matisse Actions
┌─────────────────┬──────────────────┬─────────────────┐
│ Sessions        │ Control          │ Files           │
├─────────────────┼──────────────────┼─────────────────┤
│ m Start         │ i Interrupt      │ @ Add file ref  │
│ d In directory  │ R Restart        │ # Add w/ lines  │
│ c Continue      │ p Cycle perms    │                 │
│ r Resume        │ h History search │                 │
│ s Switch        │ l List sessions  │                 │
└─────────────────┴──────────────────┴─────────────────┘
```

## UI Improvements

### Mode-line Icons

Configure icons separately from progress indicators:

```elisp
;; Icon mode (ascii, emoji, nerd-icons)
(setq matisse-progress-icons-mode 'nerd-icons)

;; Separate scale for mode-line icons
(setq matisse-modeline-icon-scale 1.0)

;; Separate scale for in-buffer progress icons
(setq matisse-icons-scale-factor 1.2)
```

### Progress Indicators

Now shows:
- Tool usage with icons: 📖 Reading file.txt...
- File changes: ✅ Updated config.json
- Performance: ⏱️ Completed in 12.3s

### Table Alignment

Markdown tables in Claude's output are automatically aligned:

```
| Before       | After          |
|--------------|----------------|
| Uneven       | Nicely         |
| Spacing      | Aligned        |
```

## Configuration Summary

```elisp
;; Enable global keybindings
(matisse-global-mode 1)

;; Set default permission mode
(setq matisse-permission-mode "default")  ; or "bypassPermissions", "acceptEdits", "yolo"

;; Configure auto-compact
(setq matisse-auto-compact-enabled t)
(setq matisse-auto-compact-threshold 0.85)

;; Show features
(setq matisse-show-progress-indicators t)
(setq matisse-show-file-changes t)
(setq matisse-show-performance-summary nil)

;; Icon configuration
(setq matisse-progress-icons-mode 'nerd-icons)
(setq matisse-modeline-icon-scale 1.0)
(setq matisse-icons-scale-factor 1.2)

;; Mode-line display
(setq matisse-show-permission-in-modeline t)
(setq matisse-show-context-in-modeline t)
```

## Common Workflows

### Quick Code Review

1. Select code in a file
2. Press `C-c m m` (start Matisse)
3. Type: "Review this code for bugs"
4. The selection is automatically added as context

### Multi-file Refactoring

1. Press `C-c m t` (transient menu)
2. Start session
3. Press `C-c m p` to cycle to "acceptEdits" mode
4. Ask Claude to refactor
5. File changes happen automatically

### Exploring Large Codebase

1. Start Matisse
2. Ask: "Explain the architecture"
3. Type `/matisse:context` to monitor token usage
4. Auto-compact kicks in when needed

### Pair Programming

1. Keep Matisse in side window
2. Use `C-c m @` to add files as you work
3. Switch to "yolo" mode for smoother flow
4. Use `C-c m i` to interrupt if needed

## Bug Fixes Included

- Fixed shell freeze when denying permissions
- Fixed @ completion with spaces in paths
- Fixed slash commands with arguments
- Fixed token counting with cache
- Fixed symlink handling
- Fixed syntax highlighting buffer overflow
- Fixed prompt spacing for multi-byte characters
- Many more stability improvements

## What's Next?

See the main README.md for:
- Installation instructions
- Basic configuration
- API key setup
- Complete feature list

See CLAUDE.md for:
- Architecture details
- Development guidelines
- How the protocol works
