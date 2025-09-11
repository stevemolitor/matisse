;;; matisse-shell.el --- Custom async shell for Matisse -*- lexical-binding: t; -*-

;;; Commentary:

;; Custom async shell implementation for Matisse.

;;; Code:

(require 'cl-lib)

;;; Custom Variables

(defvar matisse-shell-prompt "λ "
  "The prompt string to use in matisse shell.")

;;; Integration Variables

(defvar-local matisse--shell-context nil
  "Context information for integration with main matisse process.")

(defvar-local matisse--current-message-id nil
  "ID of the currently processing message for response routing.")

(defvar-local matisse--response-sections nil
  "Hash table mapping message IDs to response section markers.")

(declare-function matisse--send-message "matisse.el")
(declare-function matisse--debug-log "matisse.el")

(defun matisse-shell--signal-response-complete ()
  "Signal that the current response is complete and handle spacing."
  (when (eq major-mode 'matisse-shell-mode)
    (matisse-shell--finish-output t)))

;; Make this function available to matisse.el
(defun matisse-shell--get-completion-callback ()
  "Return the callback function for response completion."
  #'matisse-shell--signal-response-complete)

(defvar matisse-debug nil
  "Whether to enable debug output in matisse-shell.")

;;; Customization

;; [TODO] dup of group in matisse.el, remove
(defgroup matisse nil
  "Matisse shell interface for Claude Code."
  :group 'tools
  :prefix "matisse-")

;; [TODO] should we move all custom vars to matisse.el? Or, move shell specific vars to this file?
(defcustom matisse-history-delete-duplicates t
  "Whether to delete duplicate entries in history.
When non-nil, adding a message that already exists in history
will move it to the front rather than creating a duplicate."
  :type 'boolean
  :group 'matisse)

;;; Variables

(defvar-local matisse--message-counter 0
  "Counter for generating unique message IDs.")

(defvar-local matisse--pending-messages nil
  "Queue of pending messages (id . text) waiting to be sent.")

(defvar-local matisse--history nil
  "List of previous messages, newest first.")

(defvar-local matisse--history-index nil
  "Current position in history during navigation.")

(defvar-local matisse--current-input ""
  "Current input being typed before history navigation.")


(defvar-local matisse--output-start-marker nil
  "Marker pointing to start of message history region.")

(defvar-local matisse--message-sections nil
  "Hash table storing message section markers.")

;;; Face Definitions

(defface matisse-header-face
  '((t :inherit font-lock-comment-face :weight bold))
  "Face for header text."
  :group 'matisse)

(defface matisse-prompt-character-face
  '((t :inherit minibuffer-prompt :weight bold))
  "Face for the prompt character (λ)."
  :group 'matisse)

(defface matisse-prompt-inactive-face
  '((t :inherit shadow :weight normal))
  "Face for inactive/previous prompts."
  :group 'matisse)

(defface matisse-user-message-face
  '((t :inherit font-lock-string-face))
  "Face for user messages."
  :group 'matisse)

(defface matisse-message-header-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for message headers."
  :group 'matisse)

(defface matisse-response-face
  '((t :inherit default))
  "Face for Claude responses."
  :group 'matisse)

(defface matisse-status-face
  '((t :inherit font-lock-keyword-face))
  "Face for status indicators."
  :group 'matisse)

(defface matisse-info-face
  '((t :inherit font-lock-doc-face))
  "Face for info text."
  :group 'matisse)

;;; Overlay-based Highlighting

(defun matisse--overlays-remove ()
  "Remove all matisse overlays from the buffer."
  (remove-overlays (point-min) (point-max) 'category 'matisse-overlays))

(defun matisse--overlay-put (overlay &rest props)
  "Set multiple properties on OVERLAY via PROPS."
  (unless (= (mod (length props) 2) 0)
    (error "Props missing a property or value"))
  (overlay-put overlay 'category 'matisse-overlays)
  (while props
    (overlay-put overlay (pop props) (pop props))))

(defun matisse--find-patterns (pattern)
  "Find all matches of PATTERN in buffer and return list of (start . end) pairs."
  (let ((matches '()))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward pattern nil t)
        (push (cons (match-beginning 0) (match-end 0)) matches)))
    (nreverse matches)))

(defun matisse--overlays-put ()
  "Apply all matisse overlays to the buffer."
  (matisse--overlays-remove)
  
  ;; Message headers: [Message #123] ...
  (dolist (match (matisse--find-patterns "^\\[Message #[0-9]+\\].*$"))
    (matisse--overlay-put
     (make-overlay (car match) (cdr match))
     'face 'matisse-message-header-face
     'evaporate t))
  
  ;; User messages: > ...
  (dolist (match (matisse--find-patterns "^> .*$"))
    (matisse--overlay-put
     (make-overlay (car match) (cdr match))
     'face 'matisse-user-message-face
     'evaporate t))
  
  ;; No special overlay for active prompts - they just use default appearance
  
  ;; Status indicators: [PROCESSING], [COMPLETED], [ERROR]
  (dolist (match (matisse--find-patterns "\\[\\(PROCESSING\\|COMPLETED\\|ERROR\\)\\]"))
    (matisse--overlay-put
     (make-overlay (car match) (cdr match))
     'face 'matisse-status-face
     'evaporate t))
  
  ;; Code blocks: ```
  (dolist (match (matisse--find-patterns "```\\(\\w+\\)?"))
    (matisse--overlay-put
     (make-overlay (car match) (cdr match))
     'face 'font-lock-preprocessor-face
     'evaporate t)))


;;; Buffer Initialization

(defun matisse--initialize-buffer ()
  "Set up initial buffer content and markers."
  ;; Clear buffer with read-only inhibited
  (let ((inhibit-read-only t))
    (erase-buffer))
  
  ;; Insert header
  (insert (propertize "Welcome to Matisse - Claude Code Interface\n" 
                      'face 'matisse-header-face))
  (insert (propertize (format "Connected to: %s\n" (or (bound-and-true-p matisse--current-model)
                                                       (bound-and-true-p matisse-default-model)
                                                       "sonnet"))
                      'face 'matisse-info-face))
  (insert "\n")
  
  ;; Set output start marker
  (set-marker matisse--output-start-marker (point))
  
  ;; Insert initial prompt
  (matisse--insert-prompt))

;;; Region Management

(defun matisse--get-input-region ()
  "Return (start . end) of current input region.
Works with multiline input - finds the last prompt in buffer and goes to end of buffer."
  (save-excursion
    (goto-char (point-max))
    ;; Search backward for the most recent prompt
    (when (re-search-backward "^λ " nil t)
      (let ((start (+ (point) 2))  ; After "λ "
            (end (point-max)))
        (when (>= end start)
          (cons start end))))))

;;; Input Handling & Prompt Management

(defun matisse--insert-prompt ()
  "Insert prompt at end of buffer and set up input region."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    
    
    ;; Insert prompt with properties - λ gets special face, space doesn't
    (let ((prompt-start (point)))
      (insert "λ ")
      ;; Apply face only to λ character
      (put-text-property prompt-start (1+ prompt-start) 'face 'matisse-prompt-character-face)
      ;; Make entire prompt read-only
      (put-text-property prompt-start (point) 'read-only t)
      (put-text-property prompt-start (point) 'rear-nonsticky '(read-only)))
    
    ;; Position cursor for input
    (goto-char (point-max))
    
    ;; Refresh overlays after prompt insertion
    (matisse--overlays-put)))

(defun matisse-bol ()
  "Move to beginning of line, or after prompt if it's on current line."
  (interactive)
  (let ((orig-point (point)))
    (beginning-of-line)
    ;; Check if current line starts with the prompt
    (if (looking-at "^λ ")
        ;; Skip past the prompt and space
        (goto-char (+ (point) 2))
      ;; Already at beginning of line (no prompt on this line)
      )))

(defun matisse--clear-current-input ()
  "Clear text after prompt on current line."
  (let ((region (matisse--get-input-region)))
    (when region
      (delete-region (car region) (cdr region)))))

(defun matisse--get-current-input-text ()
  "Get text currently typed at prompt."
  (let ((region (matisse--get-input-region)))
    (if region
        (buffer-substring-no-properties (car region) (cdr region))
      "")))

(defun matisse--replace-current-input (text)
  "Replace current input with TEXT."
  (matisse--clear-current-input)
  (goto-char (point-max))
  (insert text))

(defun matisse--handle-return ()
  "Handle RET key press - process current input."
  (interactive)
  ;; Always go to end of buffer to ensure we capture all input
  (goto-char (point-max))
  (let ((input (string-trim (matisse--get-current-input-text)))
        ;; Capture exact boundaries - now (point) is guaranteed to be at point-max
        (prompt-start (save-excursion
                        (goto-char (point-max))
                        (when (re-search-backward "^λ " nil t)
                          (line-beginning-position))))
        (input-end (point-max)))

    ;; Now move to end and add newline
    (goto-char input-end)
    (insert "\n")

    (cond
     ;; Empty input - just add new prompt
     ((string-empty-p input)
      ;; Apply inactive face to empty prompt line
      (when (and prompt-start input-end)
        (let ((inhibit-read-only t))
          ;; Apply inactive face to entire line (this will override the prompt character face)
          (put-text-property prompt-start input-end 'face 'matisse-prompt-inactive-face)))
      (goto-char input-end)
      (matisse--insert-prompt)
      ;; Auto-scroll after inserting new prompt (user was at end when submitting)
      (matisse--auto-scroll-if-at-end t (current-buffer)))

     ;; Valid input - process message
     (t
      ;; Apply inactive face to the exact region of prompt + user input FIRST
      ;; before any buffer modifications
      (when (and prompt-start input-end)
        (let ((inhibit-read-only t))
          ;; Apply inactive face to entire line (this will override the prompt character face)
          (put-text-property prompt-start input-end 'face 'matisse-prompt-inactive-face)))

      ;; Continue with normal processing
      (matisse--process-user-input-internal input)))))

(defun matisse--process-user-input-internal (input)
  "Process user INPUT and queue for sending - internal implementation."
  (condition-case err
      (progn
        ;; Add to history
        (matisse--add-to-history input)
        
        ;; Reset history navigation state when command is executed
        (setq matisse--history-index nil)
        
        ;; Check for special commands
        (cond
         ;; Handle exit/quit commands
         ((member (string-trim (downcase input)) '("exit" "quit" "bye"))
          (when (fboundp 'matisse-quit)
            (matisse-quit)))
         
         ;; Normal message processing
         (t
          ;; Show new prompt for async input
          (matisse--insert-prompt)
          
          ;; Auto-scroll after inserting new prompt (user was at end when submitting)
          (matisse--auto-scroll-if-at-end t (current-buffer))
          
          ;; Process message asynchronously
          (matisse--send-user-message input))))
    (error
     (message "Error in matisse--process-user-input-internal: %s" (error-message-string err))
     ;; Ensure we always have a prompt
     (goto-char (point-max))
     (unless (matisse--at-prompt-p)
       (matisse--insert-prompt)
       ;; Auto-scroll after error recovery
       (matisse--auto-scroll-if-at-end t (current-buffer))))))

(defun matisse--at-prompt-p ()
  "Check if there's an active prompt at point-max."
  (save-excursion
    (goto-char (point-max))
    (beginning-of-line)
    (looking-at-p matisse-shell-prompt)))

(defun matisse--newline ()
  "Insert a newline in the current input."
  (interactive)
  ;; Ensure we're in a matisse shell buffer and on the prompt line
  (unless (derived-mode-p 'matisse-shell-mode)
    (user-error "Not in a matisse shell buffer"))
  
  ;; Check if we're in the input region
  (let ((input-region (matisse--get-input-region)))
    (if input-region
        (insert "\n")
      (message "Not in input area"))))

;;; History Management

(defun matisse--add-to-history (text)
  "Add TEXT to history list (newest first)."
  ;; Don't add empty messages
  (unless (string-empty-p text)
    (if matisse-history-delete-duplicates
        ;; Remove existing duplicate and add to front
        (progn
          (setq matisse--history (delete text matisse--history))
          (push text matisse--history))
      ;; Only add if not duplicate of most recent
      (unless (equal text (car matisse--history))
        (push text matisse--history)))))

(defun matisse-history-previous ()
  "Navigate to previous message in history (up arrow)."
  (interactive)
  ;; Ensure we're in a matisse shell buffer
  (unless (derived-mode-p 'matisse-shell-mode)
    (user-error "Not in a matisse shell buffer"))
  
  (if (not matisse--history)
      (message "No history available")
    (cond
     ;; First time navigating - save current input
     ((null matisse--history-index)
      (setq matisse--current-input (matisse--get-current-input-text)
            matisse--history-index 0)
      (matisse--replace-current-input (nth matisse--history-index matisse--history)))
     
     ;; If we have a history index but current input doesn't match what we expect,
     ;; reset and start fresh (handles C-g and other interruptions)
     ((and matisse--history-index
           (not (equal (matisse--get-current-input-text) 
                       (nth matisse--history-index matisse--history))))
      (setq matisse--current-input (matisse--get-current-input-text)
            matisse--history-index 0)
      (matisse--replace-current-input (nth matisse--history-index matisse--history)))
     
     ;; Navigate further back
     ((< matisse--history-index (1- (length matisse--history)))
      (setq matisse--history-index (1+ matisse--history-index))
      (matisse--replace-current-input (nth matisse--history-index matisse--history)))
     
     ;; At end of history
     (t
      (message "Beginning of history; no preceding item")))))

(defun matisse-history-next ()
  "Navigate to next message in history (down arrow)."
  (interactive)
  ;; Ensure we're in a matisse shell buffer
  (unless (derived-mode-p 'matisse-shell-mode)
    (user-error "Not in a matisse shell buffer"))
  
  (if (not matisse--history)
      (message "No history available")
    (cond
     ;; Go forward in history
     ((and matisse--history-index (> matisse--history-index 0))
      (setq matisse--history-index (1- matisse--history-index))
      (matisse--replace-current-input (nth matisse--history-index matisse--history)))
     
     ;; Return to original input
     ((and matisse--history-index (= matisse--history-index 0))
      (setq matisse--history-index nil)
      (matisse--replace-current-input matisse--current-input))
     
     ;; Not in history mode
     (t
      (message "End of history; no default available")))))

;;; History Search

(defun matisse-history-search-backward (regexp)
  "Search backward through history for entries matching REGEXP."
  (interactive "sSearch history backward (regexp): ")
  ;; Ensure we're in a matisse shell buffer
  (unless (derived-mode-p 'matisse-shell-mode)
    (user-error "Not in a matisse shell buffer"))
  (matisse--history-search regexp -1))

(defun matisse-history-search-forward (regexp)  
  "Search forward through history for entries matching REGEXP."
  (interactive "sSearch history forward (regexp): ")
  ;; Ensure we're in a matisse shell buffer
  (unless (derived-mode-p 'matisse-shell-mode)
    (user-error "Not in a matisse shell buffer"))
  (matisse--history-search regexp 1))

(defun matisse--history-search (regexp direction)
  "Search through history for REGEXP in DIRECTION (-1 backward, 1 forward)."
  (if (not matisse--history)
      (message "No history available")
    (let ((history-length (length matisse--history))
          (found-index nil)
          (start-index)
          (search-pattern))
      
      ;; Save current input if not already in history mode
      (unless matisse--history-index
        (setq matisse--current-input (matisse--get-current-input-text)))
      
      ;; Convert to substring search unless it looks like a full regex
      ;; If it contains regex metacharacters, use as-is, otherwise make it substring search
      (setq search-pattern
            (if (string-match-p "[.*+?^$\\[]" regexp)
                regexp  ; Looks like regex, use as-is
              (concat ".*" (regexp-quote regexp) ".*"))) ; Make it substring search
      
      ;; Determine starting index based on direction and current state
      (setq start-index 
            (cond
             ;; If searching backward and not in history mode, start from beginning (index 0)
             ((and (< direction 0) (null matisse--history-index))
              0)
             ;; If searching forward and not in history mode, start from end
             ((and (> direction 0) (null matisse--history-index))
              (1- history-length))
             ;; If already in history mode, start from next position
             (t
              (+ matisse--history-index direction))))
      
      ;; Search through history
      (let ((index start-index))
        (while (and (>= index 0) 
                    (< index history-length) 
                    (not found-index))
          (when (string-match-p search-pattern (nth index matisse--history))
            (setq found-index index))
          (setq index (+ index direction))))
      
      ;; Update input if match found
      (if found-index
          (progn
            (setq matisse--history-index found-index)
            (matisse--replace-current-input (nth found-index matisse--history)))
        (message "No %s match for: %s" 
                 (if (< direction 0) "previous" "next") (or regexp "[nil]"))))))

;;; History Completing Read

(defun matisse-history-complete ()
  "Select from history using completing-read with fuzzy matching."
  (interactive)
  ;; Ensure we're in a matisse shell buffer
  (unless (derived-mode-p 'matisse-shell-mode)
    (user-error "Not in a matisse shell buffer"))
  
  (if (not matisse--history)
      (message "No history available")
    ;; Use completing-read to select from history
    (let* ((history-candidates (cl-remove-duplicates matisse--history :test #'string-equal))
           (selected (completing-read "History: " 
                                      history-candidates
                                      nil    ; predicate
                                      nil    ; require-match (nil allows partial)
                                      nil    ; initial-input
                                      nil    ; hist
                                      (car history-candidates)))) ; default
      (when (and selected (not (string-empty-p selected)))
        ;; Replace current input with selected history item
        (matisse--replace-current-input selected)
        (message "Selected: %s" (or selected "[nil]"))))))

;;; History Display

(defun matisse-history-show ()
  "Display complete history in a separate buffer for selection."
  (interactive)
  ;; Ensure we're in a matisse shell buffer
  (unless (derived-mode-p 'matisse-shell-mode)
    (user-error "Not in a matisse shell buffer"))
  
  ;; Capture history from current shell buffer
  (let ((shell-buffer (current-buffer))
        (history-items (copy-sequence matisse--history)))
    (if (not history-items)
        (message "No history available")
      (let ((history-buffer (get-buffer-create "*Matisse History*")))
        (with-current-buffer history-buffer
          (setq buffer-read-only nil)
          (erase-buffer)
          (insert "Matisse Shell History\n")
          (insert "===================\n\n")
          (insert "Press RET to select, q to quit\n\n")
          
          ;; Insert history items with numbers
          (let ((index 0))
            (dolist (item history-items)
              (insert (format "%3d. %s\n" (1+ index) item))
              (setq index (1+ index))))
          
          ;; Set up the buffer for selection
          (goto-char (point-min))
          (when (search-forward "1. " nil t)
            (beginning-of-line))
          
          ;; Store reference to original shell buffer
          (setq-local matisse--source-buffer shell-buffer)
          
          ;; Enable special mode for navigation
          (matisse-history-display-mode))
        
        ;; Show the history buffer
        (pop-to-buffer history-buffer)))))

(define-derived-mode matisse-history-display-mode special-mode "Matisse-History"
  "Major mode for displaying and selecting from Matisse history."
  (setq buffer-read-only t)
  (local-set-key (kbd "RET") #'matisse--history-select-current)
  (local-set-key (kbd "q") #'quit-window)
  (local-set-key (kbd "n") #'next-line)
  (local-set-key (kbd "p") #'previous-line)
  (local-set-key (kbd "<down>") #'next-line)
  (local-set-key (kbd "<up>") #'previous-line))

(defun matisse--history-select-current ()
  "Select the history item at point and return to shell."
  (interactive)
  (let ((line (thing-at-point 'line t)))
    (when (and line (string-match "^\\s-*[0-9]+\\. \\(.*\\)$" line))
      (let ((selected-text (match-string 1 line))
            (shell-buffer matisse--source-buffer))
        (quit-window)
        (when (and shell-buffer (buffer-live-p shell-buffer))
          (switch-to-buffer shell-buffer)
          (when (derived-mode-p 'matisse-shell-mode)
            (matisse--replace-current-input selected-text)))))))

;;; Auto-scroll Utility

(defun matisse--auto-scroll-if-at-end (at-end-condition buffer)
  "Auto-scroll to bottom with margin if AT-END-CONDITION is true.
BUFFER specifies which buffer to scroll.
Keeps prompt away from bottom edge by using recenter -2."
  (when at-end-condition
    (let ((shell-window (get-buffer-window buffer)))
      (when shell-window
        (with-selected-window shell-window
          (with-current-buffer buffer
            (goto-char (point-max))
            (recenter -2)))))))

;;; Visual Design & Message Section Creation

(defun matisse--display-user-message (text)
  "Display user's message with proper formatting."
  (insert (propertize (format "> %s" text) 'face 'matisse-user-message-face))
  (insert "\n\n"))

(defun matisse--create-message-section (message-id text timestamp)
  "Create a section for message and its response."
  (condition-case err
      (let ((section-start (point)))
        ;; Insert message header
        (insert (propertize 
                 (format "[Message #%d] (%s) [PROCESSING]\n"
                         message-id timestamp)
                 'face 'matisse-message-header-face
                 'message-id message-id))
        
        ;; Create response area placeholder
        (let ((response-start (point)))
          (insert (propertize "[Processing...]\n\n"
                              'face 'matisse-status-face
                              'message-id message-id
                              'response-section t))
          
          ;; Store markers for this message
          (puthash message-id 
                   (list :header-start section-start
                         :response-start response-start
                         :response-end (point-marker))
                   matisse--message-sections)))
    (error
     (message "Error in matisse--create-message-section: %s" (error-message-string err)))))

(defun matisse--update-message-status (message-id new-status)
  "Update status indicator for MESSAGE-ID."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward 
           (format "\\[Message #%d\\] ([^)]+) \\[\\([^]]+\\)\\]" message-id) nil t)
      (replace-match 
       (format "[%s]%s" 
               new-status
               (pcase new-status
                 ("PROCESSING" " 🔥")
                 ("COMPLETED" " ✓")
                 ("ERROR" " ✗")
                 (_ "")))
       nil nil nil 1))))

(defun matisse--update-response-content (message-id content)
  "Update response content for MESSAGE-ID."
  (when-let ((section (gethash message-id matisse--message-sections)))
    (let ((response-start (plist-get section :response-start))
          (response-end (plist-get section :response-end)))
      (save-excursion
        ;; Clear existing response content
        (goto-char response-start)
        (delete-region response-start response-end)
        
        ;; Insert new content
        (insert (propertize content 'face 'matisse-response-face))
        (insert "\n\n")
        
        ;; Update end marker
        (set-marker response-end (point)))
      
      ;; Don't refresh overlays here - response content doesn't need overlay updates
      ;; (matisse--overlays-put)  ; Commented out to prevent incorrect face application
      )))

;;; Simplified Message Sending

(defun matisse--send-user-message (input)
  "Send user INPUT message directly to Claude."
  
  (let ((message-id (cl-incf matisse--message-counter)))
    ;; Create response section for this message
    (matisse-shell--create-response-section message-id)
    
    ;; Add to pending messages queue with the input text
    (setq matisse--pending-messages 
          (append matisse--pending-messages (list (cons message-id input))))
    
    
    ;; If no message is currently being processed, send this one
    (unless matisse--current-message-id
      (matisse--process-next-message))))

(defun matisse--process-next-message ()
  "Process the next message in the queue."
  (when matisse--pending-messages
    (let* ((msg-pair (car matisse--pending-messages))
           (message-id (car msg-pair))
           (input (cdr msg-pair)))
      
      
      ;; Set this as the current message - should already be in shell buffer context
      (setq matisse--current-message-id message-id)
      
      ;; Set up shell context for this message
      (setq matisse--shell-context
            (list :write-output #'matisse-shell--write-progress
                  :finish-output #'matisse-shell--finish-output
                  :buffer-name (buffer-name)
                  :message-id message-id))
      
      ;; Send via execute-command to get proper mode-line updates
      (when (fboundp 'matisse--execute-command)
        (matisse--execute-command input matisse--shell-context)))))

(defun matisse-shell--create-response-section (message-id)
  "Create a response section for MESSAGE-ID in the current shell buffer."
  (let (section-start)
    ;; Find insertion point - before the prompt if it exists
    (goto-char (point-max))
    (if (matisse--at-prompt-p)
        (progn
          (beginning-of-line)
          ;; Ensure we're on a new line before the prompt
          (when (and (> (point) (point-min))
                     (save-excursion
                       (backward-char 1)
                       (not (looking-at "\n"))))
            (insert "\n")
            (backward-char 1))
          (setq section-start (point)))
      (setq section-start (point-max))
      (goto-char section-start))
    
    (unless (bolp) (insert "\n"))
    
    ;; Insert response marker (visible during development, can be hidden later)
    (when matisse-debug
      (insert (propertize (format "[Response #%d]\n" (or message-id 0))
                          'face 'matisse-status-face)))
    
    ;; Create response content area
    (let ((response-start (point))
          (response-end (point-marker)))
      
      ;; Store markers for this message
      (unless matisse--response-sections
        (setq matisse--response-sections (make-hash-table :test 'equal)))
      
      ;; Shell context is set up in matisse--queue-message
      
      (puthash message-id 
               (list :start section-start
                     :response-start response-start  
                     :response-end response-end)
               matisse--response-sections)
      
      ;; Return to the prompt for continued typing
      (goto-char (point-max)))))

(defun matisse-shell--handle-response (message-id content)
  "Handle response CONTENT for MESSAGE-ID in the shell."
  (when-let ((section (gethash message-id matisse--response-sections)))
    (let ((response-start (plist-get section :response-start))
          (response-end (plist-get section :response-end))
          (current-pos (point)))
      
      ;; Insert content at the response section
      (save-excursion
        (goto-char response-end)
        (let ((content-start (point)))
          (insert content)
          ;; Ensure content ends with newline for prompt separation
          (unless (or (string-suffix-p "\n" content)
                      (eobp))
            (insert "\n"))
          ;; Explicitly remove any inactive face that might have been inherited
          (let ((pos content-start))
            (while (< pos (point))
              (when (eq (get-text-property pos 'face) 'matisse-prompt-inactive-face)
                (remove-text-properties pos (1+ pos) '(face nil)))
              (when (eq (get-text-property pos 'font-lock-face) 'matisse-prompt-inactive-face)
                (remove-text-properties pos (1+ pos) '(font-lock-face nil)))
              (setq pos (1+ pos))))
          ;; Update end marker
          (set-marker response-end (point))))
      
      ;; Don't refresh overlays here - they should only be applied to specific patterns
      ;; and refreshing them after every response insertion can cause incorrect face application
      ;; (matisse--overlays-put)  ; Commented out to prevent tool messages from getting prompt faces
      
      ;; Auto-scroll if we were at the end, but keep prompt away from bottom edge
      (matisse--auto-scroll-if-at-end (= current-pos (point-max)) (current-buffer)))))

(defun matisse-shell--write-progress (text)
  "Write progress TEXT to the shell buffer."
  ;; This function should be called from within the target shell buffer context
  (when (derived-mode-p 'matisse-shell-mode)
    (let ((at-end (= (point) (point-max))))
      (save-excursion
        ;; Find the current response end marker
        (when (and matisse--current-message-id
                   matisse--response-sections)
          (let ((section (gethash matisse--current-message-id matisse--response-sections)))
            (when section
              (let ((response-end (plist-get section :response-end))
                    (start-pos nil))

                (goto-char response-end)
                ;; Add newline before progress if needed
                (unless (bolp) (insert "\n"))
                (setq start-pos (point))
                (insert text)
                (unless (string-suffix-p "\n" text) (insert "\n"))

                ;; Explicitly remove any inactive face that might have been inherited
                (let ((pos start-pos))
                  (while (< pos (point))
                    (when (eq (get-text-property pos 'face) 'matisse-prompt-inactive-face)
                      (remove-text-properties pos (1+ pos) '(face nil)))
                    (when (eq (get-text-property pos 'font-lock-face) 'matisse-prompt-inactive-face)
                      (remove-text-properties pos (1+ pos) '(font-lock-face nil)))
                    (setq pos (1+ pos))))
                ;; Update the end marker
                (set-marker response-end (point)))))))

      ;; Auto-scroll if we were at the end, but keep prompt away from bottom edge
      (matisse--auto-scroll-if-at-end at-end (current-buffer)))))

(defun matisse-shell--finish-output (success)
  "Finish output and prepare for next prompt."
  ;; This function should be called from within the target shell buffer context
  (when (derived-mode-p 'matisse-shell-mode)
    ;; Only process if we have a current message (avoid duplicate calls)
    (when matisse--current-message-id
      ;; Remove completed message from pending queue
      (when (and matisse--pending-messages
                 (= (caar matisse--pending-messages) matisse--current-message-id))
        (setq matisse--pending-messages (cdr matisse--pending-messages)))
      ;; Clear current message
      (setq matisse--current-message-id nil))

    ;; Ensure proper spacing between response and prompt
    (save-excursion
      (goto-char (point-max))
      (when (matisse--at-prompt-p)
        (beginning-of-line)
        ;; If we're not at the beginning of a line after a newline, add one
        (when (and (> (point) (point-min))
                   (save-excursion
                     (backward-char 1)
                     (not (looking-at "\n"))))
          (insert "\n"))))

    ;; Auto-scroll when output is finished to show completion
    (matisse--auto-scroll-if-at-end t (current-buffer))

    ;; Process next message if any are queued
    (when matisse--pending-messages
      ;; Small delay to ensure Claude is ready for next message
      (run-at-time 0.5 nil
                   (lambda ()
                     ;; Should already be in shell buffer context
                     (matisse--process-next-message))))))

(defun matisse--cancel-current-message ()
  "Cancel the currently processing message."
  (interactive)
  ;; TODO: Implement message cancellation
  (message "Message cancellation not yet implemented"))

;;; Buffer State Management

(defun matisse--clear-buffer ()
  "Clear all messages and reset buffer."
  (interactive)
  (let ((inhibit-read-only t))
    ;; Reset state
    (setq matisse--message-counter 0
          matisse--pending-messages nil
          matisse--current-message-id nil)
    (clrhash matisse--message-sections)
    
    ;; Reinitialize buffer
    (matisse--initialize-buffer)))

(defun matisse--kill-buffer-hook ()
  "Cleanup when buffer is killed."
  ;; Clear markers
  (when matisse--output-start-marker
    (set-marker matisse--output-start-marker nil))
  
  ;; Clear message section markers
  (when matisse--message-sections
    (maphash (lambda (_id section)
               (when-let ((end-marker (plist-get section :response-end)))
                 (set-marker end-marker nil)))
             matisse--message-sections)))

;;; Public Interface
(defun matisse-shell-start (buffer-name &optional shell-context)
  "Start Matisse shell with integration to main matisse process.
BUFFER-NAME is the name of the buffer to create.
SHELL-CONTEXT contains integration information from main matisse system."
  (let ((buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      ;; Store context for integration
      (setq matisse--shell-context shell-context)
      
      ;; Initialize shell mode
      (matisse-shell-mode)
      
      ;; Switch to the buffer
      (switch-to-buffer buffer)
      
      ;; Return the buffer for caller
      buffer)))

;;; Major Mode Definition

;; Forward declare matisse-mode from matisse.el
(declare-function matisse-mode "matisse.el")

(define-derived-mode matisse-shell-mode fundamental-mode "Matisse-Shell"
  "Major mode for matisse shell interactions.
Provides a clean interface for Claude interactions with visual feedback."
  ;; Buffer is read-only except for input area
  (setq buffer-read-only nil)  ; We'll manage read-only regions manually
  
  ;; Initialize local variables for state management
  (setq-local matisse--message-counter 0
              matisse--pending-messages nil
              matisse--history nil
              matisse--history-index nil
              matisse--current-input ""
              matisse--output-start-marker (make-marker)
              matisse--message-sections (make-hash-table :test 'equal))
  
  ;; Key bindings
  (local-set-key (kbd "RET") #'matisse--handle-return)
  (local-set-key (kbd "S-<return>") #'matisse--newline)
  (local-set-key (kbd "<up>") #'matisse-history-previous)
  (local-set-key (kbd "<down>") #'matisse-history-next)
  (local-set-key (kbd "M-p") #'matisse-history-previous)
  (local-set-key (kbd "M-n") #'matisse-history-next)
  (local-set-key (kbd "M-r") #'matisse-history-search-backward)
  (local-set-key (kbd "M-s") #'matisse-history-search-forward)
  (local-set-key (kbd "C-c h") #'matisse-history-show)
  (local-set-key (kbd "C-c C-r") #'matisse-history-complete)
  (local-set-key (kbd "C-c C-c") #'matisse--cancel-current-message)
  (local-set-key (kbd "C-l") #'matisse--clear-buffer)
  (local-set-key (kbd "C-a") #'matisse-bol)
  
  ;; Apply overlay-based highlighting
  (matisse--overlays-put)
  
  ;; Buffer configuration
  (setq truncate-lines nil     ; Allow line wrapping
        word-wrap t            ; Wrap at word boundaries
        scroll-conservatively 10000)  ; Smooth scrolling
  
  ;; Initialize buffer content
  (matisse--initialize-buffer)
  
  ;; Enable matisse-mode for mode-line enhancements and progress indicators
  (when (fboundp 'matisse-mode)
    (matisse-mode 1))
  
  ;; Add cleanup hook
  (add-hook 'kill-buffer-hook #'matisse--kill-buffer-hook nil t))

(provide 'matisse-shell)

;;; matisse-shell.el ends here
