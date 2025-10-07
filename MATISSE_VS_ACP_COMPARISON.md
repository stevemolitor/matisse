# Matisse vs Claude-Code-ACP Context Management Comparison

**Date**: October 6, 2025

---

## Architecture Comparison

### Claude-Code-ACP (Zed's adapter)
```
Editor (Zed) → ACP Protocol → claude-code-acp → Claude Agent SDK → Claude API
                                    ↑
                            Thin wrapper (~500 lines)
                            Converts ACP ↔ SDK formats
```

### Matisse
```
Emacs → matisse.el → Claude Code CLI → Claude API
           ↑
      Full client (~6100 lines)
      Manages UI, state, token tracking
```

---

## Context Management Features

### What They Share (Both Use SDK/CLI)

| Feature | ACP | Matisse | Source |
|---------|-----|---------|--------|
| Claude Code system prompt | ✓ Preset | ✓ Default | SDK/CLI |
| User/project/local settings | ✓ Explicit | ✓ New | SDK/CLI |
| Subagent loading | ✓ Automatic | ✓ New | SDK/CLI |
| 25K token limit per Read | ✓ SDK | ✓ CLI | SDK/CLI |
| Auto-compaction (if enabled) | ✓ SDK | ✓ CLI | SDK/CLI |

**Key insight**: ACP gets all SDK features "for free" by delegating to the SDK.

---

## What Matisse Needed to Add

ACP doesn't implement these because the SDK handles everything:

### 1. Token Estimation ❌ Not in ACP
**ACP**: None - SDK handles internally
**Matisse**: Added `matisse--estimate-tokens` (NEW)
**Why needed**: Matisse manages UI and needs to show token counts

### 2. Proactive Token Tracking ❌ Not in ACP
**ACP**: None - no UI to update
**Matisse**: Added proactive tracking in `matisse--send-message-async` (NEW)
**Why needed**: Show token count in mode line before API response

### 3. Auto-Compact State Management ❌ Not in ACP
**ACP**: None - SDK handles transparently
**Matisse**: Added message queue, state flags, compact trigger (NEW)
**Why needed**: Matisse interacts via stdin/stdout, needs to queue messages

### 4. Configuration Variables ❌ Not in ACP
**ACP**: None - uses SDK defaults
**Matisse**: Added 4 new defcustoms (NEW)
**Why needed**: Emacs users expect customization

---

## Code Comparison

### ACP's Implementation (acp-agent.js:90-100)

```javascript
const options = {
  cwd: params.cwd,
  mcpServers,
  systemPrompt: { type: "preset", preset: "claude_code" },
  settingSources: ["user", "project", "local"],
  // ... other options
};

const q = query({ prompt: input, options });
```

**That's it!** Everything else handled by SDK.

### Matisse's Implementation (NEW)

```elisp
;; Configuration
(defcustom matisse-auto-compact-enabled nil ...)
(defcustom matisse-auto-compact-threshold 30000 ...)
(defcustom matisse-setting-sources "user,project,local" ...)
(defcustom matisse-aggressive-subagent-prompt ...)

;; Token estimation
(defun matisse--estimate-tokens (text)
  (round (/ (length text) 4.0)))

;; Proactive tracking
(when matisse-show-token-usage
  (let ((estimated-tokens (matisse--estimate-tokens text)))
    (setq matisse--tokens-since-compact ...)
    (force-mode-line-update)))

;; Auto-compact with message queue
(cond
  (matisse--auto-compact-in-progress
   (setq matisse--pending-user-message text))
  ((> matisse--tokens-since-compact threshold)
   (matisse--send-compact-command)))
```

**Much more complex** because Matisse manages the full client experience.

---

## Compact Boundary Handling

### ACP (acp-agent.js:192-193)
```javascript
case "compact_boundary":
    break;  // Do nothing
```

**No special handling** - just ignores it.

### Matisse (matisse.el:2814-2842)
```elisp
((equal subtype "compact_boundary")
 ;; Show message
 (message "Conversation compacted: %s" content)
 ;; Reset token count
 (matisse--reset-token-count)
 ;; Send queued message if auto-compact was in progress
 (when matisse--auto-compact-in-progress
   (setq matisse--auto-compact-in-progress nil)
   (when matisse--pending-user-message
     ;; Send queued message
     )))
```

**Extensive handling** - manages state, queue, notifications.

---

## Why The Difference?

### ACP's Simplicity
- **Thin adapter**: Only translates between ACP protocol and SDK
- **No UI**: Zed handles all UI, state management
- **No token display**: Zed doesn't show token counts (or does it differently)
- **No manual compaction**: Users can't trigger `/compact` via ACP (or it's handled by Zed)

### Matisse's Complexity
- **Full client**: Manages UI, state, notifications
- **Token visibility**: Shows counts in mode line
- **Manual controls**: Users can trigger `/compact`, `/clear`, etc.
- **State tracking**: Needs to coordinate with Emacs buffer state

---

## What ACP Gets "For Free" From SDK

Because ACP uses the SDK's `query()` function with `preset: "claude_code"`:

1. ✓ **Auto-compaction** - SDK's `Is2()` function runs automatically
2. ✓ **Token limits** - SDK's `na2()` enforces 25K per Read
3. ✓ **Proactive tracking** - SDK's `DI()` tracks before API calls
4. ✓ **Subagent prompting** - System prompt includes subagent instructions
5. ✓ **All slash commands** - Including `/compact`

**ACP doesn't need to implement any of this** - it's all in the SDK!

---

## What Matisse Had to Implement

Because Matisse uses the CLI via subprocess (not SDK as a library):

1. ✓ **Token estimation** - No direct access to SDK's z7() function
2. ✓ **Proactive tracking** - CLI sends token counts reactively, Matisse estimates proactively
3. ✓ **Auto-compact coordination** - Queue messages during compaction
4. ✓ **UI updates** - Mode line, notifications, state management
5. ✓ **Configuration** - Emacs-style defcustoms

**Matisse had to replicate SDK behavior** at the client level!

---

## Similarities in Our Implementation

Despite different architectures, our Matisse implementation matches ACP's approach:

### Both Now Use:
- ✓ `settingSources: ["user", "project", "local"]` (loads subagents)
- ✓ Claude Code system prompt (ACP via preset, Matisse via CLI default)
- ✓ Auto-compaction capability (ACP via SDK, Matisse via our implementation)

### What's Different:
- **ACP**: Gets everything from SDK, no custom code needed
- **Matisse**: Had to implement SDK features at client level

---

## Performance Comparison

### ACP
- **Token tracking**: None visible (SDK internal)
- **Context management**: Fully automatic (SDK)
- **User visibility**: Minimal (Zed's responsibility)

### Matisse
- **Token tracking**: Visible in mode line ✓
- **Context management**: Configurable (opt-in auto-compact)
- **User visibility**: High (notifications, debug logging, mode line)

---

## Conclusion

### ACP's Strategy: **Delegate Everything**
- Thin wrapper around SDK
- SDK handles all context management
- 536 lines of code (mostly protocol conversion)

### Matisse's Strategy: **Implement At Client Level**
- Full-featured client managing CLI subprocess
- Had to replicate SDK's context management features
- 6100 lines of code (full client + UI)

### Our Implementation Success:
✓ Achieved **feature parity** with ACP/SDK behavior
✓ Added **better visibility** (token counts, notifications)
✓ Added **configurability** (opt-in auto-compact, custom thresholds)
✓ Based on **proven SDK patterns** (not experimental)

**Result**: Matisse now has the same context protection as Zed using claude-code-acp, plus additional user-facing features for visibility and control.
