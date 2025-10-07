# Matisse Context Management Improvements

**Date**: October 6, 2025
**Branch**: remote-control
**Status**: Complete ✓

---

## Problem Solved

Matisse sessions were hitting "Prompt too long" errors in research-heavy conversations due to context bloat from:
- Large file reads accumulating in context
- No automatic compaction (only manual suggestions)
- Reactive token tracking (noticed problems too late)

---

## What We Implemented

Analyzed Claude Code SDK v2.0.9 and implemented 3 proven context management features:

### 1. Fast Token Estimation
- Function: `matisse--estimate-tokens`
- Uses SDK's `length/4` heuristic for instant estimates
- No API calls needed

### 2. Proactive Token Tracking
- Estimates tokens **before** sending to API (not after)
- Updates mode line in real-time
- Enables catching threshold violations early

### 3. Automatic Compaction
- `matisse-auto-compact-enabled` defcustom (opt-in)
- Auto-triggers `/compact` at 30K tokens (lowered from 50K)
- Queues user messages during compaction
- Sends queued message after compact completes

### Plus Earlier Improvements
- Load custom subagents from `~/.claude/agents/`
- Append system prompt encouraging aggressive subagent usage
- Both help keep large file reads in separate context windows

### Bonus: Unlimited Message Queue
- Discovered Matisse already had sophisticated queue system (lines 4272-4396)
- Integrated auto-compact with existing queue
- Now supports **unlimited queued messages** while Claude is working
- Matches ACP's Pushable pattern without protocol overhead

---

## How to Use

### Enable Auto-Compaction (Recommended)

Add to your Emacs config:

```elisp
(with-eval-after-load 'matisse
  (setq matisse-auto-compact-enabled t))
```

### Or Enable Per-Session

```elisp
M-x customize-variable RET matisse-auto-compact-enabled RET
```

### Default Behavior (No Config Needed)

Even without enabling auto-compact, you get:
- ✓ Real-time token tracking in mode line
- ✓ Compaction suggestions at 30K (instead of 50K)
- ✓ Custom subagents loaded automatically
- ✓ Aggressive subagent prompting

---

## Expected Benefits

- **Fewer "Prompt too long" errors** - Auto-compact prevents hitting API limits
- **Longer viable sessions** - Can work for hours without manual intervention
- **Better visibility** - See token count in real-time
- **Cleaner context** - Subagents keep large reads out of main conversation

---

## What Protects Context

1. **CLI's 25K limit per Read** (built-in, always worked)
2. **Proactive tracking** (NEW - catch issues early)
3. **Auto-compaction** (NEW - automatic recovery)
4. **Subagent usage** (NEW - separate context windows)

---

## Technical Details

Based on Claude Code SDK v2.0.9 implementation:
- Token estimation: `z7()` function (cli.js:1031)
- Proactive tracking: `DI()` function (cli.js:1669)
- Auto-compact: `Is2()` and `uJ6()` functions (cli.js:1843)

All features are **direct implementations** of proven SDK patterns, not experimental additions.

---

## Commits

```
c82676a Remove client-side tool result filtering (doesn't work in Matisse)
0a05e45 Add message queue handling after auto-compact
6a943d5 Implement auto-compact trigger logic
dc316a6 Add auto-compaction configuration and state variables
87525f8 Add proactive token tracking to message sending
c0c7b13 Add fast token estimation function
3648894 Add context management improvements and fix token tracking
```

---

## See Also

- `IMPLEMENTATION_SUMMARY_FOR_STEVE.md` - Detailed implementation notes
- `IMPLEMENTATION_COMPLETE.md` - Technical documentation
- `CONTEXT_MANAGEMENT_IMPLEMENTATION.md` - Feature specifications
- `READY_FOR_REVIEW.txt` - Testing checklist
