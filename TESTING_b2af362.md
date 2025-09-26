# Manual Testing Instructions for Commit b2af362

## What Changed
Fixed permission mode cycling not informing Claude of mode changes. Previously, when using `matisse-cycle-permission-mode` (C-c C-m), the mode would change in Emacs but Claude would continue operating under the old mode.

## Test Scenario 1: Cycle from Default to Accept Mode

1. Start a new matisse session: `M-x matisse-shell`
2. Verify initial mode shows "🛡️ default" in mode-line
3. Send a message that requires a file edit: "Add a comment to the top of matisse.el saying 'test'"
4. When Claude asks for permission, **before responding**, cycle permission mode: `C-c C-m`
5. Select "acceptEdits" from the prompt
6. Verify mode-line shows "✓ accept"
7. Now respond "y" to the permission prompt
8. **Expected**: Claude should acknowledge the mode change and not ask for permission on the next edit
9. Send another edit request: "Add another comment below the first one"
10. **Expected**: Claude should auto-accept without prompting (because mode was updated)

## Test Scenario 2: Cycle from Plan to Default Mode

1. Start matisse in plan mode: Set `matisse-permission-mode` to "plan" and `M-x matisse-shell`
2. Verify mode-line shows "📋 plan"
3. Send a message: "Help me implement a new function to validate email addresses"
4. **Expected**: Claude should respond in plan mode (asking to exit plan mode)
5. Cycle permission mode: `C-c C-m`, select "default"
6. Verify mode-line shows "🛡️ default"
7. Send message: "yes, proceed"
8. **Expected**: Claude should now operate in default mode (not plan mode)
9. When Claude attempts file operations, it should ask for permission

## Test Scenario 3: Cycle During Auto-Allowed Operation

1. Start matisse: `M-x matisse-shell`
2. Send a read-only request: "Show me the first 10 lines of matisse.el"
3. **During Claude's response**, cycle permission mode: `C-c C-m`, select "bypassPermissions"
4. Verify mode-line shows "⚡ bypass"
5. Send an edit request: "Add a comment at line 100"
6. **Expected**: Claude should auto-accept without prompting (because mode is now bypass)

## Test Scenario 4: Multiple Mode Cycles

1. Start matisse: `M-x matisse-shell` in default mode
2. Send message: "Add a comment to matisse.el"
3. Before Claude responds, cycle mode multiple times:
   - `C-c C-m` → select "plan"
   - `C-c C-m` → select "acceptEdits"
   - `C-c C-m` → select "bypassPermissions"
4. **Expected**: Final mode (bypass) should be sent to Claude
5. Claude should auto-accept the edit without prompting

## Verification Points

For each test, verify:
- [ ] Mode-line indicator updates immediately after cycling
- [ ] Claude's behavior matches the new mode (no lag from old mode)
- [ ] No error messages in `*Messages*` buffer
- [ ] Permission prompts appear/disappear as expected for each mode
- [ ] `matisse--pending-permission-update` is cleared after sending (check with `M-: matisse--pending-permission-update`)

## Debug Commands

```elisp
;; Check current mode
M-: matisse--current-permission-mode

;; Check pending update (should be nil after sending)
M-: matisse--pending-permission-update

;; Enable debug logging
M-: (setq matisse-debug t)
```

## Expected Behavior Before Fix

Without this fix, cycling mode would update the mode-line but Claude would continue operating under the old mode until the next session.
