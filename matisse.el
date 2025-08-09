;;; matisse.el --- Emacs interface to Claude Code using shell-maker -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Steve Molitor
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.0") (shell-maker "0.78.2"))
;; Keywords: ai, tools, claude
;; URL: https://github.com/stevemolitor/matisse

;;; Commentary:

;; Matisse provides a comint-based Emacs interface to Claude Code using shell-maker.
;; It communicates with Claude Code via streaming JSON input/output for real-time responses.

;;; Code:

(require 'shell-maker)
(require 'markdown-overlays)
(require 'json)
(require 'map)
(require 'seq)
(require 'cl-lib)

;;; Customization

(defgroup matisse nil
  "Claude Code shell interface."
  :group 'tools)

(defcustom matisse-claude-code-path "claude"
  "Path to the Claude Code executable."
  :type 'string
  :group 'matisse)

(defcustom matisse-api-key nil
  "API key for Claude Code.
You can set this in your init file or use auth-source."
  :type '(choice (string :tag "API Key")
                 (function :tag "Function")
                 (const :tag "Use auth-source" nil))
  :group 'matisse)

(defcustom matisse-model "claude-sonnet-4-20250514"
  "The Claude model to use."
  :type 'string
  :group 'matisse)

(defcustom matisse-temperature nil
  "Temperature parameter for Claude (0.0 to 1.0).
Higher values make output more random, lower values more deterministic.
nil means use Claude's default."
  :type '(choice (float :tag "Temperature")
                 (const :tag "Default" nil))
  :group 'matisse)

(defcustom matisse-max-tokens nil
  "Maximum number of tokens in the response.
nil means use Claude's default."
  :type '(choice (integer :tag "Max tokens")
                 (const :tag "Default" nil))
  :group 'matisse)

(defcustom matisse-system-prompt nil
  "System prompt to prepend to conversations."
  :type '(choice (string :tag "System prompt")
                 (const :tag "None" nil))
  :group 'matisse)

(defcustom matisse-streaming t
  "Whether to use streaming responses."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-debug nil
  "Enable debug logging for troubleshooting."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-permission-mode "default"
  "Permission mode for Claude Code.
Options are:
- \"default\": Normal permissions with confirmation prompts
- \"bypassPermissions\": Skip all permission checks (use with caution)
- \"plan\": Plan mode for planning tasks"
  :type '(choice (const :tag "Default" "default")
                 (const :tag "Bypass Permissions" "bypassPermissions")
                 (const :tag "Plan Mode" "plan"))
  :group 'matisse)

(defcustom matisse-show-progress-indicators t
  "Whether to show progress indicators for tool usage."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-show-file-changes t
  "Whether to show file change summaries."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-show-performance-summary nil
  "Whether to show performance summary (timing, cost, tokens)."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-progress-icons t
  "Whether to use icons in progress indicators."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-allowed-tools nil
  "List of allowed tools for Claude Code.
If nil, all tools are allowed. Otherwise, specify tools like:
\"Read,Write,Edit,MultiEdit,Bash(git commit:*),Grep,Glob,Task,WebFetch,TodoWrite\""
  :type '(choice (string :tag "Allowed tools")
                 (const :tag "All tools" nil))
  :group 'matisse)

;;; Internal variables

(defvar-local matisse--process nil
  "The Claude Code process.")

(defvar-local matisse--pending-json ""
  "Buffer for incomplete JSON data.")

(defvar matisse--config nil
  "Shell configuration for matisse.")

(defvar-local matisse--conversation-id nil
  "Current conversation ID.")

(defvar-local matisse--message-count 0
  "Count of messages in current conversation.")

(defvar-local matisse--waiting-for-response nil
  "Whether we're currently waiting for a response from Claude.")

(defvar-local matisse--spinner-timer nil
  "Timer for the spinner animation.")

(defvar-local matisse--spinner-index 0
  "Current index in the spinner sequence.")

(defconst matisse--spinner-chars '("/" "|" "\\" "-")
  "Characters used for the spinner animation.")

(defvar-local matisse--active-tools nil
  "List of currently active tool operations.")

(defvar-local matisse--progress-buffer ""
  "Buffer for accumulating progress messages before display.")

(defvar-local matisse--shell-context nil
  "Current shell context for callbacks.")

;;; Minor mode

(defvar matisse--mode-line-format nil
  "Current mode line format for matisse-mode.")

(defun matisse--update-mode-line ()
  "Update the mode line with current spinner state."
  (setq matisse--mode-line-format
        (if matisse--waiting-for-response
            (concat " 🤖" (nth matisse--spinner-index matisse--spinner-chars))
          " 🤖"))
  (force-mode-line-update t))

(defun matisse--make-spinner-tick (buffer)
  "Create a spinner tick function for BUFFER."
  (lambda ()
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq matisse--spinner-index (mod (1- matisse--spinner-index) 
                                         (length matisse--spinner-chars)))
        (matisse--update-mode-line)))))

(defun matisse--start-spinner ()
  "Start the spinner animation."
  (when matisse--spinner-timer
    (cancel-timer matisse--spinner-timer))
  (setq matisse--spinner-timer 
        (run-at-time 0.1 0.1 (matisse--make-spinner-tick (current-buffer))))
  (matisse--update-mode-line))

(defun matisse--stop-spinner ()
  "Stop the spinner animation."
  (when matisse--spinner-timer
    (cancel-timer matisse--spinner-timer)
    (setq matisse--spinner-timer nil))
  (matisse--update-mode-line))

(define-minor-mode matisse-mode
  "Minor mode for Matisse Claude Code interface."
  :lighter (:eval matisse--mode-line-format)
  :global nil
  (if matisse-mode
      (progn
        (matisse--update-mode-line)
        ;; We don't want shell-maker to prompt to save its transcript. Claude already has transcripts.
        (setq-local shell-maker-prompt-before-killing-buffer nil)
        ;; Add buffer-local kill hook to stop spinner
        (add-hook 'kill-buffer-hook #'matisse--stop-spinner nil t))
    (progn
      (when matisse--spinner-timer
        (cancel-timer matisse--spinner-timer)
        (setq matisse--spinner-timer nil))
      ;; Remove the kill hook
      (remove-hook 'kill-buffer-hook #'matisse--stop-spinner t))))

;;; Utility functions

(defun matisse--get-api-key ()
  "Get the API key for Claude Code."
  (cond
   ((functionp matisse-api-key)
    (funcall matisse-api-key))
   ((stringp matisse-api-key)
    matisse-api-key)
   ((getenv "ANTHROPIC_API_KEY")
    (getenv "ANTHROPIC_API_KEY"))
   (t
    ;; Try auth-source
    (require 'auth-source)
    (let ((auth (car (auth-source-search :host "anthropic.com"
                                         :user "apikey"
                                         :require '(:secret)))))
      (when auth
        (funcall (plist-get auth :secret)))))))

(defun matisse--validate-setup ()
  "Validate that Claude Code is properly set up."
  (unless (executable-find matisse-claude-code-path)
    (error "Claude Code executable not found at: %s" matisse-claude-code-path))
  (unless (matisse--get-api-key)
    (error "No API key configured. Set `matisse-api-key' or use auth-source")))

;;; Progress context parsing and formatting

(defun matisse--at-end-of-line-p ()
  "Check if the shell buffer position is at end of line.
Returns t if the buffer is empty or the last character is a newline."
  ;; Since we're working within the shell buffer context during output,
  ;; we can check the current buffer state directly
  (condition-case nil
      (save-excursion
        (goto-char (point-max))
        (or (= (point) (point-min))  ; empty buffer
            (= (char-before) ?\n)))   ; ends with newline
    (error t)))  ; Default to true (add newline) if we can't determine

(defun matisse--get-tool-icon (tool-name)
  "Get the appropriate icon for TOOL-NAME."
  (if matisse-progress-icons
      (pcase tool-name
        ("Read" "📖")
        ("Write" "✍️")
        ("Edit" "✏️")
        ("MultiEdit" "✏️")
        ("Bash" "💻")
        ("Grep" "🔍")
        ("Glob" "📁")
        ("Task" "🤖")
        ("WebFetch" "🌐")
        ("TodoWrite" "📝")
        (_ "🔧"))
    ""))

(defun matisse--format-progress-indicator (tool-name input-data)
  "Format a progress indicator for TOOL-NAME with INPUT-DATA."
  (when matisse-show-progress-indicators
    (let* ((icon (matisse--get-tool-icon tool-name))
           (action (pcase tool-name
                     ("Read" "Reading")
                     ("Write" "Writing")
                     ("Edit" "Editing")
                     ("MultiEdit" "Editing")
                     ("Bash" "Running")
                     ("Grep" "Searching")
                     ("Glob" "Finding files")
                     ("Task" "Starting task")
                     ("WebFetch" "Fetching")
                     ("TodoWrite" "Updating todos")
                     (_ "Using")))
           (target (pcase tool-name
                     ("Read" (alist-get 'file_path input-data))
                     ("Write" (alist-get 'file_path input-data))
                     ("Edit" (alist-get 'file_path input-data))
                     ("MultiEdit" (alist-get 'file_path input-data))
                     ("Bash" (let ((cmd (alist-get 'command input-data)))
                              (if (> (length cmd) 50)
                                  (concat (substring cmd 0 47) "...")
                                cmd)))
                     ("Grep" (format "\"%s\"" (alist-get 'pattern input-data)))
                     ("Glob" (format "\"%s\"" (alist-get 'pattern input-data)))
                     ("Task" (alist-get 'description input-data))
                     ("WebFetch" (alist-get 'url input-data))
                     ("TodoWrite" "todo list")
                     (_ tool-name))))
      (if target
          (format "%s %s %s..." (if (string-empty-p icon) "" (concat icon " ")) action target)
        (format "%s %s %s..." (if (string-empty-p icon) "" (concat icon " ")) action tool-name)))))

(defun matisse--format-file-change-summary (tool-name result-content)
  "Format a file change summary for TOOL-NAME with RESULT-CONTENT."
  (when (and matisse-show-file-changes
             (member tool-name '("Edit" "MultiEdit" "Write")))
    (cond
     ;; Handle Edit/MultiEdit results that show file updates
     ((string-match "The file \\(.+\\) has been updated" result-content)
      (let ((file-path (match-string 1 result-content))
            (icon (if matisse-progress-icons "✅ " "")))
        (format "%sUpdated %s" icon (file-name-nondirectory file-path))))
     
     ;; Handle Write operations  
     ((and (equal tool-name "Write")
           (string-match "file" result-content))
      (let ((icon (if matisse-progress-icons "✅ " "")))
        (format "%sFile written successfully" icon)))
     
     ;; Generic success for file operations
     ((member tool-name '("Edit" "MultiEdit" "Write"))
      (let ((icon (if matisse-progress-icons "✅ " "")))
        (format "%sFile operation completed" icon))))))

(defun matisse--format-performance-summary (result-data)
  "Format a performance summary from RESULT-DATA."
  (when matisse-show-performance-summary
    (let* ((duration (alist-get 'duration_ms result-data))
           (cost (alist-get 'total_cost_usd result-data))
           (usage (alist-get 'usage result-data))
           (output-tokens (when usage (alist-get 'output_tokens usage)))
           (icon (if matisse-progress-icons "⏱️ " ""))
           (parts '()))
      
      (when duration
        (push (format "%.1fs" (/ duration 1000.0)) parts))
      
      (when cost
        (push (format "$%.4f" cost) parts))
      
      (when output-tokens
        (push (format "%d tokens" output-tokens) parts))
      
      (when parts
        (format "%sCompleted in %s" icon (string-join (reverse parts) ", "))))))

(defun matisse--extract-tool-use (json-obj)
  "Extract tool use information from assistant message JSON-OBJ."
  (when (equal (alist-get 'type json-obj) "assistant")
    (let* ((message (alist-get 'message json-obj))
           (content (alist-get 'content message)))
      (when (vectorp content)
        (seq-filter (lambda (item)
                      (equal (alist-get 'type item) "tool_use"))
                    content)))))

(defun matisse--extract-tool-result (json-obj)
  "Extract tool result information from user message JSON-OBJ."
  (when (equal (alist-get 'type json-obj) "user")
    (let* ((message (alist-get 'message json-obj))
           (content (alist-get 'content message)))
      (when (vectorp content)
        (seq-find (lambda (item)
                    (equal (alist-get 'type item) "tool_result"))
                  content)))))

;;; JSON handling

(defun matisse--format-user-message (text)
  "Format TEXT as a JSON message for Claude Code."
  (json-encode
   `((type . "user")
     (message . ((role . "user")
                (content . [((type . "text")
                            (text . ,text))]))))))

(defun matisse--parse-json-line (line)
  "Parse a single LINE of JSON output from Claude Code."
  (condition-case err
      (json-read-from-string line)
    (json-error
     (message "Failed to parse JSON: %s" line)
     nil)))

(defun matisse--extract-assistant-text (json-obj)
  "Extract assistant text from JSON-OBJ."
  (when (and json-obj
             (equal (alist-get 'type json-obj) "assistant"))
    (let* ((message (alist-get 'message json-obj))
           (content (alist-get 'content message)))
      (when (vectorp content)
        (seq-reduce
         (lambda (acc item)
           (if (equal (alist-get 'type item) "text")
               (let ((text (alist-get 'text item)))
                 (if (string-empty-p acc)
                     text
                   ;; Always concatenate directly - Claude Code should handle spacing
                   (concat acc text)))
             acc))
         content
         "")))))

(defun matisse--debug-log (format-str &rest args)
  "Log debug message if debugging is enabled."
  (when matisse-debug
    ;; Convert args to strings and escape % characters to prevent format errors
    (let ((safe-args (mapcar (lambda (arg)
                               (let ((str-arg (if (stringp arg)
                                                 arg
                                               (prin1-to-string arg))))
                                 (replace-regexp-in-string "%" "%%" str-arg)))
                             args)))
      (if safe-args
          (apply #'message (cons format-str safe-args))
        (message "%s" format-str)))))

(defun matisse--process-filter (process output)
  "Process filter for handling OUTPUT from Claude Code PROCESS."
  (let ((buffer (process-get process 'matisse-buffer)))
    (when (and buffer (buffer-live-p buffer))
      (with-current-buffer buffer
        (matisse--debug-log "Raw output: %s" output)
        (let ((pending (concat matisse--pending-json output))
              (lines '())
              (start 0))
    ;; Split output into lines
    (while (string-match "\n" pending start)
      (let ((line (substring pending start (match-beginning 0))))
        (unless (string-empty-p line)
          (push line lines))
        (setq start (match-end 0))))
    ;; Save any incomplete line for next iteration
    (setq matisse--pending-json (substring pending start))

    ;; Process complete lines
    (dolist (line (nreverse lines))
      (matisse--debug-log "Processing line: %s" line)
      (let ((json-obj (matisse--parse-json-line line)))
        (when json-obj
          (matisse--debug-log "Parsed JSON: %s" json-obj)
          (cond
           ;; Handle init/system message
           ((and (equal (alist-get 'type json-obj) "system")
                 (equal (alist-get 'subtype json-obj) "init"))
            ;; (message "Claude Code initialized: %s"
            ;;          (alist-get 'session_id json-obj))
            (setq matisse--conversation-id (alist-get 'session_id json-obj)))

           ;; Handle assistant messages
           ((equal (alist-get 'type json-obj) "assistant")
            ;; Check for tool usage and show progress indicators
            (let ((tool-uses (matisse--extract-tool-use json-obj)))
              (dolist (tool-use tool-uses)
                (let* ((tool-name (alist-get 'name tool-use))
                       (tool-input (alist-get 'input tool-use))
                       (tool-id (alist-get 'id tool-use))
                       (progress-msg (matisse--format-progress-indicator tool-name tool-input)))
                  (when progress-msg
                    (matisse--debug-log "Tool progress: %s" progress-msg)
                    ;; Add to active tools for tracking
                    (push `((id . ,tool-id) (name . ,tool-name) (input . ,tool-input)) matisse--active-tools)
                    ;; Display progress indicator
                    (when (and matisse--shell-context
                               (alist-get :write-output matisse--shell-context))
                      (condition-case err
                          (let ((prefix (if (matisse--at-end-of-line-p) "" "\n")))
                            (funcall (alist-get :write-output matisse--shell-context)
                                     (concat prefix progress-msg "\n")))
                        (error (matisse--debug-log "Error writing progress: %s" err))))))))
            
            (let ((text (matisse--extract-assistant-text json-obj)))
              (matisse--debug-log "Assistant text: %s" text)
              (matisse--debug-log "Shell context exists: %s" (if matisse--shell-context "yes" "no"))
              (when matisse--shell-context
                (matisse--debug-log "write-output function: %s" (alist-get :write-output matisse--shell-context)))
              (when (and text 
                         (not (string-empty-p text))
                         matisse--shell-context
                         (alist-get :write-output matisse--shell-context))
                (matisse--debug-log "Writing output to shell: %s" text)
                (condition-case err
                    (progn
                      (funcall (alist-get :write-output matisse--shell-context)
                               text)
                      (matisse--debug-log "Output written successfully"))
                  (error (matisse--debug-log "Error writing output: %s" err))))))

           ;; Handle result/completion
           ((equal (alist-get 'type json-obj) "result")
            (matisse--debug-log "Got result, finishing output")
            ;; Show performance summary if enabled
            (let ((perf-summary (matisse--format-performance-summary json-obj)))
              (when (and perf-summary
                         matisse--shell-context
                         (alist-get :write-output matisse--shell-context))
                (condition-case err
                    (funcall (alist-get :write-output matisse--shell-context)
                             (concat perf-summary "\n"))
                  (error (matisse--debug-log "Error writing performance summary: %s" err)))))
            ;; Apply markdown overlays to the response
            (condition-case err
                (markdown-overlays-put)
              (error (matisse--debug-log "Error applying markdown overlays: %s" err)))
            ;; Clear active tools and reset state
            (setq matisse--active-tools nil
                  matisse--waiting-for-response nil)
            (matisse--stop-spinner)
            (when (and matisse--shell-context
                       (alist-get :finish-output matisse--shell-context))
              (condition-case err
                  (funcall (alist-get :finish-output matisse--shell-context) t)
                (error (matisse--debug-log "Error finishing output: %s" err)))))

           ;; Handle errors
           ((equal (alist-get 'type json-obj) "error")
            (let ((error-msg (alist-get 'message json-obj)))
              (matisse--debug-log "Got error: %s" error-msg)
              (setq matisse--waiting-for-response nil)
              (matisse--stop-spinner)
              (when matisse--shell-context
                (when (alist-get :write-output matisse--shell-context)
                  (condition-case err
                      (funcall (alist-get :write-output matisse--shell-context)
                               (format "\nError: %s\n" error-msg))
                    (error (matisse--debug-log "Error writing error message: %s" err))))
                (when (alist-get :finish-output matisse--shell-context)
                  (condition-case err
                      (funcall (alist-get :finish-output matisse--shell-context) nil)
                    (error (matisse--debug-log "Error finishing on error: %s" err)))))))

           ;; Handle user messages (tool results from Claude's internal processing)
           ((equal (alist-get 'type json-obj) "user")
            ;; Extract tool results and show completion summaries
            (let ((tool-result (matisse--extract-tool-result json-obj)))
              (when tool-result
                (let* ((tool-use-id (alist-get 'tool_use_id tool-result))
                       (result-content (alist-get 'content tool-result))
                       ;; Find the matching active tool
                       (active-tool (seq-find (lambda (tool)
                                                (equal (alist-get 'id tool) tool-use-id))
                                              matisse--active-tools)))
                  (when active-tool
                    (let* ((tool-name (alist-get 'name active-tool))
                           (change-summary (matisse--format-file-change-summary tool-name result-content)))
                      ;; Show file change summary if available
                      (when (and change-summary
                                 matisse--shell-context
                                 (alist-get :write-output matisse--shell-context))
                        (condition-case err
                            (funcall (alist-get :write-output matisse--shell-context)
                                     (concat change-summary "\n"))
                          (error (matisse--debug-log "Error writing change summary: %s" err))))
                      ;; Remove completed tool from active list
                      (setq matisse--active-tools 
                            (seq-remove (lambda (tool)
                                          (equal (alist-get 'id tool) tool-use-id))
                                        matisse--active-tools))))))))           
           (t
            (matisse--debug-log "Unhandled message type: %s" (alist-get 'type json-obj))))))))))))

;;; Process management


(defun matisse--start-process ()
  "Start the Claude Code process with streaming JSON."
  (when (and matisse--process (process-live-p matisse--process))
    (delete-process matisse--process))
  
  (let* ((api-key (matisse--get-api-key))
         (process-environment (cons (format "ANTHROPIC_API_KEY=%s" api-key)
                                   process-environment))
         (cmd (list matisse-claude-code-path
                   "code"
                   "--permission-mode" matisse-permission-mode
                   "--input-format" "stream-json"
                   "--output-format" "stream-json"
                   "--verbose")))
    
    ;; Add optional parameters
    (when matisse-model
      (setq cmd (append cmd (list "--model" matisse-model))))
    (when matisse-temperature
      (setq cmd (append cmd (list "--temperature" 
                                 (number-to-string matisse-temperature)))))
    (when matisse-max-tokens
      (setq cmd (append cmd (list "--max-tokens" 
                                 (number-to-string matisse-max-tokens)))))
    (when matisse-allowed-tools
      (setq cmd (append cmd (list "--allowedTools" matisse-allowed-tools))))
    
    (matisse--debug-log "Starting process with command: %s" (string-join cmd " "))
    (let ((process-name (format "matisse-claude-%s" (buffer-name)))
          (stderr-name (format " *matisse-stderr-%s*" (buffer-name))))
      (setq matisse--process
            (make-process
             :name process-name
             :command cmd
             :buffer (get-buffer-create (format " *matisse-process-%s*" (buffer-name)))
             :filter #'matisse--process-filter
             :sentinel (lambda (process event)
                        (matisse--debug-log "Process event: %s" event)
                        (unless (process-live-p process)
                          (message "Claude Code process ended: %s" event)
                          ;; Show stderr on error
                          (when (string-match "exited abnormally" event)
                            (with-current-buffer (get-buffer stderr-name)
                              (message "Claude Code error: %s" (buffer-string))))))
             :stderr (get-buffer-create stderr-name)
             :connection-type 'pipe))
      ;; Associate the current buffer with the process
      (process-put matisse--process 'matisse-buffer (current-buffer)))
    
    (set-process-query-on-exit-flag matisse--process nil)
    (matisse--debug-log "Process started: %s" (process-live-p matisse--process))
    matisse--process))

(defun matisse--send-message (text)
  "Send TEXT message to Claude Code process."
  (unless (and matisse--process (process-live-p matisse--process))
    (matisse--start-process))
  
  (let ((json-msg (matisse--format-user-message text)))
    (matisse--debug-log "Sending JSON: %s" json-msg)
    (matisse--debug-log "Process alive before send: %s" (process-live-p matisse--process))
    (process-send-string matisse--process (concat json-msg "\n"))
    (matisse--debug-log "Process alive after send: %s" (process-live-p matisse--process))))

;;; Shell-maker integration

(defun matisse--execute-command (command shell)
  "Execute COMMAND using Claude Code, writing output to SHELL."
  (matisse--debug-log "Executing command: %s" command)
  (matisse--debug-log "Shell parameter received: %s" shell)
  (matisse--debug-log "Shell write-output: %s" (alist-get :write-output shell))
  (matisse--debug-log "Shell finish-output: %s" (alist-get :finish-output shell))
  
  ;; Handle exit command
  (if (string-equal (string-trim command) "exit")
      (matisse-quit)
  
    ;; Always update shell context to ensure we have the latest valid one
    (setq matisse--shell-context shell)
  
    ;; Start spinner to indicate waiting
    (setq matisse--waiting-for-response t)
    (matisse--start-spinner)
  
    ;; Send the user's command
    (matisse--send-message command)))

(defun matisse--validate-command (command)
  "Validate COMMAND before sending to Claude.
Returns nil if valid, error message string otherwise."
  (cond
   ((string-empty-p (string-trim command))
    "Please enter a message.")
   ((> (length command) 100000)  ; Arbitrary large limit
    "Message is too long.")
   (t nil)))

;;; Configuration

(defun matisse--make-config ()
  "Create the shell-maker configuration for Matisse."
  (let ((keymap (make-sparse-keymap)))
    (define-key keymap (kbd "C-c C-q") 'matisse-quit)
    (make-shell-maker-config
     :name "Matisse"
     :prompt "λ "
     :prompt-regexp "^λ "
     :execute-command #'matisse--execute-command
     :validate-command #'matisse--validate-command
     :on-command-finished (lambda (command output success)
                           (when (not success)
                             (message "Command failed: %s" command))))))

;;; Public interface

;;;###autoload
(defun matisse-shell ()
  "Create a new Matisse Claude Code shell session."
  (interactive)
  (matisse--validate-setup)
  (unless matisse--config
    (setq matisse--config (matisse--make-config)))
  (let ((buffer-name (generate-new-buffer-name "*matisse*")))
    (shell-maker-start matisse--config
                      nil  ; no-focus
                      (lambda (config)
                        (format "Welcome to Matisse - Claude Code Interface\n\nModel: %s\nTemperature: %s\n\nType your message and press RET to send.\nType 'help' for more information.\n"
                               (or matisse-model "default")
                               (or matisse-temperature "default")))
                      t  ; always new-session
                      buffer-name)
    ;; Enable matisse-mode in the shell buffer
    (with-current-buffer buffer-name
      (matisse-mode 1)
      ;; Reset session state to ensure clean start for this buffer
      (matisse--reset))))

(defun matisse--reset ()
  "Reset the Matisse session."
  (when matisse--process
    (delete-process matisse--process)
    (setq matisse--process nil))
  (setq matisse--pending-json ""
        matisse--conversation-id nil
        matisse--message-count 0
        matisse--shell-context nil  ; Clear shell context too
        matisse--waiting-for-response nil
        matisse--active-tools nil   ; Clear active tool tracking
        matisse--progress-buffer "")  ; Clear progress buffer
  (matisse--stop-spinner))

;;;###autoload
(defun matisse-show-stderr ()
  "Show the stderr buffer for debugging."
  (interactive)
  (let ((stderr-name (format " *matisse-stderr-%s*" (buffer-name))))
    (if (get-buffer stderr-name)
        (switch-to-buffer stderr-name)
      (message "No stderr buffer found for this session"))))

;;;###autoload
(defun matisse-set-model (model)
  "Set the Claude MODEL to use."
  (interactive
   (list (completing-read "Model: "
                         '("claude-sonnet-4-20250514"
                           "claude-opus-4-1-20250805"
                           "claude-3-5-sonnet-20241022"
                           "claude-3-5-haiku-20241022"
                           "claude-3-opus-20240229")
                         nil nil matisse-model)))
  (setq matisse-model model)
  (matisse--reset)
  (message "Model set to: %s" model))

;;;###autoload
(defun matisse-set-temperature (temp)
  "Set the temperature TEMP for responses."
  (interactive "nTemperature (0.0-1.0): ")
  (setq matisse-temperature (max 0.0 (min 1.0 temp)))
  (matisse--reset)
  (message "Temperature set to: %.1f" matisse-temperature))

;;;###autoload
(defun matisse-toggle-progress-indicators ()
  "Toggle display of progress indicators."
  (interactive)
  (setq matisse-show-progress-indicators (not matisse-show-progress-indicators))
  (message "Progress indicators %s" 
           (if matisse-show-progress-indicators "enabled" "disabled")))

;;;###autoload
(defun matisse-toggle-file-changes ()
  "Toggle display of file change summaries."
  (interactive)
  (setq matisse-show-file-changes (not matisse-show-file-changes))
  (message "File change summaries %s" 
           (if matisse-show-file-changes "enabled" "disabled")))

;;;###autoload
(defun matisse-toggle-performance-summary ()
  "Toggle display of performance summaries."
  (interactive)
  (setq matisse-show-performance-summary (not matisse-show-performance-summary))
  (message "Performance summaries %s" 
           (if matisse-show-performance-summary "enabled" "disabled")))

;;;###autoload
(defun matisse-toggle-progress-icons ()
  "Toggle use of icons in progress indicators."
  (interactive)
  (setq matisse-progress-icons (not matisse-progress-icons))
  (message "Progress icons %s" 
           (if matisse-progress-icons "enabled" "disabled")))

;;;###autoload
(defun matisse-quit ()
  "Quit Matisse by killing the process and buffer."
  (interactive)
  (when matisse--process
    (delete-process matisse--process)
    (setq matisse--process nil))
  (setq matisse--pending-json ""
        matisse--conversation-id nil
        matisse--message-count 0
        matisse--shell-context nil
        matisse--waiting-for-response nil
        matisse--active-tools nil
        matisse--progress-buffer "")
  (matisse--stop-spinner)
  (kill-buffer (current-buffer))
  (message "Matisse quit"))

(provide 'matisse)
;;; matisse.el ends here
