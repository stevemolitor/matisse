# Matisse Context Management Implementation Plan

## Overview

Implement SDK-style context management in Matisse to prevent "Prompt too long" errors by adopting the same strategies used in Claude Code CLI v2.0.9.

**Author**: Based on SDK analysis
**Date**: October 2025
**Status**: Implementation Plan

---

## Background: What Claude Code SDK Does

### Token Counting
- **Fast estimation**: `length / 4` (function `z7()` in cli.js:1031)
- **Accurate counting**: API call to `countTokens` endpoint when precision needed
- **Two-stage validation**: Estimate first, verify if close to limits

### Per-Tool Result Limits
- **256KB file size limit** (`zk1 = 262144`)
- **25K token limit per Read** (`aa2 = 25000`)
- Function `na2()` (cli.js:1843) validates before returning content
- Returns error to Claude instead of oversized content

### Proactive Context Tracking
- Function `DI()` (cli.js:1669) extracts token usage from message history
- Checks thresholds **before** making next API call
- Function `Tj()` calculates warning/error/auto-compact thresholds

### Auto-Compaction
- Function `Is2()` (cli.js:1843) checks if auto-compact should trigger
- Trigger point: `tokens >= (context_window - 13000)`
- Controlled by `autoCompactEnabled` setting
- Calls compaction automatically, no user intervention

---

## Implementation Plan

## Feature 1: Fast Token Estimation

### Location: After line 2290 (near `matisse--reset-token-count`)

### Code to Add:

```elisp
(defun matisse--estimate-tokens (text)
  "Estimate token count for TEXT using fast approximation.
Uses the same heuristic as Claude Code CLI: string length divided by 4.
This is a rough estimate but sufficient for threshold checks.
Returns estimated token count as integer."
  (if (or (null text) (string-empty-p text))
      0
    (round (/ (length text) 4.0))))
```

### Usage:
- Quick checks before operations
- Proactive context tracking
- Threshold calculations

---

## Feature 2: Client-Side Tool Result Filtering

### Location 1: New defcustom after line 92 (after `matisse-aggressive-subagent-prompt`)

```elisp
(defcustom matisse-max-tool-result-tokens 15000
  "Maximum tokens allowed in a single tool result.
Tool results exceeding this limit will be truncated with a message to Claude.
The Claude Code CLI enforces 25K tokens per Read, but lowering this to 15K
helps prevent context bloat more aggressively.
Set to nil to disable client-side filtering (uses CLI's 25K limit only)."
  :type '(choice (integer :tag "Token limit")
                 (const :tag "Disabled (use CLI limit)" nil))
  :group 'matisse)
```

### Location 2: New function after line 2238 (after `matisse--extract-tool-result`)

```elisp
(defun matisse--check-tool-result-size (tool-result-content)
  "Check if TOOL-RESULT-CONTENT exceeds token limits.
Returns nil if size is acceptable, or an error message string if too large.
Uses fast token estimation to avoid expensive API calls."
  (when (and matisse-max-tool-result-tokens
             tool-result-content
             (stringp tool-result-content))
    (let ((estimated-tokens (matisse--estimate-tokens tool-result-content)))
      (when (> estimated-tokens matisse-max-tool-result-tokens)
        (format "<tool_use_error>Tool result (%d estimated tokens) exceeds maximum allowed tokens (%d). The content was too large to include. Consider using offset/limit parameters, Grep instead of Read, or breaking this into smaller operations.</tool_use_error>"
                estimated-tokens
                matisse-max-tool-result-tokens)))))

(defun matisse--maybe-filter-tool-result (json-obj)
  "Filter tool result in JSON-OBJ if it exceeds size limits.
Returns modified JSON-OBJ with truncated content if needed.
If tool result is within limits, returns JSON-OBJ unchanged."
  (if (not (equal (alist-get 'type json-obj) "user"))
      json-obj
    (let* ((message (alist-get 'message json-obj))
           (content (alist-get 'content message)))
      (if (not (vectorp content))
          json-obj
        ;; Check each content block for tool_result
        (let ((modified-content
               (mapcar
                (lambda (item)
                  (if (equal (alist-get 'type item) "tool_result")
                      (let* ((result-content (alist-get 'content item))
                             (error-msg (matisse--check-tool-result-size result-content)))
                        (if error-msg
                            ;; Replace content with error message
                            `((type . "tool_result")
                              (tool_use_id . ,(alist-get 'tool_use_id item))
                              (content . ,error-msg)
                              (is_error . t))
                          item))
                    item))
                (append content nil))))  ; Convert vector to list
          (if (equal modified-content (append content nil))
              json-obj
            ;; Return modified JSON-OBJ
            `((type . "user")
              (message . ((role . "user")
                         (content . ,(vconcat modified-content))))
              ,@(seq-filter (lambda (pair)
                             (not (memq (car pair) '(type message))))
                           json-obj))))))))
```

### Location 3: Integration point in `matisse--process-filter`

Around line 2900-3000, before forwarding user messages with tool results to the buffer, add filtering:

```elisp
;; Filter oversized tool results before processing
(when (equal (alist-get 'type json-obj) "user")
  (setq json-obj (matisse--maybe-filter-tool-result json-obj)))
```

---

## Feature 3: Proactive Context Tracking

### Location 1: Update `matisse--send-message-async` (around line 3450)

Before sending, estimate and track tokens:

```elisp
;; In matisse--send-message-async, after formatting message:
(when matisse-show-token-usage
  (let ((estimated-tokens (matisse--estimate-tokens text)))
    (setq matisse--tokens-since-compact
          (+ matisse--tokens-since-compact estimated-tokens))
    (matisse--debug-log "User message estimated at %d tokens (total: %d)"
                        estimated-tokens
                        matisse--tokens-since-compact)))
```

### Location 2: Update threshold checking

Currently happens reactively. Add proactive check before sending:

```elisp
;; Check if we should suggest or auto-compact BEFORE sending
(when (> matisse--tokens-since-compact matisse-auto-compact-threshold)
  (if matisse-auto-compact-enabled
      (progn
        (matisse--debug-log "Auto-compact threshold reached, triggering compaction")
        ;; Send compact command instead of user message
        ;; User message will be queued and sent after compact
        )
    (matisse--suggest-compaction)))
```

---

## Feature 4: True Auto-Compaction

### Location 1: New defcustom after line 779 (after `matisse-auto-compact-threshold`)

```elisp
(defcustom matisse-auto-compact-enabled nil
  "When non-nil, automatically trigger /compact when threshold is reached.
When nil, only suggest compaction to the user (current behavior).

When enabled, Matisse will automatically send the /compact command when
token usage exceeds `matisse-auto-compact-threshold'. The current user
message will be queued and sent after compaction completes.

Note: Auto-compaction can take 10-30 seconds. Consider setting
`matisse-auto-compact-threshold' lower (e.g., 30000) to compact earlier."
  :type 'boolean
  :group 'matisse)
```

### Location 2: Update `matisse-auto-compact-threshold` default

Change from 50000 to 30000:

```elisp
(defcustom matisse-auto-compact-threshold 30000
  "Suggest compaction after this many tokens (roughly 25% of context).
Changed from 50K to 30K to trigger compaction earlier and prevent
approaching API limits."
  :type 'integer
  :group 'matisse)
```

### Location 3: New message queue system

Add after line 970 (near buffer-local variables):

```elisp
(defvar-local matisse--pending-user-message nil
  "User message queued while waiting for auto-compact to complete.")

(defvar-local matisse--auto-compact-in-progress nil
  "Non-nil when auto-compaction is in progress.")
```

### Location 4: Update `matisse--send-message-async` (around line 3437)

Add auto-compact logic:

```elisp
(defun matisse--send-message-async (text)
  "Send TEXT to Claude asynchronously, with auto-compact if needed."
  (interactive)
  (let ((estimated-tokens (matisse--estimate-tokens text)))
    ;; Update token count proactively
    (setq matisse--tokens-since-compact
          (+ matisse--tokens-since-compact estimated-tokens))

    ;; Check if we should auto-compact
    (cond
     ;; Already compacting - queue this message
     (matisse--auto-compact-in-progress
      (matisse--debug-log "Auto-compact in progress, queueing message")
      (setq matisse--pending-user-message text))

     ;; Threshold reached and auto-compact enabled
     ((and matisse-auto-compact-enabled
           (> matisse--tokens-since-compact matisse-auto-compact-threshold))
      (matisse--debug-log "Auto-compact threshold reached (%d > %d), triggering compaction"
                          matisse--tokens-since-compact
                          matisse-auto-compact-threshold)
      ;; Queue user message and trigger compact
      (setq matisse--pending-user-message text)
      (setq matisse--auto-compact-in-progress t)
      (matisse--send-compact-command))

     ;; Normal message sending
     (t
      (matisse--send-message-internal text)))))
```

### Location 5: New compact command sender

Add after `matisse--send-message-async`:

```elisp
(defun matisse--send-compact-command ()
  "Send /compact command to trigger auto-compaction."
  (when matisse--shell-context
    (funcall (plist-get matisse--shell-context :write-output)
             "\n⚙️  Auto-compacting conversation (threshold reached)...\n"))
  (matisse--send-message-internal "/compact"))
```

### Location 6: Handle compact completion

In `matisse--process-filter`, after handling "compact_boundary" system message (around line 2730):

```elisp
;; After compact completes, send queued message
(when matisse--auto-compact-in-progress
  (setq matisse--auto-compact-in-progress nil)
  (when matisse--pending-user-message
    (let ((queued-message matisse--pending-user-message))
      (setq matisse--pending-user-message nil)
      (matisse--debug-log "Auto-compact completed, sending queued message")
      ;; Send queued message
      (run-at-time 0.5 nil
                   (lambda ()
                     (matisse--send-message-internal queued-message))))))
```

---

## Configuration Variables Summary

```elisp
;; Existing (modified defaults)
matisse-auto-compact-threshold  ; Changed from 50000 to 30000

;; New defcustoms
matisse-max-tool-result-tokens  ; Default: 15000 (nil to disable)
matisse-auto-compact-enabled    ; Default: nil (opt-in for safety)
```

---

## Implementation Order

### Phase 1: Foundation (Low Risk)
1. Add `matisse--estimate-tokens` function
2. Add new defcustom variables
3. Test token estimation accuracy

### Phase 2: Filtering (Medium Risk)
1. Add tool result size checking functions
2. Integrate filtering in message processing
3. Test with large file reads

### Phase 3: Proactive Tracking (Medium Risk)
1. Update `matisse--send-message-async` to estimate tokens
2. Update threshold checking to be proactive
3. Test token count accuracy

### Phase 4: Auto-Compaction (High Risk)
1. Add message queue system
2. Add compact command sender
3. Integrate queue processing after compact
4. Test auto-compact flow thoroughly

---

## Testing Strategy

### Manual Tests
1. **Token estimation**: Compare estimated vs actual tokens from API
2. **Tool filtering**: Try reading files > 15K tokens
3. **Proactive tracking**: Verify token count updates before API calls
4. **Auto-compact**: Trigger threshold and verify automatic compaction

### Edge Cases
- Multiple messages during auto-compact
- Compact failure handling
- Manual `/compact` during auto-compact
- `/clear` resetting all state correctly

---

## Risks and Mitigations

### Risk 1: Token Estimation Inaccuracy
- **Impact**: Low - only used for approximate checks
- **Mitigation**: SDK uses same method, ~25% error acceptable

### Risk 2: Tool Result Filtering Breaking Workflows
- **Impact**: Medium - might block legitimate large reads
- **Mitigation**: Make it configurable (default 15K), can disable

### Risk 3: Auto-Compact Interrupting User Flow
- **Impact**: Medium - unexpected pauses
- **Mitigation**:
  - Disabled by default (opt-in)
  - Clear notification when triggered
  - Lower threshold to 30K (triggers earlier, less likely to fail)

### Risk 4: Message Queue Complexity
- **Impact**: High - potential for lost/duplicate messages
- **Mitigation**:
  - Implement simple queue (one pending message max)
  - Thorough testing of edge cases
  - Clear debug logging

---

## Expected Improvements

### Before (Current State)
- Token tracking: Reactive (from API responses only)
- Tool results: No client-side limits (relies on CLI's 25K)
- Context management: Manual `/compact` or suggestion only
- Result: "Prompt too long" errors in research-heavy sessions

### After (With All Features)
- Token tracking: Proactive (estimates before sending)
- Tool results: Client-side 15K limit prevents bloat
- Context management: Automatic compaction at 30K tokens
- Result: Cleaner context, fewer API errors, longer sessions

### Specific Improvements
- **Prevent large file reads**: Block before they pollute context
- **Earlier compaction**: At 30K instead of 50K or API failure
- **Better visibility**: Real-time token estimates
- **Reduced errors**: Catch issues before API rejects

---

## Code Locations Reference

### Existing Code to Modify
- Line 779: `matisse-auto-compact-threshold` - lower default to 30000
- Line 966: Near `matisse--tokens-since-compact` - add queue variables
- Line 2290: Near token functions - add estimation function
- Line 2238: After `matisse--extract-tool-result` - add filtering functions
- Line 2730: `compact_boundary` handler - add queue processing
- Line 2900-3000: Message processing - add filtering integration
- Line 3437: `matisse--send-message-async` - add proactive tracking and auto-compact

### New Functions to Add
1. `matisse--estimate-tokens` - Fast token counting
2. `matisse--check-tool-result-size` - Size validation
3. `matisse--maybe-filter-tool-result` - Result filtering
4. `matisse--send-compact-command` - Trigger auto-compact
5. `matisse--send-message-internal` - Extract from async (if needed)

---

## Alternative: Minimal Implementation

If full implementation is too risky, start with just:

1. **Token estimation** (Feature 1) - enables better visibility
2. **Lower threshold** to 30K - triggers suggestions earlier
3. **Tool result filtering** (Feature 2) - prevents worst bloat

This gives ~70% of the benefit with ~30% of the complexity.

---

## SDK Code References

### Token Estimation
- cli.js:1031 - `function z7(A){return Math.round(A.length/4)}`

### Tool Result Filtering
- cli.js:1834 - `var zk1=262144,aa2=25000;`
- cli.js:1843 - `async function na2(A,B,{maxSizeBytes:Q=zk1,maxTokens:Z=aa2})`

### Proactive Tracking
- cli.js:1669 - `function DI(A)` - Extract tokens from messages
- cli.js:1843 - `function Tj(A)` - Calculate thresholds

### Auto-Compaction
- cli.js:1843 - `function Rj(){return D0().autoCompactEnabled}`
- cli.js:1843 - `async function uJ6(A,B)` - Check if should auto-compact
- cli.js:1843 - `async function Is2(A,B,Q)` - Perform auto-compact

---

## Next Steps

1. Review this plan
2. Decide on full or minimal implementation
3. Create feature branch for development
4. Implement in phases (1 → 2 → 3 → 4)
5. Test thoroughly between phases
6. Document new settings for users

---

## Open Questions

1. Should auto-compact be opt-in or opt-out?
   - **Recommendation**: Opt-in (safer), can enable by default later

2. What should the default `matisse-max-tool-result-tokens` be?
   - **Recommendation**: 15K (60% of CLI's 25K limit, more aggressive)

3. Should we implement message queue or block until compact completes?
   - **Recommendation**: Queue (better UX, but more complex)

4. Should we add a visual indicator during auto-compact?
   - **Recommendation**: Yes - show "⚙️ Auto-compacting..." message
