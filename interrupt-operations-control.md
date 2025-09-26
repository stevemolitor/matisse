# Matisse: Interrupt Operations and Dynamic Control

## Executive Summary

This document outlines how to add interrupt operations and dynamic control to matisse.el. Since matisse already has bidirectional JSON streaming, we can send control requests for interrupts, model changes, and permission mode updates without any new infrastructure.

## Current Limitations

### No Graceful Cancellation
- Only way to stop is killing the entire process
- No way to interrupt long-running operations
- Cannot cancel specific tool uses
- Lost context when forcefully stopping

### Static Configuration
- Model selection fixed at startup
- Permission mode cannot be changed mid-session
- No way to adjust settings without restart

### Poor Interrupt Handling
- C-g (keyboard-quit) doesn't cleanly interrupt Claude
- No feedback when operations are cancelled
- Risk of partial operations completing

## Solution: Use Existing JSON Stream for Control

### Available Control Operations (all via process-send-string)

1. **Interrupt** - Send `interrupt` control request
2. **Set Model** - Send `set_model` control request
3. **Set Permission Mode** - Send `set_permission_mode` control request
4. **Cancel Control Request** - Send `control_cancel_request` message

## Implementation Plan

### Phase 1: Interrupt Infrastructure

#### 1.1 Interrupt Command
```elisp
(defun matisse-interrupt ()
  "Interrupt the current Claude Code operation.
This sends an interrupt request to gracefully stop processing."
  (interactive)
  (if (and matisse--process
           (process-live-p matisse--process))
      (progn
        (matisse--send-interrupt-request)
        (message "Interrupting Claude..."))
    (message "No active Claude process to interrupt")))

(defun matisse--send-interrupt-request ()
  "Send interrupt control request to Claude Code."
  (let* ((request-id (matisse--generate-request-id))
         (interrupt-request
          `((type . "control_request")
            (request_id . ,request-id)
            (request . ((subtype . "interrupt"))))))

    ;; Mark that we're interrupting
    (setq matisse--interrupting t)

    ;; Send request
    (process-send-string matisse--process
                         (concat (json-encode interrupt-request) "\n"))

    ;; Visual feedback
    (matisse--show-interrupt-indicator)

    (matisse--debug-log "Sent interrupt request: %s" request-id)))
```

#### 1.2 Keyboard Interrupt Binding
```elisp
(defun matisse--setup-interrupt-keys ()
  "Setup keyboard interrupt handling."
  ;; Override C-g in matisse buffers
  (local-set-key (kbd "C-g") #'matisse-interrupt-or-quit)
  ;; Add C-c C-c as alternative interrupt
  (local-set-key (kbd "C-c C-c") #'matisse-interrupt))

(defun matisse-interrupt-or-quit ()
  "Interrupt Claude if busy, otherwise normal keyboard-quit."
  (interactive)
  (if (and matisse--process-busy
           matisse--process
           (process-live-p matisse--process))
      (matisse-interrupt)
    (keyboard-quit)))
```

#### 1.3 Visual Interrupt Feedback
```elisp
(defvar matisse--interrupt-overlay nil
  "Overlay showing interrupt status.")

(defun matisse--show-interrupt-indicator ()
  "Show visual indicator that interrupt was sent."
  (when matisse--output-end-marker
    (let ((pos (marker-position matisse--output-end-marker)))
      (when (and pos (> pos (point-min)))
        ;; Create overlay at current output position
        (setq matisse--interrupt-overlay
              (make-overlay (1- pos) pos))
        (overlay-put matisse--interrupt-overlay 'after-string
                     (propertize " [INTERRUPTING...]"
                                'face 'warning))
        ;; Remove after timeout
        (run-with-timer 3 nil
                        (lambda ()
                          (when matisse--interrupt-overlay
                            (delete-overlay matisse--interrupt-overlay)
                            (setq matisse--interrupt-overlay nil))))))))

(defun matisse--handle-interrupt-response (response-data)
  "Handle response to interrupt request."
  (setq matisse--interrupting nil
        matisse--process-busy nil)

  ;; Clear interrupt indicator
  (when matisse--interrupt-overlay
    (delete-overlay matisse--interrupt-overlay)
    (setq matisse--interrupt-overlay nil))

  (message "Operation interrupted successfully")

  ;; Insert indicator in buffer
  (matisse--insert-system-message
   "\n[Operation interrupted by user]\n"))
```

### Phase 2: Dynamic Model Switching

#### 2.1 Model Change Command
```elisp
(defun matisse-change-model ()
  "Change the Claude model mid-conversation."
  (interactive)
  (unless matisse--available-models
    (error "Model list not available. Is initialization complete?"))

  (let* ((current-model matisse--current-model-id)
         (models (mapcar (lambda (m)
                          (let ((id (plist-get m :id))
                                (name (plist-get m :name)))
                            (cons (format "%s%s"
                                        name
                                        (if (string= id current-model)
                                            " (current)" ""))
                                  id)))
                        matisse--available-models))
         (choice (completing-read "Select model: " models nil t)))

    (when-let ((model-id (cdr (assoc choice models))))
      (unless (string= model-id current-model)
        (matisse--set-model-async model-id)))))

(defun matisse--set-model-async (model-id)
  "Asynchronously set model to MODEL-ID."
  (let* ((request-id (matisse--generate-request-id))
         (model-request
          `((type . "control_request")
            (request_id . ,request-id)
            (request . ((subtype . "set_model")
                       (model . ,model-id))))))

    ;; Store pending model change
    (setq matisse--pending-model-change model-id)

    ;; Send request
    (process-send-string matisse--process
                         (concat (json-encode model-request) "\n"))

    (message "Changing model to %s..." model-id)))

(defun matisse--handle-model-change-response (response-data success)
  "Handle model change response."
  (if success
      (progn
        (setq matisse--current-model-id matisse--pending-model-change)
        (setq matisse--pending-model-change nil)
        (matisse--update-mode-line)
        (message "Model changed to: %s"
                 (matisse--get-model-display-name matisse--current-model-id))
        ;; Insert indicator in conversation
        (matisse--insert-system-message
         (format "\n[Switched to model: %s]\n"
                 (matisse--get-model-display-name matisse--current-model-id))))
    (message "Failed to change model")
    (setq matisse--pending-model-change nil)))
```

#### 2.2 Quick Model Toggle
```elisp
(defun matisse-toggle-model ()
  "Quick toggle between two favorite models."
  (interactive)
  (let* ((primary-model "claude-3-5-sonnet-20241022")
         (secondary-model "claude-3-5-haiku-20241022")
         (target (if (string= matisse--current-model-id primary-model)
                     secondary-model
                   primary-model)))
    (matisse--set-model-async target)))

(defun matisse-use-powerful-model ()
  "Switch to most powerful available model."
  (interactive)
  (when-let ((powerful (car (sort matisse--available-models
                                  #'matisse--model-power-comparator))))
    (matisse--set-model-async (plist-get powerful :id))))
```

### Phase 3: Dynamic Permission Mode

#### 3.1 Permission Mode Control
```elisp
(defun matisse-set-permission-mode (mode)
  "Set permission mode to MODE.
Valid modes: default, plan, acceptEdits, bypassPermissions."
  (interactive
   (list (completing-read "Permission mode: "
                         '("default" "plan" "acceptEdits" "bypassPermissions")
                         nil t nil nil "default")))

  (matisse--set-permission-mode-async mode))

(defun matisse--set-permission-mode-async (mode)
  "Asynchronously set permission mode."
  (let* ((request-id (matisse--generate-request-id))
         (mode-request
          `((type . "control_request")
            (request_id . ,request-id)
            (request . ((subtype . "set_permission_mode")
                       (mode . ,mode))))))

    ;; Send request
    (process-send-string matisse--process
                         (concat (json-encode mode-request) "\n"))

    (message "Setting permission mode to: %s" mode)))

(defun matisse--handle-permission-mode-response (mode success)
  "Handle permission mode change response."
  (if success
      (progn
        (setq matisse-permission-mode mode)
        (message "Permission mode changed to: %s" mode)
        (matisse--insert-system-message
         (format "\n[Permission mode: %s]\n" mode)))
    (message "Failed to change permission mode")))

(defun matisse-toggle-bypass-mode ()
  "Toggle between default and bypass permission modes.
Useful for temporary trust during development."
  (interactive)
  (let ((new-mode (if (string= matisse-permission-mode "bypassPermissions")
                      "default"
                    "bypassPermissions")))
    (matisse--set-permission-mode-async new-mode)))
```

### Phase 4: Cancel Control Requests

#### 4.1 Cancelable Operations Tracking
```elisp
(defvar-local matisse--pending-control-requests nil
  "Alist of pending control requests that can be cancelled.")

(defun matisse--track-control-request (request-id type)
  "Track a control request that can be cancelled."
  (push (cons request-id type) matisse--pending-control-requests))

(defun matisse--untrack-control-request (request-id)
  "Remove completed control request from tracking."
  (setq matisse--pending-control-requests
        (assq-delete-all request-id matisse--pending-control-requests)))

(defun matisse-cancel-pending-request ()
  "Cancel a pending control request."
  (interactive)
  (if matisse--pending-control-requests
      (let* ((choices (mapcar (lambda (req)
                               (cons (format "%s (%s)"
                                           (car req)
                                           (cdr req))
                                     (car req)))
                             matisse--pending-control-requests))
             (choice (completing-read "Cancel request: " choices nil t)))
        (when-let ((request-id (cdr (assoc choice choices))))
          (matisse--send-cancel-request request-id)))
    (message "No pending requests to cancel")))

(defun matisse--send-cancel-request (request-id)
  "Send cancel request for REQUEST-ID."
  (let ((cancel-message
         `((type . "control_cancel_request")
           (request_id . ,request-id))))

    (process-send-string matisse--process
                         (concat (json-encode cancel-message) "\n"))

    (message "Cancelling request: %s" request-id)))
```

### Phase 5: Interrupt State Management

#### 5.1 State Tracking
```elisp
(defvar-local matisse--operation-stack nil
  "Stack of current operations for better interrupt handling.")

(defun matisse--push-operation (type details)
  "Push an operation onto the stack."
  (push (list :type type
              :details details
              :start-time (current-time))
        matisse--operation-stack))

(defun matisse--pop-operation ()
  "Pop completed operation from stack."
  (pop matisse--operation-stack))

(defun matisse--clear-operations ()
  "Clear all operations (after interrupt)."
  (setq matisse--operation-stack nil))

(defun matisse-show-current-operations ()
  "Show what Claude is currently doing."
  (interactive)
  (if matisse--operation-stack
      (let ((ops (mapcar (lambda (op)
                          (format "%s (%s)"
                                  (plist-get op :type)
                                  (format-seconds "%s"
                                                (time-subtract
                                                 (current-time)
                                                 (plist-get op :start-time)))))
                        matisse--operation-stack)))
        (message "Current operations: %s"
                 (string-join ops ", ")))
    (message "No operations in progress")))
```

#### 5.2 Smart Interrupt
```elisp
(defun matisse-smart-interrupt ()
  "Intelligently interrupt based on current operation."
  (interactive)
  (cond
   ;; If in permission prompt, deny
   ((matisse--in-permission-prompt-p)
    (matisse--deny-current-permission))

   ;; If tool is running, cancel it
   ((and matisse--active-tools
         (> (length matisse--active-tools) 0))
    (message "Interrupting tool execution...")
    (matisse-interrupt))

   ;; If Claude is generating, interrupt
   (matisse--process-busy
    (message "Interrupting response generation...")
    (matisse-interrupt))

   ;; Otherwise, normal quit
   (t
    (keyboard-quit))))
```

### Phase 6: UI Integration

#### 6.1 Interrupt Menu
```elisp
(defun matisse-interrupt-menu ()
  "Show interrupt/control menu."
  (interactive)
  (let ((choice (completing-read
                 "Action: "
                 '("Interrupt current operation"
                   "Change model"
                   "Set permission mode"
                   "Toggle bypass mode"
                   "Cancel pending request"
                   "Show current operations")
                 nil t)))
    (pcase choice
      ("Interrupt current operation" (matisse-interrupt))
      ("Change model" (matisse-change-model))
      ("Set permission mode" (matisse-set-permission-mode))
      ("Toggle bypass mode" (matisse-toggle-bypass-mode))
      ("Cancel pending request" (matisse-cancel-pending-request))
      ("Show current operations" (matisse-show-current-operations)))))
```

#### 6.2 Status Bar Integration
```elisp
(defun matisse--mode-line-interrupt-indicator ()
  "Generate interrupt indicator for mode line."
  (when matisse--interrupting
    (propertize " [INTERRUPTING]" 'face 'warning)))

(defun matisse--mode-line-permission-indicator ()
  "Generate permission mode indicator."
  (when (not (string= matisse-permission-mode "default"))
    (propertize (format " [%s]"
                       (pcase matisse-permission-mode
                         ("bypassPermissions" "BYPASS")
                         ("plan" "PLAN")
                         ("acceptEdits" "EDITS")
                         (_ matisse-permission-mode)))
                'face 'warning)))
```

## Benefits

### User Control
- Can stop runaway operations
- Change models based on task complexity
- Adjust permission level for different workflows
- Cancel specific operations without losing context

### Better UX
- Responsive to user interrupts
- Visual feedback for all operations
- Graceful handling of cancellations
- No need to restart for configuration changes

### Developer Experience
- Debug long-running operations
- Test with different models easily
- Temporarily bypass permissions during development
- Better control during testing

## Testing Strategy

1. **Interrupt Testing**
   - During tool execution
   - During response generation
   - Multiple rapid interrupts
   - Interrupt with pending requests

2. **Model Switching**
   - Mid-conversation switching
   - Switch during tool use
   - Invalid model handling

3. **Permission Mode**
   - Mode changes affect behavior
   - Persistence across operations
   - Mode indicator accuracy

## Implementation Timeline

- **Day 1**: Basic interrupt infrastructure
- **Day 2**: Model switching
- **Day 3**: Permission mode control
- **Day 4**: Cancel requests and state management
- **Day 5**: UI integration and testing

## Success Metrics

1. Interrupt response time < 500ms
2. Model switches preserve conversation context
3. Permission mode changes take effect immediately
4. All operations can be cancelled cleanly
5. No orphaned operations after interrupt