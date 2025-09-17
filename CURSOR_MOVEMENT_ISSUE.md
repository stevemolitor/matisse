# Cursor Movement Issue in Matisse Shell

## Problem Description

There is a persistent cursor movement bug in matisse-shell-mode where `backward-char` (C-b or left arrow) fails when the cursor is at `point-max` (end of buffer). This occurs even when there is text after the prompt that the cursor should be able to move through.

### Symptoms
- When cursor is at the very end of the buffer, `backward-char` fails with a "beginning-of-buffer" error
- The issue occurs whether the input area is empty or contains text
- Interestingly, `(backward-char 2)` works but moves cursor to position `point-max - 1` (the "sticky position")
- Once at the sticky position, further backward movement works normally
- Forward movement from the sticky position back to `point-max` also fails

## Current Implementation

Matisse uses text properties to implement the shell prompt:

```elisp
;; The prompt consists of two parts:
;; 1. A prompt character (e.g., "❯", ">", or an emoji)
;; 2. A space character

;; Current approach:
(put-text-property prompt-start prompt-end 'read-only t)
(put-text-property prompt-start prompt-end 'rear-nonsticky '(read-only))
```

### How Read-Only Text Properties Work
- `read-only`: Prevents modification of the text
- `rear-nonsticky`: Prevents the property from "sticking" to newly inserted text after it
- Emacs treats read-only boundaries as implicit field boundaries
- This creates movement restrictions even with `inhibit-field-text-motion` set to `t`

## Root Cause Analysis

The issue appears to be a bug or quirk in Emacs's handling of cursor movement near read-only text boundaries:

1. **Implicit Field Boundaries**: Emacs treats the transition from read-only to editable text as a field boundary
2. **The Sticky Position**: Position `point-max - 1` acts as a "trap" where normal movement commands fail
3. **Inconsistent Behavior**: `(backward-char 2)` succeeds while `(backward-char 1)` fails, suggesting internal Emacs logic issues

## Alternative Approaches

### 1. Overlays (Recommended)

Overlays are a more flexible alternative to text properties that don't affect cursor movement:

```elisp
(defun matisse--insert-prompt-with-overlay ()
  "Insert prompt using overlays instead of text properties."
  (let ((prompt-start (point)))
    (insert matisse-shell-prompt)

    ;; Create overlay for the prompt character
    (let ((ov (make-overlay prompt-start
                           (+ prompt-start (length (matisse--get-shell-prompt-character))))))
      (overlay-put ov 'face 'matisse-prompt-character-face)
      (overlay-put ov 'evaporate t)  ; Auto-delete if region becomes empty
      ;; Make prompt read-only via overlay
      (overlay-put ov 'modification-hooks
                   '((lambda (ov after beg end &optional len)
                       (unless after
                         (error "Prompt is read-only"))))))))
```

**Advantages:**
- No cursor movement issues
- Already used elsewhere in matisse for syntax highlighting
- Can be dynamically updated without modifying buffer text
- Cleaner separation of presentation from content

**Disadvantages:**
- Slightly more complex to manage
- Need to track overlay objects
- May need special handling for buffer modifications

### 2. Field Properties

Use explicit field properties to create proper boundaries:

```elisp
(defun matisse--insert-prompt-with-fields ()
  "Insert prompt using field properties."
  (let ((prompt-start (point)))
    (insert matisse-shell-prompt)

    ;; Set field property on prompt
    (put-text-property prompt-start
                      (+ prompt-start (length matisse-shell-prompt))
                      'field 'prompt)

    ;; Input area gets a different field
    (put-text-property (point) (point) 'field 'input)

    ;; Make prompt read-only
    (put-text-property prompt-start
                      (+ prompt-start (length (matisse--get-shell-prompt-character)))
                      'read-only t)))
```

**Advantages:**
- Explicit control over field boundaries
- Built-in Emacs support for field navigation
- Can use `constrain-to-field` functions

**Disadvantages:**
- Still uses text properties (similar issues possible)
- More complex field management required

### 3. Invisible Text Properties

Keep prompt as regular text but make unwanted parts invisible:

```elisp
(defun matisse--insert-prompt-invisible ()
  "Insert prompt with invisible markers."
  ;; Insert a special marker before the visible prompt
  (insert "\0")  ; Null character or other marker
  (put-text-property (1- (point)) (point) 'invisible t)
  (put-text-property (1- (point)) (point) 'matisse-prompt-start t)

  ;; Insert visible prompt normally
  (insert matisse-shell-prompt))
```

**Advantages:**
- No read-only restrictions
- Simple implementation
- No cursor movement issues

**Disadvantages:**
- Prompt can be accidentally deleted
- Need other mechanisms to prevent prompt modification

## Recommendation

**Use overlays consistently throughout matisse** for the following reasons:

1. **Consistency**: Already using overlays for syntax highlighting and other visual features
2. **No Movement Issues**: Overlays don't affect cursor movement
3. **Flexibility**: Easy to update visual properties without touching buffer text
4. **Clean Separation**: Keeps presentation separate from content
5. **Future-Proof**: Easier to add features like prompt animation, dynamic colors, etc.

## Implementation Plan

1. Create `matisse--prompt-overlay` variable to track current prompt overlay
2. Modify `matisse--insert-prompt` to use overlays instead of text properties
3. Update `matisse--clear-current-input` to work with overlay-based prompts
4. Test thoroughly with various prompt characters and input scenarios
5. Consider migrating other text properties to overlays for consistency

## Workarounds Attempted

1. **Setting `inhibit-field-text-motion`**: Didn't help
2. **Using `goto-char` directly**: Same failures as `backward-char`
3. **Temporarily modifying buffer**: Too complex and fragile
4. **Using `(backward-char 2)`**: Works but moves 2 positions instead of 1
5. **Making only prompt character read-only**: Partial improvement but issue persists

## References

- Emacs Manual: [Overlays](https://www.gnu.org/software/emacs/manual/html_node/elisp/Overlays.html)
- Emacs Manual: [Text Properties](https://www.gnu.org/software/emacs/manual/html_node/elisp/Text-Properties.html)
- Emacs Manual: [Fields](https://www.gnu.org/software/emacs/manual/html_node/elisp/Fields.html)