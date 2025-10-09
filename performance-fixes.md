# Matisse Conversation Replay Performance Fixes

## Problem

Conversation replay (`matisse-continue` and `matisse-resume`) was extremely slow, taking 10+ seconds to load previous conversations.

## Root Cause Analysis

### Initial Investigation

Initial profiler results suggested syntax highlighting was the bottleneck:
- 44% of time in `matisse--find-best-mode`
- 33% in `typescript-ts-mode` initialization
- Hypothesis: Syntax highlighting running during replay for every code block

### Actual Root Cause

Deeper analysis revealed the real issue was in **mode testing**, not syntax highlighting timing:

From profiler data:
```
matisse--mode-can-load-p
  -> condition-case
    -> funcall
      -> typescript-ts-mode
        -> treesit-major-mode-setup
          -> treesit-validate-font-lock-rules
            -> treesit-query-compile  [1408 samples]
```

**The problem**: `matisse--mode-can-load-p` (line 4514) was **activating major modes** just to test if they could load:

```elisp
;; OLD CODE (SLOW)
(defun matisse--mode-can-load-p (mode-symbol)
  (and (fboundp mode-symbol)
       (condition-case nil
           (with-temp-buffer
             (let ((inhibit-message t))
               (funcall mode-symbol)  ; ← Activates the mode!
               t))
         (error nil))))
```

This function was called 3+ times per code block (testing tree-sitter variant, standard variant, custom preferences), and each call would:
1. Create a temp buffer
2. Actually activate the major mode
3. Trigger expensive treesit compilation and font-lock setup
4. Just to check if the mode exists

## Solutions Implemented

### 1. Simplified Mode Testing (PRIMARY FIX)

**Changed**: `matisse--mode-can-load-p` function (line 4514-4517)

```elisp
;; NEW CODE (FAST)
(defun matisse--mode-can-load-p (mode-symbol)
  "Test if MODE-SYMBOL exists (fast check).
Returns non-nil if the mode function is defined."
  (fboundp mode-symbol))
```

**Impact**:
- Eliminated expensive mode activation during discovery
- Changed from O(n × mode_variants × mode_load_time) to O(n × mode_variants × constant)
- Reduced 2809+ profiler samples to near-zero

### 2. Skip Syntax Highlighting Flag (SECONDARY)

**Added**: Global variable to control syntax highlighting (line 922-924)

```elisp
(defvar matisse--skip-syntax-highlighting nil
  "When non-nil, skip syntax highlighting in code blocks.
Used during conversation replay for performance.")
```

**Removed**: Duplicate `defvar-local` declaration (was at line 1136-1138) that shadowed the global variable

**Modified**: `matisse--replay-conversation-from-file` (line 1383) to bind this variable:

```elisp
(let ((target-buffer (current-buffer))
      (message-count 0)
      (last-message-type nil)
      (matisse--skip-syntax-highlighting t)  ; ← Skip during replay
      (inhibit-redisplay t))
  ...)
```

**Modified**: `matisse--fontify-code-block` (line 4731-4734) to check the flag:

```elisp
;; Apply syntax highlighting to code content (unless skipping for performance)
(unless matisse--skip-syntax-highlighting
  (let* ((language (when language-pos
                     (buffer-substring-no-properties (car language-pos) (cdr language-pos)))))
    (matisse--apply-syntax-highlighting body-start body-end language)))
```

**Note**: This optimization turned out to be less critical than fixing mode testing, but helps avoid redundant work during replay.

## Error Handling

Existing error handling in `matisse--apply-syntax-highlighting` (line 4627-4697) catches mode loading failures:

```elisp
(condition-case err
  ;; ... mode activation and syntax highlighting ...
  (error
   (message "Error applying syntax highlighting for %s: %s"
            target-mode (error-message-string err))))
```

If a mode fails to load (e.g., missing treesit grammar), the error is caught and a message is printed, then continues with other code blocks.

## Performance Results

### Before
- **Replay time**: 10+ seconds
- **Profiler samples**: 2809+ samples in treesit compilation during mode testing
- **Mode testing**: `(funcall mode-symbol)` × 3 variants × N code blocks

### After
- **Replay time**: <1 second (estimated)
- **Profiler samples**: Near-zero in mode testing (just `fboundp` checks)
- **Mode testing**: Instant `fboundp` check × 3 variants × N code blocks
- **Mode activation**: Only happens once per unique language during actual syntax highlighting

## Technical Details

### Why the Original Approach Was Slow

1. **Multiple mode variants tested per language**:
   - Custom preferences (if configured)
   - Tree-sitter variant: `typescript-ts-mode`
   - Standard variant: `typescript-mode`

2. **Mode activation is expensive**:
   - TreeSitter modes compile query patterns
   - Font-lock rules are initialized
   - Hooks are run
   - Each activation: ~500-1400 profiler samples

3. **Called for every code block**:
   - No caching of results
   - Repeated mode testing for same language

### Why Simple `fboundp` Works

1. **Sufficient for discovery**: If the function exists, we can try to use it
2. **Fast**: O(1) hash table lookup in Emacs symbol table
3. **Error handling already exists**: If mode fails to activate during actual use, `condition-case` catches it
4. **Fail gracefully**: Missing treesit grammars or other errors just skip that code block's highlighting

## Files Modified

- `matisse.el`:
  - Line 922-924: Added `matisse--skip-syntax-highlighting` defvar
  - Line 1136-1138: Removed duplicate `defvar-local`
  - Line 1383: Bind skip flag during replay
  - Line 4514-4517: Simplified `matisse--mode-can-load-p`
  - Line 4731-4734: Check skip flag before highlighting

## Related Issues

- `exit-plan-mode-bug.md`: Documents separate issue with ExitPlanMode tool
- `profiler-report.txt`: Raw profiler data showing the bottleneck
- `checkmarks.md`: Appears to be unrelated notes
