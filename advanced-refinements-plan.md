# Matisse: Advanced Refinements Based on SDK Analysis

## Executive Summary

This document outlines advanced refinements for matisse.el based on patterns discovered in the Claude Code SDK. Many of these are nice-to-have improvements that build on the existing JSON streaming infrastructure matisse already has.

## Key Discoveries from SDK

### Architectural Patterns We Can Adopt
- Request/response correlation using request IDs (useful for control messages)
- Better streaming JSON handling with partial messages
- Session management with checkpoints
- MCP server integration (if needed)
- More comprehensive error recovery
- Better debugging infrastructure

## Implementation Areas

### Area 1: Request/Response Correlation

Since we're now using control messages, tracking request IDs becomes useful:

#### 1.1 Request ID Management
```elisp
(defvar-local matisse--request-counter 0
  "Counter for generating unique request IDs.")

(defvar-local matisse--pending-requests (make-hash-table :test 'equal)
  "Hash table mapping request IDs to pending request data.")

(defun matisse--generate-request-id ()
  "Generate a unique request ID."
  (cl-incf matisse--request-counter)
  (format "req_%s_%d_%s"
          (buffer-name)
          matisse--request-counter
          (format-time-string "%Y%m%d%H%M%S")))

(cl-defstruct matisse-request
  "Structure for tracking requests."
  id type timestamp callback timeout-timer)

(defun matisse--track-request (request-id type &optional callback timeout)
  "Track a request with REQUEST-ID and TYPE.
Optional CALLBACK called on response.
Optional TIMEOUT in seconds for automatic cleanup."
  (let ((request (make-matisse-request
                  :id request-id
                  :type type
                  :timestamp (current-time)
                  :callback callback)))

    ;; Set timeout if specified
    (when timeout
      (setf (matisse-request-timeout-timer request)
            (run-with-timer timeout nil
                           (lambda ()
                             (matisse--handle-request-timeout request-id)))))

    (puthash request-id request matisse--pending-requests)))

(defun matisse--complete-request (request-id response)
  "Complete request with REQUEST-ID using RESPONSE."
  (when-let ((request (gethash request-id matisse--pending-requests)))
    ;; Cancel timeout timer if exists
    (when (matisse-request-timeout-timer request)
      (cancel-timer (matisse-request-timeout-timer request)))

    ;; Call callback if exists
    (when (matisse-request-callback request)
      (funcall (matisse-request-callback request) response))

    ;; Remove from pending
    (remhash request-id matisse--pending-requests)))

(defun matisse--handle-request-timeout (request-id)
  "Handle timeout for REQUEST-ID."
  (when-let ((request (gethash request-id matisse--pending-requests)))
    (message "Request timeout: %s (%s)"
             request-id (matisse-request-type request))
    (remhash request-id matisse--pending-requests)))
```

### Area 2: Enhanced Streaming and Partial Messages

#### 2.1 Robust JSON Streaming Parser
```elisp
(defvar-local matisse--json-parser-state nil
  "State machine for JSON parsing.")

(defvar-local matisse--json-buffer ""
  "Buffer for accumulating JSON data.")

(defvar-local matisse--json-depth 0
  "Current nesting depth in JSON structure.")

(defun matisse--parse-json-stream (data)
  "Parse streaming JSON DATA with better error handling.
Returns list of complete JSON objects."
  (let ((complete-objects '())
        (buffer (concat matisse--json-buffer data))
        (start 0))

    ;; Find complete JSON objects
    (while (string-match "^[[:space:]]*{" buffer start)
      (let ((object-start (match-beginning 0))
            (depth 0)
            (in-string nil)
            (escape nil)
            (pos (match-beginning 0))
            (complete nil))

        ;; Parse to find complete object
        (while (and (< pos (length buffer)) (not complete))
          (let ((char (aref buffer pos)))
            (cond
             ;; Handle escape sequences
             (escape
              (setq escape nil))

             ;; Handle string content
             (in-string
              (cond
               ((= char ?\\) (setq escape t))
               ((= char ?\") (setq in-string nil))))

             ;; Not in string
             (t
              (cond
               ((= char ?\") (setq in-string t))
               ((= char ?{) (cl-incf depth))
               ((= char ?}) (cl-decf depth)
                            (when (= depth 0)
                              (setq complete t)))))))
          (cl-incf pos))

        ;; Extract complete object if found
        (if complete
            (let ((object-str (substring buffer object-start (1+ pos))))
              (condition-case err
                  (progn
                    (push (json-read-from-string object-str) complete-objects)
                    (setq start (1+ pos)))
                (error
                 (matisse--debug-log "JSON parse error: %s" err)
                 (setq start (1+ pos)))))
          ;; No complete object, save remainder
          (setq matisse--json-buffer (substring buffer object-start))
          (setq start (length buffer)))))

    ;; Update buffer with unparsed remainder
    (setq matisse--json-buffer
          (if (< start (length buffer))
              (substring buffer start)
            ""))

    (nreverse complete-objects)))
```

#### 2.2 Partial Message Handling
```elisp
(defvar-local matisse--partial-message nil
  "Current partial message being assembled.")

(defvar-local matisse--partial-message-timer nil
  "Timer for partial message updates.")

(defun matisse--handle-partial-message (message)
  "Handle partial streaming message."
  (let ((message-id (alist-get 'id message))
        (content (alist-get 'content message))
        (is-final (alist-get 'stop_reason message)))

    ;; Cancel existing timer
    (when matisse--partial-message-timer
      (cancel-timer matisse--partial-message-timer)
      (setq matisse--partial-message-timer nil))

    (if is-final
        ;; Final message, display and clear
        (progn
          (matisse--update-assistant-message message-id content t)
          (setq matisse--partial-message nil))

      ;; Partial message, accumulate and set timer
      (setq matisse--partial-message message)
      (setq matisse--partial-message-timer
            (run-with-timer 0.1 nil
                           (lambda ()
                             (matisse--update-assistant-message
                              message-id content nil)))))))

(defun matisse--update-assistant-message (message-id content is-final)
  "Update assistant message with MESSAGE-ID and CONTENT.
IS-FINAL indicates if this is the complete message."
  (let ((section (gethash message-id matisse--message-sections)))
    (if section
        ;; Update existing section
        (save-excursion
          (let ((inhibit-read-only t))
            (delete-region (plist-get section :start)
                          (plist-get section :end))
            (goto-char (plist-get section :start))
            (matisse--insert-assistant-content content is-final)
            (puthash message-id
                    (list :start (plist-get section :start)
                          :end (point)
                          :type 'assistant)
                    matisse--message-sections)))

      ;; Create new section
      (matisse--create-message-section message-id content 'assistant))))
```

### Area 3: Session Management

#### 3.1 Session Persistence
```elisp
(defcustom matisse-session-directory
  (expand-file-name "matisse-sessions" user-emacs-directory)
  "Directory for storing matisse session files."
  :type 'directory
  :group 'matisse)

(defvar-local matisse--session-id nil
  "Current session ID.")

(defvar-local matisse--session-file nil
  "Current session file path.")

(defun matisse--initialize-session ()
  "Initialize a new session or resume existing."
  (unless (file-exists-p matisse-session-directory)
    (make-directory matisse-session-directory t))

  (setq matisse--session-id
        (format "%s-%s"
                (format-time-string "%Y%m%d-%H%M%S")
                (buffer-name)))

  (setq matisse--session-file
        (expand-file-name
         (format "%s.json" matisse--session-id)
         matisse-session-directory)))

(defun matisse--save-session-message (message)
  "Save MESSAGE to session file."
  (when matisse--session-file
    (let ((json-encoding-pretty-print nil))
      (with-temp-buffer
        (insert (json-encode message) "\n")
        (append-to-file (point-min) (point-max) matisse--session-file)))))

(defun matisse--create-checkpoint ()
  "Create a session checkpoint."
  (interactive)
  (let ((checkpoint
         `((type . "checkpoint")
           (id . ,(matisse--generate-request-id))
           (timestamp . ,(format-time-string "%Y-%m-%dT%H:%M:%S"))
           (buffer . ,(buffer-name))
           (conversation . ,(matisse--get-conversation-state)))))

    (matisse--save-session-message checkpoint)
    (message "Checkpoint created: %s" (alist-get 'id checkpoint))))

(defun matisse-resume-session ()
  "Resume a previous session."
  (interactive)
  (let* ((sessions (directory-files matisse-session-directory nil "\\.json$"))
         (choice (completing-read "Resume session: " sessions nil t)))
    (when choice
      (matisse--load-session
       (expand-file-name choice matisse-session-directory)))))
```

#### 3.2 Conversation State Management
```elisp
(defun matisse--get-conversation-state ()
  "Get current conversation state for persistence."
  (let ((messages '()))
    (maphash (lambda (id section)
              (push `((id . ,id)
                     (type . ,(plist-get section :type))
                     (content . ,(matisse--extract-section-content section)))
                    messages))
            matisse--message-sections)
    (nreverse messages)))

(defun matisse--restore-conversation-state (state)
  "Restore conversation from STATE."
  (clrhash matisse--message-sections)
  (goto-char (point-max))
  (dolist (message state)
    (let ((type (alist-get 'type message))
          (content (alist-get 'content message)))
      (pcase type
        ('user (matisse--insert-user-message content))
        ('assistant (matisse--insert-assistant-content content t))
        ('system (matisse--insert-system-message content))))))
```

### Area 4: MCP Server Integration

#### 4.1 MCP Server Support
```elisp
(defcustom matisse-mcp-servers nil
  "Alist of MCP server configurations.
Each element is (NAME . CONFIG) where CONFIG is a plist with
:command, :args, :env properties."
  :type '(alist :key-type string :value-type plist)
  :group 'matisse)

(defvar-local matisse--mcp-servers (make-hash-table :test 'equal)
  "Active MCP servers for this session.")

(defun matisse--initialize-mcp-servers ()
  "Initialize configured MCP servers."
  (dolist (server-config matisse-mcp-servers)
    (let ((name (car server-config))
          (config (cdr server-config)))
      (matisse--start-mcp-server name config))))

(defun matisse--start-mcp-server (name config)
  "Start MCP server with NAME and CONFIG."
  (let* ((command (plist-get config :command))
         (args (plist-get config :args))
         (env (plist-get config :env))
         (process (make-process
                   :name (format "mcp-%s" name)
                   :command (cons command args)
                   :filter #'matisse--mcp-filter
                   :sentinel #'matisse--mcp-sentinel
                   :environment env)))

    (process-put process 'mcp-server-name name)
    (puthash name process matisse--mcp-servers)

    (matisse--debug-log "Started MCP server: %s" name)))

(defun matisse--handle-mcp-request (server-name request)
  "Handle MCP request for SERVER-NAME."
  (when-let ((process (gethash server-name matisse--mcp-servers)))
    (process-send-string process (json-encode request))))
```

### Area 5: Error Handling and Recovery

#### 5.1 Comprehensive Error Handling
```elisp
(defvar-local matisse--error-recovery-strategies
  '((network-error . matisse--recover-network-error)
    (json-error . matisse--recover-json-error)
    (process-died . matisse--recover-process-died)
    (timeout . matisse--recover-timeout))
  "Error recovery strategies.")

(defun matisse--handle-error-with-recovery (error-type error-data)
  "Handle ERROR-TYPE with ERROR-DATA and attempt recovery."
  (let ((strategy (alist-get error-type matisse--error-recovery-strategies)))
    (if strategy
        (funcall strategy error-data)
      (matisse--handle-generic-error error-type error-data))))

(defun matisse--recover-network-error (error-data)
  "Recover from network error."
  (message "Network error detected, retrying...")
  (run-with-timer 2 nil #'matisse--retry-last-request))

(defun matisse--recover-json-error (error-data)
  "Recover from JSON parsing error."
  (message "JSON error, clearing buffer and continuing...")
  (setq matisse--json-buffer "")
  (setq matisse--pending-json ""))

(defun matisse--recover-process-died (error-data)
  "Recover from process death."
  (when (y-or-n-p "Claude process died. Restart?")
    (matisse--restart-with-context)))

(defun matisse--restart-with-context ()
  "Restart Claude preserving conversation context."
  (let ((state (matisse--get-conversation-state)))
    (matisse--cleanup-process)
    (matisse--start-claude-code-process)
    (matisse--restore-conversation-state state)))
```

#### 5.2 Retry Logic
```elisp
(defvar-local matisse--retry-queue nil
  "Queue of operations to retry.")

(cl-defstruct matisse-retry
  "Retry information."
  operation attempt max-attempts delay callback)

(defun matisse--retry-with-backoff (operation &optional callback)
  "Retry OPERATION with exponential backoff."
  (let ((retry (make-matisse-retry
                :operation operation
                :attempt 0
                :max-attempts 3
                :delay 1
                :callback callback)))
    (matisse--execute-retry retry)))

(defun matisse--execute-retry (retry)
  "Execute a retry attempt."
  (cl-incf (matisse-retry-attempt retry))

  (condition-case err
      (funcall (matisse-retry-operation retry))
    (error
     (if (< (matisse-retry-attempt retry)
            (matisse-retry-max-attempts retry))
         ;; Schedule next retry
         (let ((delay (* (matisse-retry-delay retry)
                        (expt 2 (1- (matisse-retry-attempt retry))))))
           (message "Retry %d/%d in %d seconds..."
                   (matisse-retry-attempt retry)
                   (matisse-retry-max-attempts retry)
                   delay)
           (run-with-timer delay nil
                          #'matisse--execute-retry retry))
       ;; Max retries reached
       (message "Operation failed after %d retries: %s"
               (matisse-retry-max-attempts retry)
               (error-message-string err))
       (when (matisse-retry-callback retry)
         (funcall (matisse-retry-callback retry) nil))))))
```

### Area 6: Diagnostic and Debug Infrastructure

#### 6.1 Diagnostic System
```elisp
(defvar-local matisse--diagnostics (make-hash-table :test 'equal)
  "Diagnostic information for debugging.")

(defvar-local matisse--metrics (make-hash-table :test 'equal)
  "Performance metrics.")

(defun matisse--record-metric (name value)
  "Record performance metric NAME with VALUE."
  (let ((metrics (gethash name matisse--metrics '())))
    (puthash name (cons value metrics) matisse--metrics)))

(defun matisse--start-timer (name)
  "Start a timer for metric NAME."
  (puthash (format "%s-start" name) (current-time) matisse--diagnostics))

(defun matisse--stop-timer (name)
  "Stop timer for metric NAME and record elapsed time."
  (when-let ((start (gethash (format "%s-start" name) matisse--diagnostics)))
    (let ((elapsed (float-time (time-subtract (current-time) start))))
      (matisse--record-metric name elapsed)
      (remhash (format "%s-start" name) matisse--diagnostics)
      elapsed)))

(defun matisse-show-diagnostics ()
  "Show diagnostic information."
  (interactive)
  (with-current-buffer (get-buffer-create "*matisse-diagnostics*")
    (erase-buffer)
    (insert "=== Matisse Diagnostics ===\n\n")

    ;; Metrics
    (insert "Performance Metrics:\n")
    (maphash (lambda (name values)
              (when values
                (let* ((sorted (sort values #'<))
                       (avg (/ (apply #'+ sorted) (length sorted)))
                       (median (nth (/ (length sorted) 2) sorted)))
                  (insert (format "  %s: avg=%.3fs median=%.3fs n=%d\n"
                                 name avg median (length values))))))
            matisse--metrics)

    ;; Current state
    (insert "\nCurrent State:\n")
    (insert (format "  Process: %s\n"
                   (if (process-live-p matisse--process) "alive" "dead")))
    (insert (format "  Busy: %s\n" matisse--process-busy))
    (insert (format "  Model: %s\n" matisse--current-model-id))
    (insert (format "  Permission mode: %s\n" matisse-permission-mode))
    (insert (format "  Pending requests: %d\n"
                   (hash-table-count matisse--pending-requests)))

    (display-buffer (current-buffer))))
```

#### 6.2 Protocol Logger
```elisp
(defcustom matisse-protocol-log-file nil
  "File to log all protocol messages for debugging."
  :type '(choice (const nil) file)
  :group 'matisse)

(defun matisse--log-protocol-message (direction message)
  "Log protocol MESSAGE in DIRECTION to file if configured."
  (when matisse-protocol-log-file
    (let ((log-entry
           (format "[%s] %s %s\n"
                   (format-time-string "%Y-%m-%d %H:%M:%S.%3N")
                   (if (eq direction 'in) "<<<" ">>>")
                   (json-encode message))))
      (append-to-file log-entry nil matisse-protocol-log-file))))

(defun matisse-toggle-protocol-logging ()
  "Toggle protocol logging on/off."
  (interactive)
  (if matisse-protocol-log-file
      (progn
        (setq matisse-protocol-log-file nil)
        (message "Protocol logging disabled"))
    (setq matisse-protocol-log-file
          (expand-file-name "matisse-protocol.log" temporary-file-directory))
    (message "Protocol logging to: %s" matisse-protocol-log-file)))
```

## Benefits Summary

### Reliability
- Robust error handling and recovery
- Request/response correlation
- Retry logic with backoff
- Session persistence and recovery

### Advanced Features
- MCP server integration
- Partial message streaming
- Session checkpoints
- Comprehensive diagnostics

### Developer Experience
- Protocol logging
- Performance metrics
- Diagnostic commands
- Debug infrastructure

## Implementation Priority

1. **High Priority**
   - Request/response correlation
   - Enhanced JSON streaming
   - Basic error recovery

2. **Medium Priority**
   - Session management
   - Diagnostic system
   - Retry logic

3. **Low Priority**
   - MCP server integration
   - Advanced metrics
   - Protocol logging

## Testing Strategy

1. **Reliability Testing**
   - Process crashes and recovery
   - Network interruptions
   - Malformed JSON handling

2. **Performance Testing**
   - Large message handling
   - Streaming performance
   - Memory usage

3. **Integration Testing**
   - Session persistence
   - MCP servers
   - Error recovery

## Success Metrics

1. Zero data loss on process crash
2. < 100ms JSON parsing latency
3. Successful recovery from 90% of errors
4. Session resume works across Emacs restarts
5. Diagnostic data helps resolve issues quickly