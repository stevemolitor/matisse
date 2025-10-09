# Bug Fix: Shell Freeze After Denying Permission

## Problem

When denying a permission prompt in **minibuffer mode** (not in-buffer mode), Matisse would sometimes freeze with:
- Mode-line animation stuck on the "fire" icon
- Unable to send new prompts (prompts would queue but nothing happened)
- The shell appeared completely unresponsive

This issue occurred in long conversations and was intermittent/difficult to reproduce.

## Root Cause

When a user denied permission in minibuffer mode, the code at `matisse.el:3238-3241` would:

1. Send a control response with `(interrupt . t)` to Claude
2. Wait for Claude to send back a "result" message
3. Only clear `matisse--waiting-for-response` and stop the spinner when the "result" message arrived

**The bug**: If the "result" message never arrived (due to network issues, Claude crash, or other failures), the shell would stay stuck with:
- `matisse--waiting-for-response = t`
- Spinner still running (showing fire icon)
- No new messages being processed (because the message queue checks `matisse--waiting-for-response`)

## Why In-Buffer Mode Didn't Have This Problem

The in-buffer permission flow (at `matisse.el:2314-2315`) correctly handled denial by immediately:
```elisp
;; Stop animation and clear waiting state on denial
(setq matisse--waiting-for-response nil)
(matisse--stop-spinner)
```

This ensured the shell was always ready for new input, regardless of whether Claude's "result" message arrived.

## The Fix

Added the same defensive state cleanup to the minibuffer denial flow:

```elisp
;; Deny: need behavior + message + interrupt
(matisse--send-control-response process request-id
                                `((behavior . "deny")
                                  (message . "User denied permission")
                                  (interrupt . t)))
;; CRITICAL: Clear waiting state and stop spinner immediately on denial
;; Don't wait for Claude's "result" message - it might never arrive
(setq matisse--waiting-for-response nil)
(matisse--stop-spinner)
```

**Key insight**: Don't rely on external events (Claude's response) for critical state management. Always clean up local state immediately when an operation is rejected.

## Location

File: `matisse.el`
Function: `matisse--handle-can-use-tool-request`
Lines: 3242-3245

## Testing

The fix compiles cleanly with no warnings or errors:
```bash
/Applications/Emacs.app/Contents/MacOS/bin/emacs --batch -L . \
  --eval "(setq sentence-end-double-space nil)" \
  -f batch-byte-compile matisse.el
```

## Impact

- **Low risk**: Only affects the denial path in minibuffer mode
- **High value**: Prevents shell from becoming unresponsive
- **Consistent**: Makes minibuffer mode behavior match in-buffer mode
- **Defensive**: Protects against network failures and edge cases
