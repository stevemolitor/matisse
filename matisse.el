;;; matisse.el --- Emacs interface to Claude Code -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Steve Molitor
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.0"))
;; Keywords: ai, tools, claude
;;; Commentary:

;; Matisse provides an Emacs interface to Claude Code with a custom async shell.
;; It communicates with Claude Code via streaming JSON input/output for real-time responses.

;;; Code:

(require 'json)
(require 'map)
(require 'seq)
(require 'cl-lib)
(require 'server)

;; External function declarations
(declare-function auth-source-search "auth-source" (&rest spec))

;; Start Emacs server for hook callbacks if not already running
(condition-case nil
    (unless (server-running-p)
      (server-start))
  (error
   ;; If server start fails, try to clean up and restart
   (ignore-errors (server-force-delete))
   (server-start)))

;; Note: Server connection messages are suppressed at the wrapper script level
;; by redirecting stderr to /dev/null when calling emacsclient

(defvar matisse--shell-context) ; Forward declaration, defined later as buffer-local

(defun matisse--route-to-shell (text)
  "Route TEXT output to the matisse-shell implementation."
  (when-let* ((buffer-name (plist-get matisse--shell-context :buffer-name))
              (message-id (plist-get matisse--shell-context :message-id))
              (shell-buffer (get-buffer buffer-name)))
    (when (buffer-live-p shell-buffer)
      (with-current-buffer shell-buffer
        ;; Route response to shell using message ID from context
        (matisse-shell--handle-response message-id text)))))

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

(defcustom matisse-default-model "sonnet"
  "The default Claude model to use for new sessions."
  :type '(choice (const :tag "Sonnet" "sonnet")
                 (const :tag "Opus" "opus")
                 (string :tag "Custom model string"))
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

(defgroup matisse-progress-icons nil
  "Progress indicator icons and display settings."
  :group 'matisse)

(defcustom matisse-icons-scale-factor 1.0
  "Scale factor for icon height.
This controls the relative size of icons in progress indicators.
A value of 1.0 uses the default text height, 1.2 makes icons 20% larger, etc."
  :type 'float
  :group 'matisse-progress-icons)

(defgroup matisse-emoji-icons nil
  "Emoji icon settings for progress indicators."
  :group 'matisse-progress-icons)

(defcustom matisse-progress-icons-mode 'ascii
  "Mode for displaying progress indicator icons.
Options:
- \\='emoji: Use emoji icons
- \\='nerd-icons: Use Nerd Font icons
- \\='ascii: Use simple ASCII characters only (default)"
  :type '(choice (const :tag "Emoji" emoji)
                 (const :tag "Nerd Font icons" nerd-icons)
                 (const :tag "ASCII only" ascii))
  :group 'matisse-progress-icons)

(defcustom matisse-ascii-shell-prompt "❯"
  "ASCII character for shell prompt."
  :type 'string
  :group 'matisse-progress-icons)

(defcustom matisse-emoji-icon-read "📖"
  "Emoji icon for Read tool progress indicator."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-write "✍️"
  "Emoji icon for Write tool progress indicator."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-edit "✏️"
  "Emoji icon for Edit tool progress indicator."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-multiedit "✏️"
  "Emoji icon for MultiEdit tool progress indicator."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-bash "💻"
  "Emoji icon for Bash tool progress indicator."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-grep "🔍"
  "Emoji icon for Grep tool progress indicator."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-glob "📁"
  "Emoji icon for Glob tool progress indicator."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-task "🤖"
  "Emoji icon for Task tool progress indicator."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-webfetch "🌐"
  "Emoji icon for WebFetch tool progress indicator."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-todowrite "📝"
  "Emoji icon for TodoWrite tool progress indicator."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-default "🔧"
  "Default emoji icon for unknown tools."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-success "✅"
  "Emoji icon for successful operations."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-performance "⏱️"
  "Emoji icon for performance summaries."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-shell-prompt "🖌️"
  "Emoji character for shell prompt."
  :type 'string
  :group 'matisse-emoji-icons)

(defgroup matisse-nerd-icons nil
  "Nerd Font icon settings for progress indicators."
  :group 'matisse-progress-icons)

(defcustom matisse-nerd-icon-read ""
  "Nerd Font icon for Read tool progress indicator."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-write ""
  "Nerd Font icon for Write tool progress indicator."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-edit ""
  "Nerd Font icon for Edit tool progress indicator."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-multiedit "󰓰"
  "Nerd Font icon for MultiEdit tool progress indicator."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-bash ""
  "Nerd Font icon for Bash tool progress indicator."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-grep ""
  "Nerd Font icon for Grep tool progress indicator."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-glob ""
  "Nerd Font icon for Glob tool progress indicator."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-task ""
  "Nerd Font icon for Task tool progress indicator."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-webfetch "󰖟"
  "Nerd Font icon for WebFetch tool progress indicator."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-todowrite ""
  "Nerd Font icon for TodoWrite tool progress indicator."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-default "󰖷"
  "Default nerd Font icon for unknown tools."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-success ""
  "Nerd Font icon for successful operations."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-performance ""
  "Nerd Font icon for performance summaries."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-shell-prompt ""
  "Nerd Font character for shell prompt."
  :type 'string
  :group 'matisse-nerd-icons)

;;; Nerd icon faces - copied from nerd-icons-faces.el to avoid dependency

(defface matisse-nerd-icon-blue
  '((((background dark)) :foreground "#6A9FB5")
    (((background light)) :foreground "#6A9FB5"))
  "Face for blue nerd icons."
  :group 'matisse-nerd-icons)

(defface matisse-nerd-icon-green
  '((((background dark)) :foreground "#90A959")
    (((background light)) :foreground "#90A959"))
  "Face for green nerd icons."
  :group 'matisse-nerd-icons)

(defface matisse-nerd-icon-orange
  '((((background dark)) :foreground "#D4843E")
    (((background light)) :foreground "#D4843E"))
  "Face for orange nerd icons."
  :group 'matisse-nerd-icons)

(defface matisse-nerd-icon-lorange
  '((((background dark)) :foreground "#FFA500")
    (((background light)) :foreground "#FFA500"))
  "Face for light orange nerd icons."
  :group 'matisse-nerd-icons)

(defface matisse-nerd-icon-purple
  '((((background dark)) :foreground "#AA759F")
    (((background light)) :foreground "#68295B"))
  "Face for purple nerd icons."
  :group 'matisse-nerd-icons)

(defface matisse-nerd-icon-yellow
  '((((background dark)) :foreground "#FFD446")
    (((background light)) :foreground "#FFCC0E"))
  "Face for yellow nerd icons."
  :group 'matisse-nerd-icons)

(defface matisse-nerd-icon-dyellow
  '((((background dark)) :foreground "#B48D56")
    (((background light)) :foreground "#B48D56"))
  "Face for dark yellow nerd icons."
  :group 'matisse-nerd-icons)

(defface matisse-nerd-icon-cyan
  '((((background dark)) :foreground "#75B5AA")
    (((background light)) :foreground "#75B5AA"))
  "Face for cyan nerd icons."
  :group 'matisse-nerd-icons)

(defface matisse-nerd-icon-lblue
  '((((background dark)) :foreground "#8FD7F4")
    (((background light)) :foreground "#677174"))
  "Face for light blue nerd icons."
  :group 'matisse-nerd-icons)

(defface matisse-nerd-icon-pink
  '((((background dark)) :foreground "#F2B4B8")
    (((background light)) :foreground "#FC505B"))
  "Face for pink nerd icons."
  :group 'matisse-nerd-icons)

(defface matisse-nerd-icon-silver
  '((((background dark)) :foreground "#716E68")
    (((background light)) :foreground "#716E68"))
  "Face for silver nerd icons."
  :group 'matisse-nerd-icons)

(defface matisse-nerd-icon-lgreen
  '((((background dark)) :foreground "#C6E87A")
    (((background light)) :foreground "#3D6837"))
  "Face for light green nerd icons."
  :group 'matisse-nerd-icons)

(defface matisse-nerd-icon-maroon
  '((((background dark)) :foreground "#8F5536")
    (((background light)) :foreground "#8F5536"))
  "Face for maroon nerd icons."
  :group 'matisse-nerd-icons)

(defgroup matisse-nerd-icon-faces nil
  "Face settings for colorizing Nerd Font icons in progress indicators."
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-read-face 'matisse-nerd-icon-blue
  "Face for Read tool nerd icon.
Uses blue color suitable for reading operations."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-write-face 'matisse-nerd-icon-green
  "Face for Write tool nerd icon.
Uses green color suitable for creation operations."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-edit-face 'matisse-nerd-icon-orange
  "Face for Edit tool nerd icon.
Uses orange color suitable for modification operations."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-multiedit-face 'matisse-nerd-icon-lorange
  "Face for MultiEdit tool nerd icon.
Uses light orange color suitable for batch edit operations."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-bash-face 'matisse-nerd-icon-purple
  "Face for Bash tool nerd icon.
Uses purple color suitable for command execution."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-grep-face 'matisse-nerd-icon-yellow
  "Face for Grep tool nerd icon.
Uses yellow color suitable for search operations."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-glob-face 'matisse-nerd-icon-dyellow
  "Face for Glob tool nerd icon.
Uses dark yellow color suitable for file pattern matching."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-task-face 'matisse-nerd-icon-cyan
  "Face for Task tool nerd icon.
Uses cyan color suitable for task operations."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-webfetch-face 'matisse-nerd-icon-lblue
  "Face for WebFetch tool nerd icon.
Uses light blue color suitable for web operations."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-todowrite-face 'matisse-nerd-icon-pink
  "Face for TodoWrite tool nerd icon.
Uses pink color suitable for todo management."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-default-face 'matisse-nerd-icon-silver
  "Face for default tool nerd icon.
Uses silver color suitable for unknown tools."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-success-face 'matisse-nerd-icon-lgreen
  "Face for success operation nerd icon.
Uses light green color suitable for successful operations."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-performance-face 'matisse-nerd-icon-maroon
  "Face for performance summary nerd icon.
Uses maroon color suitable for timing information."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-allowed-tools nil
  "List of allowed tools for Claude Code.
If nil, all tools are allowed. Otherwise, specify tools like:
\"Read,Write,Edit,MultiEdit,Bash(git commit:*),Grep,Glob,Task,WebFetch,TodoWrite\""
  :type '(choice (string :tag "Allowed tools")
                 (const :tag "All tools" nil))
  :group 'matisse)

(defcustom matisse-prefix-key nil
  "Prefix key for matisse commands.

When non-nil, this key will be bound to `matisse-command-map' in
`matisse-mode'. For example: \\`C-c m' or \\`s-m'."
  :type '(choice (string :tag "Key sequence")
                 (const :tag "No automatic binding" nil))
  :group 'matisse)

(defcustom matisse-send-selection-p t
  "Whether to include current selection context in prompts.
When non-nil, the last text selection from non-matisse buffers will be
appended to prompts in the format @/file/path#L5-L9."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-spinner-interval 0.13
  "Interval in seconds between spinner animation updates.
Controls how fast the mode-line emoji blinks when waiting for Claude responses.
Smaller values make faster blinking, larger values make slower blinking."
  :type 'number
  :group 'matisse)

;;; Internal variables

(defvar-local matisse--process nil
  "The Claude Code process.")

(defvar-local matisse--pending-json ""
  "Buffer for incomplete JSON data.")

(defvar matisse--config nil
  "Shell configuration for matisse.")

(defvar-local matisse--initial-directory nil
  "The directory where the Matisse session was initially started.
Used for consistent project paths regardless of directory changes.")

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

(defvar-local matisse--interrupted-session-id nil
  "Session ID preserved after interruption for resuming.")

(defvar-local matisse--interrupted-tools nil
  "List of tools that were active when interruption occurred.")

(defvar-local matisse--pending-message nil
  "The last message sent that hasn't received a response yet.")

(defvar-local matisse--current-model nil
  "The current model for this session. If nil, uses matisse-default-model.")


(defvar matisse--last-selection nil
  "Last text selection from a non-matisse buffer.
Contains an alist with keys: file-path, start-line, end-line,
start-char, end-char, text, has-selection.")

(defvar matisse--selection-timer nil
  "Timer for debouncing selection updates.")

;;; Token tracking variables

(defvar-local matisse--total-tokens-used 0
  "Total tokens used in current conversation.")

(defvar-local matisse--tokens-since-compact 0
  "Tokens used since last compaction.")

(defcustom matisse-auto-compact-threshold 50000
  "Suggest compaction after this many tokens (roughly 25% of context)."
  :type 'integer
  :group 'matisse)

(defcustom matisse-show-token-usage t
  "Whether to display token usage in mode line."
  :type 'boolean
  :group 'matisse)


(defvar matisse-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "q" #'matisse-quit)
    (define-key map "c" #'matisse-cancel)
    map)
  "Keymap for Matisse commands.")

;;; Minor mode

(defvar matisse--mode-line-format nil
  "Current mode line format for matisse-mode.")

;;; Utility functions

(defun matisse--get-project-directory ()
  "Get the project directory for Claude sessions based on initial directory."
  (expand-file-name
   (concat "~/.claude/projects/"
           (let ((dir (directory-file-name (or matisse--initial-directory default-directory))))
             (if (string-match "^\\(.*\\)/\\([^/]+\\)$" dir)
                 (concat (replace-regexp-in-string "/" "-" (match-string 1 dir))
                         "-" (match-string 2 dir))
               (replace-regexp-in-string "/" "-" dir))))))

(defun matisse--get-session-file (session-id)
  "Get the session file path for SESSION-ID."
  (expand-file-name (concat session-id ".jsonl") (matisse--get-project-directory)))

(defun matisse-get-latest-conversation-file ()
  "Get the path to the most recent conversation file."
  (let* ((project-dir (matisse--get-project-directory))
         (files (when (file-directory-p project-dir)
                  (directory-files project-dir t "\\.jsonl$" t))))
    (when files
      (car (sort files (lambda (a b)
                         (time-less-p (nth 5 (file-attributes b))
                                     (nth 5 (file-attributes a)))))))))

(defun matisse-replay-previous-conversation ()
  "Replay the previous conversation in current buffer.

Returns \='user if last message was from user, \='assistant if from
assistant, nil if no messages."
  (let ((file (matisse-get-latest-conversation-file))
        (target-buffer (current-buffer))
        (message-count 0)
        (last-message-type nil))
    (when file
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position)
                       (line-end-position))))
            (when (and (> (length line) 0)
                       (string-match "\"type\":\"\\(user\\|assistant\\)\"" line))
              (condition-case nil
                  (let* ((json (json-parse-string line :object-type 'alist))
                         (type (alist-get 'type json))
                         (message (alist-get 'message json))
                         (content (alist-get 'content message)))
                    (when content
                      ;; Handle both list and vector formats
                      (let ((items (if (vectorp content)
                                       (append content nil) ; Convert vector to list
                                     content)))
                        (dolist (item items)
                          (when (equal (alist-get 'type item) "text")
                            (let ((text (alist-get 'text item)))
                              (when text
                                (setq message-count (1+ message-count))
                                (setq last-message-type (intern type))
                                (with-current-buffer target-buffer
                                  (let ((inhibit-read-only t))
                                    (cond
                                     ((equal type "user")
                                      ;; Format user message with prompt char and inactive face
                                      (let ((prompt-char (matisse--get-shell-prompt-character)))
                                        (insert (propertize (concat prompt-char " " text)
                                                            'face 'matisse-prompt-inactive-face))
                                        (insert "\n")))
                                     ((equal type "assistant")
                                      ;; Format assistant message - just text
                                      (insert text)
                                      (insert "\n\n"))))))))))))
                (error nil))))
          (forward-line)))
      ;; Return the last message type
      last-message-type)))

(defun matisse--update-mode-line ()
  "Update the mode line with current spinner state and selection info."
  (let* ((spinner-part (if matisse--waiting-for-response
                           (if (< (mod matisse--spinner-index 2) 1)
                               " 🔥"  ; Fire emoji when "on"
                             " 🤖") ; Robot when "off"
                         " 🤖"))
         (selection-part (matisse--format-selection-status))
         (token-part (matisse--format-token-status)))
    (setq matisse--mode-line-format
          (concat spinner-part
                  (if token-part (concat " " token-part) "")
                  (if selection-part (concat " " selection-part) "")))
    (force-mode-line-update t)))

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
        (run-at-time matisse-spinner-interval matisse-spinner-interval (matisse--make-spinner-tick (current-buffer))))
  (matisse--update-mode-line))

(defun matisse--stop-spinner ()
  "Stop the spinner animation."
  (when matisse--spinner-timer
    (cancel-timer matisse--spinner-timer)
    (setq matisse--spinner-timer nil))
  (matisse--update-mode-line))

(defun matisse--finish-current-message ()
  "Mark the current message as finished."
  ;; Stop spinner in shell buffer if it exists
  (let* ((buffer-name (plist-get matisse--shell-context :buffer-name))
         (shell-buffer (and buffer-name (get-buffer buffer-name))))
    (if (and shell-buffer (buffer-live-p shell-buffer))
        (with-current-buffer shell-buffer
          (setq matisse--waiting-for-response nil)
          (matisse--stop-spinner))
      ;; Fallback for non-shell usage
      (setq matisse--waiting-for-response nil)
      (matisse--stop-spinner))))

(defvar matisse-mode-map
  (let ((map (make-sparse-keymap)))
    (when matisse-prefix-key
      (define-key map (kbd matisse-prefix-key) matisse-command-map))
    map)
  "Keymap for `matisse-mode'.")

(defun matisse--cleanup-on-kill ()
  "Cleanup function called when a matisse buffer is killed.
Does the same cleanup as `matisse-quit' without killing the buffer."
  (when matisse--process
    (delete-process matisse--process)
    (setq matisse--process nil))
  (setq matisse--pending-json ""
        matisse--conversation-id nil
        matisse--message-count 0
        matisse--shell-context nil
        matisse--waiting-for-response nil
        matisse--active-tools nil
        matisse--progress-buffer ""
        matisse--interrupted-session-id nil
        matisse--interrupted-tools nil
        matisse--pending-message nil
        matisse--current-model nil)
  (matisse--stop-spinner)
  ;; Clean up selection timer
  (when matisse--selection-timer
    (cancel-timer matisse--selection-timer)
    (setq matisse--selection-timer nil)))

(define-minor-mode matisse-mode
  "Minor mode for Matisse Claude Code interface."
  :lighter (:eval matisse--mode-line-format)
  :global nil
  :keymap matisse-mode-map
  (if matisse-mode
      (progn
        (matisse--update-mode-line)
        ;; Update mode line for matisse-mode activation
        ;; Add buffer-local kill hook to do full cleanup
        (add-hook 'kill-buffer-hook #'matisse--cleanup-on-kill nil t)
        ;; Add global hook for selection tracking
        (add-hook 'post-command-hook #'matisse--track-selection-change))
    (progn
      (when matisse--spinner-timer
        (cancel-timer matisse--spinner-timer)
        (setq matisse--spinner-timer nil))
      ;; Remove the kill hook
      (remove-hook 'kill-buffer-hook #'matisse--cleanup-on-kill t)
      ;; Remove selection tracking hook when no matisse buffers are active
      (unless (cl-some (lambda (buffer)
                         (with-current-buffer buffer
                           matisse-mode))
                       (buffer-list))
        (remove-hook 'post-command-hook #'matisse--track-selection-change)))))


;;; Utility functions

(defun matisse--get-current-model ()
  "Get the current model to use for this session."
  (or matisse--current-model matisse-default-model))

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

(defun matisse--generate-hook-settings ()
  "Generate Claude Code hooks settings JSON for permission handling.
Returns a JSON string configuring PreToolUse and PostToolUse hooks."
  (let* ((matisse-file (locate-library "matisse"))
         ;; If it's a symlink, get the real path
         (matisse-real-file (if matisse-file
                               (file-truename matisse-file)
                             (error "Cannot locate matisse.el")))
         (matisse-dir (file-name-directory matisse-real-file))
         (wrapper-path (expand-file-name "matisse-hook-wrapper.sh" matisse-dir)))
    ;; Check if wrapper script exists
    (unless (file-exists-p wrapper-path)
      (error "Matisse hook wrapper script not found at: %s
Please ensure matisse-hook-wrapper.sh is in the same directory as matisse.el" wrapper-path))
    ;; Check if wrapper script is executable
    (unless (file-executable-p wrapper-path)
      (error "Matisse hook wrapper script is not executable: %s
Please run: chmod +x %s" wrapper-path wrapper-path))
    (let* ((pretool-command (format "%s pretooluse" wrapper-path))
           (posttool-command (format "%s posttooluse" wrapper-path))
           (pretool-hook
            (vector
             (list (cons 'matcher "")
                   (cons 'hooks
                         (vector
                          (list (cons 'type "command")
                                (cons 'command pretool-command)
                                (cons 'timeout 30)))))))
           (posttool-hook
            (vector
             (list (cons 'matcher "")
                   (cons 'hooks
                         (vector
                          (list (cons 'type "command")
                                (cons 'command posttool-command)
                                (cons 'timeout 30)))))))
           (settings
            `((hooks . ((PreToolUse . ,pretool-hook)
                       (PostToolUse . ,posttool-hook))))))
      (json-encode settings))))

;;; Hook handlers for Claude Code permission system

(defvar matisse--pending-tool-requests (make-hash-table :test 'equal)
  "Hash table storing pending tool requests by buffer name.")

(defun matisse-handle-pretooluse-hook (json-data)
  "Handle PreToolUse hook from Claude Code.
This is called by emacsclient when Claude wants to use a tool.
JSON-DATA is the JSON string passed from Claude Code via stdin.
Returns a JSON response with permission decision."
  (condition-case err
      (let* ((json-obj (json-read-from-string json-data))
             ;; Claude Code uses snake_case not camelCase
             (tool-name (or (alist-get 'tool_name json-obj)
                           (alist-get 'toolName json-obj)))
             (tool-input (or (alist-get 'tool_input json-obj)
                            (alist-get 'toolInput json-obj)))
             (decision (matisse--decide-tool-permission tool-name tool-input)))

        ;; Log the hook event
        (matisse--debug-log "PreToolUse hook: tool=%s, decision=%s"
                          tool-name decision)

        ;; Return JSON response
        (json-encode
         `((hookSpecificOutput . ((hookEventName . "PreToolUse")
                                 (permissionDecision . ,decision)
                                 (permissionDecisionReason . ,(if (string= decision "allow")
                                                                 "Approved by Matisse"
                                                               "Denied by Matisse")))))))
    (error
     ;; On error, allow the tool to avoid blocking Claude
     (ignore-errors  ; Suppress any message errors
       (message "Matisse hook error: %s" (error-message-string err)))
     (json-encode
      `((hookSpecificOutput . ((hookEventName . "PreToolUse")
                              (permissionDecision . "allow")
                              (permissionDecisionReason . "Error in hook, allowing by default"))))))))

(defun matisse-handle-posttooluse-hook (json-data)
  "Handle PostToolUse hook from Claude Code.
This is called by emacsclient after Claude uses a tool.
JSON-DATA is the JSON string passed from Claude Code via stdin."
  (when json-data
    (condition-case err
        (let* ((json-obj (json-read-from-string json-data))
               ;; Claude Code passes tool_name and tool_output (with underscores)
               (tool-name (or (alist-get 'tool_name json-obj)
                             (alist-get 'toolName json-obj)))
               (_tool-output (or (alist-get 'tool_output json-obj)
                                (alist-get 'toolOutput json-obj))))
          (matisse--debug-log "PostToolUse hook: tool=%s" tool-name))
      (error
       (message "Matisse post-hook error: %s" (error-message-string err)))))
  ;; Return empty JSON response
  (json-encode '((hookSpecificOutput . nil))))

(defun matisse--decide-tool-permission (tool-name tool-input)
  "Decide whether to allow TOOL-NAME with TOOL-INPUT.
Returns \"allow\" or \"deny\"."
  ;; For now, implement a simple allow-list approach
  ;; You can make this more sophisticated with user prompts
  (cond
   ;; Always allow read-only tools
   ((member tool-name '("Read" "Grep" "Glob" "WebSearch" "WebFetch" "ListMcpResourcesTool" "ReadMcpResourceTool"))
    "allow")

   ;; Ask user for dangerous commands
   ((string= tool-name "Bash")
    (if (matisse--prompt-for-bash-permission tool-input)
        "allow"
      "deny"))

   ;; Ask for file modifications
   ((member tool-name '("Write" "Edit" "MultiEdit"))
    (if (matisse--prompt-for-file-permission tool-name tool-input)
        "allow"
      "deny"))

   ;; Default to asking
   (t
    (let* ((prompt (format "Allow %s tool? (y/n): " tool-name))
           (char (read-char-choice prompt '(?y ?n ?Y ?N))))
      (if (memq char '(?y ?Y))
          "allow"
        "deny")))))

(defun matisse--prompt-for-bash-permission (tool-input)
  "Prompt user to approve Bash command with TOOL-INPUT."
  (let ((command (alist-get 'command tool-input)))
    ;; Suppress server connection errors during prompt
    (with-demoted-errors "Server connection warning: %S"
      ;; Use read-char-choice for robust input handling
      (let* ((prompt (format "Allow command: %s? (y/n): " command))
             (char (read-char-choice prompt '(?y ?n ?Y ?N))))
        (memq char '(?y ?Y))))))

(defun matisse--prompt-for-file-permission (tool-name tool-input)
  "Prompt user to approve file operation TOOL-NAME with TOOL-INPUT."
  (let ((file-path (or (alist-get 'file_path tool-input)
                        (alist-get 'path tool-input))))
    ;; Suppress server connection errors during prompt
    (with-demoted-errors "Server connection warning: %S"
      ;; Use read-char-choice for robust input handling
      (let* ((prompt (format "Allow %s on %s? (y/n): " tool-name file-path))
             (char (read-char-choice prompt '(?y ?n ?Y ?N))))
        (memq char '(?y ?Y))))))

;;; Progress context parsing and formatting
(defun matisse--at-end-of-line-p ()
  "Check if the shell buffer position is at end of line.
Returns t if the buffer is empty or if we're looking at a newline."
  ;; Since we're working within the shell buffer context during output,
  ;; we can check the current buffer state directly
  (condition-case nil
      (or (= (point) (point-min))  ; empty buffer
            (= (char-after) ?\n)) ; ends with newline
    (error t)))  ; Default to true (add newline) if we can't determine

(defun matisse--apply-icon-face-properties (icon-string &optional color-face)
  "Apply face properties to ICON-STRING based on current settings.
Returns the icon string with appropriate face properties applied.
COLOR-FACE is an optional face to apply for coloring (used with nerd icons)."
  (when (and icon-string (not (string-empty-p icon-string)))
    (let ((styled-icon (copy-sequence icon-string))
          (face-props `(:height ,matisse-icons-scale-factor)))
      ;; If a color face is provided and we're using nerd icons, inherit from it
      (when (and color-face (eq matisse-progress-icons-mode 'nerd-icons))
        (setq face-props `(:height ,matisse-icons-scale-factor :inherit ,color-face)))
      (put-text-property 0 (length styled-icon) 'font-lock-face face-props styled-icon)
      styled-icon)))

(defun matisse--get-tool-icon (tool-name)
  "Get the appropriate icon for TOOL-NAME based on current icon mode."
  (pcase matisse-progress-icons-mode
    ('emoji
     (let ((icon (pcase tool-name
                   ("Read" matisse-emoji-icon-read)
                   ("Write" matisse-emoji-icon-write)
                   ("Edit" matisse-emoji-icon-edit)
                   ("MultiEdit" matisse-emoji-icon-multiedit)
                   ("Bash" matisse-emoji-icon-bash)
                   ("Grep" matisse-emoji-icon-grep)
                   ("Glob" matisse-emoji-icon-glob)
                   ("Task" matisse-emoji-icon-task)
                   ("WebFetch" matisse-emoji-icon-webfetch)
                   ("TodoWrite" matisse-emoji-icon-todowrite)
                   (_ matisse-emoji-icon-default))))
       (concat (matisse--apply-icon-face-properties icon) " ")))
    ('nerd-icons
     (let ((icon-and-face (pcase tool-name
                            ("Read" (cons matisse-nerd-icon-read matisse-nerd-icon-read-face))
                            ("Write" (cons matisse-nerd-icon-write matisse-nerd-icon-write-face))
                            ("Edit" (cons matisse-nerd-icon-edit matisse-nerd-icon-edit-face))
                            ("MultiEdit" (cons matisse-nerd-icon-multiedit matisse-nerd-icon-multiedit-face))
                            ("Bash" (cons matisse-nerd-icon-bash matisse-nerd-icon-bash-face))
                            ("Grep" (cons matisse-nerd-icon-grep matisse-nerd-icon-grep-face))
                            ("Glob" (cons matisse-nerd-icon-glob matisse-nerd-icon-glob-face))
                            ("Task" (cons matisse-nerd-icon-task matisse-nerd-icon-task-face))
                            ("WebFetch" (cons matisse-nerd-icon-webfetch matisse-nerd-icon-webfetch-face))
                            ("TodoWrite" (cons matisse-nerd-icon-todowrite matisse-nerd-icon-todowrite-face))
                            (_ (cons matisse-nerd-icon-default matisse-nerd-icon-default-face)))))
       (concat (matisse--apply-icon-face-properties (car icon-and-face) (cdr icon-and-face)) " ")))
    ('ascii "- ")
    (_ "")))

(defun matisse--get-success-icon ()
  "Get the appropriate success icon based on current icon mode."
  (pcase matisse-progress-icons-mode
    ('emoji (concat (matisse--apply-icon-face-properties matisse-emoji-icon-success) " "))
    ('nerd-icons (concat (matisse--apply-icon-face-properties matisse-nerd-icon-success matisse-nerd-icon-success-face) " "))
    ('ascii "- ")
    (_ "")))

(defun matisse--get-performance-icon ()
  "Get the appropriate performance icon based on current icon mode."
  (pcase matisse-progress-icons-mode
    ('emoji (concat (matisse--apply-icon-face-properties matisse-emoji-icon-performance) " "))
    ('nerd-icons (concat (matisse--apply-icon-face-properties matisse-nerd-icon-performance matisse-nerd-icon-performance-face) " "))
    ('ascii "- ")
    (_ "")))

(defun matisse--get-shell-prompt-character ()
  "Get the appropriate shell prompt character based on current icon mode."
  (pcase matisse-progress-icons-mode
    ('emoji matisse-emoji-shell-prompt)
    ('nerd-icons matisse-nerd-shell-prompt)
    ('ascii matisse-ascii-shell-prompt)
    (_ matisse-ascii-shell-prompt)))

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
                                   (concat (substring cmd 0 47) "…")
                                 cmd)))
                     ("Grep" (format "\"%s\"" (alist-get 'pattern input-data)))
                     ("Glob" (format "\"%s\"" (alist-get 'pattern input-data)))
                     ("Task" (alist-get 'description input-data))
                     ("WebFetch" (alist-get 'url input-data))
                     ("TodoWrite" "todo list")
                     (_ tool-name))))
      (if target
          (format "%s%s %s…" (if (string-empty-p icon) "" icon) action target)
        (format "%s%s %s…" (if (string-empty-p icon) "" icon) action tool-name)))))

(defun matisse--format-file-change-summary (tool-name result-content)
  "Format a file change summary for TOOL-NAME with RESULT-CONTENT."
  (when (and matisse-show-file-changes
             (member tool-name '("Edit" "MultiEdit" "Write")))
    (cond
     ;; Handle Edit/MultiEdit results that show file updates
     ((string-match "The file \\(.+\\) has been updated" result-content)
      (let ((file-path (match-string 1 result-content))
            (icon (matisse--get-success-icon)))
        (format "%sUpdated %s" icon (file-name-nondirectory file-path))))

     ;; Handle Write operations
     ((and (equal tool-name "Write")
           (string-match "file" result-content))
      (let ((icon (matisse--get-success-icon)))
        ;; [TODO] sometimes this prints when file writing has not completed
        (format "%sFile written successfully" icon)))

     ;; Generic success for file operations
     ((member tool-name '("Edit" "MultiEdit" "Write"))
      (let ((icon (matisse--get-success-icon)))
        (format "%sFile operation completed" icon))))))

(defun matisse--format-performance-summary (result-data)
  "Format a performance summary from RESULT-DATA."
  (when matisse-show-performance-summary
    (let* ((duration (alist-get 'duration_ms result-data))
           (cost (alist-get 'total_cost_usd result-data))
           (usage (alist-get 'usage result-data))
           (output-tokens (when usage (alist-get 'output_tokens usage)))
           (icon (matisse--get-performance-icon))
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

;;; Token tracking helpers

(defun matisse--track-tokens (json-obj)
  "Track token usage from result messages.
JSON-OBJ is the result message containing usage data."
  (let* ((usage (alist-get 'usage json-obj))
         (input-tokens (when usage (alist-get 'input_tokens usage)))
         (output-tokens (when usage (alist-get 'output_tokens usage)))
         (total-this-turn (+ (or input-tokens 0) (or output-tokens 0))))

    (when (> total-this-turn 0)
      (setq matisse--total-tokens-used (+ matisse--total-tokens-used total-this-turn))
      (setq matisse--tokens-since-compact (+ matisse--tokens-since-compact total-this-turn))

      ;; Check if we should suggest compaction
      (when (> matisse--tokens-since-compact matisse-auto-compact-threshold)
        (matisse--suggest-compaction))

      (matisse--debug-log "Tokens this turn: %d (total: %d, since compact: %d)"
                          total-this-turn
                          matisse--total-tokens-used
                          matisse--tokens-since-compact)

      ;; Update mode line to show new token count
      (matisse--update-mode-line))))

(defun matisse--suggest-compaction ()
  "Suggest to user that they should compact the conversation."
  (when matisse--shell-context
    (funcall (plist-get matisse--shell-context :write-output)
             "\n⚠️  Context is getting long (>50k tokens). Consider starting a fresh conversation.\n"))
  (message "Tip: Context is getting long. Consider starting a fresh conversation"))

(defun matisse--format-token-status ()
  "Format token usage for mode line display."
  (when (and matisse-show-token-usage (> matisse--tokens-since-compact 0))
    (let* ((tokens-k (/ matisse--tokens-since-compact 1000))
           (percentage (if (> matisse-auto-compact-threshold 0)
                           (* 100.0 (/ (float matisse--tokens-since-compact)
                                      matisse-auto-compact-threshold))
                         0))
           (face (cond
                  ((>= percentage 90) '(:foreground "red" :weight bold))
                  ((>= percentage 70) '(:foreground "orange"))
                  ((>= percentage 50) '(:foreground "yellow"))
                  (t nil))))
      (propertize (format "[%dk]" tokens-k) 'face face))))

;;; JSON handling

;; Buffer-local variable to store pending images
(defvar-local matisse--pending-images nil
  "List of pending images to be included with the next message.
Each element is a plist with :type, :data, and optionally :filename.")

(defun matisse--add-pending-image (mime-type data &optional filename)
  "Add an image to the pending images list.
MIME-TYPE is the MIME type of the image.
DATA is the raw image data.
FILENAME is an optional filename hint."
  (let ((media-type (cond
                     ((string-prefix-p "image/jpeg" mime-type) "image/jpeg")
                     ((string-prefix-p "image/jpg" mime-type) "image/jpeg")
                     ((string-prefix-p "image/png" mime-type) "image/png")
                     ((string-prefix-p "image/gif" mime-type) "image/gif")
                     ((string-prefix-p "image/webp" mime-type) "image/webp")
                     ((string-prefix-p "image/bmp" mime-type) "image/bmp")
                     (t "image/png")))) ; fallback
    (push (list :type media-type
                :data (base64-encode-string data t)
                :filename filename)
          matisse--pending-images)
    (message "Image added to next message%s"
             (if filename (format " (%s)" filename) ""))))

(defun matisse--format-user-message (text)
  "Format TEXT as a JSON message for Claude Code.
If `matisse-send-selection-p' is non-nil and there's a last selection,
append it as context to the text.
If there are pending images, include them in the message content."
  (let* ((selection-context (matisse--format-selection-context))
         (enhanced-text (if selection-context
                            (concat text "\n\n" selection-context)
                          text))
         (content-blocks (list (list (cons 'type "text")
                                     (cons 'text enhanced-text)))))

    ;; Add any pending images to content blocks
    (when matisse--pending-images
      (dolist (image (reverse matisse--pending-images))
        (push (list (cons 'type "image")
                    (cons 'source (list (cons 'type "base64")
                                        (cons 'media_type (plist-get image :type))
                                        (cons 'data (plist-get image :data)))))
              content-blocks))
      ;; Clear pending images after adding them
      (setq matisse--pending-images nil))

    (json-encode
     `((type . "user")
       (message . ((role . "user")
                   (content . ,(vconcat content-blocks))))))))

(defun matisse--parse-json-line (line)
  "Parse a single LINE of JSON output from Claude Code."
  (condition-case nil
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

(defun matisse--debug-log (_format-str &rest args)
  "Log debug message to buffer if debugging is enabled.
FORMAT-STR is the format string for the message.
ARGS are the arguments for the format string."
  (when matisse-debug
    (message "%S" args)))

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
                 ((and (equal (alist-get 'type json-obj) "system")
                       (equal (alist-get 'subtype json-obj) "init"))
                  (setq matisse--conversation-id (alist-get 'session_id json-obj)))

                 ((equal (alist-get 'type json-obj) "assistant")
                  ;; Clear pending message since we got a response
                  (setq matisse--pending-message nil)

                  (let ((tool-uses (matisse--extract-tool-use json-obj)))
                    (dolist (tool-use tool-uses)
                      (let* ((tool-name (alist-get 'name tool-use))
                             (tool-input (alist-get 'input tool-use))
                             (tool-id (alist-get 'id tool-use))
                             (progress-msg (matisse--format-progress-indicator tool-name tool-input)))
                        (when progress-msg
                          (matisse--debug-log "Tool progress: %s" progress-msg)
                          (push `((id . ,tool-id) (name . ,tool-name) (input . ,tool-input)) matisse--active-tools)
                          ;; Display progress indicator
                          (when (and matisse--shell-context
                                     (plist-get matisse--shell-context :write-output))
                            (condition-case err
                                (let ((prefix (if (matisse--at-end-of-line-p) "" "\n")))
                                  (funcall (plist-get matisse--shell-context :write-output)
                                           (concat prefix progress-msg)))
                              (error (matisse--debug-log "Error writing progress: %s" (error-message-string err)))))))))

                  (let ((text (matisse--extract-assistant-text json-obj)))
                    (matisse--debug-log "Assistant text: %s" text)
                    (matisse--debug-log "Shell context exists: %s" (if matisse--shell-context "yes" "no"))
                    (when matisse--shell-context
                      (matisse--debug-log "write-output function: %s" (plist-get matisse--shell-context :write-output)))
                    (when (and text
                               (not (string-empty-p text)))
                      (matisse--debug-log "Writing output to shell: %s" text)
                      (condition-case err
                          (progn
                            ;; Route to matisse-shell implementation
                            (matisse--route-to-shell text)
                            (matisse--debug-log "Output written successfully")) ;; END progn
                        (error (matisse--debug-log "Error writing output: %s" (error-message-string err)))) ;; END condition-case
                      )))

                 ((equal (alist-get 'type json-obj) "result")
                  ;; Clear pending message since we got a response
                  (setq matisse--pending-message nil)
                  (matisse--debug-log "Got result, finishing output")
                  ;; Track token usage
                  (matisse--track-tokens json-obj)
                  ;; Show performance summary if enabled
                  (let ((perf-summary (matisse--format-performance-summary json-obj)))
                    (when (and perf-summary
                               matisse--shell-context
                               (plist-get matisse--shell-context :write-output))
                      (condition-case err
                          (funcall (plist-get matisse--shell-context :write-output)
                                   perf-summary)
                        (error (matisse--debug-log "Error writing performance summary: %s" (error-message-string err))))))
                  ;; Apply markdown overlays to the response
                  (condition-case err
                      (matisse--overlays-put)
                    (error (matisse--debug-log "Error applying markdown overlays: %s" (error-message-string err))))
                  ;; Clear active tools and reset state
                  (setq matisse--active-tools nil)
                  ;; Finish the current shell command before processing next
                  (when (and matisse--shell-context
                             (plist-get matisse--shell-context :finish-output))
                    (condition-case err
                        (funcall (plist-get matisse--shell-context :finish-output))
                      (error (matisse--debug-log "Error finishing output: %s" (error-message-string err)))))
                  ;; Signal matisse-shell that response is complete
                  (when (fboundp 'matisse-shell--signal-response-complete)
                    (condition-case err
                        (matisse-shell--signal-response-complete)
                      (error (matisse--debug-log "Error signaling response complete: %s" (error-message-string err)))))
                  ;; Now finish current message and process next
                  (matisse--finish-current-message)) ;; END COND CLAUSE 3

                 (t
                  (matisse--debug-log "Unhandled message type: %s" (alist-get 'type json-obj))))))))))))

(defun matisse--interrupt ()
  "Gracefully interrupt the current Claude process while preserving session state."
  (if (and matisse--process (process-live-p matisse--process))
      (progn
        ;; If no session ID yet, that means Claude is still processing the very first message
        ;; and has not written the session file. Just kill and restart a new session.
        (unless matisse--conversation-id
          (when matisse--active-tools
            (setq matisse--interrupted-tools (copy-sequence matisse--active-tools))))

        ;; Stop UI indicators
        (matisse--stop-spinner)

        ;; Store active tools for potential cleanup notification
        (when matisse--active-tools
          (setq matisse--interrupted-tools (copy-sequence matisse--active-tools)))

        ;; Store session ID for resuming
        (when matisse--conversation-id
          (setq matisse--interrupted-session-id matisse--conversation-id))

        ;; Reset state variables
        (setq matisse--waiting-for-response nil
              matisse--active-tools nil)

        ;; Send SIGINT (Ctrl+C) for graceful interruption that preserves session
        (interrupt-process matisse--process)

        ;; Set timer for SIGTERM if process doesn't terminate gracefully
        (run-at-time 2 nil
                     (lambda (proc)
                       (when (and proc (process-live-p proc))
                         (signal-process proc 'SIGTERM)
                         ;; And SIGKILL as last resort
                         (run-at-time 1 nil
                                      (lambda (p)
                                        (when (and p (process-live-p p))
                                          (signal-process p 'SIGKILL)
                                          (message "Force-killed Claude process")))
                                      proc)))
                     matisse--process)

        ;; Clear process reference but keep session ID
        (setq matisse--process nil))
    (message "No active Claude process to interrupt")))

(defun matisse--restore ()
  "Resume the interrupted Claude conversation."
  (let ((session-id (or matisse--interrupted-session-id
                        matisse--conversation-id)))
    (if session-id
        (progn
          ;; Kill any existing process
          (when (and matisse--process (process-live-p matisse--process))
            (delete-process matisse--process))

          ;; Clear any interrupted tools without verbose notification
          (when matisse--interrupted-tools
            (matisse--debug-log "Resuming with %d interrupted tool(s)"
                                (length matisse--interrupted-tools)))

          ;; Start new process with resume flag
          (matisse--start-process-with-resume session-id)

          ;; Clear interrupted state
          (setq matisse--interrupted-session-id nil
                matisse--interrupted-tools nil))
      ;; No session to resume - the pending message will be handled by matisse--send-message
      (message "Ready for new conversation."))))

(defun matisse--wait-for-session-file (session-id callback check-count)
  "Wait for session file to exist before resuming.
SESSION-ID is the session to check for.
CALLBACK is called after successful resume.
CHECK-COUNT tracks how many times we've checked."
  (let* ((session-file (matisse--get-session-file session-id)))
    (if (file-exists-p session-file)
        ;; Session file exists, safe to resume
        (progn
          (message "Interrupted.")
          (matisse--restore)
          (when callback
            (funcall callback)))
      ;; Session file doesn't exist yet, check again
      (if (< check-count 20)            ; Max 2 seconds wait
          (progn
            ;; Don't show waiting message - just wait silently
            (run-at-time 0.1 nil
                         (lambda ()
                           (matisse--wait-for-session-file session-id callback (1+ check-count)))))
        ;; Timeout - session file never appeared, start fresh
        (progn
          (message "Could not resume session id %s - starting new conversation" session-id)
          (setq matisse--interrupted-session-id nil) ; Clear it so we don't try to resume
          (matisse--restore)
          (when callback
            (funcall callback)))))))

(defun matisse--wait-and-resume (callback check-count)
  "Wait for process to terminate, then resume.
CALLBACK is called after successful resume.
CHECK-COUNT tracks how many times we've checked."
  (if (or (not matisse--process) (not (process-live-p matisse--process)))
      ;; Process is dead, now wait for session file to be written
      (if matisse--interrupted-session-id
          (matisse--wait-for-session-file matisse--interrupted-session-id callback 0)
        ;; No session to resume
        (progn
          (matisse--restore)
          (when callback
            (funcall callback))))
    ;; Process still alive, check again
    (if (< check-count 30) ; Max 3 seconds wait
        (run-at-time 0.1 nil
                     (lambda ()
                       (matisse--wait-and-resume callback (1+ check-count))))
      ;; Timeout - force kill and resume
      (progn
        (message "Process didn't terminate gracefully, forcing...")
        (when (and matisse--process (process-live-p matisse--process))
          (delete-process matisse--process)
          (setq matisse--process nil))
        (run-at-time 0.2 nil
                     (lambda ()
                       (matisse--restore)
                       (when callback
                         (funcall callback))))))))

(defun matisse--interrupt-and-resume (&optional callback)
  "Interrupt current process and resume session after a delay.
If CALLBACK is provided, it will be called after resumption."
  (when (and matisse--process (process-live-p matisse--process))
    ;; Store session for resume if available
    (when matisse--conversation-id
      (setq matisse--interrupted-session-id matisse--conversation-id))
    (matisse--interrupt))
  ;; Wait for process to fully terminate before resuming
  (matisse--wait-and-resume callback 0))

(defun matisse-cancel ()
  "Cancel the currently processing message.
Interrupts Claude and restarts the process while preserving the session."
  (interactive)
  ;; Check if we're in a matisse-shell buffer with active message processing
  (if (and (boundp 'matisse--current-message-id)
           matisse--current-message-id)
      (progn
        ;; Remove the current message from pending queue if it's there
        (when (boundp 'matisse--pending-messages)
          (setq matisse--pending-messages
                (cl-remove-if (lambda (msg)
                                (= (car msg) matisse--current-message-id))
                              matisse--pending-messages)))

        ;; Clear current message state
        (setq matisse--current-message-id nil)

        ;; Update the response section to show cancellation
        (when (fboundp 'matisse-shell--write-progress)
          (matisse-shell--write-progress "[Message cancelled]"))
        (when (fboundp 'matisse-shell--finish-output)
          (matisse-shell--finish-output))

        ;; Use the shared interrupt-and-resume function to preserve session
        (matisse--interrupt-and-resume
         (lambda ()
           ;; Process any remaining queued messages after resumption
           (when (and (boundp 'matisse--pending-messages)
                      matisse--pending-messages)
             (run-at-time 0.1 nil
                          (lambda ()
                            (when (fboundp 'matisse--process-next-message)
                              (matisse--process-next-message)))))))

        (message "Matisse message cancelled"))
    ;; If no active message, just interrupt
    (when (and matisse--process (process-live-p matisse--process))
      (matisse--interrupt-and-resume)
      (message "Matisse process interrupted"))))

(defun matisse--create-process-with-options (&optional resume-session-id continue-flag)
  "Create Claude Code process with optional RESUME-SESSION-ID or CONTINUE-FLAG.
Returns the created process object."
  (when (and matisse--process (process-live-p matisse--process))
    (delete-process matisse--process))

  (let* ((api-key (matisse--get-api-key))
         (process-environment (cons (format "ANTHROPIC_API_KEY=%s" api-key)
                                    process-environment))
         (cmd (list matisse-claude-code-path
                    "--permission-mode" matisse-permission-mode
                    "--input-format" "stream-json"
                    "--output-format" "stream-json")))

    ;; Add hooks settings if not in bypassPermissions mode
    (unless (string= matisse-permission-mode "bypassPermissions")
      (let ((hook-settings (matisse--generate-hook-settings)))
        (setq cmd (append cmd (list "--settings" hook-settings)))))

    ;; Add continue flag if requested
    (when continue-flag
      (setq cmd (append cmd (list "--continue"))))

    ;; Add resume flag if session ID provided
    (when resume-session-id
      (setq cmd (append cmd (list "--resume" resume-session-id))))

    ;; Add verbose flag
    (setq cmd (append cmd (list "--verbose")))

    ;; Add optional parameters
    (when (matisse--get-current-model)
      (setq cmd (append cmd (list "--model" (matisse--get-current-model)))))
    (when matisse-temperature
      (setq cmd (append cmd (list "--temperature"
                                  (number-to-string matisse-temperature)))))
    (when matisse-max-tokens
      (setq cmd (append cmd (list "--max-tokens"
                                  (number-to-string matisse-max-tokens)))))
    (when matisse-allowed-tools
      (setq cmd (append cmd (list "--allowedTools" matisse-allowed-tools))))

    ;; Log the command
    (matisse--debug-log "Starting process%s, command: %s"
                        (if resume-session-id " with resume" "")
                        (string-join cmd " "))

    ;; Create the process
    (let ((process-name (format "matisse-claude-%s" (buffer-name)))
          (stderr-name (format " *matisse-stderr-%s*" (buffer-name))))
      (setq matisse--process
            (make-process
             :name process-name
             :command cmd
             :buffer (get-buffer-create (format " *matisse-process-%s*" (buffer-name)))
             :filter #'matisse--process-filter
             :sentinel #'matisse--enhanced-process-sentinel
             :stderr (get-buffer-create stderr-name)
             :connection-type 'pipe))
      ;; Associate the current buffer with the process
      (process-put matisse--process 'matisse-buffer (current-buffer)))

    (set-process-query-on-exit-flag matisse--process nil)
    (matisse--debug-log "Process started%s: %s"
                        (if resume-session-id " with resume" "")
                        (process-live-p matisse--process))
    matisse--process))

(defun matisse--start-process-with-resume (session-id)
  "Start the Claude Code process with SESSION-ID for resuming."
  (matisse--create-process-with-options session-id nil))

;;; Process management
(defun matisse--enhanced-process-sentinel (process event)
  "Enhanced process sentinel to handle interruptions and abnormal exits.
PROCESS is the Claude process, EVENT is the process status change."
  (matisse--debug-log "Process event: %s" event)
  (let ((buffer (process-get process 'matisse-buffer)))
    (when (and buffer (buffer-live-p buffer))
      (with-current-buffer buffer
        (cond
         ;; Normal finish
         ((string-match "finished" event)
          (matisse--stop-spinner)
          (setq matisse--waiting-for-response nil
                matisse--active-tools nil))

         ;; Process was killed/terminated (likely interrupted)
         ((or (string-match "killed" event)
              (string-match "terminated" event))
          (matisse--stop-spinner)
          (setq matisse--waiting-for-response nil))

         ;; Abnormal exit
         ((string-match "exited abnormally" event)
          (matisse--stop-spinner)
          (setq matisse--waiting-for-response nil)
          ;; Save session for potential resume
          (when matisse--conversation-id
            (setq matisse--interrupted-session-id matisse--conversation-id))
          ;; Check stderr for critical errors only
          (let ((stderr-name (format " *matisse-stderr-%s*" (buffer-name buffer)))
                (found-critical-error nil))
            (when (get-buffer stderr-name)
              (with-current-buffer (get-buffer stderr-name)
                (let ((error-output (string-trim (buffer-string))))
                  ;; Only show errors that indicate a real problem
                  (when (and (not (string-empty-p error-output))
                             (or (string-match-p "No version is set for command" error-output)
                                 (string-match-p "command not found" error-output)
                                 (string-match-p "cannot find" error-output)
                                 (string-match-p "fatal" error-output)
                                 (string-match-p "Error:" error-output)))
                    (setq found-critical-error t)
                    (matisse--stop-spinner)
                    (message "Claude Code failed to start: %s"
                             (if (> (length error-output) 200)
                                 (concat (substring error-output 0 197) "…")
                               error-output)))
                  ;; Always log to debug
                  (matisse--debug-log "Claude Code stderr: %s" error-output)
                  ;; TODO add to a matisse stderr buffer because debugging might be turned off
                  )))
            ;; Notify shell-maker that the command failed if there was a critical error
            (when (and found-critical-error
                       matisse--shell-context
                       (plist-get matisse--shell-context :finish-output))
              (funcall (plist-get matisse--shell-context :finish-output)))))

         ;; Other events
         (t
          (matisse--debug-log "Unhandled process event: %s" event)))))))

(defun matisse--start-process ()
  "Start the Claude Code process with streaming JSON."
  (matisse--create-process-with-options nil nil))

(defun matisse--send-message (text)
  "Send TEXT message to Claude Code process."
  (condition-case err
      (progn
        (unless (and matisse--process (process-live-p matisse--process))
          (matisse--start-process))

        ;; Start the visual feedback immediately
        (setq matisse--pending-message text)

        ;; Format message asynchronously to avoid blocking with image encoding
        ;; Capture current buffer context to ensure async call has correct context
        (let ((current-buffer (current-buffer)))
          (run-with-timer 0.01 nil
                          (lambda ()
                            (with-current-buffer current-buffer
                              (matisse--send-message-async text))))))
    (error
     ;; Stop the spinner and reset state
     (matisse--stop-spinner)
     (setq matisse--waiting-for-response nil
           matisse--pending-message nil) ; Clear pending message on send error
     ;; Display error message in echo area
     (message "Matisse error: %s" (error-message-string err))
     (matisse--debug-log "Error in matisse--send-message: %s" (error-message-string err)))))

(defun matisse--send-message-async (text)
  "Asynchronously format and send TEXT message to Claude Code process."
  (condition-case err
      (progn
        ;; Ensure process is still alive
        (unless (and matisse--process (process-live-p matisse--process))
          (matisse--start-process))

        (let ((json-msg (matisse--format-user-message text)))
          (matisse--debug-log "Sending JSON: %s" json-msg)
          (matisse--debug-log "Process alive before send: %s" (process-live-p matisse--process))
          (process-send-string matisse--process (concat json-msg "\n"))
          (matisse--debug-log "Process alive after send: %s" (process-live-p matisse--process))))
    (error
     ;; Stop the spinner and reset state
     (matisse--stop-spinner)
     (setq matisse--waiting-for-response nil
           matisse--pending-message nil) ; Clear pending message on send error
     ;; Display error message in echo area
     (message "Matisse error: %s" (error-message-string err))
     (matisse--debug-log "Error in matisse--send-message-async: %s" (error-message-string err)))))

;;; Selection tracking

(defun matisse--get-selection-info ()
  "Get selection information from the current buffer.
Returns alist with selection data, nil if no file or matisse buffer."
  (when (and buffer-file-name
             matisse-send-selection-p
             ;; Don't track selections from matisse shell buffers
             (not (string-match-p "\\*matisse\\*" (buffer-name))))
    (let* ((file-path (expand-file-name buffer-file-name))
           (point-pos (point))
           (has-selection (use-region-p))
           (start-pos (if has-selection (region-beginning) point-pos))
           (end-pos (if has-selection (region-end) point-pos))
           (selected-text (if has-selection
                              (buffer-substring-no-properties start-pos end-pos)
                            ""))
           (start-line (line-number-at-pos start-pos))
           (end-line (line-number-at-pos end-pos))
           (start-char (save-excursion
                         (goto-char start-pos)
                         (current-column)))
           (end-char (save-excursion
                       (goto-char end-pos)
                       (current-column))))
      `((file-path . ,file-path)
        (start-line . ,start-line)
        (end-line . ,end-line)
        (start-char . ,start-char)
        (end-char . ,end-char)
        (text . ,selected-text)
        (has-selection . ,has-selection)))))

(defun matisse--track-selection-change ()
  "Track selection changes in file buffers.
Called from `post-command-hook' to update the last selection."
  (when (and matisse-send-selection-p
             buffer-file-name
             ;; Don't track selections from matisse shell buffers
             (not (string-match-p "\\*matisse\\*" (buffer-name))))
    ;; Cancel any existing timer
    (when matisse--selection-timer
      (cancel-timer matisse--selection-timer))
    ;; Set new timer for debounced update
    (setq matisse--selection-timer
          (run-with-timer 0.05 nil ; Same delay as monet.el
                          (lambda ()
                            (let ((selection-info (matisse--get-selection-info)))
                              (when selection-info
                                (setq matisse--last-selection selection-info)
                                (matisse--update-mode-line))))))))

(defun matisse--format-selection-context ()
  "Format the last selection as a file reference string.
Returns a string like '@/path/to/file.txt#L5:10-L9:25' or nil if no selection."
  (when (and matisse-send-selection-p matisse--last-selection)
    (let* ((file-path (alist-get 'file-path matisse--last-selection))
           (start-line (alist-get 'start-line matisse--last-selection))
           (end-line (alist-get 'end-line matisse--last-selection))
           (start-char (alist-get 'start-char matisse--last-selection))
           (end-char (alist-get 'end-char matisse--last-selection))
           (has-selection (alist-get 'has-selection matisse--last-selection))
           (selected-text (alist-get 'text matisse--last-selection)))
      (when file-path
        (let ((reference (if (and has-selection (not (= start-line end-line)))
                             (format "@%s#L%d:%d-L%d:%d" file-path start-line start-char end-line end-char)
                           (format "@%s#L%d:%d" file-path start-line start-char))))
          ;; Optionally include selected text if there is any
          (if (and has-selection (not (string-empty-p selected-text)))
              (format "%s - %s" reference selected-text)
            reference))))))

(defun matisse--format-selection-status ()
  "Format selection status for mode-line display.
Returns a string like \\='in matisse.el\\=' or \\='2 lines selected\\='."
  (when (and matisse-send-selection-p matisse--last-selection)
    (let* ((file-path (alist-get 'file-path matisse--last-selection))
           (start-line (alist-get 'start-line matisse--last-selection))
           (end-line (alist-get 'end-line matisse--last-selection))
           (has-selection (alist-get 'has-selection matisse--last-selection)))
      (when file-path
        (let ((file-name (file-name-nondirectory file-path)))
          (if has-selection
              (let ((line-count (1+ (- end-line start-line))))
                (if (= line-count 1)
                    "1 line selected"
                  (format "%d lines selected" line-count)))
            (format "in %s" file-name)))))))

;;; Shell-maker integration

(defun matisse--execute-command (command shell)
  "Execute COMMAND using Claude Code, writing output to SHELL."
  (matisse--debug-log "Executing command: %s" command)
  (matisse--debug-log "Shell parameter received: %s" shell)
  (matisse--debug-log "Shell write-output: %s" (if (alist-get :write-output shell) "present" "nil"))
  (matisse--debug-log "Shell finish-output: %s" (if (alist-get :finish-output shell) "present" "nil"))

  ;; Handle exit command
  (if (string-equal (string-trim command) "exit")
      (matisse-quit)

    (condition-case err
        (progn
          ;; Store shell context for callbacks
          (setq matisse--shell-context shell)

          ;; Set buffer-local initial directory from context
          (when-let* ((initial-dir (plist-get shell :initial-directory)))
            (setq matisse--initial-directory initial-dir))
          ;; Start processing indicators in the shell buffer if it exists
          (let* ((buffer-name (plist-get shell :buffer-name))
                 (shell-buffer (and buffer-name (get-buffer buffer-name))))
            (if (and shell-buffer (buffer-live-p shell-buffer))
                (with-current-buffer shell-buffer
                  (setq matisse--waiting-for-response t)
                  (matisse--start-spinner))
              ;; Fallback for non-shell usage
              (setq matisse--waiting-for-response t)
              (matisse--start-spinner)))
          ;; Send message directly - Claude handles queuing internally
          (matisse--send-message command))
      (error
       ;; Display error message in echo area
       (message "Matisse error: %s" (error-message-string err))
       (matisse--debug-log "Error in matisse--execute-command: %s" (error-message-string err))
       ;; Notify shell-maker that the command finished with an error
       (when (alist-get :finish-output shell)
         (funcall (alist-get :finish-output shell)))))))

(defun matisse--validate-command (command)
  "Validate COMMAND before sending to Claude.
Returns nil if valid, error message string otherwise."
  (cond
   ((string-empty-p (string-trim command))
    "Please enter a message.")
   ((> (length command) 100000)         ; Arbitrary large limit
    "Message is too long.")
   (t nil)))

;;; Configuration

;; Integration with matisse-shell.el for shell functionality

;;; Public interface

;;;###autoload
(defun matisse-shell ()
  "Create a new Matisse Claude Code shell session."
  (interactive)
  (matisse--validate-setup)

  ;; Generate buffer name with automatic numbering
  (let* ((initial-dir default-directory)  ; Store current directory before buffer switching
         (existing-shells (seq-filter (lambda (buf)
                                        (with-current-buffer buf
                                          (derived-mode-p 'matisse-shell-mode)))
                                      (buffer-list)))
         (buffer-name (if (zerop (length existing-shells))
                          "*matisse-shell*"
                        (format "*matisse-shell<%d>*" (1+ (length existing-shells))))))
    ;; Create shell context with buffer name and initial directory
    (let ((shell-context (list :buffer-name buffer-name :initial-directory initial-dir)))
      ;; Use matisse-shell implementation with buffer name
      (matisse-shell-start buffer-name shell-context))))

;;;###autoload
(defun matisse-shell-switch ()
  "Switch to an existing matisse shell buffer, or create a new one if none exist."
  (interactive)
  (let ((matisse-buffers (seq-filter (lambda (buf)
                                       (with-current-buffer buf
                                         (derived-mode-p 'matisse-shell-mode)))
                                     (buffer-list))))
    (cond
     ((null matisse-buffers)
      (message "No matisse shell buffers found, creating new one...")
      (matisse-shell))
     ((= (length matisse-buffers) 1)
      (switch-to-buffer (car matisse-buffers)))
     (t
      ;; Multiple buffers - let user choose
      (let* ((buffer-names (mapcar #'buffer-name matisse-buffers))
             (selected (completing-read "Switch to matisse shell: " buffer-names nil t)))
        (when selected
          (switch-to-buffer selected)))))))

;;;###autoload
(defun matisse-continue ()
  "Continue the previous Claude conversation in a new shell.
Uses the --continue flag to maintain context from the last conversation."
  (interactive)
  (matisse--validate-setup)

  ;; Generate buffer name for continue session
  (let* ((initial-dir default-directory)
         (existing-shells (seq-filter (lambda (buf)
                                        (with-current-buffer buf
                                          (derived-mode-p 'matisse-shell-mode)))
                                      (buffer-list)))
         (buffer-name (if (zerop (length existing-shells))
                          "*matisse-shell*"
                        (format "*matisse-shell<%d>*" (1+ (length existing-shells)))))
         ;; Create shell context with continue flag
         (shell-context (list :buffer-name buffer-name
                              :initial-directory initial-dir
                              :continue-session t))
         ;; Start the shell
         (buffer (matisse-shell-start buffer-name shell-context)))
    ;; Create shell context with continue flag
    (with-current-buffer buffer
      ;; Kill any existing process
      (when (and matisse--process (process-live-p matisse--process))
        (delete-process matisse--process))
      ;; Ensure initial directory is set for getting the right project directory
      (when (not matisse--initial-directory)
        (setq matisse--initial-directory initial-dir))

      ;; Ensure shell prompt is initialized
      (matisse--update-shell-prompt)

      ;; Start new process with continue flag
      (setq matisse--process (matisse--create-process-with-options nil t))

      ;; Clear the initial prompt that was inserted during buffer initialization
      ;; but keep the header (first 3 lines: welcome, connected, blank line)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-min))
          (forward-line 3)              ; Skip header lines
          (delete-region (point) (point-max))))

      ;; Replay previous conversation and check what type of message was last
      (let ((last-message-type (matisse-replay-previous-conversation)))
        ;; Apply syntax highlighting
        (matisse--overlays-put)

        ;; Insert prompt based on the last message type
        (cond
         ;; If last message was from assistant, add a prompt for the user
         ((eq last-message-type 'assistant)
          (matisse--insert-prompt))
         ;; If last message was from user, no prompt needed - Claude will respond
         ((eq last-message-type 'user)
          nil)
         ;; If no messages at all, add a prompt
         ((null last-message-type)
          (matisse--insert-prompt)))

        ;; Position cursor and screen nicely
        (goto-char (point-max))
        ;; Ensure the prompt/end of conversation is visible but not at screen bottom
        (recenter -2))  ; Position 2 lines from bottom
      (switch-to-buffer buffer))))

;;;###autoload
(defun matisse-shell-list ()
  "List all active matisse shell buffers."
  (interactive)
  (let ((matisse-buffers (seq-filter (lambda (buf)
                                       (with-current-buffer buf
                                         (derived-mode-p 'matisse-shell-mode)))
                                     (buffer-list))))
    (if matisse-buffers
        (message "Active matisse shell buffers: %s"
                 (mapconcat #'buffer-name matisse-buffers ", "))
      (message "No active matisse shell buffers"))))

(defun matisse--reset ()
  "Reset the Matisse session."
  (when matisse--process
    (delete-process matisse--process)
    (setq matisse--process nil))
  (setq matisse--pending-json ""
        matisse--conversation-id nil
        matisse--message-count 0
        matisse--shell-context nil      ; Clear shell context too
        matisse--waiting-for-response nil
        matisse--active-tools nil       ; Clear active tool tracking
        matisse--progress-buffer ""     ; Clear progress buffer
        matisse--interrupted-session-id nil
        matisse--interrupted-tools nil
        matisse--pending-message nil
        matisse--current-model nil      ; Reset to default model
        )  ; Clear state
  (matisse--stop-spinner)
  ;; Clean up selection timer
  (when matisse--selection-timer
    (cancel-timer matisse--selection-timer)
    (setq matisse--selection-timer nil)))

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
  "Set the Claude MODEL to use for this session only.
This restarts the Claude process with the new model."
  (interactive
   (list (let* ((choices '(("Sonnet (default)" . "sonnet")
                           ("Opus" . "opus")))
                (selection (completing-read "Model: " choices nil t)))
           (cdr (assoc selection choices)))))
  (let ((old-model (or matisse--current-model matisse-default-model)))
    (setq matisse--current-model model)
    ;; If we have an active process, gracefully restart it with the new model
    (if (and matisse--process (process-live-p matisse--process))
        (progn
          (message "Switching model from %s to %s..." old-model model)
          ;; Use the shared interrupt-and-resume function
          (matisse--interrupt-and-resume))
      ;; No active process, just update the setting
      (matisse--reset))))

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
(defun matisse-cycle-progress-icons ()
  "Cycle through icon modes: emoji -> nerd-icons -> ascii."
  (interactive)
  (setq matisse-progress-icons-mode
        (pcase matisse-progress-icons-mode
          ('emoji 'nerd-icons)
          ('nerd-icons 'ascii)
          (_ 'emoji)))
  (matisse--update-shell-prompt)
  (message "Progress icons mode: %s"
           (pcase matisse-progress-icons-mode
             ('emoji "Emoji")
             ('nerd-icons "Nerd Font icons")
             ('ascii "ASCII only"))))

;;;###autoload
(defun matisse-set-progress-icons-mode (mode)
  "Set progress icons display MODE.
MODE can be \\='emoji, \\='nerd-icons, or \\='ascii."
  (interactive
   (list (intern (completing-read "Icons mode: "
                                  '("emoji" "nerd-icons" "ascii")
                                  nil t))))
  (setq matisse-progress-icons-mode mode)
  (matisse--update-shell-prompt)
  (message "Progress icons mode set to: %s"
           (pcase matisse-progress-icons-mode
             ('emoji "Emoji")
             ('nerd-icons "Nerd Font icons")
             ('ascii "ASCII only"))))

;;;###autoload
(defun matisse-send (message)
  "Send MESSAGE to a matisse-shell buffer and submit it.
Uses existing shell if available, otherwise creates a new one."
  (interactive "sMessage for Matisse: ")
  (let* ((shell-buffers (seq-filter (lambda (buf)
                                     (with-current-buffer buf
                                       (derived-mode-p 'matisse-shell-mode)))
                                   (buffer-list)))
         (matisse-buffer (cond
                          ;; Use existing shell if only one exists
                          ((= (length shell-buffers) 1)
                           (car shell-buffers))
                          ;; Use most recent shell if multiple exist
                          ((> (length shell-buffers) 1)
                           (car shell-buffers))
                          ;; Create new shell if none exist
                          (t
                           (matisse-shell)
                           ;; Find the newly created buffer
                           (car (seq-filter (lambda (buf)
                                             (with-current-buffer buf
                                               (derived-mode-p 'matisse-shell-mode)))
                                           (buffer-list)))))))
    (with-current-buffer matisse-buffer
      ;; Insert the message at the prompt
      (goto-char (point-max))
      (insert message)
      ;; Submit the message using our custom handler
      (matisse--handle-return))))

;;;###autoload
(defun matisse-quit ()
  "Quit Matisse by killing the process and buffer."
  (interactive)
  ;; Just kill the buffer - the kill-buffer-hook will handle all the cleanup
  (kill-buffer (current-buffer)))

;;; Token tracking user functions

(defun matisse-show-tokens ()
  "Show current token usage statistics."
  (interactive)
  (let ((percentage (if (> matisse-auto-compact-threshold 0)
                        (format " (%.0f%% of threshold)"
                                (* 100.0 (/ (float matisse--tokens-since-compact)
                                           matisse-auto-compact-threshold)))
                      "")))
    (message "Tokens: %d total, %d since last reset%s"
             matisse--total-tokens-used
             matisse--tokens-since-compact
             percentage)))



;;; Shell Interface
;;; Shell implementation integrated from matisse-shell.el

;;; Shell Custom Variables

;; Shell prompt is now dynamic based on matisse-progress-icons-mode
(defvar matisse-shell-prompt nil
  "The prompt string to use in matisse shell.")

(defvar matisse-shell-prompt-regex nil
  "Regex pattern to match the matisse shell prompt.")

(defun matisse--update-shell-prompt ()
  "Update shell prompt variables based on current icon mode."
  (let ((char (matisse--get-shell-prompt-character)))
    (setq matisse-shell-prompt (concat char " ")
          matisse-shell-prompt-regex (concat "^" (regexp-quote char) " "))))

;; Initialize prompt variables
(matisse--update-shell-prompt)          ; [TODO] this is weird statically updating this!

;;; Integration Variables for Shell

(defvar-local matisse--shell-context nil
  "Context information for integration with main matisse process.")

(defvar-local matisse--current-message-id nil
  "ID of the currently processing message for response routing.")

(defvar-local matisse--response-sections nil
  "Hash table mapping message IDs to response section markers.")

(defvar-local matisse--source-buffer nil
  "Reference to the source shell buffer for history display mode.")

(defun matisse-shell--signal-response-complete ()
  "Signal that the current response is complete and handle spacing."
  (when (eq major-mode 'matisse-shell-mode)
    (matisse-shell--finish-output)))

;;; Shell Customization

(defcustom matisse-history-delete-duplicates t
  "Whether to delete duplicate entries in history.
When non-nil, adding a message that already exists in history
will move it to the front rather than creating a duplicate."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-language-mode-preferences
  '(("typescript" . ("typescript-ts-mode" "typescript-mode"))
    ("typescript-ts" . ("typescript-ts-mode" "typescript-mode"))
    ("ts" . ("typescript-ts-mode" "typescript-mode"))
    ("javascript" . ("js-ts-mode" "js-mode" "javascript-mode"))
    ("js" . ("js-ts-mode" "js-mode" "javascript-mode"))
    ("python" . ("python-ts-mode" "python-mode"))
    ("py" . ("python-ts-mode" "python-mode"))
    ("rust" . ("rust-ts-mode" "rust-mode"))
    ("rs" . ("rust-ts-mode" "rust-mode"))
    ("go" . ("go-ts-mode" "go-mode"))
    ("elisp" . ("emacs-lisp-mode"))
    ("emacs-lisp" . ("emacs-lisp-mode"))
    ("el" . ("emacs-lisp-mode"))
    ("cpp" . ("c++-ts-mode" "c++-mode"))
    ("c++" . ("c++-ts-mode" "c++-mode"))
    ("c" . ("c-ts-mode" "c-mode"))
    ("java" . ("java-ts-mode" "java-mode"))
    ("json" . ("json-ts-mode" "json-mode"))
    ("html" . ("html-mode"))
    ("css" . ("css-mode"))
    ("sh" . ("sh-mode"))
    ("bash" . ("sh-mode"))
    ("ruby" . ("ruby-ts-mode" "ruby-mode"))
    ("php" . ("php-mode")))
  "Language mode preferences with fallbacks for syntax highlighting.
Each entry maps a language name to a list of preferred modes,
with tree-sitter modes listed first when available."
  :type '(alist :key-type string
                :value-type (repeat string))
  :group 'matisse)

(defcustom matisse-list-bullet-string "  - "
  "String to display in place of markdown list markers (-, *, +, 1. etc).
Common options include \"  - \", \"  • \", \"  ◦ \", \"  ▸ \", \"  → \"."
  :type 'string
  :group 'matisse)

;;; Shell Variables

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


;;; Mode Detection and Shell Functions


(defun matisse--normalize-language (language)
  "Normalize common LANGUAGE names to their correct identifiers."
  (when language
    (let ((lang-lower (downcase (string-trim language))))
      ;; Fix common LLM mistakes
      (cond
       ((string= lang-lower "typescript") "typescript-ts")
       ((string= lang-lower "javascript") "js")
       ((string= lang-lower "python") "python")
       (t lang-lower)))))

(defun matisse--find-best-mode (language)
  "Find the best available mode for LANGUAGE, preferring tree-sitter modes.
Returns the mode symbol if found, nil otherwise."
  (when language
    (let* ((normalized (matisse--normalize-language language))
           (lang-lower (downcase (string-trim (or normalized language)))))
      ;; Debug message to see what language we're trying to find
      (when matisse-debug
        (message "DEBUG: Finding mode for language: '%s' (normalized: '%s')" language lang-lower))
      (let ((result
             (or
              ;; 1. Check custom preferences first
              (when-let* ((preferences (alist-get lang-lower matisse-language-mode-preferences nil nil #'string=)))
                (cl-find-if (lambda (mode-name-str)
                              (let ((mode-symbol (intern mode-name-str)))
                                (and (fboundp mode-symbol)
                                     ;; Remove the provided-mode-derived-p check as it may be too restrictive
                                     (or (provided-mode-derived-p mode-symbol 'prog-mode)
                                         (provided-mode-derived-p mode-symbol 'text-mode)
                                         ;; Allow any mode that exists
                                         (fboundp mode-symbol)))))
                            preferences))
              ;; 2. Try tree-sitter variant: LANGUAGE-ts-mode
              (let ((ts-mode (intern (concat lang-lower "-ts-mode"))))
                (when (fboundp ts-mode)
                  (symbol-name ts-mode)))
              ;; 3. Try standard variant: LANGUAGE-mode
              (let ((standard-mode (intern (concat lang-lower "-mode"))))
                (when (fboundp standard-mode)
                  (symbol-name standard-mode))))))
        (when matisse-debug
          (message "DEBUG: Found mode: %s" (or result "none")))
        result))))

;;; Face Definitions

(defface matisse-header-face
  '((t :inherit font-lock-comment-face :weight bold))
  "Face for header text."
  :group 'matisse)

(defface matisse-prompt-character-face
  '((t :inherit minibuffer-prompt :weight bold))
  "Face for the prompt character."
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

(defface matisse-markdown-bold-face
  '((t :weight bold))
  "Face for markdown bold text."
  :group 'matisse)

(defface matisse-markdown-italic-face
  '((t :slant italic))
  "Face for markdown italic text."
  :group 'matisse)

(defface matisse-markdown-header-1-face
  '((t :inherit font-lock-function-name-face :weight bold :height 1.3))
  "Face for markdown level 1 headers."
  :group 'matisse)

(defface matisse-markdown-header-2-face
  '((t :inherit font-lock-function-name-face :weight bold :height 1.2))
  "Face for markdown level 2 headers."
  :group 'matisse)

(defface matisse-markdown-header-3-face
  '((t :inherit font-lock-function-name-face :weight bold :height 1.1))
  "Face for markdown level 3 headers."
  :group 'matisse)

(defface matisse-markdown-inline-code-face
  '((t :inherit font-lock-constant-face))
  "Face for markdown inline code."
  :group 'matisse)

(defface matisse-markdown-bullet-face
  '((t :inherit font-lock-keyword-face))
  "Face for markdown bullet characters."
  :group 'matisse)

;;; Customization Variables

(defcustom matisse-markdown-hide-emphasis-markers t
  "Whether to hide markdown emphasis markers like ** and *."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-markdown-fontify-headers t
  "Whether to apply special formatting to markdown headers."
  :type 'boolean
  :group 'matisse)

;;; Overlay-based Highlighting

(defun matisse--position-in-ranges-p (position ranges)
  "Check if POSITION falls within any of the RANGES.
Each range in RANGES should be a cons cell (start . end)."
  (cl-some (lambda (range)
             (and (>= position (car range))
                  (<= position (cdr range))))
           ranges))

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

;;; Markdown Support

(defun matisse-toggle-markdown-emphasis-markers ()
  "Toggle visibility of markdown emphasis markers."
  (interactive)
  (setq matisse-markdown-hide-emphasis-markers
        (not matisse-markdown-hide-emphasis-markers))
  (matisse--overlays-put)
  (message "Markdown emphasis markers %s"
           (if matisse-markdown-hide-emphasis-markers "hidden" "visible")))

(defun matisse--find-markdown-code-blocks ()
  "Find all markdown code blocks in buffer.
Returns list of alists with keys: start, end, language, body."
  (let ((blocks '()))
    (save-excursion
      (goto-char (point-min))
      ;; More flexible regex that handles various formats
      (while (re-search-forward "^[ \t]*```\\([a-zA-Z0-9_+-]*\\)" nil t)
        (let* ((start-marker (match-beginning 0))
               (lang-start (match-beginning 1))
               (lang-end (match-end 1))
               (line-end (line-end-position))
               (body-start (1+ line-end)))  ; Start after the newline
          ;; Debug the language capture
          (when matisse-debug
            (message "DEBUG: Found code block opener at %d, language: '%s'"
                     start-marker
                     (if (and lang-start lang-end (> lang-end lang-start))
                         (buffer-substring-no-properties lang-start lang-end)
                       "none")))
          ;; Now find the closing ```
          (when (re-search-forward "^[ \t]*```[ \t]*$" nil t)
            (let ((body-end (line-beginning-position))
                  (end-start (match-beginning 0)))
              (push (list 'start (cons start-marker (+ start-marker 3))  ; Just the ```
                          'end (cons end-start (+ end-start 3))  ; Just the ```
                          'language (when (and lang-start lang-end
                                               (> lang-end lang-start))
                                      (cons lang-start lang-end))
                          'body (cons body-start body-end))
                    blocks))))))
    (nreverse blocks)))

(defun matisse--apply-syntax-highlighting (body-start body-end language)
  "Apply proper syntax highlighting to code block using major mode.
BODY-START BODY-END: positions of the code content
LANGUAGE: language string (e.g. \\='json\\=', \\='typescript\\=')"
  (when (and body-start body-end (< body-start body-end))
    (let* ((code-string (buffer-substring-no-properties body-start body-end))
           (target-mode (matisse--find-best-mode language))
           (original-buffer (current-buffer)))

      (when (and target-mode (> (length (string-trim code-string)) 0))
        (condition-case err
            (let ((faces-to-apply nil))
              ;; Collect face information in temp buffer
              (with-temp-buffer
                ;; Insert the code in a temp buffer
                (insert code-string)

                ;; Enable the appropriate major mode
                (let ((mode-symbol (intern target-mode)))
                  (when matisse-debug
                    (message "DEBUG: Attempting to enable mode: %s" target-mode))
                  (when (fboundp mode-symbol)
                    (funcall mode-symbol)
                    (when matisse-debug
                      (message "DEBUG: Mode enabled, major-mode is now: %s" major-mode))

                    ;; Force font-lock to run
                    (font-lock-mode 1)
                    (font-lock-ensure)

                    ;; Debug: check if faces were applied
                    (when matisse-debug
                      (message "DEBUG: First char face: %s" (get-text-property (point-min) 'face))
                      (message "DEBUG: Buffer substring: %s" (buffer-substring-no-properties (point-min) (min 20 (point-max)))))

                    ;; Extract face properties
                    (let ((temp-start (point-min))
                          (temp-end (point-max)))
                      (save-excursion
                        (goto-char temp-start)
                        (while (< (point) temp-end)
                          (let* ((next-change (or (next-single-property-change (point) 'face nil temp-end)
                                                 temp-end))
                                 (face (get-text-property (point) 'face))
                                 (temp-pos (point))
                                 ;; Calculate corresponding position in original buffer
                                 (orig-start (+ body-start (- temp-pos temp-start)))
                                 (orig-end (+ body-start (- next-change temp-start))))

                            ;; Debug output
                            (when (and matisse-debug face)
                              (message "DEBUG: Found face %s from %d to %d (orig %d-%d)"
                                       face temp-pos next-change orig-start orig-end))

                            ;; Collect face info if there's a face and we're within bounds
                            (when (and face
                                      (< orig-start body-end)
                                      (> orig-end body-start))
                              (let ((actual-start (max orig-start body-start))
                                    (actual-end (min orig-end body-end)))
                                (push (list actual-start actual-end face) faces-to-apply)))

                            (goto-char next-change))))))))

              ;; Apply overlays in the original buffer
              (when matisse-debug
                (message "DEBUG: Applying %d overlays" (length faces-to-apply)))
              (with-current-buffer original-buffer
                (dolist (face-info faces-to-apply)
                  (let ((start (nth 0 face-info))
                        (end (nth 1 face-info))
                        (face (nth 2 face-info)))
                    (when matisse-debug
                      (message "DEBUG: Creating overlay from %d to %d with face %s" start end face))
                    (matisse--overlay-put
                     (make-overlay start end)
                     'evaporate t
                     'face face)))))
          (error
           (message "Error applying syntax highlighting for %s: %s" target-mode (error-message-string err))))))))

(defun matisse--fontify-code-block (start-pos end-pos language-pos body-start body-end end-start end-end)
  "Apply syntax highlighting to a code block.
START-POS END-POS: opening ``` markers
LANGUAGE-POS: language name positions (cons or nil)
BODY-START BODY-END: code content positions
END-START END-END: closing ``` markers"
  ;; Validate all required positions exist
  (when (and start-pos end-pos body-start body-end end-start end-end)
    ;; Hide the entire opening line (```language\n)
    ;; This avoids blank lines and cleanly hides all markdown syntax
    (matisse--overlay-put
     (make-overlay start-pos (min body-start (point-max)))
     'evaporate t
     'invisible t)

    ;; Hide only the closing ``` markers, not the newline after
    ;; This ensures the prompt appears on the next line
    (matisse--overlay-put
     (make-overlay end-start (min end-end (point-max)))
     'evaporate t
     'invisible t)

    ;; Apply syntax highlighting to code content
    (let* ((language (when language-pos
                       (buffer-substring-no-properties (car language-pos) (cdr language-pos)))))
      (matisse--apply-syntax-highlighting body-start body-end language))))

(defun matisse--find-markdown-headers (&optional avoid-ranges)
  "Find markdown headers, avoiding AVOID-RANGES.
Returns list of alists with start, end, level, title positions."
  (let ((headers '()))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              (rx bol (group (one-or-more "#"))
                  (one-or-more space)
                  (group (one-or-more (not (any "\n")))) eol)
              nil t)
        (let ((begin (match-beginning 0))
              (end (match-end 0)))
          (unless (and avoid-ranges
                       (cl-find-if (lambda (range)
                                     (and (>= begin (car range))
                                          (<= end (cdr range))))
                                   avoid-ranges))
            (push (list 'start begin
                        'end end
                        'level (cons (match-beginning 1) (match-end 1))
                        'title (cons (match-beginning 2) (match-end 2)))
                  headers)))))
    (nreverse headers)))

(defun matisse--find-markdown-bolds (&optional avoid-ranges)
  "Find markdown bold text, avoiding AVOID-RANGES."
  (let ((bolds '()))
    (save-excursion
      (goto-char (point-min))
      ;; Match **text** or __text__ patterns
      (while (re-search-forward
              "\\(\\*\\*\\([^*\n]+?\\)\\*\\*\\|__\\([^_\n]+?\\)__\\)"
              nil t)
        (let ((begin (match-beginning 0))
              (end (match-end 0))
              (text-begin (or (match-beginning 2)
                              (match-beginning 3)))
              (text-end (or (match-end 2)
                            (match-end 3))))
          (unless (and avoid-ranges
                       (cl-find-if (lambda (range)
                                     (and (>= begin (car range))
                                          (<= end (cdr range))))
                                   avoid-ranges))
            (push (list 'start begin
                        'end end
                        'text (cons text-begin text-end))
                  bolds)))))
    (nreverse bolds)))

(defun matisse--find-markdown-italics (&optional avoid-ranges)
  "Find markdown italic text, avoiding AVOID-RANGES."
  (let ((italics '()))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              (rx (or (group (or bol (one-or-more (any "\n \t")))
                             (group "*")
                             (group (one-or-more (not (any "\n*")))) "*")
                      (group (or bol (one-or-more (any "\n \t")))
                             (group "_")
                             (group (one-or-more (not (any "\n_")))) "_")))
              nil t)
        (let ((begin (match-beginning 0))
              (end (match-end 0)))
          (unless (and avoid-ranges
                       (cl-find-if (lambda (range)
                                     (and (>= begin (car range))
                                          (<= end (cdr range))))
                                   avoid-ranges))
            (push (list 'start (or (match-beginning 2) (match-beginning 5))
                        'end end
                        'text (cons (or (match-beginning 3) (match-beginning 6))
                                    (or (match-end 3) (match-end 6))))
                  italics)))))
    (nreverse italics)))

(defun matisse--find-markdown-strikethroughs (&optional avoid-ranges)
  "Find markdown strikethrough text, avoiding AVOID-RANGES."
  (let ((strikethroughs '()))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              (rx "~~" (group (one-or-more (not (any "\n~")))) "~~")
              nil t)
        (let ((begin (match-beginning 0))
              (end (match-end 0)))
          (unless (and avoid-ranges
                       (cl-find-if (lambda (range)
                                     (and (>= begin (car range))
                                          (<= end (cdr range))))
                                   avoid-ranges))
            (push (list 'start begin
                        'end end
                        'text (cons (match-beginning 1) (match-end 1)))
                  strikethroughs)))))
    (nreverse strikethroughs)))

(defun matisse--find-markdown-inline-codes (&optional avoid-ranges)
  "Find markdown inline code, avoiding AVOID-RANGES."
  (let ((codes '()))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              "`\\([^`\n]+\\)`"
              nil t)
        (let ((begin (match-beginning 0))
              (end (match-end 0)))
          (unless (and avoid-ranges
                       (cl-find-if (lambda (range)
                                     (and (>= begin (car range))
                                          (<= end (cdr range))))
                                   avoid-ranges))
            (push (list 'body (cons (match-beginning 1) (match-end 1)))
                  codes)))))
    (nreverse codes)))

(defun matisse--fontify-header (start _end level-start level-end title-start title-end)
  "Fontify a markdown header from START to END.
LEVEL-START to LEVEL-END marks the header level markers.
TITLE-START to TITLE-END marks the header title."
  (when matisse-markdown-fontify-headers
    ;; Hide markup (# symbols and space)
    (matisse--overlay-put
     (make-overlay start title-start)
     'evaporate t
     'invisible t)

    ;; Apply header face based on level
    (let ((level-count (- level-end level-start)))
      (matisse--overlay-put
       (make-overlay title-start title-end)
       'evaporate t
       'face (cond ((= level-count 1) 'matisse-markdown-header-1-face)
                   ((= level-count 2) 'matisse-markdown-header-2-face)
                   ((= level-count 3) 'matisse-markdown-header-3-face)
                   (t 'matisse-markdown-header-3-face))))))

(defun matisse--fontify-bold (start end text-start text-end)
  "Fontify markdown bold text from START to END.
TEXT-START to TEXT-END marks the actual text."
  ;; Hide opening markup if configured
  (when matisse-markdown-hide-emphasis-markers
    (matisse--overlay-put
     (make-overlay start text-start)
     'evaporate t
     'invisible t))
  ;; Apply bold face
  (matisse--overlay-put
   (make-overlay text-start text-end)
   'evaporate t
   'face 'matisse-markdown-bold-face)
  ;; Hide closing markup if configured
  (when matisse-markdown-hide-emphasis-markers
    (matisse--overlay-put
     (make-overlay text-end end)
     'evaporate t
     'invisible t)))

(defun matisse--fontify-italic (start end text-start text-end)
  "Fontify markdown italic text from START to END.
TEXT-START to TEXT-END marks the actual text."
  ;; Hide opening markup if configured
  (when matisse-markdown-hide-emphasis-markers
    (matisse--overlay-put
     (make-overlay start text-start)
     'evaporate t
     'invisible t))
  ;; Apply italic face
  (matisse--overlay-put
   (make-overlay text-start text-end)
   'evaporate t
   'face 'matisse-markdown-italic-face)
  ;; Hide closing markup if configured
  (when matisse-markdown-hide-emphasis-markers
    (matisse--overlay-put
     (make-overlay text-end end)
     'evaporate t
     'invisible t)))

(defun matisse--fontify-strikethrough (start end text-start text-end)
  "Fontify markdown strikethrough text from START to END.
TEXT-START to TEXT-END marks the actual text."
  ;; Hide opening markup
  (matisse--overlay-put
   (make-overlay start text-start)
   'evaporate t
   'invisible t)
  ;; Apply strikethrough face
  (matisse--overlay-put
   (make-overlay text-start text-end)
   'evaporate t
   'face '(:strike-through t))
  ;; Hide closing markup
  (matisse--overlay-put
   (make-overlay text-end end)
   'evaporate t
   'invisible t))

(defun matisse--fontify-inline-code (body-start body-end)
  "Fontify markdown inline code from BODY-START to BODY-END."
  ;; Apply inline code face
  (matisse--overlay-put
   (make-overlay body-start body-end)
   'evaporate t
   'face 'matisse-markdown-inline-code-face)
  ;; Optionally hide backticks if configured
  (when matisse-markdown-hide-emphasis-markers
    ;; Hide opening backtick
    (matisse--overlay-put
     (make-overlay (1- body-start) body-start)
     'evaporate t
     'invisible t)
    ;; Hide closing backtick
    (matisse--overlay-put
     (make-overlay body-end (1+ body-end))
     'evaporate t
     'invisible t)))

(defun matisse-refresh-overlays ()
  "Manually refresh all overlays in the buffer."
  (interactive)
  (matisse--overlays-put)
  (message "Overlays refreshed"))

(defun matisse-debug-code-blocks ()
  "Debug function to show found code blocks."
  (interactive)
  (let ((blocks (matisse--find-markdown-code-blocks)))
    (if blocks
        (progn
          (message "Found %d code blocks:" (length blocks))
          (dolist (block blocks)
            (let* ((_start-pos (plist-get block 'start))
                   (language-pos (plist-get block 'language))
                   (language (when language-pos
                               (buffer-substring-no-properties
                                (car language-pos) (cdr language-pos))))
                   (mode (matisse--find-best-mode language)))
              (message "  Block with language: '%s' -> mode: %s"
                       (or language "none")
                       (or mode "NONE FOUND")))))
      (message "No code blocks found"))))

(defun matisse-test-mode (language)
  "Test if we can find and use a mode for LANGUAGE."
  (interactive "sLanguage: ")
  (let ((mode-name (matisse--find-best-mode language)))
    (if mode-name
        (let ((mode-symbol (intern mode-name)))
          (if (fboundp mode-symbol)
              (with-temp-buffer
                (insert "// Test code\nconst x = 42;")
                (funcall mode-symbol)
                (font-lock-mode 1)
                (if (fboundp 'font-lock-ensure)
                    (font-lock-ensure)
                  (font-lock-ensure))
                (message "Mode %s works! Font-lock-mode: %s, Faces: %s"
                         mode-name
                         font-lock-mode
                         (get-text-property 1 'face)))
            (message "Mode %s found but function not available" mode-name)))
      (message "No mode found for language: %s" language))))

(defun matisse-test-highlight-region ()
  "Test highlighting a region with TypeScript."
  (interactive)
  (when (region-active-p)
    (let* ((start (region-beginning))
           (end (region-end))
           (code (buffer-substring-no-properties start end)))
      (message "Testing highlight for region from %d to %d" start end)
      ;; Try to apply typescript highlighting
      (with-temp-buffer
        (insert code)
        (typescript-ts-mode)
        (font-lock-mode 1)
        (font-lock-ensure)
        ;; Check what faces we got
        (goto-char (point-min))
        (let ((faces '()))
          (while (< (point) (point-max))
            (when-let* ((face (get-text-property (point) 'face)))
              (push face faces))
            (forward-char))
          (message "Found faces: %s" (delete-dups faces))))
      ;; Now try to apply it to the current buffer
      (let ((ov (make-overlay start end)))
        (overlay-put ov 'face 'font-lock-keyword-face)
        (overlay-put ov 'evaporate t)
        (message "Applied test overlay")))))

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

  ;; Markdown code blocks with syntax highlighting
  (condition-case err
      (dolist (block (matisse--find-markdown-code-blocks))
        (let ((start-pos (plist-get block 'start))
              (end-pos (plist-get block 'end))
              (language-pos (plist-get block 'language))
              (body-pos (plist-get block 'body)))
          ;; Only process if we have valid positions with valid car/cdr values
          (when (and start-pos end-pos body-pos
                     (car start-pos) (cdr start-pos)
                     (car end-pos) (cdr end-pos)
                     (car body-pos) (cdr body-pos))
            (matisse--fontify-code-block
             (car start-pos) (cdr start-pos)
             language-pos
             (car body-pos) (cdr body-pos)
             (car end-pos) (cdr end-pos)))))
    (error
     (message "Error processing markdown code blocks: %s" (error-message-string err))))

  ;; Calculate avoid-ranges for text formatting (code block ranges)
  (let ((avoid-ranges (delq nil
                            (mapcar (lambda (block)
                                      (let ((body-pos (plist-get block 'body)))
                                        (when (and body-pos (car body-pos) (cdr body-pos))
                                          (cons (car body-pos) (cdr body-pos)))))
                                    (matisse--find-markdown-code-blocks)))))

    ;; Markdown headers
    (dolist (header (matisse--find-markdown-headers avoid-ranges))
      (let ((start (plist-get header 'start))
            (end (plist-get header 'end))
            (level (plist-get header 'level))
            (title (plist-get header 'title)))
        (when (and start end level title
                   (car level) (cdr level)
                   (car title) (cdr title))
          (matisse--fontify-header
           start end
           (car level) (cdr level)
           (car title) (cdr title)))))

    ;; Markdown bold text
    (dolist (bold (matisse--find-markdown-bolds avoid-ranges))
      (let ((start (plist-get bold 'start))
            (end (plist-get bold 'end))
            (text (plist-get bold 'text)))
        (when (and start end text
                   (car text) (cdr text))
          (matisse--fontify-bold
           start end
           (car text) (cdr text)))))

    ;; Markdown italic text
    (dolist (italic (matisse--find-markdown-italics avoid-ranges))
      (let ((start (plist-get italic 'start))
            (end (plist-get italic 'end))
            (text (plist-get italic 'text)))
        (when (and start end text
                   (car text) (cdr text))
          (matisse--fontify-italic
           start end
           (car text) (cdr text)))))

    ;; Markdown strikethrough text
    (dolist (strikethrough (matisse--find-markdown-strikethroughs avoid-ranges))
      (let ((start (plist-get strikethrough 'start))
            (end (plist-get strikethrough 'end))
            (text (plist-get strikethrough 'text)))
        (when (and start end text
                   (car text) (cdr text))
          (matisse--fontify-strikethrough
           start end
           (car text) (cdr text)))))

    ;; Markdown inline code
    (dolist (code (matisse--find-markdown-inline-codes avoid-ranges))
      (let ((body-pos (plist-get code 'body)))
        (when (and body-pos (car body-pos) (cdr body-pos))
          (matisse--fontify-inline-code
           (car body-pos)
           (cdr body-pos)))))

    ;; Process markdown links
    (dolist (link (matisse--find-markdown-links avoid-ranges))
      (let ((text-pos (alist-get 'text link))
            (url-pos (alist-get 'url link))
            (full-pos (alist-get 'full link)))
        (when (and text-pos url-pos full-pos
                   (car text-pos) (cdr text-pos)
                   (car url-pos) (cdr url-pos)
                   (car full-pos) (cdr full-pos))
          (matisse--fontify-link
           (car text-pos) (cdr text-pos)
           (car url-pos) (cdr url-pos)
           (car full-pos) (cdr full-pos)))))

    ;; Process markdown lists
    (dolist (list-item (matisse--find-markdown-lists avoid-ranges))
      (let ((marker-pos (alist-get 'marker list-item))
            (space-pos (alist-get 'space list-item))
            (text-pos (alist-get 'text list-item)))
        (when (and marker-pos space-pos text-pos
                   (car marker-pos) (cdr marker-pos)
                   (car space-pos) (cdr space-pos)
                   (car text-pos) (cdr text-pos))
          (matisse--fontify-list-item
           (car marker-pos) (cdr marker-pos)
           (car space-pos) (cdr space-pos)
           (car text-pos) (cdr text-pos)))))))

(defun matisse--find-markdown-links (&optional avoid-ranges)
  "Find all markdown links [text](url) in buffer, avoiding AVOID-RANGES."
  (let ((links '())
        (link-regex "\\[\\([^]]+\\)\\](\\([^)]+\\))"))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward link-regex nil t)
        (let ((full-start (match-beginning 0))
              (full-end (match-end 0))
              (text-start (match-beginning 1))
              (text-end (match-end 1))
              (url-start (match-beginning 2))
              (url-end (match-end 2)))
          ;; Only include if not in avoid-ranges
          (unless (matisse--position-in-ranges-p full-start avoid-ranges)
            (push `((text . (,text-start . ,text-end))
                    (url . (,url-start . ,url-end))
                    (full . (,full-start . ,full-end)))
                  links)))))
    (nreverse links)))

(defun matisse--find-markdown-lists (&optional avoid-ranges)
  "Find markdown list items (bullet and numbered), avoiding AVOID-RANGES.
Only matches lists in Claude's responses, not in user input."
  (let ((lists '()))
    (save-excursion
      (goto-char (point-min))
      ;; Match:
      ;; - Bullet lists with -, *, or +
      ;; - Numbered lists like 1. 2. etc
      ;; But only if NOT preceded by "> " (user message indicator)
      (while (re-search-forward
              "^\\(?:[ \t]*\\)\\([•*+-]\\|[0-9]+\\.\\)\\([ \t]+\\)\\(.+\\)$"
              nil t)
        (let ((line-start (line-beginning-position))
              (marker-start (match-beginning 1))
              (marker-end (match-end 1))
              (space-start (match-beginning 2))
              (space-end (match-end 2))
              (text-start (match-beginning 3))
              (text-end (match-end 3)))
          ;; Check this isn't in a user message (starts with "> ")
          (save-excursion
            (goto-char line-start)
            (unless (or (looking-at "^> ")
                        (and avoid-ranges
                             (matisse--position-in-ranges-p marker-start avoid-ranges)))
              (push `((marker . (,marker-start . ,marker-end))
                      (space . (,space-start . ,space-end))
                      (text . (,text-start . ,text-end))
                      (line . (,line-start . ,text-end)))
                    lists))))))
    (nreverse lists)))

(defun matisse--fontify-list-item (marker-start _marker-end _space-start space-end _text-start _text-end)
  "Fontify a markdown list item by replacing marker with a bullet.
MARKER-START to MARKER-END is the list marker (-, *, +, 1. etc).
SPACE-START to SPACE-END is the space after the marker.
TEXT-START to TEXT-END is the list item text."
  ;; Replace the marker and space with a bullet using display property
  (matisse--overlay-put
   (make-overlay marker-start space-end)
   'evaporate t
   'display matisse-list-bullet-string
   'face 'matisse-markdown-bullet-face))

(defun matisse--fontify-link (text-start text-end url-start url-end full-start full-end)
  "Fontify markdown link by hiding markup and making text clickable.
TEXT-START to TEXT-END is the visible link text.
URL-START to URL-END is the URL to open.
FULL-START to FULL-END is the entire [text](url) pattern."
  (let ((url (buffer-substring-no-properties url-start url-end)))

    ;; Hide the entire markdown syntax [text](url) except for the text
    (let ((before-overlay (make-overlay full-start text-start)))
      (overlay-put before-overlay 'invisible t)
      (overlay-put before-overlay 'matisse-markdown t))

    ;; Hide everything after the text (](url))
    (let ((after-overlay (make-overlay text-end full-end)))
      (overlay-put after-overlay 'invisible t)
      (overlay-put after-overlay 'matisse-markdown t))

    ;; Make the visible text part clickable with link face
    (let ((text-overlay (make-overlay text-start text-end)))
      (overlay-put text-overlay 'face 'link)
      (overlay-put text-overlay 'mouse-face 'highlight)
      (overlay-put text-overlay 'help-echo url)
      (overlay-put text-overlay 'matisse-markdown t)
      ;; Add keymap for clicking
      (let ((map (make-sparse-keymap)))
        (define-key map [mouse-1]
          (lambda (_event)
            (interactive "e")
            (browse-url url)))
        (define-key map (kbd "RET")
          (lambda ()
            (interactive)
            (browse-url url)))
        (overlay-put text-overlay 'keymap map)))))


;;; Buffer Initialization

(defun matisse--initialize-buffer ()
  "Set up initial buffer content and markers."
  ;; Ensure marker exists
  (unless matisse--output-start-marker
    (setq matisse--output-start-marker (make-marker)))

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

  ;; Set output start marker - ensure point is valid
  (when (and matisse--output-start-marker (point))
    (set-marker matisse--output-start-marker (point)))

  ;; Insert initial prompt
  (matisse--insert-prompt))

;;; Region Management

(defun matisse--get-input-region ()
  "Return (start . end) of current input region.
Works with multiline input - finds the last prompt in buffer and goes to
end of buffer."
  (save-excursion
    (goto-char (point-max))
    ;; Search backward for the most recent prompt
    (when (re-search-backward matisse-shell-prompt-regex nil t)
      (let ((start (+ (point) (length matisse-shell-prompt)))  ; After prompt
            (end (point-max)))
        (when (>= end start)
          (cons start end))))))

;;; Input Handling & Prompt Management

(defun matisse--insert-prompt ()
  "Insert prompt at end of buffer and set up input region."
  (condition-case err
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))

        ;; Insert prompt with properties - character gets special face, space doesn't
        (let ((prompt-start (point)))
          (insert matisse-shell-prompt)
          ;; Apply face only to prompt character
          (when (and prompt-start (> (point) prompt-start))
            (put-text-property prompt-start (+ prompt-start (length (matisse--get-shell-prompt-character))) 'face 'matisse-prompt-character-face)
            ;; Make entire prompt read-only
            (put-text-property prompt-start (point) 'read-only t)
            (put-text-property prompt-start (point) 'rear-nonsticky '(read-only))))

        ;; Position cursor for input
        (goto-char (point-max))

        ;; Refresh overlays after prompt insertion - wrapped in error handler
        (condition-case overlay-err
            (matisse--overlays-put)
          (error
           (message "Error in matisse--overlays-put: %s" (error-message-string overlay-err)))))
    (error
     (message "Error in matisse--insert-prompt: %s" (error-message-string err))
     (message "Error details: %S" err))))

(defun matisse-bol ()
  "Move to beginning of line, or after prompt if it's on current line."
  (interactive)
  (beginning-of-line)
  ;; Check if current line starts with the prompt
  (if (looking-at matisse-shell-prompt-regex)
      ;; Skip past the prompt and space
      (goto-char (+ (point) 2))
    ;; Already at beginning of line (no prompt on this line)
    ))

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
                        (when (re-search-backward matisse-shell-prompt-regex nil t)
                          (line-beginning-position))))
        (input-end (point-max)))

    ;; Now move to end and add newline
    (goto-char input-end)
    (insert "\n")

    (cond
     ;; Empty input - just add new prompt
     ((string-empty-p input)
      ;; Apply inactive face to empty prompt line (only if we found the prompt)
      (when prompt-start
        (let ((inhibit-read-only t))
          ;; Apply inactive face to entire line (this will override the prompt character face)
          (put-text-property prompt-start input-end 'face 'matisse-prompt-inactive-face)))
      (goto-char input-end)
      (matisse--insert-prompt)
      ;; Auto-scroll after inserting new prompt (user was at end when submitting)
      (matisse--auto-scroll-if-at-end (matisse--user-at-end-p) (current-buffer)))

     ;; Valid input - process message
     (t
      ;; Apply inactive face to the exact region of prompt + user input FIRST
      ;; before any buffer modifications (only if we found the prompt)
      (when prompt-start
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
          (matisse--auto-scroll-if-at-end (matisse--user-at-end-p) (current-buffer))

          ;; Process message asynchronously
          (matisse--send-user-message input))))
    (error
     (message "Error in matisse--process-user-input-internal: %s" (error-message-string err))
     ;; Ensure we always have a prompt
     (goto-char (point-max))
     (unless (matisse--at-prompt-p)
       (matisse--insert-prompt)
       ;; Auto-scroll after error recovery
       (matisse--auto-scroll-if-at-end (matisse--user-at-end-p) (current-buffer))))))

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
        (progn
          (insert "\n")
          ;; Auto-scroll to keep the new line visible
          (matisse--auto-scroll-if-at-end (matisse--user-at-end-p) (current-buffer)))
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
  "Select from history using `completing-read' with fuzzy matching."
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

(defun matisse--user-at-end-p ()
  "Check if user is at or near the end of the buffer for scrolling purposes."
  (>= (point) (- (point-max) 1)))

(defun matisse--auto-scroll-if-at-end (at-end-condition buffer)
  "Auto-scroll to keep all typed input visible when AT-END-CONDITION is true.
BUFFER specifies which buffer to scroll.
Intelligently handles multi-line input at the prompt."
  (when at-end-condition
    (let ((shell-window (get-buffer-window buffer)))
      (when shell-window
        (with-selected-window shell-window
          (with-current-buffer buffer
            ;; Save cursor position to avoid interfering with movement commands
            (let ((original-point (point)))
              (save-excursion
                (goto-char (point-max))
                ;; Find the prompt start to calculate input height
                (let* ((prompt-line (save-excursion
                                      (goto-char (point-max))
                                      (if (re-search-backward matisse-shell-prompt-regex nil t)
                                          (line-number-at-pos)
                                        nil)))
                       (current-line (line-number-at-pos (point-max)))
                       (input-lines (if prompt-line
                                        (1+ (- current-line prompt-line))
                                      1))
                       ;; Calculate window height
                       (window-height (window-height))
                       ;; Keep at least 2 lines margin at bottom, but adjust for multi-line input
                       (desired-margin (min 2 (max 1 (- window-height input-lines 3)))))
                  ;; Use recenter with dynamic margin based on input size
                  ;; Negative value means lines from bottom
                  (recenter (- desired-margin))))
              ;; Restore original cursor position
              (goto-char original-point))))))))

;;; Visual Design & Message Section Creation

(defun matisse--display-user-message (text)
  "Display user's message with proper formatting.
TEXT is the message content to display."
  (insert (propertize (format "> %s" text) 'face 'matisse-user-message-face))
  (insert "\n\n"))

(defun matisse--create-message-section (message-id timestamp)
  "Create a section for message and its response.
MESSAGE-ID is the unique identifier for the message.
TIMESTAMP is when the message was sent."
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
  "Update status indicator for MESSAGE-ID.
MESSAGE-ID is the unique identifier for the message.
NEW-STATUS is the new status to set."
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
  "Update response content for MESSAGE-ID.
MESSAGE-ID is the unique identifier for the message.
CONTENT is the new content to set."
  (when-let* ((section (gethash message-id matisse--message-sections)))
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
      (matisse--execute-command input matisse--shell-context))))

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
  (when-let* ((section (gethash message-id matisse--response-sections)))
    (let ((response-end (plist-get section :response-end))
          (current-pos (point)))

      ;; Insert content at the response section
      (save-excursion
        (goto-char response-end)
        (let ((content-start (point))
              (inhibit-read-only t))  ; Allow inserting in read-only regions
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
      (matisse--auto-scroll-if-at-end (with-current-buffer (current-buffer)
                                         (save-excursion
                                           (goto-char current-pos)
                                           (matisse--user-at-end-p))) (current-buffer)))))

(defun matisse-shell--write-progress (text)
  "Write progress TEXT to the shell buffer."
  ;; This function should be called from within the target shell buffer context
  (when (derived-mode-p 'matisse-shell-mode)
    (let ((at-end (matisse--user-at-end-p)))
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

      ;; Refresh overlays to apply syntax highlighting to new content
      (matisse--overlays-put)

      ;; Auto-scroll if we were at the end, but keep prompt away from bottom edge
      (matisse--auto-scroll-if-at-end at-end (current-buffer)))))

(defun matisse-shell--finish-output ()
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

    ;; Refresh overlays one final time when response is complete
    (matisse--overlays-put)

    ;; Auto-scroll when output is finished to show completion
    (matisse--auto-scroll-if-at-end (matisse--user-at-end-p) (current-buffer))

    ;; Process next message if any are queued
    (when matisse--pending-messages
      ;; Small delay to ensure Claude is ready for next message
      (run-at-time 0.5 nil
                   (lambda (&rest _)
                     ;; Should already be in shell buffer context
                     (matisse--process-next-message))))))

(defun matisse--cancel-current-message ()
  "Cancel the currently processing message."
  (interactive)
  (when matisse--current-message-id
    ;; Remove the current message from pending queue if it's there
    (setq matisse--pending-messages
          (cl-remove-if (lambda (msg)
                          (= (car msg) matisse--current-message-id))
                        matisse--pending-messages))

    ;; Clear current message state
    (setq matisse--current-message-id nil)

    ;; Update the response section to show cancellation
    (matisse-shell--write-progress "[Message cancelled]")
    (matisse-shell--finish-output)

    ;; Use the shared interrupt-and-resume function to preserve session
    (matisse--interrupt-and-resume
     (lambda ()
       ;; Process any remaining queued messages after resumption
       (when matisse--pending-messages
         (run-at-time 0.1 nil (lambda (&rest _) (matisse--process-next-message))))))

    (message "Matisee message cancelled")))

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
               (when-let* ((end-marker (plist-get section :response-end)))
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

;;; Post-command hook for smart scrolling

(defun matisse--post-command-scroll ()
  "Ensure typed text remains visible after each command.
Only scrolls when user is typing at the prompt."
  (when (and (derived-mode-p 'matisse-shell-mode)
             ;; Only scroll if we're in the input region
             (matisse--get-input-region)
             ;; And cursor is near the end
             (matisse--user-at-end-p))
    (matisse--auto-scroll-if-at-end (matisse--user-at-end-p) (current-buffer))))

;;; Image Support Functions

(defun matisse--image-yank-media-handler (mimetype data)
  "Handle pasted images in matisse-shell buffers.
MIMETYPE is the MIME type of the image data (can be string or symbol).
DATA is the raw image data."
  (when (derived-mode-p 'matisse-shell-mode)
    (let* ((mimetype-str (if (symbolp mimetype) (symbol-name mimetype) mimetype))
           (filename (cond
                      ((string-prefix-p "image/jpeg" mimetype-str) "pasted-image.jpg")
                      ((string-prefix-p "image/jpg" mimetype-str) "pasted-image.jpg")
                      ((string-prefix-p "image/png" mimetype-str) "pasted-image.png")
                      ((string-prefix-p "image/gif" mimetype-str) "pasted-image.gif")
                      ((string-prefix-p "image/webp" mimetype-str) "pasted-image.webp")
                      ((string-prefix-p "image/bmp" mimetype-str) "pasted-image.bmp")
                      (t "pasted-image.png"))))
      (matisse--add-pending-image mimetype-str data filename)
      ;; Insert a visual indicator in the buffer
      (insert (format "[Image pasted: %s]" filename))
      t))) ; Return t to indicate we handled the media

;;; Major Mode Definition

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
              matisse--message-sections (make-hash-table :test 'equal)
              matisse--pending-images nil)

  ;; Key bindings
  (local-set-key (kbd "RET") #'matisse--handle-return)
  (local-set-key (kbd "S-<return>") #'matisse--newline)
  (local-set-key (kbd "<up>") #'matisse-history-previous)
  (local-set-key (kbd "<down>") #'matisse-history-next)
  (local-set-key (kbd "M-p") #'matisse-history-previous)
  (local-set-key (kbd "M-n") #'matisse-history-next)
  (local-set-key (kbd "M-r") #'matisse-history-search-backward)
  (local-set-key (kbd "M-s") #'matisse-history-search-forward)
  (local-set-key (kbd "C-c mh") #'matisse-history-show)
  (local-set-key (kbd "C-c C-r") #'matisse-history-complete)
  (local-set-key (kbd "C-c C-c") #'matisse-cancel)
  (local-set-key (kbd "C-l") #'matisse--clear-buffer)
  (local-set-key (kbd "C-a") #'matisse-bol)
  (local-set-key (kbd "C-c mr") #'matisse-refresh-overlays)
  (local-set-key (kbd "C-c md") #'matisse-debug-code-blocks)
  (local-set-key (kbd "C-c mi") #'yank-media)
  
  ;; Apply overlay-based highlighting
  (matisse--overlays-put)

  ;; Buffer configuration
  (setq-local truncate-lines nil            ; Allow line wrapping
              word-wrap t                   ; Wrap at word boundaries
              scroll-conservatively 10000)  ; Smooth scrolling

  ;; Initialize buffer content
  (matisse--initialize-buffer)

  ;; Enable matisse-mode for mode-line enhancements and progress indicators
  (matisse-mode 1)

  ;; Add hooks
  (add-hook 'post-command-hook #'matisse--post-command-scroll nil t)
  (add-hook 'kill-buffer-hook #'matisse--kill-buffer-hook nil t)

  ;; Register yank-media handler for images (Emacs 29+)
  (when (fboundp 'yank-media-handler)
    (yank-media-handler "image/.*" #'matisse--image-yank-media-handler)))

(provide 'matisse-shell)

;;; matisse-shell.el ends here

(provide 'matisse)
;;; matisse.el ends here
