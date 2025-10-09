# Matisse Thinking Feature Implementation Plan

## Overview
Implement a "Thinking" toggle feature for Matisse similar to Claude Code's thinking display, allowing users to see Claude's internal reasoning process.

## How Claude Code's Thinking Works

### Protocol Details
Based on analysis of Claude Code's JSONL session files:

1. **User messages include thinking metadata**:
```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": "what does this folder do?"
  },
  "thinkingMetadata": {
    "level": "high",
    "disabled": false,
    "triggers": []
  }
}
```

2. **Assistant responses arrive in two separate messages**:
   - **First message**: Contains thinking content
   ```json
   {
     "message": {
       "role": "assistant",
       "content": [
         {
           "type": "thinking",
           "thinking": "The user is asking what the current folder does...",
           "signature": "EvQDCkYICBgCKkA..." // cryptographic signature
         }
       ]
     }
   }
   ```

   - **Second message**: Contains actual response text
   ```json
   {
     "message": {
       "role": "assistant",
       "content": [
         {
           "type": "text",
           "text": "This is your **scratch directory**..."
         }
       ]
     }
   }
   ```

3. **Key characteristics**:
   - Both messages share the same `requestId` and model message `id`
   - Each thinking block includes a cryptographic signature
   - Thinking metadata has `level` ("high"), `disabled` flag, and `triggers` array

## Implementation Plan

### 1. Add Customization Variables

Add new customization options to matisse.el:

```elisp
(defcustom matisse-thinking-enabled nil
  "Whether to request and display Claude's thinking process.
When enabled, Claude will show its internal reasoning before responding."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-show-thinking t
  "Whether to display thinking blocks in the output.
Only applies when `matisse-thinking-enabled' is t."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-thinking-level "high"
  "Level of thinking detail to request from Claude.
Valid values: \"low\", \"medium\", \"high\"."
  :type '(choice (const "low")
                 (const "medium")
                 (const "high"))
  :group 'matisse)

(defface matisse-thinking-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for displaying Claude's thinking process."
  :group 'matisse)
```

### 2. Modify User Message Protocol

Update `matisse--send-message-unified` to include `thinkingMetadata` when sending user messages:

```elisp
(defun matisse--build-user-message (text)
  "Build a user message with thinking metadata if enabled."
  (let ((base-message
         `((type . "user")
           (message . ((role . "user")
                      (content . ,(vector (list (cons 'type "text")
                                               (cons 'text text)))))))))
    (if matisse-thinking-enabled
        (append base-message
                `((thinkingMetadata . ((level . ,matisse-thinking-level)
                                      (disabled . ,(if matisse-thinking-enabled
                                                      :json-false
                                                      t))
                                      (triggers . ,(vector))))))
      base-message)))
```

### 3. Parse Thinking Content Blocks

Update `matisse-shell--handle-response` to recognize and handle thinking blocks:

```elisp
(defun matisse-shell--handle-thinking-block (thinking-text section-id)
  "Handle a thinking content block."
  (when (and matisse-thinking-enabled matisse-show-thinking)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (or (gethash section-id matisse--message-sections)
                      matisse--output-start-marker))
        (insert (propertize "💭 Thinking:\n"
                           'face 'matisse-thinking-face
                           'matisse-thinking t))
        (let ((start (point)))
          (insert thinking-text "\n\n")
          (add-text-properties start (point)
                              '(face matisse-thinking-face
                                matisse-thinking t)))))))

(defun matisse-shell--process-content-item (item section-id)
  "Process a single content item from assistant response."
  (let ((item-type (alist-get 'type item)))
    (cond
     ((equal item-type "thinking")
      (matisse-shell--handle-thinking-block
       (alist-get 'thinking item)
       section-id))

     ((equal item-type "text")
      (matisse-shell--insert-text
       (alist-get 'text item)
       section-id))

     ((equal item-type "tool_use")
      (matisse-shell--handle-tool-use item section-id))

     ;; ... other content types
     )))
```

### 4. Handle Multi-Part Responses

Track assistant messages by `requestId` to properly associate thinking blocks with their corresponding text responses:

```elisp
;; Add buffer-local variable
(defvar-local matisse--current-request-id nil
  "The request ID of the current assistant response being processed.")

(defun matisse-shell--handle-response (response)
  "Handle assistant response, including thinking blocks."
  (let* ((message (alist-get 'message response))
         (request-id (alist-get 'requestId response))
         (content (alist-get 'content message)))

    ;; Track request ID for multi-part responses
    (unless (equal request-id matisse--current-request-id)
      (setq matisse--current-request-id request-id)
      ;; Start new response section if needed
      (matisse-shell--start-response-section))

    ;; Process each content item
    (when (vectorp content)
      (seq-do (lambda (item)
                (matisse-shell--process-content-item
                 item
                 matisse--current-request-id))
              content))))
```

### 5. Add Interactive Toggle Command

Provide a command to toggle thinking mode:

```elisp
(defun matisse-toggle-thinking ()
  "Toggle the thinking feature on or off."
  (interactive)
  (setq matisse-thinking-enabled (not matisse-thinking-enabled))
  (message "Matisse thinking mode: %s"
           (if matisse-thinking-enabled "enabled" "disabled")))

(defun matisse-toggle-thinking-display ()
  "Toggle display of thinking blocks without changing whether they're requested."
  (interactive)
  (setq matisse-show-thinking (not matisse-show-thinking))
  (message "Matisse thinking display: %s"
           (if matisse-show-thinking "shown" "hidden")))
```

### 6. Update Key Bindings

Add key bindings for the new commands:

```elisp
(define-key matisse-shell-mode-map (kbd "C-c C-t") #'matisse-toggle-thinking)
(define-key matisse-shell-mode-map (kbd "C-c C-d") #'matisse-toggle-thinking-display)
```

### 7. Add Mode Line Indicator

Show thinking status in the mode line:

```elisp
(defun matisse--thinking-mode-line ()
  "Generate mode line indicator for thinking status."
  (when matisse-thinking-enabled
    (if matisse-show-thinking
        " 💭"
      " 💭⃠")))

;; Add to mode-line-format
(setq matisse--mode-line-format
      '(:eval (concat (matisse--permission-mode-line)
                     (matisse--thinking-mode-line)
                     (matisse--shell-context-mode-line))))
```

## Testing Plan

1. **Enable thinking mode** and verify that:
   - User messages include `thinkingMetadata` field
   - Thinking blocks appear before text responses
   - Thinking text is visually distinct (italicized, dimmed)

2. **Toggle thinking display** and verify:
   - `C-c C-d` hides/shows thinking blocks
   - Mode line indicator updates correctly

3. **Verify multi-part handling**:
   - Thinking and text appear in correct order
   - Multiple tool uses work correctly with thinking
   - Long responses with multiple thinking blocks display properly

4. **Test different thinking levels**:
   - Try "low", "medium", "high" levels
   - Verify the metadata is sent correctly

## Future Enhancements

- Add folding/collapsing of thinking blocks
- Syntax highlighting within thinking blocks
- Option to save/export thinking separately
- Thinking history review
- Per-message thinking toggle (not just global)
