;;; matisse.el --- Emacs interface to Claude Code -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Steve Molitor
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.0") (shell-maker "0.78.2"))  
;; Keywords: ai, tools, claude
;;; Commentary:

;; shell-maker has been replaced with matisse-shell.el but I'm still using markdown-overlays from shell-maker for now

;; Matisse provides an Emacs interface to Claude Code with a custom async shell.
;; It communicates with Claude Code via streaming JSON input/output for real-time responses.

;; For now I'm vendoring cezanne.el (the MCP server) but I will pull that out into its own package as its reusable
;; in claude-code.el and other packages.

;;; Code:

(require 'markdown-overlays)            ;; still using this from shell-maker!
(require 'json)
(require 'map)
(require 'seq)
(require 'cl-lib)

;; Always load matisse-shell
(require 'matisse-shell)

(declare-function matisse-shell--handle-response "matisse-shell.el")
(declare-function matisse-shell-start "matisse-shell.el")
(declare-function matisse-shell--signal-response-complete "matisse-shell.el")

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
- 'emoji: Use emoji icons
- 'nerd-icons: Use Nerd Font icons
- 'ascii: Use simple ASCII characters only (default)"
  :type '(choice (const :tag "Emoji" emoji)
                 (const :tag "Nerd Font icons" nerd-icons)
                 (const :tag "ASCII only" ascii))
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
`matisse-mode'. For example: \"C-c m\" or \"s-m\"."
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


(defvar matisse-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "q" #'matisse-quit)
    (define-key map "c" #'matisse-interrupt)
    (define-key map "k" #'matisse-cancel)
    map)
  "Keymap for Matisse commands.")

;;; Minor mode

(defvar matisse--mode-line-format nil
  "Current mode line format for matisse-mode.")

(defun matisse--update-mode-line ()
  "Update the mode line with current spinner state and selection info."
  (let* ((spinner-part (if matisse--waiting-for-response
                           (if (< (mod matisse--spinner-index 2) 1)
                               " 🔥"  ; Fire emoji when "on"
                             " 🤖") ; Robot when "off"
                         " 🤖"))
         (selection-part (matisse--format-selection-status)))
    (setq matisse--mode-line-format
          (concat spinner-part
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

;;; JSON handling

(defun matisse--format-user-message (text)
  "Format TEXT as a JSON message for Claude Code.
If `matisse-send-selection-p' is non-nil and there's a last selection,
append it as context to the text."
  (let* ((selection-context (matisse--format-selection-context))
         (enhanced-text (if selection-context
                            (concat text "\n\n" selection-context)
                          text)))
    (json-encode
     `((type . "user")
       (message . ((role . "user")
                   (content . [((type . "text")
                                (text . ,enhanced-text))])))))))

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
  "Log debug message to buffer if debugging is enabled."
  (when matisse-debug
    (let ((buffer (get-buffer-create "*matisse-debug*")))
      (message "%S" args))))

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
                              (error (matisse--debug-log "Error writing progress: %s" (error-message-string err))))
                            )))))

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
                      (markdown-overlays-put)
                    (error (matisse--debug-log "Error applying markdown overlays: %s" (error-message-string err))))
                  ;; Clear active tools and reset state
                  (setq matisse--active-tools nil)
                  ;; Finish the current shell command before processing next
                  (when (and matisse--shell-context
                             (plist-get matisse--shell-context :finish-output))
                    (condition-case err
                        (funcall (plist-get matisse--shell-context :finish-output) t)
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
        ;; If no session ID yet, wait for it before interrupting
        (unless matisse--conversation-id
          (message "Waiting for session to establish before interrupting...")
          (let ((wait-count 0))
            (while (and (not matisse--conversation-id)
                        (< wait-count 50) ; Max 5 seconds wait
                        matisse--process
                        (process-live-p matisse--process))
              (sit-for 0.1)
              (setq wait-count (1+ wait-count)))
            (unless matisse--conversation-id
              (matisse--debug-log "Session ID not received after waiting"))))

        ;; Stop UI indicators
        (matisse--stop-spinner)

        ;; Store active tools for potential cleanup notification
        (when matisse--active-tools
          (setq matisse--interrupted-tools (copy-sequence matisse--active-tools))
          (message "Interrupting with %d active tool(s): %s"
                   (length matisse--interrupted-tools)
                   (mapconcat (lambda (tool) (alist-get 'name tool))
                              matisse--interrupted-tools ", ")))

        ;; Store session ID for resuming
        (when matisse--conversation-id
          (setq matisse--interrupted-session-id matisse--conversation-id))

        ;; Reset state variables
        (setq matisse--waiting-for-response nil
              matisse--active-tools nil)

        ;; Send SIGTERM to process
        (signal-process matisse--process 'SIGTERM)

        ;; Set timer for SIGKILL if process doesn't terminate gracefully
        (run-at-time 2 nil
                     (lambda (proc)
                       (when (and proc (process-live-p proc))
                         (signal-process proc 'SIGKILL)
                         (message "Force-killed Claude process")))
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

          ;; Notify about interrupted tools if any
          (when matisse--interrupted-tools
            (message "Resuming session. Note: %d tool operation(s) were interrupted: %s"
                     (length matisse--interrupted-tools)
                     (mapconcat (lambda (tool) (alist-get 'name tool))
                                matisse--interrupted-tools ", ")))

          ;; Start new process with resume flag
          (matisse--start-process-with-resume session-id)

          ;; Clear interrupted state
          (setq matisse--interrupted-session-id nil
                matisse--interrupted-tools nil))
      ;; No session to resume - the pending message will be handled by matisse--send-message
      (message "Ready for new conversation."))))

(defun matisse-cancel ()
  "Cancel current operation and restart Claude process.
This is a combined interrupt and resume operation for stuck processes."
  (interactive)
  (let ((pending-msg matisse--pending-message))
    (when (and matisse--process (process-live-p matisse--process))
      (matisse--interrupt))
    ;; Small delay to ensure process is killed
    (run-at-time 0.5 nil #'matisse--restore)
    (run-at-time 0.1 nil (lambda ()
                           ;; No shell-maker interrupt needed - process is already killed
                           ;; Restore pending message would be handled by shell restoration
                           ))))

(defun matisse--start-process-with-resume (session-id)
  "Start the Claude Code process with SESSION-ID for resuming."
  (when (and matisse--process (process-live-p matisse--process))
    (delete-process matisse--process))

  (let* ((api-key (matisse--get-api-key))
         (process-environment (cons (format "ANTHROPIC_API_KEY=%s" api-key)
                                    process-environment))
         (cmd (list matisse-claude-code-path
                    "--permission-mode" matisse-permission-mode
                    "--input-format" "stream-json"
                    "--output-format" "stream-json"
                    "--resume" session-id ; Add resume flag
                    "--verbose")))

    
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

    (matisse--debug-log "Starting process with resume, command: %s" (string-join cmd " "))
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
    (matisse--debug-log "Process started with resume: %s" (process-live-p matisse--process))
    matisse--process))

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
          (setq matisse--waiting-for-response nil)
          ;; Session ID should already be saved if this was an interrupt
          (when matisse--interrupted-session-id
            (message "Process terminated. Use `matisse--restore' to continue the conversation.")))

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
              (funcall (plist-get matisse--shell-context :finish-output) nil))))

         ;; Other events
         (t
          (matisse--debug-log "Unhandled process event: %s" event)))))))

(defun matisse--start-process ()
  "Start the Claude Code process with streaming JSON."
  (when (and matisse--process (process-live-p matisse--process))
    (delete-process matisse--process))

  (let* ((api-key (matisse--get-api-key))
         (process-environment (cons (format "ANTHROPIC_API_KEY=%s" api-key)
                                    process-environment))
         (cmd (list matisse-claude-code-path
                    "--permission-mode" matisse-permission-mode
                    "--input-format" "stream-json"
                    "--output-format" "stream-json"
                    "--verbose")))


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

    (matisse--debug-log "Starting process with command: %s" (string-join cmd " "))

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
    (matisse--debug-log "Process started: %s" (process-live-p matisse--process))
    matisse--process))

(defun matisse--send-message (text)
  "Send TEXT message to Claude Code process."
  (condition-case err
      (progn
        (unless (and matisse--process (process-live-p matisse--process))
          (matisse--start-process))

        (let ((json-msg (matisse--format-user-message text)))
          (matisse--debug-log "Sending JSON: %s" json-msg)
          (matisse--debug-log "Process alive before send: %s" (process-live-p matisse--process))
          ;; Store message as pending until we get any response
          (setq matisse--pending-message text)
          (process-send-string matisse--process (concat json-msg "\n"))
          (matisse--debug-log "Process alive after send: %s" (process-live-p matisse--process))))
    (error
     ;; Stop the spinner and reset state
     (matisse--stop-spinner)
     (setq matisse--waiting-for-response nil
           matisse--pending-message nil) ; Clear pending message on send error
     ;; Display error message in echo area
     (message "Matisse error: %s" (error-message-string err))
     (matisse--debug-log "Error in matisse--send-message: %s" (error-message-string err)))))

;;; Selection tracking

(defun matisse--get-selection-info ()
  "Get selection information from the current buffer.
Returns an alist with selection data, or nil if buffer has no file or is a matisse buffer."
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
Called from post-command-hook to update the last selection from non-matisse buffers."
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
Returns a string like 'in matisse.el' or '2 lines selected'."
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
         (funcall (alist-get :finish-output shell) nil))))))

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
  (let* ((existing-shells (seq-filter (lambda (buf)
                                        (with-current-buffer buf
                                          (derived-mode-p 'matisse-shell-mode)))
                                      (buffer-list)))
         (buffer-name (if (zerop (length existing-shells))
                          "*matisse-shell*" 
                        (format "*matisse-shell<%d>*" (1+ (length existing-shells))))))
    ;; Create shell context with buffer name
    (let ((shell-context (list :buffer-name buffer-name)))
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
          ;; Store session for potential resume
          (when matisse--conversation-id
            (setq matisse--interrupted-session-id matisse--conversation-id))
          ;; Stop current process
          (matisse--interrupt)
          ;; Restart with new model after a brief delay
          (run-at-time 0.5 nil #'matisse--restore))
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
  "Cycle through progress icon display modes: emoji -> nerd-icons -> ascii -> emoji."
  (interactive)
  (setq matisse-progress-icons-mode
        (pcase matisse-progress-icons-mode
          ('emoji 'nerd-icons)
          ('nerd-icons 'ascii)
          (_ 'emoji)))
  (message "Progress icons mode: %s" 
           (pcase matisse-progress-icons-mode
             ('emoji "Emoji")
             ('nerd-icons "Nerd Font icons")
             ('ascii "ASCII only"))))

;;;###autoload
(defun matisse-set-progress-icons-mode (mode)
  "Set progress icons display MODE.
MODE can be 'emoji, 'nerd-icons, or 'ascii."
  (interactive 
   (list (intern (completing-read "Icons mode: " 
                                  '("emoji" "nerd-icons" "ascii") 
                                  nil t))))
  (setq matisse-progress-icons-mode mode)
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

(message "HELLO")

(provide 'matisse)
;;; matisse.el ends here
