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
;;;; Require
(require 'json)
(require 'map)
(require 'seq)
(require 'cl-lib)
(require 'server)
(require 'diff-mode)
(require 'diff)
(require 'project)
(require 'transient nil t)

;;;; External function declarations
(declare-function auth-source-search "auth-source" (&rest spec))

;;; Customization
;;;; Matisse
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

(defcustom matisse-setting-sources "user,project,local"
  "Comma-separated list of setting sources to load.
Valid values: user, project, local.
Loads custom subagents, commands, and settings from these locations.
This enables your user-level subagents in ~/.claude/agents/ to be available."
  :type 'string
  :group 'matisse)

(defcustom matisse-aggressive-subagent-prompt
  "IMPORTANT: Use subagents (Task tool) proactively for file research and multi-file operations to preserve main context. When researching code or reading multiple files, use the general-purpose subagent (subagent_type: \"general-purpose\") to keep large tool results out of the main conversation. Subagents have separate context windows."
  "System prompt addition to encourage aggressive subagent usage.
When non-nil, this prompt is appended to Claude's system prompt to encourage
using subagents for file-intensive operations, keeping the main context clean.
Set to nil to disable this behavior."
  :type '(choice (string :tag "Custom prompt")
                 (const :tag "Disabled" nil))
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
- \"acceptEdits\": Auto-accept file edits (Edit, Write, MultiEdit)
- \"bypassPermissions\": Skip all permission checks (use with caution)
- \"plan\": Plan mode for planning tasks
- \"yolo\": Client-side auto-allow all permissions (can be toggled dynamically)"
  :type '(choice (const :tag "Default" "default")
                 (const :tag "Accept Edits" "acceptEdits")
                 (const :tag "Bypass Permissions" "bypassPermissions")
                 (const :tag "Plan Mode" "plan")
                 (const :tag "YOLO Mode" "yolo"))
  :group 'matisse)

(defcustom matisse-in-buffer-permission-prompts t
  "When non-nil, show permission prompts in the buffer instead of minibuffer.
Users can respond by typing \\='yes\\=', \\='no\\=', or \\='accept\\=' at the prompt.
When nil, permission prompts appear in the minibuffer as `y-or-n-p' queries."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-exit-commands '("exit" "quit" "bye")
  "List of commands that will exit the Matisse shell.
These commands are case-insensitive and work both at the regular prompt
and when responding to permission prompts."
  :type '(repeat string)
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

(defcustom matisse-session-list-auto-refresh t
  "Whether to automatically refresh the matisse session list.
When non-nil, the session list buffer will automatically update
every `matisse-session-list-refresh-interval' seconds to show
current session statuses."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-session-list-refresh-interval 2.0
  "Interval in seconds for auto-refreshing the session list.
Only applies when `matisse-session-list-auto-refresh' is non-nil."
  :type 'number
  :group 'matisse)

(defcustom matisse-verbose-mode nil
  "Whether to display messages in full without truncation.
When nil, long messages may be truncated with […] to keep the display concise.
When non-nil, all messages are displayed in their entirety."
  :type 'boolean
  :group 'matisse)

;;;; Matisse Icons
;;;;; General Icon Settings
(defgroup matisse-icons nil
  "Progress indicator icons and display settings."
  :group 'matisse)

(defcustom matisse-icons-scale-factor 1.0
  "Scale factor for icon height.
This controls the relative size of icons in progress indicators.
A value of 1.0 uses the default text height, 1.2 makes icons 20% larger, etc."
  :type 'float
  :group 'matisse-icons)

(defcustom matisse-icons-mode 'ascii
  "Mode for displaying progress indicator icons.
Options:
- \\='emoji: Use emoji icons
- \\='nerd-icons: Use Nerd Font icons
- \\='ascii: Use simple ASCII characters only (default)"
  :type '(choice (const :tag "Emoji" emoji)
                 (const :tag "Nerd Font icons" nerd-icons)
                 (const :tag "ASCII only" ascii))
  :group 'matisse-icons)

(defcustom matisse-modeline-use-emoji t
  "Use emoji icons in modeline even when using nerd-icons or ascii mode.
When non-nil, modeline indicators will always use emoji icons regardless
of `matisse-icons-mode'. This allows using ASCII or nerd-icons for progress
indicators while keeping the animated emoji in the modeline."
  :type 'boolean
  :group 'matisse-icons)

;;;;; ASCII Icons
(defgroup matisse-ascii-icons nil
  "ASCII icon settings for progress indicators."
  :group 'matisse-icons)

(defcustom matisse-ascii-shell-prompt "❯"
  "ASCII character for shell prompt."
  :type 'string
  :group 'matisse-ascii-icons)

(defcustom matisse-ascii-icon-permission ""
  "ASCII representation for permission request prompts."
  :type 'string
  :group 'matisse-ascii-icons)

(defcustom matisse-ascii-icon-allow "[OK]"
  "ASCII representation for allowed/approved actions."
  :type 'string
  :group 'matisse-ascii-icons)

(defcustom matisse-ascii-icon-deny "[NO]"
  "ASCII representation for denied/rejected actions."
  :type 'string
  :group 'matisse-ascii-icons)

(defcustom matisse-ascii-icon-auto-compact "-"
  "ASCII representation for auto-compact messages."
  :type 'string
  :group 'matisse-ascii-icons)

(defcustom matisse-ascii-icon-modeline-default "|"
  "ASCII character for mode-line default/idle state."
  :type 'string
  :group 'matisse-ascii-icons)

(defcustom matisse-ascii-icon-modeline-permission "!"
  "ASCII character for mode-line permission request state."
  :type 'string
  :group 'matisse-ascii-icons)

;;;;; Emoji Icons
(defgroup matisse-emoji-icons nil
  "Emoji icon settings for progress indicators."
  :group 'matisse-icons)

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

(defcustom matisse-emoji-icon-command "⚡"
  "Emoji icon for command completion messages."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-auto-compact "⚙️"
  "Emoji icon for auto-compact messages."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-shell-prompt "🖌️"
  "Emoji character for shell prompt."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-permission "🔐"
  "Emoji icon for permission request prompts."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-allow "✅"
  "Emoji icon for allowed/approved actions."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-deny "❌"
  "Emoji icon for denied/rejected actions."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-modeline-default "🤖"
  "Emoji icon for mode-line default/idle state."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-modeline-permission "🔐"
  "Emoji icon for mode-line permission request state."
  :type 'string
  :group 'matisse-emoji-icons)

(defcustom matisse-emoji-icon-modeline-active "🔥"
  "Emoji icon for mode-line active/waiting state animation."
  :type 'string
  :group 'matisse-emoji-icons)

;;;;; Nerd Icons
(defgroup matisse-nerd-icons nil
  "Nerd Font icon settings for progress indicators."
  :group 'matisse-icons)

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

(defcustom matisse-nerd-icon-command ""
  "Nerd Font icon for command completion messages."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-auto-compact ""
  "Nerd Font icon for auto-compact messages."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-permission ""
  "Nerd Font icon for permission request prompts."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-allow "✓"
  "Nerd Font icon for allowed/approved actions."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-deny "✗"
  "Nerd Font icon for denied/rejected actions."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-modeline-default ""
  "Nerd Font icon for mode-line default/idle state."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-modeline-permission " "
  "Nerd Font icon for mode-line permission request state."
  :type 'string
  :group 'matisse-nerd-icons)

(defcustom matisse-nerd-icon-modeline-active ""
  "Nerd Font icon for mode-line active/waiting state animation."
  :type 'string
  :group 'matisse-nerd-icons)

;;;;; Nerd Icon Faces
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

(defcustom matisse-nerd-icon-command-face 'matisse-nerd-icon-yellow
  "Face for command completion nerd icon.
Uses yellow color suitable for command feedback."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-auto-compact-face 'font-lock-keyword-face
  "Face for auto-compact nerd icon.
Uses keyword face suitable for system operations."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-permission-face 'matisse-nerd-icon-yellow
  "Face for permission request nerd icon.
Uses yellow color to indicate attention required."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-allow-face 'matisse-nerd-icon-lgreen
  "Face for allowed/approved action nerd icon.
Uses light green color to indicate success."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-deny-face 'matisse-nerd-icon-pink
  "Face for denied/rejected action nerd icon.
Uses pink/red color to indicate rejection."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-modeline-default-face 'matisse-nerd-icon-blue
  "Face for mode-line default/idle state nerd icon.
Uses blue color for the default state."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-modeline-permission-face 'matisse-nerd-icon-yellow
  "Face for mode-line permission request state nerd icon.
Uses yellow color to indicate attention required."
  :type 'face
  :group 'matisse-nerd-icon-faces)

(defcustom matisse-nerd-icon-modeline-active-face 'matisse-nerd-icon-orange
  "Face for mode-line active/waiting state nerd icon.
Uses orange color to indicate activity."
  :type 'face
  :group 'matisse-nerd-icon-faces)

;;;; Message Display Faces
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

(defface matisse-accept-mode-face
  '((t :foreground "medium purple" :weight bold))
  "Face for accept/bypass permission mode indicator."
  :group 'matisse)

(defface matisse-default-mode-face
  '((t :inherit shadow :weight bold))
  "Face for default permission mode indicator."
  :group 'matisse)

(defface matisse-permission-prompt-face
  '((t :inherit warning :weight bold))
  "Face for in-buffer permission prompts."
  :group 'matisse)

;;;; Markdown Display Options
(defcustom matisse-markdown-hide-emphasis-markers t
  "Whether to hide markdown emphasis markers like ** and *."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-markdown-fontify-headers t
  "Whether to apply special formatting to markdown headers."
  :type 'boolean
  :group 'matisse)

;;;; Keybindings
(defgroup matisse-keybindings nil
  "Key binding settings for Matisse shell mode."
  :group 'matisse)

;; Key binding customizations for matisse-shell-mode
(defcustom matisse-key-return "RET"
  "Key binding for handling return/enter in matisse shell."
  :type 'string
  :group 'matisse-keybindings)

(defcustom matisse-key-newline "S-<return>"
  "Key binding for inserting a newline in matisse shell."
  :type 'string
  :group 'matisse-keybindings)

(defcustom matisse-key-history-previous "<up>"
  "Key binding for navigating to previous message in history."
  :type 'string
  :group 'matisse-keybindings)

(defcustom matisse-key-history-next "<down>"
  "Key binding for navigating to next message in history."
  :type 'string
  :group 'matisse-keybindings)

(defcustom matisse-key-history-previous-alt "M-p"
  "Alternative key binding for navigating to previous message in history."
  :type 'string
  :group 'matisse-keybindings)

(defcustom matisse-key-history-next-alt "M-n"
  "Alternative key binding for navigating to next message in history."
  :type 'string
  :group 'matisse-keybindings)

(defcustom matisse-key-history-search-backward "M-r"
  "Key binding for searching backward through history."
  :type 'string
  :group 'matisse-keybindings)

(defcustom matisse-key-history-search-forward "M-s"
  "Key binding for searching forward through history."
  :type 'string
  :group 'matisse-keybindings)

(defcustom matisse-key-history-complete "C-c C-r"
  "Key binding for selecting from history with completion."
  :type 'string
  :group 'matisse-keybindings)

(defcustom matisse-key-cancel "C-c C-c"
  "Key binding for canceling the currently processing message."
  :type 'string
  :group 'matisse-keybindings)

(defcustom matisse-key-clear-buffer "C-l"
  "Key binding for clearing all messages and resetting buffer."
  :type 'string
  :group 'matisse-keybindings)

(defcustom matisse-key-beginning-of-line "C-a"
  "Key binding for moving to beginning of line or after prompt."
  :type 'string
  :group 'matisse-keybindings)

(defcustom matisse-key-yank-media "C-c mi"
  "Key binding for inserting media/images."
  :type 'string
  :group 'matisse-keybindings)

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

(defcustom matisse-context-window 200000
  "Context window size in tokens for current model.
Used to calculate auto-compact and warning thresholds.
Common values:
- 200000 (200K) - Sonnet 4.5, Opus 4, default models
- 1000000 (1M) - Models with [1m] suffix (e.g., claude-sonnet-4-5[1m])
Adjust based on your model's actual context window."
  :type 'integer
  :group 'matisse)

(defcustom matisse-auto-compact-reserve 13000
  "Reserve tokens before context limit to trigger auto-compact.
Auto-compact triggers when: tokens_used >= (context_window - reserve).
Default 13000 matches Claude Code SDK behavior.
Examples:
- 200K context: triggers at 187K tokens
- 1M context: triggers at 987K tokens"
  :type 'integer
  :group 'matisse)

(defcustom matisse-warning-reserve 20000
  "Reserve tokens before context limit to show warning.
Warning shows when: tokens_used >= (context_window - reserve).
Default 20000 matches Claude Code SDK behavior.
Examples:
- 200K context: warns at 180K tokens
- 1M context: warns at 980K tokens"
  :type 'integer
  :group 'matisse)

(defcustom matisse-auto-compact-enabled t
  "When non-nil, automatically trigger /compact at threshold.
Default t (enabled) matches Claude Code SDK default behavior.

When enabled, Matisse automatically sends /compact when token usage
exceeds (context_window - auto_compact_reserve). Messages are queued
during compaction and sent afterward.

Set to nil if you prefer manual /compact control.

Note: Auto-compaction takes 10-30 seconds but prevents context overflow."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-show-token-usage t
  "Whether to display token usage in mode line."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-override-mode-line t
  "Whether to override the entire mode line in matisse shell buffers.
When non-nil, matisse will take over the entire mode line display,
showing only the matisse-specific information (icon, buffer name,
mode, tokens, selection). When nil, matisse information is added
to the existing mode line via the matisse-mode lighter."
  :type 'boolean
  :group 'matisse)

(defcustom matisse-chunk-size 32768
  "Size of chunks when sending large messages (32KB).
Used to avoid pipe buffer blocking with large prompts."
  :type 'integer
  :group 'matisse)

(defcustom matisse-chunk-threshold 65536
  "Messages larger than this will be sent in chunks (64KB).
This prevents blocking when sending large prompts through the pipe."
  :type 'integer
  :group 'matisse)

(defcustom matisse-large-paste-threshold 5000
  "Number of characters above which to show paste placeholder.
Text pastes larger than this will show '[Pasted text #N +X lines]'
instead of the full content in the buffer."
  :type 'integer
  :group 'matisse)

(defcustom matisse-debug-log-max-length 500
  "Maximum length of arguments in debug log messages.
Longer values will be truncated to prevent buffer performance issues."
  :type 'integer
  :group 'matisse)

(defcustom matisse-max-progress-message-length 1000
  "Maximum length of progress and command completion messages.
Even in verbose mode, messages longer than this will be truncated
to prevent buffer performance issues. Set to nil for no limit."
  :type '(choice (const :tag "No limit" nil)
                 (integer :tag "Max characters"))
  :group 'matisse)

(defcustom matisse-large-prompt-threshold 100000
  "Maximum characters for inline prompts and arguments.
User prompts and slash command arguments larger than this will be written
to session-scoped temporary files and referenced using @ syntax instead of
being sent inline. This prevents \\='Prompt is too long\\=' errors with large
inputs like CI logs or pasted code files."
  :type 'integer
  :group 'matisse)

(defcustom matisse-buffer-name-function #'matisse--default-buffer-name
  "Function to generate matisse shell buffer names.
The function is called with one argument, the directory path, and should
return a base name string (without uniquification).  The returned name will
be passed to `generate-new-buffer-name' to ensure uniqueness.

The default function uses the project name from project.el if available,
otherwise falls back to the abbreviated directory path."
  :type 'function
  :group 'matisse)

;;; Variables & Constants
;;;; Internal Constants
(defconst matisse--spinner-chars '("/" "|" "\\" "-")
  "Characters used for the spinner animation.")

(defconst matisse--mode-line-separator "  "
  "Separator between mode line sections.")

(defvar matisse--scroll-throttle-ms 50
  "Minimum milliseconds between scroll operations.")

(defvar matisse--skip-syntax-highlighting nil
  "When non-nil, skip syntax highlighting in code blocks.
Used during conversation replay for performance.")

(defvar matisse--mode-buffer-cache (make-hash-table :test 'equal)
  "Cache of temp buffers with major modes already activated.
Keys are mode names (strings), values are buffer objects.
This avoids expensive TreeSitter recompilation on every code block.")

;;;; Dynamic Variables & Data Structures
(defvar matisse--slash-commands
  '(("/clear" . "Clear the conversation buffer")
    ("/compact" . "Compact conversation to save context")
    ("/context" . "Show current context information")
    ("/cost" . "Display token usage and cost information")
    ("/init" . "Initialize a new CLAUDE.md file")
    ("/output-style:new" . "Create a custom output style")
    ("/pr-comments" . "Get comments from a GitHub pull request")
    ("/release-notes" . "View release notes")
    ("/todos" . "List current todo items")
    ("/review" . "Review a pull request")
    ("/security-review" . "Complete a security review"))
  "Available slash commands and their descriptions.
This is a fallback list used before discovery completes.")

(defvar matisse--compact-options
  '(("--instructions" . "Provide specific guidance for compaction")
    ("--help" . "Show help for compact command"))
  "Options available for the /compact command.")

;;;; Remote Control State Variables
(defvar matisse--buffer-mru-list nil
  "List of matisse buffer names in most-recently-used order.
The first element is the most recently used matisse buffer.")

;;;; Buffer-Local State Variables
(defvar-local matisse--process nil
  "The Claude Code process.")

(defvar-local matisse--pending-json ""
  "Buffer for incomplete JSON data.")

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

(defvar-local matisse--pending-permission-request nil
  "Pending permission request waiting for user response in buffer.
Format: (process request-id tool-name tool-input suggestions)")

(defvar-local matisse--spinner-index 0
  "Current index in the spinner sequence.")

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

(defvar-local matisse--pending-slash-command nil
  "The slash command currently being processed, if any.")

(defvar-local matisse--current-model nil
  "The current model for this session. If nil, uses matisse-default-model.")

(defvar-local matisse--current-permission-mode nil
  "Current permission mode for this session.
If nil, uses matisse-permission-mode.")

(defvar-local matisse--pending-permission-update nil
  "Pending permission mode update to send in next control response.
Set by `matisse-set-permission-mode' when mode is changed.
Included as updatedPermissions in next control_response.")

(defvar-local matisse--auto-allow-next-write-tool nil
  "When non-nil, automatically allow the next write tool without prompting.
Set when user approves ExitPlanMode with \\='yes\\=' to allow the first edit.
Cleared after the first write tool is executed.")

(defvar-local matisse--available-commands nil
  "Commands available from Claude Code, discovered at initialization.")

(defvar-local matisse--available-models nil
  "Models available from Claude Code, discovered at initialization.")

(defvar-local matisse--mode-line-left nil
  "Left-aligned portion of mode line for matisse-mode.")

(defvar-local matisse--mode-line-right nil
  "Right-aligned portion of mode line for matisse-mode.")

(defvar-local matisse--total-tokens-used 0
  "Total tokens used in current conversation.")

(defvar-local matisse--tokens-since-compact 0
  "Tokens used since last compaction.")

(defvar-local matisse--resumed-session nil
  "Non-nil when session was resumed/continued from previous conversation.")

(defvar-local matisse--message-queue nil
  "Queue of user messages waiting to be sent.
Messages are queued when:
- Auto-compaction is in progress
- Waiting for response from previous message
Processed in FIFO order (first in, first out).
Similar to ACP's Pushable stream pattern.")

(defvar-local matisse--auto-compact-in-progress nil
  "Non-nil when auto-compaction is in progress.")

(defvar-local matisse--pending-images nil
  "List of pending images to be included with the next message.
Each element is a plist with :type, :data, and optionally :filename.")

(defvar-local matisse--pending-large-paste nil
  "Stores the actual text of a large paste when placeholder is shown.
Plist with :text and :placeholder-text.")

(defvar-local matisse--large-paste-counter 0
  "Counter for numbering large paste placeholders.")

(defvar-local matisse--temp-files nil
  "List of session-scoped temp files created for large arguments.
Files persist for session lifetime to support follow-up questions and resume.
Cleaned up only on explicit /clear command.")

(defvar-local matisse--shell-prompt nil
  "The prompt string to use in matisse shell.")

(defvar-local matisse--shell-prompt-regex nil
  "Regex pattern to match the matisse shell prompt.")

(defvar-local matisse--shell-context nil
  "Context information for integration with main matisse process.")

(defvar-local matisse--current-message-id nil
  "ID of the currently processing message for response routing.")

(defvar-local matisse--response-sections nil
  "Hash table mapping message IDs to response section markers.")

(defvar-local matisse--source-buffer nil
  "Reference to the source shell buffer for history display mode.")

(defvar-local matisse--message-counter 0
  "Counter for generating unique message IDs.")

(defvar-local matisse--message-queue nil
  "Unified queue of all messages with their metadata.
Each element is a plist with:
  :id         - unique message ID
  :type       - \\='user or \\='slash-command
  :text       - the message text
  :command    - slash command name if type is \\='slash-command
  :status     - \\='pending, \\='processing, \\='completed, or \\='cancelled
  :timestamp  - when the message was queued")

(defvar-local matisse--queue-paused nil
  "When non-nil, automatic queue processing is paused.
Set to t when user interrupts with \\[matisse-interrupt].
Cleared when user sends a new message.")

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

(defvar-local matisse--last-scroll-time nil
  "Time of last scroll operation to throttle rapid scrolling.")

(defvar-local matisse--last-overlay-position nil
  "Buffer position where overlays were last applied.
Used for incremental overlay updates to avoid rescanning entire buffer.")

;;;; Global State Variables
(defvar matisse--config nil
  "Shell configuration for matisse.")

(defvar matisse--last-selection nil
  "Last text selection from a non-matisse buffer.
Contains an alist with keys: file-path, start-line, end-line,
start-char, end-char, text, has-selection.")

(defvar matisse--selection-timer nil
  "Timer for debouncing selection updates.")

(defvar-local matisse--overlay-timer nil
  "Idle timer for applying overlays during streaming.")

(defvar-local matisse--session-list-timer nil
  "Timer for auto-refreshing the session list buffer.")

(defvar-local matisse--overlay-update-scheduled nil
  "Flag indicating an overlay update is already scheduled.")

;;; Core Utilities
(defun matisse--route-to-shell (text)
  "Route TEXT output to the matisse-shell implementation."
  (when-let* ((buffer-name (plist-get matisse--shell-context :buffer-name))
              (message-id (plist-get matisse--shell-context :message-id))
              (shell-buffer (get-buffer buffer-name)))
    (when (buffer-live-p shell-buffer)
      (with-current-buffer shell-buffer
        ;; Route response to shell using message ID from context
        (matisse-shell--handle-response message-id text)))))

(defun matisse--default-buffer-name (dir)
  "Generate default matisse shell buffer name for directory DIR.
Uses the project name from project.el if available, otherwise uses
the abbreviated directory path."
  (let* ((proj (project-current nil dir))
         (context-name (if proj
                           (project-name proj)
                         (abbreviate-file-name (directory-file-name dir)))))
    (format "*M %s" context-name)))

(defun matisse--generate-buffer-name (dir)
  "Generate a unique matisse shell buffer name for directory DIR.
Uses `matisse-buffer-name-function' to generate the base name,
then ensures uniqueness with a numeric suffix before the closing asterisk."
  (let* ((base-name (funcall matisse-buffer-name-function dir))
         (buffer-name base-name)
         (counter 2))
    ;; Check if base name (with trailing *) already exists
    (if (not (get-buffer (concat buffer-name "*")))
        (concat buffer-name "*")
      ;; Find unique name by adding <N> before the closing *
      (while (get-buffer (format "%s<%d>*" buffer-name counter))
        (setq counter (1+ counter)))
      (format "%s<%d>*" buffer-name counter))))

(defun matisse--get-working-directory ()
  "Get the working directory for starting a matisse session.
Returns the project root if in a project, otherwise returns `default-directory'."
  (if-let* ((proj (project-current)))
      (expand-file-name (project-root proj))
    (expand-file-name default-directory)))

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

(defun matisse--get-latest-conversation-file ()
  "Get the path to the most recent conversation file."
  (let* ((project-dir (matisse--get-project-directory))
         (files (when (file-directory-p project-dir)
                  (directory-files project-dir t "\\.jsonl$" t))))
    (when files
      (car (sort files (lambda (a b)
                         (time-less-p (nth 5 (file-attributes b))
                                     (nth 5 (file-attributes a)))))))))

(defun matisse-resume ()
  "Resume a previous conversation from the project directory.
Displays a list of previous sessions with timestamps and previews,
allowing the user to select one to resume in a new shell.
Starts in the project root if in a project, otherwise in `default-directory'."
  (interactive)
  ;; Get the working directory first and temporarily bind matisse--initial-directory
  (let* ((initial-dir (matisse--get-working-directory))
         (matisse--initial-directory initial-dir)
         (project-dir (matisse--get-project-directory))
         (session-files (when (file-directory-p project-dir)
                         (directory-files project-dir t "\\.jsonl$" t))))
    (if (not session-files)
        (message "No previous conversations found in %s" project-dir)
      ;; Build completion candidates with previews
      (let* ((candidates
              (delq nil  ; Remove nil entries (filtered empty sessions)
                    (mapcar (lambda (file)
                              (let* ((session-id (file-name-base file))
                                     (attrs (file-attributes file))
                                     (mtime (nth 5 attrs))
                                     (timestamp (format-time-string "%Y-%m-%d %H:%M" mtime))
                                     (msg-count (matisse--count-session-messages file))
                                     (preview (let ((raw-preview (matisse--get-session-preview file)))
                                               ;; Clean up preview: remove newlines and truncate
                                               (truncate-string-to-width
                                                (string-replace "\n" " " raw-preview)
                                                50 nil nil "[…]"))))
                                ;; Only include sessions with messages
                                (when (> msg-count 0)
                                  ;; Store metadata as text properties on session-id
                                  (propertize session-id
                                             'timestamp timestamp
                                             'msg-count msg-count
                                             'preview preview))))
                            ;; Sort by modification time (newest first)
                            (sort session-files
                                  (lambda (a b)
                                    (time-less-p (nth 5 (file-attributes b))
                                                (nth 5 (file-attributes a))))))))
             (choice (when candidates
                       (completing-read "Resume conversation: "
                                       (lambda (string pred action)
                                         (cond
                                          ((eq action 'metadata)
                                           `(metadata
                                             (display-sort-function . identity)
                                             (affixation-function . ,#'matisse--resume-affixation)))
                                          (t (complete-with-action action candidates string pred))))
                                       nil t)))
             (session-id choice))
        (if (not candidates)
            (message "No conversations with messages found in %s" project-dir)
          (when session-id
            ;; Create new shell buffer and resume the session
            (let* ((new-buffer (matisse--generate-buffer-name initial-dir))
                   (session-file (matisse--get-session-file session-id)))
              (switch-to-buffer new-buffer)
              (matisse-shell-mode)

              ;; Set default-directory and matisse--initial-directory for the session
              (setq default-directory initial-dir
                    matisse--initial-directory initial-dir)

              ;; Clear the initial prompt that was inserted during buffer initialization
              ;; but keep the header (first 3 lines: welcome, connected, blank line)
              (let ((inhibit-read-only t))
                (save-excursion
                  (goto-char (point-min))
                  (forward-line 3)              ; Skip header lines
                  (delete-region (point) (point-max))))

              ;; Replay conversation history in the buffer
              (let ((last-message-type (matisse--replay-conversation-from-file session-file)))
                ;; Apply syntax highlighting to all code blocks once after replay
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
                  (matisse--insert-prompt))))

              ;; Start process with resume flag
              (matisse--start-process-with-resume session-id)
              (message "Resumed session: %s" session-id))))))))

(defun matisse--resume-affixation (candidates)
  "Format CANDIDATES for matisse-resume with aligned columns.
Each candidate has timestamp, msg-count, and preview as text properties."
  (mapcar (lambda (cand)
            (let ((timestamp (get-text-property 0 'timestamp cand))
                  (msg-count (get-text-property 0 'msg-count cand))
                  (preview (get-text-property 0 'preview cand)))
              (list cand
                    (concat (propertize (format "%-16s" timestamp) 'face 'marginalia-date)
                            "  "
                            (propertize (format "%4d msgs" msg-count) 'face 'marginalia-number)
                            "  ")
                    (concat "  "
                            (propertize preview 'face 'marginalia-documentation)))))
          candidates))

(defun matisse--count-session-messages (session-file)
  "Count the number of user and assistant messages in SESSION-FILE.
Returns the total count of messages."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents session-file)
        (goto-char (point-min))
        (let ((count 0))
          (while (not (eobp))
            (let ((line (buffer-substring-no-properties
                        (line-beginning-position)
                        (line-end-position))))
              (when (not (string-empty-p line))
                (let ((json (ignore-errors (json-parse-string line :object-type 'alist))))
                  (when json
                    (let ((type (alist-get 'type json)))
                      ;; Count user and assistant messages
                      (when (or (equal type "user") (equal type "assistant"))
                        (setq count (1+ count)))))))
              (forward-line 1)))
          count))
    (error 0)))

(defun matisse--get-session-preview (session-file)
  "Get a preview string from SESSION-FILE.
First tries to extract the summary from the first line.
Falls back to the first user message text.
Returns a short text preview or the string `No preview available'."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents session-file nil 0 50000) ; Read first 50KB
        (goto-char (point-min))

        ;; Try to get summary from first line
        (when (not (eobp))
          (let* ((first-line (buffer-substring-no-properties
                             (line-beginning-position)
                             (line-end-position)))
                 (summary-json (ignore-errors (json-parse-string first-line :object-type 'alist)))
                 (summary (alist-get 'summary summary-json)))
            (if summary
                summary
              ;; Fall back to finding first user message
              (goto-char (point-min))
              (if (re-search-forward "\"type\":\"user\"" nil t)
                  (progn
                    (beginning-of-line)
                    (let* ((line (buffer-substring-no-properties
                                 (line-beginning-position)
                                 (line-end-position)))
                           (json (ignore-errors (json-parse-string line :object-type 'alist)))
                           (message (alist-get 'message json))
                           (content (alist-get 'content message)))
                      (if (and content (vectorp content) (> (length content) 0))
                          (let ((first-item (aref content 0)))
                            (or (alist-get 'text first-item) "No preview available"))
                        "No preview available")))
                "No preview available")))))
    (error "No preview available")))

(defun matisse--replay-conversation-from-file (file)
  "Replay conversation from FILE into the current buffer.
Returns \='user if last message was from user, \='assistant if from
assistant, nil if no messages."
  (let ((target-buffer (current-buffer))
        (message-count 0)
        (last-message-type nil)
        (matisse--skip-syntax-highlighting t)  ; Skip highlighting during replay for performance
        (inhibit-redisplay t))  ; Prevent redrawing after each insert
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
                                    ;; Use batch property application for better performance
                                    (let ((prompt-char (matisse--get-icon :prompt))
                                          (start (point)))
                                      (insert (concat prompt-char " " text))
                                      (put-text-property start (point) 'face 'matisse-prompt-inactive-face)
                                      (insert "\n")))
                                   ((equal type "assistant")
                                    ;; Format assistant message - just text
                                    (insert text)
                                    (insert "\n\n"))))))))))))
              (error nil))))
        (forward-line)))
    ;; Return the last message type
    last-message-type))

(defun matisse--replay-previous-conversation ()
  "Replay the previous conversation in current buffer.

Returns \='user if last message was from user, \='assistant if from
assistant, nil if no messages."
  (let ((file (matisse--get-latest-conversation-file)))
    (when file
      (matisse--replay-conversation-from-file file))))

(defun matisse--update-mode-line ()
  "Update the mode line with current spinner state and selection info."
  ;; Update mode line in all matisse shell buffers
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq major-mode 'matisse-shell-mode)
          (let* ((spinner-part (cond
                                (matisse--pending-permission-request
                                 (matisse--get-icon :modeline-permission))
                                (matisse--waiting-for-response
                                 (matisse--get-icon :modeline-active))
                                (t (matisse--get-icon :modeline-default))))
                 (buffer-part (propertize (buffer-name) 'face 'font-lock-constant-face))
                 (selection-part (matisse--format-selection-status))
                 (token-part (matisse--format-token-status))
                 (mode-part (matisse--format-permission-mode)))
            (setq matisse--mode-line-left
                  (concat matisse--mode-line-separator spinner-part
                          " " buffer-part
                          (if mode-part (concat matisse--mode-line-separator mode-part) "")
                          (if token-part (concat " " token-part) ""))
                  matisse--mode-line-right
                  (if selection-part
                      (concat matisse--mode-line-separator selection-part "   ")
                    ""))
            (force-mode-line-update t)))))))

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

;;; Permission System
;;;; Permission Logic
(defun matisse--should-auto-allow-tool (tool-name)
  "Check if TOOL-NAME should be auto-allowed without prompting.
Returns t if tool should be auto-allowed, nil otherwise."
  (let ((mode (or matisse--current-permission-mode matisse-permission-mode)))
    (or
     ;; If in bypass mode or yolo mode, allow everything
     (string= mode "bypassPermissions")
     (string= mode "yolo")
     ;; Always allow read-only tools
     (member tool-name '("Read" "Grep" "Glob" "WebSearch" "WebFetch" "ListMcpResourcesTool" "ReadMcpResourceTool"))
     ;; In acceptEdits mode, auto-allow file editing tools
     (and (string= mode "acceptEdits")
          (member tool-name '("Edit" "Write" "MultiEdit")))
     ;; Auto-allow next write tool if flag is set (after plan approval with "yes")
     (and matisse--auto-allow-next-write-tool
          (not (member tool-name '("Read" "Grep" "Glob" "WebSearch" "WebFetch" "ListMcpResourcesTool" "ReadMcpResourceTool" "ExitPlanMode")))))))

(defun matisse--log-permission-decision (buffer-name _tool-name decision)
  "Log permission DECISION for TOOL-NAME in BUFFER-NAME.
This adds a simple log entry to the matisse shell buffer."
  (when-let* ((buffer (get-buffer buffer-name)))
    (with-current-buffer buffer
      (let ((insert-pos (matisse--get-current-response-position)))
        (save-excursion
          (goto-char insert-pos)
          (let ((inhibit-read-only t))
            (insert (format "  → %s%s\n"
                           (if (string= decision "allow")
                               (matisse--get-icon :allow)
                             (matisse--get-icon :deny))
                           (if (string= decision "allow") "Allowed" "Denied")))
            ;; Update the response-end marker if we have one
            (when (and (boundp 'matisse--current-message-id)
                       matisse--current-message-id
                       (boundp 'matisse--response-sections)
                       matisse--response-sections)
              (let ((section (gethash matisse--current-message-id matisse--response-sections)))
                (when section
                  (let ((response-end (plist-get section :response-end)))
                    (when (markerp response-end)
                      (set-marker response-end (point)))))))))))))

(defun matisse--decide-tool-permission-shell (tool-name tool-input _tool-id &optional buffer-name)
  "Decide whether to allow TOOL-NAME with TOOL-INPUT using `y-or-n-p'.
TOOL-ID is the tool request identifier (unused).
BUFFER-NAME is the specific matisse shell buffer (used in prompt).
Returns \"allow\" or \"deny\" synchronously."
  (let ((mode (or matisse--current-permission-mode matisse-permission-mode)))
    (cond
     ;; If in bypass mode or yolo mode, allow everything
     ((string= mode "bypassPermissions")
      "allow")

     ((string= mode "yolo")
      "allow")

     ;; Always allow read-only tools
     ((member tool-name '("Read" "Grep" "Glob" "WebSearch" "WebFetch" "ListMcpResourcesTool" "ReadMcpResourceTool"))
      "allow")

     ;; In acceptEdits mode, auto-allow file editing tools
     ((and (string= mode "acceptEdits")
           (member tool-name '("Edit" "Write" "MultiEdit")))
      "allow")

   ;; Use simple y-or-n-p for other tools
   (t
    ;; Display permission request in the shell buffer first
    (when buffer-name
      (let ((buffer (get-buffer buffer-name)))
        (when buffer
          (with-current-buffer buffer
            (let ((insert-pos (matisse--get-current-response-position)))
              (save-excursion
                (goto-char insert-pos)
                (let* ((inhibit-read-only t)
                       (icon (matisse--get-icon :permission))
                       (permission-text (cond
                                         ((string= tool-name "Bash")
                                          (let* ((command (alist-get 'command tool-input))
                                                 (truncated-command (if (and (not matisse-verbose-mode)
                                                                            (> (length command) 40))
                                                                       (concat (substring command 0 40) "[…]")
                                                                     command)))
                                            (format "\n%sPermission Request: Claude wants to run command:\n  %s\n"
                                                    icon truncated-command)))
                                         ((member tool-name '("Write" "Edit" "MultiEdit"))
                                          (let ((file-path (or (alist-get 'file_path tool-input)
                                                               (alist-get 'path tool-input))))
                                            (format "\n%sPermission Request: Claude wants to %s:\n  %s\n"
                                                    icon (downcase tool-name) file-path)))
                                         (t
                                          (format "\n%sPermission Request: Claude wants to use %s tool\n"
                                                  icon tool-name)))))
                  (insert permission-text)
                  ;; Update the response-end marker if we have one
                  (when (and (boundp 'matisse--current-message-id)
                             matisse--current-message-id
                             (boundp 'matisse--response-sections)
                             matisse--response-sections)
                    (let ((section (gethash matisse--current-message-id matisse--response-sections)))
                      (when section
                        (let ((response-end (plist-get section :response-end)))
                          (when (markerp response-end)
                            (set-marker response-end (point))))))))))))))

    ;; Now prompt in minibuffer
    (let* ((prompt (cond
                    ((string= tool-name "Bash")
                     (let* ((command (alist-get 'command tool-input))
                            (truncated-command (if (and (not matisse-verbose-mode)
                                                       (> (length command) 40))
                                                  (concat (substring command 0 40) "[…]")
                                                command)))
                       (format "Allow command: %s? " truncated-command)))
                    ((member tool-name '("Write" "Edit" "MultiEdit"))
                     (let ((file-path (or (alist-get 'file_path tool-input)
                                          (alist-get 'path tool-input))))
                       (format "Allow %s on %s? " (downcase tool-name) file-path)))
                    (t
                     (format "Allow %s tool? " tool-name))))
           (decision (if (y-or-n-p prompt) "allow" "deny")))

      ;; Clear minibuffer message
      (message nil)

      ;; Log decision if buffer available
      (when buffer-name
        (matisse--log-permission-decision buffer-name tool-name decision))

      decision)))))

(defun matisse--decide-tool-permission-with-suggestions (tool-name tool-input suggestions buffer-name)
  "Decide permission with optional suggestions for \\='always allow\\='.
TOOL-NAME is the tool being requested.
TOOL-INPUT is the input to the tool.
SUGGESTIONS is the permission_suggestions array from Claude.
BUFFER-NAME is the matisse shell buffer.
Returns a cons cell: (decision . updated-permissions) where decision
is \"allow\" or \"deny\" and updated-permissions is nil or the
suggestions array."
  (let ((mode (or matisse--current-permission-mode matisse-permission-mode)))
    (cond
     ;; If in bypass mode or yolo mode, allow everything
     ((string= mode "bypassPermissions")
      (cons "allow" nil))

     ((string= mode "yolo")
      (cons "allow" nil))

     ;; Always allow read-only tools
     ((member tool-name '("Read" "Grep" "Glob" "WebSearch" "WebFetch" "ListMcpResourcesTool" "ReadMcpResourceTool"))
      (cons "allow" nil))

     ;; In acceptEdits mode, auto-allow file editing tools
     ((and (string= mode "acceptEdits")
           (member tool-name '("Edit" "Write" "MultiEdit")))
      (cons "allow" nil))

   ;; For write tools, check if we have acceptEdits suggestion
   (t
    ;; Check if suggestions include setMode to acceptEdits
    (let* ((has-accept-edits-suggestion
            (and (vectorp suggestions)
                 (cl-some (lambda (suggestion)
                            (let ((type-val (alist-get 'type suggestion))
                                  (mode-val (alist-get 'mode suggestion)))
                              (and (equal type-val "setMode")
                                   (equal mode-val "acceptEdits"))))
                          suggestions))))

      ;; Display permission request in the shell buffer first
      (when buffer-name
        (let ((buffer (get-buffer buffer-name)))
          (when buffer
            (with-current-buffer buffer
              (let ((insert-pos (matisse--get-current-response-position)))
                (save-excursion
                  (goto-char insert-pos)
                  (let* ((inhibit-read-only t)
                         (icon (matisse--get-icon :permission))
                         ;; Use common description builder (non-brief = full format)
                         (description (matisse--build-permission-description tool-name tool-input))
                         (permission-text (format "\n%sPermission Request: %s\n" icon description)))
                    (insert permission-text)
                    ;; Update the response-end marker if we have one
                    (when (and (boundp 'matisse--current-message-id)
                               matisse--current-message-id
                               (boundp 'matisse--response-sections)
                               matisse--response-sections)
                      (let ((section (gethash matisse--current-message-id matisse--response-sections)))
                        (when section
                          (let ((response-end (plist-get section :response-end)))
                            (when (markerp response-end)
                              (set-marker response-end (point))))))))))))))

      ;; Now prompt in minibuffer with extended options if suggestions available
      (let* (;; Use common description builder (brief = short format)
             (prompt-base (concat (matisse--build-permission-description tool-name tool-input t) " "))
             (response (condition-case nil
                          (if (and has-accept-edits-suggestion
                                   (member tool-name '("Edit" "Write" "MultiEdit")))
                              ;; Use read-char-choice for y/a/n prompt with proper formatting
                              ;; Only show "always" option for edit-related tools
                              (let* ((options-text (matisse--format-permission-options t t))  ; has-accept=t, for-minibuffer=t
                                     (prompt-formatted (concat prompt-base options-text))
                                     (char (read-char-choice prompt-formatted '(?y ?Y ?a ?A ?n ?N))))
                                (cond
                                 ((memq char '(?y ?Y)) 'yes)
                                 ((memq char '(?a ?A)) 'always)
                                 ((memq char '(?n ?N)) 'no)))
                            ;; Use standard y-or-n-p
                            (if (y-or-n-p prompt-base) 'yes 'no))
                        ;; Handle C-g (quit) as denial
                        (quit 'no)))
             (decision (if (eq response 'no) "deny" "allow"))
             (updated-permissions (if (eq response 'always) suggestions nil)))

        ;; If user chose "always", switch mode based on suggestions
        (when (eq response 'always)
          (when-let* ((shell-buffer (get-buffer buffer-name)))
            (with-current-buffer shell-buffer
              ;; Check if suggestions include acceptEdits mode
              (let ((suggested-mode (if (and (vectorp suggestions)
                                             (cl-some (lambda (s)
                                                       (and (equal (alist-get 'type s) "setMode")
                                                            (equal (alist-get 'mode s) "acceptEdits")))
                                                     suggestions))
                                       "acceptEdits"
                                     "bypassPermissions")))
                (setq matisse--current-permission-mode suggested-mode)
                (matisse--update-mode-line)))))

        ;; Clear minibuffer message
        (message nil)

        ;; Log decision if buffer available
        (when buffer-name
          (matisse--log-permission-decision buffer-name tool-name decision))

        (cons decision updated-permissions)))))))

;;;; In-Buffer Permission Prompts
(defun matisse--find-string-line-number (file-path search-string)
  "Find the starting line number of SEARCH-STRING in FILE-PATH.
Returns the 1-indexed line number where SEARCH-STRING starts, or nil
if not found.  If the file does not exist, returns nil."
  (when (and file-path (file-exists-p file-path))
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents file-path)
          (goto-char (point-min))
          (when (search-forward search-string nil t)
            ;; Found it - calculate line number at the start of the match
            ;; Use save-restriction + widen for correctness (temp buffers
            ;; are rarely narrowed, but be consistent)
            (save-restriction
              (widen)
              (line-number-at-pos (match-beginning 0)))))
      (error nil))))

(defun matisse--create-edit-diff (file-path old-string new-string)
  "Create a syntax-highlighted diff for Edit tool permission prompt.
FILE-PATH is the path to the file being edited.
OLD-STRING is the text to be replaced.
NEW-STRING is the replacement text.
Returns a propertized string with diff highlighting."
  (let ((old-temp-buffer (generate-new-buffer " *matisse-diff-old*"))
        (new-temp-buffer (generate-new-buffer " *matisse-diff-new*"))
        (diff-buffer (generate-new-buffer " *matisse-diff*")))
    (unwind-protect
        (progn
          ;; Fill the old temp buffer
          (with-current-buffer old-temp-buffer
            (insert old-string)
            (set-buffer-modified-p nil))

          ;; Fill the new temp buffer
          (with-current-buffer new-temp-buffer
            (insert new-string)
            (set-buffer-modified-p nil))

          ;; Create the diff
          (let ((switches `("-u"
                            "--label" ,(shell-quote-argument (concat "a/" (file-name-nondirectory file-path)))
                            "--label" ,(shell-quote-argument (concat "b/" (file-name-nondirectory file-path))))))

            ;; Generate diff with dynamic bindings for diff-mode variables
            (let ((diff-font-lock-syntax 'hunk-also)
                  (diff-font-lock-prettify t)
                  (diff-use-labels nil))
              (diff-no-select old-temp-buffer new-temp-buffer switches t diff-buffer)

              ;; Configure and fontify the diff buffer
              (with-current-buffer diff-buffer
                (setq default-directory (file-name-directory file-path))
                (setq-local diff-vc-backend nil)
                (setq-local diff-default-directory default-directory)
                (setq-local diff-font-lock-syntax 'hunk-also)
                (diff-mode)
                (font-lock-ensure)

                ;; Clean up and enhance diff output
                (let ((inhibit-read-only t))
                  (goto-char (point-min))
                  ;; Remove the "diff -u" command line at the start
                  (when (re-search-forward "^diff -u .*\n" nil t)
                    (delete-region (match-beginning 0) (match-end 0)))
                  ;; Remove the --- and +++ file headers
                  (goto-char (point-min))
                  (when (re-search-forward "^--- .*\n" nil t)
                    (delete-region (match-beginning 0) (match-end 0)))
                  (goto-char (point-min))
                  (when (re-search-forward "^\\+\\+\\+ .*\n" nil t)
                    (delete-region (match-beginning 0) (match-end 0)))
                  ;; Remove hunk headers (@@...@@) since line numbers are relative to fragments, not file
                  (goto-char (point-min))
                  (while (re-search-forward "^@@.*@@.*\n" nil t)
                    (delete-region (match-beginning 0) (match-end 0)))
                  ;; Remove the "Diff finished" footer message
                  (goto-char (point-min))
                  (when (re-search-forward "^Diff finished\\..*\n" nil t)
                    (delete-region (match-beginning 0) (match-end 0)))

                  ;; Add line numbers if we can find the starting line
                  (when-let* ((start-line (matisse--find-string-line-number file-path old-string)))
                    (goto-char (point-min))
                    (let ((current-line start-line))
                      (while (not (eobp))
                        (cond
                         ;; Lines starting with '-' or ' ' (context): show line number
                         ((looking-at "^[-  ]")
                          (insert (propertize (format "%4d │ " current-line) 'face 'shadow))
                          (delete-char 1)  ;; Remove the diff marker (-, or space)
                          (setq current-line (1+ current-line)))
                         ;; Lines starting with '+': show blank space
                         ((looking-at "^\\+")
                          (insert (propertize "     │ " 'face 'shadow))
                          (delete-char 1))  ;; Remove the diff marker (+)
                         ;; Other lines: no line number
                         (t nil))
                        (forward-line 1))))

                  ;; Add file header and separators
                  (goto-char (point-min))
                  (let* ((separator (make-string 60 ?━))
                         (relative-path (if (file-name-absolute-p file-path)
                                           (file-relative-name file-path default-directory)
                                         file-path)))
                    ;; Insert top separator
                    (insert (propertize separator 'face 'shadow) "\n")
                    ;; Insert filename
                    (insert (propertize relative-path 'face 'bold) "\n")
                    ;; Insert separator before diff content
                    (insert (propertize separator 'face 'shadow) "\n")
                    ;; Add bottom separator at the end
                    (goto-char (point-max))
                    (unless (bolp)
                      (insert "\n"))
                    (insert (propertize separator 'face 'shadow))))

                ;; Return the propertized diff content
                (buffer-string)))))

      ;; Clean up temporary buffers
      (when (buffer-live-p old-temp-buffer)
        (kill-buffer old-temp-buffer))
      (when (buffer-live-p new-temp-buffer)
        (kill-buffer new-temp-buffer))
      (when (buffer-live-p diff-buffer)
        (kill-buffer diff-buffer)))))

(defun matisse--format-tool-params-with-highlighting (tool-input)
  "Format TOOL-INPUT parameters as syntax-highlighted JSON.
Returns a propertized string with JSON syntax highlighting applied.
Uses the cached json-mode buffer for performance."
  (condition-case _err
      (let* ((json-string (json-encode tool-input))
             ;; Pretty-print the JSON
             (pretty-json (with-temp-buffer
                           (insert json-string)
                           (json-pretty-print-buffer)
                           (buffer-string)))
             ;; Get cached json-mode buffer
             (target-mode (matisse--find-best-mode "json"))
             (faces-to-apply nil))

        (when target-mode
          (let ((cached-buffer (matisse--get-cached-mode-buffer target-mode)))
            ;; Use the cached buffer for syntax highlighting
            (with-current-buffer cached-buffer
              ;; Clear the buffer and insert JSON
              (erase-buffer)
              (insert pretty-json)

              ;; Force font-lock to run
              (font-lock-ensure)

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
                           (text (buffer-substring-no-properties temp-pos next-change)))
                      (when face
                        (push (list text face) faces-to-apply))
                      (unless face
                        (push (list text nil) faces-to-apply))
                      (goto-char next-change)))))))

          ;; Build the propertized string
          (with-temp-buffer
            (dolist (item (reverse faces-to-apply))
              (let ((text (car item))
                    (face (cadr item)))
                (if face
                    (insert (propertize text 'face face))
                  (insert text))))
            (buffer-string))))
    (error
     ;; If highlighting fails, just return plain JSON
     (json-encode tool-input))))

(defun matisse--build-permission-description (tool-name tool-input &optional brief)
  "Build permission description for TOOL-NAME with TOOL-INPUT.
When BRIEF is non-nil, return short form suitable for minibuffer prompts.
Returns a string describing what the tool wants to do."
  (cond
   ((string= tool-name "Bash")
    (let* ((command (alist-get 'command tool-input))
           (truncated-command (if (and (not matisse-verbose-mode)
                                      (> (length command) 40))
                                 (concat (substring command 0 40) "[…]")
                               command)))
      (if brief
          (format "Allow command: %s?" truncated-command)
        (format "Claude wants to run command:\n  %s" truncated-command))))

   ((string= tool-name "Write")
    (let ((file-path (alist-get 'file_path tool-input)))
      (if brief
          (format "Allow write on %s?" file-path)
        (format "Claude wants to write:\n  %s" file-path))))

   ((string= tool-name "Edit")
    (let ((file-path (alist-get 'file_path tool-input)))
      (if brief
          (format "Allow edit on %s?" file-path)
        (format "Claude wants to edit:\n  %s" file-path))))

   ((string= tool-name "MultiEdit")
    (if brief
        "Allow multi-file edit?"
      "Claude wants to edit multiple files"))

   (t
    (if brief
        (format "Allow %s tool?" tool-name)
      (format "Claude wants to use %s tool" tool-name)))))

(defun matisse--format-permission-options (has-accept &optional for-minibuffer)
  "Format permission response options string.
HAS-ACCEPT determines if \\'accept\\' or \\'always\\' option is shown.
FOR-MINIBUFFER adjusts formatting for minibuffer vs in-buffer display.
Returns a formatted string describing valid responses."
  (if for-minibuffer
      ;; Minibuffer format: (y/a/n) or (y/n)
      (if has-accept
          (concat "("
                  (propertize "y" 'face 'help-key-binding)
                  "es, "
                  (propertize "a" 'face 'help-key-binding)
                  "lways, "
                  (propertize "n" 'face 'help-key-binding)
                  "o) ")
        (concat "("
                (propertize "y" 'face 'help-key-binding)
                "es, "
                (propertize "n" 'face 'help-key-binding)
                "o) "))
    ;; In-buffer format: Type yes/accept/no and press RETURN:
    (if has-accept
        (concat "Type "
                (propertize "y" 'face 'help-key-binding)
                "es, "
                (propertize "n" 'face 'help-key-binding)
                "o, or "
                (propertize "a" 'face 'help-key-binding)
                "ccept and press RETURN:")
      (concat "Type "
              (propertize "y" 'face 'help-key-binding)
              "es or "
              (propertize "n" 'face 'help-key-binding)
              "o and press RETURN:"))))

(defun matisse--format-permission-prompt (tool-name tool-input suggestions)
  "Format permission prompt message for in-buffer display.
TOOL-NAME is the name of the tool requesting permission.
TOOL-INPUT is the input parameters for the tool.
SUGGESTIONS is the permission_suggestions array from Claude.
Returns a formatted prompt string."
  (let* ((icon (matisse--get-icon :permission))
         ;; Check if acceptEdits suggestion is present
         (has-accept (and (vectorp suggestions)
                         (cl-some (lambda (s)
                                   (and (equal (alist-get 'type s) "setMode")
                                        (equal (alist-get 'mode s) "acceptEdits")))
                                 suggestions)))
         ;; Use common options formatter
         (options (matisse--format-permission-options has-accept)))

    ;; Handle ExitPlanMode specially with plan display
    (cond
     ((string= tool-name "ExitPlanMode")
      (let ((plan-text (alist-get 'plan tool-input)))
        ;; ExitPlanMode always has accept option
        (format "\n%s\n\nApprove this plan?\n\n%s\n"
                plan-text
                (matisse--format-permission-options t))))  ; t = has-accept

     ;; Handle Edit tool specially with diff display
     ((string= tool-name "Edit")
      (let* ((file-path (alist-get 'file_path tool-input))
             (old-string (alist-get 'old_string tool-input))
             (new-string (alist-get 'new_string tool-input))
             (diff-text (matisse--create-edit-diff file-path old-string new-string)))
        (format "%sEdit %s?\n\n%s\n%s\n" icon file-path diff-text options)))

     ;; Other tools - show parameters with syntax highlighting
     (t
      (let* ((action-header (cond
                             ((string= tool-name "Bash")
                              "Run command")
                             ((string= tool-name "Write")
                              (format "Write file: %s" (alist-get 'file_path tool-input)))
                             ((string= tool-name "MultiEdit")
                              "Edit multiple files")
                             (t (format "Use %s tool" tool-name))))
             ;; Show parameters as syntax-highlighted JSON for detailed view
             (params-display (if (and tool-input
                                      ;; Only show detailed params for certain tools
                                      (member tool-name '("Bash" "Write" "NotebookEdit" "WebFetch")))
                                 (concat "\n\nParameters:\n"
                                        (matisse--format-tool-params-with-highlighting tool-input)
                                        "\n")
                               "")))
        (format "%s%s?%s\n%s\n" icon action-header params-display options))))))

(defun matisse--prompt-permission-in-buffer (process request-id tool-name tool-input suggestions)
  "Show permission prompt in buffer and wait for user response.
PROCESS is the Claude Code process.
REQUEST-ID is the control request identifier.
TOOL-NAME is the name of the tool requesting permission.
TOOL-INPUT is the input parameters for the tool.
SUGGESTIONS is the permission_suggestions array from Claude."
  (matisse--debug-log "IN-BUFFER PERMISSION: Prompting for %s (id=%s)" tool-name request-id)

  ;; Stop the spinner animation while waiting for permission
  (when matisse--spinner-timer
    (cancel-timer matisse--spinner-timer)
    (setq matisse--spinner-timer nil))

  ;; Store pending request with current buffer
  (setq matisse--pending-permission-request
        (list (current-buffer) process request-id tool-name tool-input suggestions))

  ;; Update mode-line to show permission icon
  (matisse--update-mode-line)

  ;; Insert permission prompt at current response position (as part of Claude's output)
  (let ((inhibit-read-only t))
    (save-excursion
      ;; Get the position where Claude's response is being written
      (let ((insert-pos (matisse--get-current-response-position)))
        (goto-char insert-pos)

        ;; Ensure we're on a new line
        (unless (bolp)
          (insert "\n"))
        (insert "\n")

        ;; Insert permission request
        (let ((prompt-text (matisse--format-permission-prompt tool-name tool-input suggestions))
              (start-pos (point)))
          (insert prompt-text)

          ;; Make permission text read-only
          (put-text-property start-pos (point) 'read-only t)
          (put-text-property start-pos (point) 'rear-nonsticky '(read-only))

          ;; Update the response-end marker to after our insertion
          (when (and (boundp 'matisse--current-message-id)
                     matisse--current-message-id
                     (boundp 'matisse--response-sections)
                     matisse--response-sections)
            (let ((section (gethash matisse--current-message-id matisse--response-sections)))
              (when section
                (let ((response-end (plist-get section :response-end)))
                  (when (markerp response-end)
                    (set-marker response-end (point)))))))))))

  ;; Force immediate scroll to show permission prompt
  (matisse--auto-scroll-if-at-end t (current-buffer) t)

  ;; Apply syntax highlighting to any code blocks in the prompt (incremental to avoid full buffer scan)
  (condition-case err
      (matisse--overlays-put t)  ; incremental=t for performance
    (error (matisse--debug-log "Error applying overlays to permission prompt: %s" (error-message-string err))))

  ;; Force redisplay so syntax highlighting is visible immediately
  (redisplay t))

(defun matisse--process-permission-response (process request-id tool-name tool-input suggestions response)
  "Process permission RESPONSE for TOOL-NAME.
PROCESS is the Claude Code process.
REQUEST-ID is the control request identifier.
TOOL-INPUT is the tool input parameters.
SUGGESTIONS is the permission suggestions array.
RESPONSE is the user's response string."
  (let ((decision (pcase response
                    ("yes" "allow")
                    ("no" "deny")
                    ("accept" "allow")
                    (_ nil))))

    (when decision
      ;; If user chose "accept", switch mode based on suggestions
      (when (string= response "accept")
        (when-let* ((proc-buffer (process-buffer process)))
          (with-current-buffer proc-buffer
            ;; Check if suggestions include acceptEdits mode
            (let ((suggested-mode (if (and (vectorp suggestions)
                                           (cl-some (lambda (s)
                                                     (and (equal (alist-get 'type s) "setMode")
                                                          (equal (alist-get 'mode s) "acceptEdits")))
                                                   suggestions))
                                     "acceptEdits"
                                   "bypassPermissions")))
              (setq matisse--current-permission-mode suggested-mode)
              (matisse--update-mode-line)))))

      ;; Show decision in buffer
      (matisse--show-permission-decision decision tool-name)

      ;; Send control response
      (let* ((updated-permissions (when (string= response "accept") suggestions))
             (response-data (if (string= decision "allow")
                               (let ((base-response `((behavior . "allow")
                                                     (updatedInput . ,tool-input))))
                                 ;; Include updatedPermissions from "accept" choice
                                 (when updated-permissions
                                   (setq base-response (append base-response `((updatedPermissions . ,updated-permissions)))))
                                 ;; Also include pending permission mode update if user cycled mode
                                 (when matisse--pending-permission-update
                                   (setq base-response (append base-response
                                                              `((updatedPermissions . ((permissionMode . ,matisse--pending-permission-update))))))
                                   (setq matisse--pending-permission-update nil))
                                 base-response)
                             `((behavior . "deny")
                               (message . "User denied permission")
                               (interrupt . t)))))
        (matisse--debug-log "IN-BUFFER PERMISSION: Sending control response: %s" decision)
        (matisse--send-control-response process request-id response-data)))))

(defun matisse--handle-permission-response (response)
  "Process user RESPONSE to pending permission request.
RESPONSE is the user's input string (\\='yes\\=', \\='no\\=', or \\='accept\\=')."
  (matisse--debug-log "IN-BUFFER PERMISSION: Got response: %s" response)

  (if (not matisse--pending-permission-request)
      (error "No pending permission request")

    (let ((response-trimmed (string-trim (downcase response))))
      ;; Check if user wants to exit
      (if (member response-trimmed matisse-exit-commands)
          (progn
            (matisse--debug-log "IN-BUFFER PERMISSION: Exit command detected")
            ;; Clear pending request
            (setq matisse--pending-permission-request nil)
            ;; Exit matisse
            (when (fboundp 'matisse-quit)
              (matisse-quit)))

        ;; Handle normal permission response
        (pcase-let ((`(,_buffer ,process ,request-id ,tool-name ,tool-input ,suggestions)
                     matisse--pending-permission-request))

          (matisse--debug-log "IN-BUFFER PERMISSION: Processing response for %s (id=%s)" tool-name request-id)

          ;; Special handling for ExitPlanMode
          (if (equal tool-name "ExitPlanMode")
              (let* ((normalized-response (pcase response-trimmed
                                           ((or "y" "yes") "yes")
                                           ((or "n" "no") "no")
                                           ((or "a" "accept") "accept")
                                           (_ response-trimmed))))
                ;; Clear pending request
                (setq matisse--pending-permission-request nil)

                ;; Clear input line
                (let ((inhibit-read-only t)
                      (prompt-start (save-excursion
                                     (goto-char (point-max))
                                     (when (re-search-backward matisse--shell-prompt-regex nil t)
                                       (line-beginning-position))))
                      (input-end (point-max)))
                  (when prompt-start
                    (delete-region prompt-start input-end)))

                (cond
                 ;; User chose "accept" - switch to acceptEdits mode
                 ((string= normalized-response "accept")
                  (setq matisse--current-permission-mode "acceptEdits")
                  (matisse--update-mode-line)
                  ;; Show decision in buffer
                  (matisse--show-permission-decision "allow" "ExitPlanMode")
                  (matisse--send-control-response process request-id
                                                  `((behavior . "allow")
                                                    (updatedInput . ,tool-input)
                                                    (updatedPermissions . [((type . "setMode") (mode . "acceptEdits") (destination . "session"))])))
                  (matisse--start-spinner)
                  ;; Insert new prompt so user can queue next message
                  (matisse--insert-prompt))

                 ;; User chose "yes" - switch to default mode and auto-allow next write tool
                 ((string= normalized-response "yes")
                  (matisse--debug-log "EXITPLANMODE: User chose 'yes', switching to default mode")
                  (setq matisse--current-permission-mode "default")
                  (setq matisse--auto-allow-next-write-tool t)  ; Auto-allow the first edit
                  (matisse--debug-log "EXITPLANMODE: Mode set to=%s, auto-allow-flag=%s"
                                      matisse--current-permission-mode
                                      matisse--auto-allow-next-write-tool)
                  (matisse--update-mode-line)
                  ;; Show decision in buffer
                  (matisse--show-permission-decision "allow" "ExitPlanMode")
                  (matisse--send-control-response process request-id
                                                  `((behavior . "allow")
                                                    (updatedInput . ,tool-input)
                                                    (updatedPermissions . [((type . "setMode") (mode . "default") (destination . "session"))])))
                  (matisse--start-spinner)
                  ;; Insert new prompt so user can queue next message
                  (matisse--insert-prompt))

                 ;; User chose "no" - reject plan, stay in plan mode
                 ((string= normalized-response "no")
                  ;; Show decision in buffer
                  (matisse--show-permission-decision "deny" "ExitPlanMode")
                  (matisse--send-control-response process request-id
                                                  `((behavior . "deny")
                                                    (message . "User rejected the plan")
                                                    (interrupt . t)))
                  (setq matisse--waiting-for-response nil)
                  (matisse--stop-spinner)
                  ;; Insert new prompt so user can enter new message
                  (matisse--insert-prompt))

                 ;; Invalid response
                 (t
                  ;; ExitPlanMode always has accept option
                  (message "Invalid response. Type 'yes', 'no', or 'accept'.")
                  ;; Re-insert prompt for retry
                  (matisse--insert-prompt))))

            ;; Normal tool permission handling
            ;; Check if accept is valid for this request
            ;; Map abbreviations to full words and validate response
            (let* ((has-accept (and (vectorp suggestions)
                                 (cl-some (lambda (s)
                                           (and (equal (alist-get 'type s) "setMode")
                                                (equal (alist-get 'mode s) "acceptEdits")))
                                         suggestions)))
                 ;; Normalize response: map abbreviations to full words
                 (normalized-response (pcase response-trimmed
                                       ((or "y" "yes") "yes")
                                       ((or "n" "no") "no")
                                       ((or "a" "accept") "accept")
                                       (_ response-trimmed)))
                 (decision (pcase normalized-response
                             ("yes" "allow")
                             ("no" "deny")
                             ("accept" (if has-accept "allow" nil))
                             (_ nil))))

            (matisse--debug-log "IN-BUFFER PERMISSION: Decision=%s for response=%s" decision response-trimmed)

            (if decision
                (progn
                  ;; Clear pending request FIRST to prevent re-entry
                  (matisse--debug-log "IN-BUFFER PERMISSION: Clearing pending request")
                  (setq matisse--pending-permission-request nil)

                  ;; Clear input line
                  (let ((inhibit-read-only t)
                        (prompt-start (save-excursion
                                       (goto-char (point-max))
                                       (when (re-search-backward matisse--shell-prompt-regex nil t)
                                         (line-beginning-position))))
                        (input-end (point-max)))
                    (when prompt-start
                      (delete-region prompt-start input-end)))

                  ;; If user chose "accept", switch mode based on suggestions
                  (when (string= normalized-response "accept")
                    ;; Check if suggestions include acceptEdits mode
                    (let ((suggested-mode (if (and (vectorp suggestions)
                                                   (cl-some (lambda (s)
                                                             (and (equal (alist-get 'type s) "setMode")
                                                                  (equal (alist-get 'mode s) "acceptEdits")))
                                                           suggestions))
                                             "acceptEdits"
                                           "bypassPermissions")))
                      (setq matisse--current-permission-mode suggested-mode)
                      (matisse--update-mode-line)))

                  ;; Show decision in buffer
                  (matisse--show-permission-decision decision tool-name)

                  ;; Send control response
                  (let* ((updated-permissions (when (string= normalized-response "accept") suggestions))
                     (response-data (if (string= decision "allow")
                                       (let ((base-response `((behavior . "allow")
                                                             (updatedInput . ,tool-input))))
                                         (if updated-permissions
                                             (append base-response `((updatedPermissions . ,updated-permissions)))
                                           base-response))
                                     `((behavior . "deny")
                                       (message . "User denied permission")
                                       (interrupt . t)))))
                (matisse--debug-log "IN-BUFFER PERMISSION: Sending control response: %s" decision)
                (matisse--send-control-response process request-id response-data)

                ;; Update animation state based on decision
                (if (string= decision "allow")
                    ;; Restart the spinner animation after permission is granted
                    (matisse--start-spinner)
                  ;; Stop animation and clear waiting state on denial
                  (setq matisse--waiting-for-response nil)
                  (matisse--stop-spinner)))

              ;; Insert new prompt
              (matisse--debug-log "IN-BUFFER PERMISSION: Inserting new prompt")
              (matisse--insert-prompt)
              (matisse--debug-log "IN-BUFFER PERMISSION: Done handling response"))

              ;; Invalid response - show error and keep waiting
              (message "Invalid response. Type %s"
                      (if has-accept "'yes', 'no', or 'accept'." "'yes' or 'no'."))))))))))

(defun matisse--show-permission-decision (decision _tool-name)
  "Show permission DECISION for TOOL-NAME in buffer.
DECISION is either \"allow\" or \"deny\".
TOOL-NAME is the name of the tool that was allowed or denied."
  (let ((inhibit-read-only t)
        (icon (if (string= decision "allow")
                 (matisse--get-icon :allow)
                (matisse--get-icon :deny)))
        (text (if (string= decision "allow") "Allowed" "Denied"))
        (insert-pos (matisse--get-current-response-position)))
    (save-excursion
      (goto-char insert-pos)
      (unless (bolp) (insert "\n"))
      (let ((start-pos (point)))
        (insert (format "  → %s%s\n" icon text))
        (put-text-property start-pos (point) 'read-only t)
        ;; Update response-end marker
        (when (and (boundp 'matisse--current-message-id)
                   matisse--current-message-id
                   (boundp 'matisse--response-sections)
                   matisse--response-sections)
          (let ((section (gethash matisse--current-message-id matisse--response-sections)))
            (when section
              (let ((response-end (plist-get section :response-end)))
                (when (markerp response-end)
                  (set-marker response-end (point)))))))))))

;;;; Icon & Formatting Functions
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
      (when (and color-face (eq matisse-icons-mode 'nerd-icons))
        (setq face-props `(:height ,matisse-icons-scale-factor :inherit ,color-face)))
      (put-text-property 0 (length styled-icon) 'font-lock-face face-props styled-icon)
      styled-icon)))

(defun matisse--get-icon-data (icon-type &optional tool-name)
  "Get icon data for ICON-TYPE.
For :tool icons, TOOL-NAME specifies which tool.
Returns list: (emoji-icon nerd-icon nerd-face ascii-text)."
  (pcase icon-type
    (:tool
     (pcase tool-name
       ("Read" (list matisse-emoji-icon-read matisse-nerd-icon-read
                     matisse-nerd-icon-read-face "- "))
       ("Write" (list matisse-emoji-icon-write matisse-nerd-icon-write
                      matisse-nerd-icon-write-face "- "))
       ("Edit" (list matisse-emoji-icon-edit matisse-nerd-icon-edit
                     matisse-nerd-icon-edit-face "- "))
       ("Bash" (list matisse-emoji-icon-bash matisse-nerd-icon-bash
                     matisse-nerd-icon-bash-face "- "))
       ("Grep" (list matisse-emoji-icon-grep matisse-nerd-icon-grep
                     matisse-nerd-icon-grep-face "- "))
       ("Glob" (list matisse-emoji-icon-glob matisse-nerd-icon-glob
                     matisse-nerd-icon-glob-face "- "))
       ("Task" (list matisse-emoji-icon-task matisse-nerd-icon-task
                     matisse-nerd-icon-task-face "- "))
       ("WebFetch" (list matisse-emoji-icon-webfetch matisse-nerd-icon-webfetch
                         matisse-nerd-icon-webfetch-face "- "))
       ("TodoWrite" (list matisse-emoji-icon-todowrite matisse-nerd-icon-todowrite
                          matisse-nerd-icon-todowrite-face "- "))
       (_ (list matisse-emoji-icon-default matisse-nerd-icon-default
                matisse-nerd-icon-default-face "- "))))
    (:success
     (list matisse-emoji-icon-success matisse-nerd-icon-success
           matisse-nerd-icon-success-face "- "))
    (:performance
     (list matisse-emoji-icon-performance matisse-nerd-icon-performance
           matisse-nerd-icon-performance-face "- "))
    (:command
     (list matisse-emoji-icon-command matisse-nerd-icon-command
           matisse-nerd-icon-command-face ""))
    (:permission
     (list matisse-emoji-icon-permission matisse-nerd-icon-permission
           matisse-nerd-icon-permission-face matisse-ascii-icon-permission))
    (:allow
     (list matisse-emoji-icon-allow matisse-nerd-icon-allow
           matisse-nerd-icon-allow-face matisse-ascii-icon-allow))
    (:deny
     (list matisse-emoji-icon-deny matisse-nerd-icon-deny
           matisse-nerd-icon-deny-face matisse-ascii-icon-deny))
    (:prompt
     (list matisse-emoji-shell-prompt matisse-nerd-shell-prompt
           nil matisse-ascii-shell-prompt))
    (:auto-compact
     (list matisse-emoji-icon-auto-compact matisse-nerd-icon-auto-compact
           matisse-nerd-icon-auto-compact-face matisse-ascii-icon-auto-compact))
    (:modeline-default
     (list matisse-emoji-icon-modeline-default matisse-nerd-icon-modeline-default
           matisse-nerd-icon-modeline-default-face matisse-ascii-icon-modeline-default))
    (:modeline-permission
     (list matisse-emoji-icon-modeline-permission matisse-nerd-icon-modeline-permission
           matisse-nerd-icon-modeline-permission-face matisse-ascii-icon-modeline-permission))
    (:modeline-active
     (list matisse-emoji-icon-modeline-active matisse-nerd-icon-modeline-active
           matisse-nerd-icon-modeline-active-face nil))
    ;; Session list status icons
    (:status-working
     (list "⏳" "" 'matisse-nerd-icon-orange ""))
    (:status-permission
     (list matisse-emoji-icon-permission matisse-nerd-icon-permission 'matisse-nerd-icon-yellow "?"))
    (:status-idle
     (list matisse-emoji-icon-success matisse-nerd-icon-success matisse-nerd-icon-success-face "ok"))
    (:status-not-started
     (list "" "" nil ""))))

(defun matisse--get-icon (icon-type &optional tool-name)
  "Get formatted icon for ICON-TYPE based on current icon mode.
For :tool icons, TOOL-NAME specifies which tool.
Icon types: :tool, :success, :performance, :command, :permission,
:allow, :deny, :prompt, :modeline-default, :modeline-permission,
:modeline-active."
  (let ((icon-data (matisse--get-icon-data icon-type tool-name))
        (effective-mode (if (and matisse-modeline-use-emoji
                                 (memq icon-type '(:modeline-default :modeline-permission :modeline-active)))
                            'emoji
                          matisse-icons-mode)))
    (pcase effective-mode
      ('emoji
       (let ((icon (nth 0 icon-data)))
         ;; For modeline-active in emoji mode, alternate between active and default icons
         (when (eq icon-type :modeline-active)
           (setq icon (if (< (mod matisse--spinner-index 2) 1)
                          (nth 0 (matisse--get-icon-data :modeline-active))
                        (nth 0 (matisse--get-icon-data :modeline-default)))))
         (if (string-empty-p icon) "" (concat (matisse--apply-icon-face-properties icon) " "))))
      ('nerd-icons
       (let ((icon (nth 1 icon-data))
             (face (nth 2 icon-data)))
         ;; For modeline-active in nerd-icons mode, alternate between active and default icons
         (when (eq icon-type :modeline-active)
           (if (< (mod matisse--spinner-index 2) 1)
               (setq icon (nth 1 (matisse--get-icon-data :modeline-active))
                     face (nth 2 (matisse--get-icon-data :modeline-active)))
             (setq icon (nth 1 (matisse--get-icon-data :modeline-default))
                   face (nth 2 (matisse--get-icon-data :modeline-default)))))
         (if (string-empty-p icon) "" (concat (matisse--apply-icon-face-properties icon face) " "))))
      ('ascii
       (let ((text (nth 3 icon-data)))
         ;; For modeline-active in ascii mode, use spinner chars for animation
         (when (eq icon-type :modeline-active)
           (setq text (nth matisse--spinner-index matisse--spinner-chars)))
         (if (string-empty-p text) "" (concat text " "))))
      (_ ""))))

(defun matisse--format-progress-indicator (tool-name input-data)
  "Format a progress indicator for TOOL-NAME with INPUT-DATA."
  (when (and matisse-show-progress-indicators
             ;; Don't show progress for internal automatic tools
             (not (equal tool-name "ExitPlanMode")))
    (let* ((icon (matisse--get-icon :tool tool-name))
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
            (icon (matisse--get-icon :success)))
        (format "%sUpdated %s" icon (file-name-nondirectory file-path))))

     ;; Handle Write operations
     ((and (equal tool-name "Write")
           (string-match "file" result-content))
      (let ((icon (matisse--get-icon :success)))
        ;; [TODO] sometimes this prints when file writing has not completed
        (format "%sFile written successfully" icon)))

     ;; Generic success for file operations
     ((member tool-name '("Edit" "MultiEdit" "Write"))
      (let ((icon (matisse--get-icon :success)))
        (format "%sFile operation completed" icon))))))

(defun matisse--format-performance-summary (result-data)
  "Format a performance summary from RESULT-DATA."
  (when matisse-show-performance-summary
    (let* ((duration (alist-get 'duration_ms result-data))
           (cost (alist-get 'total_cost_usd result-data))
           (usage (alist-get 'usage result-data))
           (output-tokens (when usage (alist-get 'output_tokens usage)))
           (icon (matisse--get-icon :performance))
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

;;; Process & Protocol
;;;; Token Tracking
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

      ;; Check if we should suggest compaction (warn before auto-compact triggers)
      (when (>= matisse--tokens-since-compact (matisse--warning-threshold))
        (matisse--suggest-compaction))

      (matisse--debug-log "Tokens this turn: %d (total: %d, since compact: %d)"
                          total-this-turn
                          matisse--total-tokens-used
                          matisse--tokens-since-compact)

      ;; Update mode line to show new token count
      (matisse--update-mode-line))))

(defun matisse--suggest-compaction ()
  "Suggest compaction or inform about upcoming auto-compact."
  (when matisse--shell-context
    (funcall (plist-get matisse--shell-context :write-output)
             (if matisse-auto-compact-enabled
                 (format "\n⚠️  Context at %dk tokens (auto-compact at %dk threshold)...\n"
                        (/ matisse--tokens-since-compact 1000)
                        (/ (matisse--auto-compact-threshold) 1000))
               (format "\n⚠️  Context at %dk tokens. Consider /compact or enable auto-compact.\n"
                      (/ matisse--tokens-since-compact 1000)))))
  (message (if matisse-auto-compact-enabled
               (format "Context at %dk tokens (auto-compact at %dk threshold)"
                      (/ matisse--tokens-since-compact 1000)
                      (/ (matisse--auto-compact-threshold) 1000))
             "Context is getting long. Consider /compact or enable auto-compact")))

(defun matisse--reset-token-count ()
  "Reset the tokens-since-compact counter."
  (setq matisse--tokens-since-compact 0)
  ;; Update mode line to reflect the reset
  (force-mode-line-update))

(defun matisse--calculate-initial-tokens-from-log (session-id)
  "Calculate initial token count from conversation log for SESSION-ID.
Returns total tokens used, accounting for compactions.
Returns nil if log file cannot be found or parsed."
  (condition-case err
      (let* ((claude-dir (expand-file-name "~/.claude/projects"))
             (log-file nil)
             (tokens-from-compactions 0)
             (tokens-after-last-compact 0)
             (last-compact-line 0))

        ;; Find the log file by searching all project directories
        (when (file-directory-p claude-dir)
          (dolist (project-dir (directory-files claude-dir t "^[^.]"))
            (when (file-directory-p project-dir)
              (let ((candidate (expand-file-name (concat session-id ".jsonl") project-dir)))
                (when (file-exists-p candidate)
                  (setq log-file candidate))))))

        (if (not log-file)
            (progn
              (matisse--debug-log "Log file not found for session %s" session-id)
              nil)

          ;; Parse the log file
          (with-temp-buffer
            (insert-file-contents log-file)
            (goto-char (point-min))
            (let ((line-number 0))
              (while (not (eobp))
                (setq line-number (1+ line-number))
                (let ((line (buffer-substring-no-properties
                            (line-beginning-position)
                            (line-end-position))))
                  (unless (string-empty-p line)
                    (condition-case parse-err
                        (let* ((json-obj (json-parse-string line :object-type 'alist))
                               (type (alist-get 'type json-obj)))

                          ;; Check for compact_boundary messages
                          (when (and (equal type "system")
                                    (equal (alist-get 'subtype json-obj) "compact_boundary"))
                            (let* ((compact-metadata (alist-get 'compactMetadata json-obj))
                                   (pre-tokens (when compact-metadata
                                               (alist-get 'preTokens compact-metadata))))
                              (when pre-tokens
                                (setq tokens-from-compactions (+ tokens-from-compactions pre-tokens))
                                (setq last-compact-line line-number)
                                (setq tokens-after-last-compact 0)
                                (matisse--debug-log "Found compaction at line %d: %d tokens"
                                                   line-number pre-tokens))))

                          ;; Check for result messages (only count those after last compact)
                          (when (and (equal type "assistant")
                                    (> line-number last-compact-line))
                            (let* ((message (alist-get 'message json-obj))
                                   (usage (when message (alist-get 'usage message)))
                                   (input-tokens (when usage (alist-get 'input_tokens usage)))
                                   (output-tokens (when usage (alist-get 'output_tokens usage))))
                              (when (and input-tokens output-tokens)
                                (setq tokens-after-last-compact
                                     (+ tokens-after-last-compact input-tokens output-tokens))))))

                      (error
                       (matisse--debug-log "Error parsing line %d: %s" line-number
                                         (error-message-string parse-err))))))
                (forward-line 1))))

          ;; Return total tokens
          (let ((total-tokens (+ tokens-from-compactions tokens-after-last-compact)))
            (matisse--debug-log "Calculated initial tokens for session %s: %d (compactions: %d, after last compact: %d)"
                               session-id total-tokens tokens-from-compactions tokens-after-last-compact)
            total-tokens)))

    (error
     (matisse--debug-log "Error calculating initial tokens: %s" (error-message-string err))
     nil)))

;;;; Threshold Calculations (SDK-style)
(defun matisse--auto-compact-threshold ()
  "Calculate auto-compact threshold dynamically.
Returns: context_window - auto_compact_reserve.
Matches SDK's calculation: y11() - WD0 (context - 13000)."
  (- matisse-context-window matisse-auto-compact-reserve))

(defun matisse--warning-threshold ()
  "Calculate warning threshold dynamically.
Returns: context_window - warning_reserve.
Matches SDK's warning threshold calculation."
  (- matisse-context-window matisse-warning-reserve))

(defun matisse--estimate-tokens (text)
  "Estimate token count for TEXT using fast approximation.
Uses the same heuristic as Claude Code CLI (z7 function):
string length divided by 4.  This is a rough estimate but sufficient
for threshold checks.  Returns estimated token count as integer."
  (if (or (null text) (string-empty-p text))
      0
    (round (/ (length text) 4.0))))

(defun matisse--format-token-status ()
  "Format token usage for mode line display."
  (when (and matisse-show-token-usage (> matisse--tokens-since-compact 0))
    (let* ((tokens-k (/ matisse--tokens-since-compact 1000))
           (threshold (matisse--auto-compact-threshold))
           (percentage (if (> threshold 0)
                           (* 100.0 (/ (float matisse--tokens-since-compact)
                                      threshold))
                         0))
           (face (cond
                  ((>= percentage 90) '(:inherit error :weight bold))
                  ((>= percentage 70) 'warning)
                  ((>= percentage 50) 'warning)
                  (t 'shadow))))
      (propertize (format "[%dk]" tokens-k) 'face face))))

;;;; JSON Protocol
;; Buffer-local variable to store pending images

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

(defun matisse--is-slash-command-p (text)
  "Return non-nil if TEXT is a slash command."
  (and (stringp text)
       (numberp (string-match-p "^\\s-*/[a-zA-Z]+" text))))

(defun matisse--parse-slash-command (text)
  "Parse slash command TEXT into command and arguments.
Returns a plist with :command, :args, and :raw-args."
  (let* ((trimmed (string-trim text))
         (parts (split-string trimmed "\\s-+" t))
         (command (car parts))
         (args-text (when (cdr parts)
                      (string-join (cdr parts) " ")))
         (parsed-args (when args-text
                        (matisse--parse-command-arguments args-text))))
    (list :command command
          :args parsed-args
          :raw-args args-text)))

(defun matisse--tokenize-arguments (args-text)
  "Tokenize ARGS-TEXT, handling quoted strings properly.
Returns a list of tokens where quoted strings are kept as single tokens."
  (let ((tokens '())
        (i 0)
        (len (length args-text)))
    (while (< i len)
      ;; Skip whitespace
      (while (and (< i len) (= (aref args-text i) ?\s))
        (setq i (1+ i)))

      (when (< i len)
        (let ((start i)
              token)
          (cond
           ;; Quoted string
           ((= (aref args-text i) ?\")
            (setq i (1+ i)) ; skip opening quote
            (while (and (< i len) (not (= (aref args-text i) ?\")))
              (setq i (1+ i)))
            (setq token (substring args-text (1+ start) i))
            (when (< i len)
              (setq i (1+ i)))) ; skip closing quote

           ;; Regular token
           (t
            (while (and (< i len)
                       (not (= (aref args-text i) ?\s)))
              (setq i (1+ i)))
            (setq token (substring args-text start i))))

          (when token
            (push token tokens)))))
    (nreverse tokens)))

(defun matisse--parse-command-arguments (args-text)
  "Parse command-line style arguments from ARGS-TEXT.
Returns an alist of (option . value) pairs.
Handles quoted strings properly."
  (let ((args '())
        (tokens (matisse--tokenize-arguments args-text)))
    (while tokens
      (let ((token (car tokens)))
        (cond
         ;; Long option with potential value: --option [value]
         ((string-match "^--\\([a-zA-Z-]+\\)$" token)
          (let ((option (match-string 1 token))
                (next-token (cadr tokens)))
            (if (and next-token (not (string-prefix-p "-" next-token)))
                (progn
                  (push (cons option next-token) args)
                  (setq tokens (cddr tokens)))
              (push (cons option t) args)
              (setq tokens (cdr tokens)))))

         ;; Short option with potential value: -i [value]
         ((string-match "^-\\([a-zA-Z]\\)$" token)
          (let ((option (match-string 1 token))
                (next-token (cadr tokens)))
            (if (and next-token (not (string-prefix-p "-" next-token)))
                (progn
                  (push (cons option next-token) args)
                  (setq tokens (cddr tokens)))
              (push (cons option t) args)
              (setq tokens (cdr tokens)))))

         ;; Skip unrecognized tokens
         (t (setq tokens (cdr tokens))))))
    (nreverse args)))

(defun matisse--get-temp-file-directory ()
  "Get or create temp file directory for current session.
Returns directory path: ~/.claude/projects/<project>/.temp-files/<session-id>/"
  (let* ((project-dir (matisse--get-project-directory))
         (session-id (or matisse--conversation-id "pending"))
         (temp-dir (expand-file-name
                    (format ".temp-files/%s" session-id)
                    project-dir)))
    (unless (file-exists-p temp-dir)
      (make-directory temp-dir t))
    temp-dir))

(defun matisse--write-arg-to-temp-file (content)
  "Write CONTENT to a session-scoped temporary file and return the file path.
File is stored in ~/.claude/projects/<project>/.temp-files/<session-id>/ so it
persists for the session lifetime and works with resume.
The file path is tracked in `matisse--temp-files' for reference."
  (let* ((temp-dir (matisse--get-temp-file-directory))
         (temp-file (make-temp-file
                     (expand-file-name "arg-" temp-dir)
                     nil ".txt")))
    (with-temp-file temp-file
      (insert content))
    ;; Track for reference (not for immediate cleanup)
    (push temp-file matisse--temp-files)
    temp-file))

(defun matisse--maybe-convert-to-file-reference (text &optional prefix)
  "Convert TEXT to temp file reference if it exceeds threshold.
If TEXT is longer than `matisse-large-prompt-threshold', writes
it to a temp file and returns @ reference with optional PREFIX.
Otherwise returns TEXT unchanged."
  (if (and (stringp text) (> (length text) matisse-large-prompt-threshold))
      (let ((temp-file (matisse--write-arg-to-temp-file text)))
        (matisse--debug-log "Converted large text (%d chars) to temp file: %s" (length text) temp-file)
        (if prefix
            (format "%s @%s" prefix temp-file)
          (format "@%s" temp-file)))
    text))

(defun matisse--format-slash-command (text)
  "Format TEXT as a slash command for Claude Code.
Handles arguments for supported commands. Returns nil for locally
handled commands. Converts large arguments to temp files with @ references."
  (let* ((parsed (matisse--parse-slash-command text))
         (command (plist-get parsed :command))
         (args (plist-get parsed :args))
         (raw-args (plist-get parsed :raw-args)))

    (cond
     ;; Handle /compact with --instructions
     ((and (equal command "/compact")
           (assoc "instructions" args))
      (let ((instructions (cdr (assoc "instructions" args))))
        (format "Please compact our conversation history using these specific instructions: %s\n\nCompact the conversation while following these guidelines." instructions)))

     ;; Handle /clear command locally (return nil to prevent sending to Claude)
     ((equal command "/clear")
      nil)

     ;; Handle help commands locally (return nil to prevent sending to Claude)
     ((or (equal command "/help")
          (and args (assoc "help" args)))
      nil)

     ;; Default: check if raw args are too large
     (t
      (if raw-args
          (matisse--maybe-convert-to-file-reference raw-args command)
        (string-trim text))))))

(defun matisse--format-user-message (text)
  "Format TEXT as a JSON message for Claude Code.
If `matisse-send-selection-p' is non-nil and there's a last selection,
append it as context to the text.
If there are pending images, include them in the message content.
If TEXT is a slash command, format it as XML command structure.
Large non-slash text is converted to temp file references."
  (let* ((is-slash-command (matisse--is-slash-command-p text))
         (selection-context (unless is-slash-command
                              (matisse--format-selection-context)))
         (initial-text (cond
                        (is-slash-command
                         (let ((formatted (matisse--format-slash-command text)))
                           (if formatted
                               formatted
                             ;; Return special marker for locally handled commands
                             'locally-handled)))
                        (selection-context (concat text "\n\n" selection-context))
                        (t text)))
         ;; Handle large non-slash text by converting to temp file
         (final-text (if (and (stringp initial-text) (not is-slash-command))
                         (matisse--maybe-convert-to-file-reference initial-text)
                       initial-text))
         (content-blocks (list (list (cons 'type "text")
                                     (cons 'text final-text)))))

    ;; Handle locally processed commands
    (if (eq final-text 'locally-handled)
        (progn
          ;; Handle the command locally (e.g., show help)
          (matisse--handle-local-command text)
          ;; Return nil to prevent sending message to Claude
          nil)
      ;; Normal processing for non-local commands
      (progn
        ;; Track slash command for completion feedback
        (when is-slash-command
          (setq matisse--pending-slash-command (string-trim text)))

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
                       (content . ,(vconcat content-blocks))))))))))

(defun matisse--handle-local-command (text)
  "Handle locally processed slash commands like help.
TEXT is the raw slash command text to process."
  (let* ((parsed (matisse--parse-slash-command text))
         (command (plist-get parsed :command))
         (args (plist-get parsed :args)))
    (cond
     ;; Handle /clear command
     ((equal command "/clear")
      (matisse-clear))

     ;; Handle /help command
     ((equal command "/help")
      (matisse--show-help))

     ;; Handle --help argument for any command
     ((assoc "help" args)
      (matisse--show-command-help (substring command 1)))  ; Remove leading /

     ;; Default case
     (t (message "Unknown local command: %s" command)))))

(defun matisse--show-help ()
  "Show general help for slash commands."
  (message "Available commands: /compact [--instructions \"text\"], /cost, /clear, /context. Use --help for specific command help."))

(defun matisse--show-command-help (command)
  "Show help for a specific COMMAND."
  (let ((help-text (cond
                    ((equal command "compact")
                     "/compact [--instructions \"text\"] - Compact conversation history. Use --instructions to provide specific summarization guidance.")
                    (t
                     (format "No specific help available for command: %s" command)))))
    (message "%s" help-text)))

;;;; Slash Commands
(defun matisse--get-available-commands ()
  "Get list of available slash commands.
Returns dynamically discovered commands merged with local commands."
  (let ((local-commands '("/clear" "/help"))
        (discovered (if matisse--available-commands
                       (append matisse--available-commands nil)
                     (mapcar #'car matisse--slash-commands))))
    ;; Merge local commands with discovered commands, removing duplicates
    (delete-dups (append local-commands discovered))))

(defun matisse--in-input-region-p ()
  "Return non-nil if point is in the input region."
  (when-let* ((input-region (matisse--get-input-region)))
    (and (>= (point) (car input-region))
         (<= (point) (cdr input-region)))))

(defun matisse--slash-command-completion-at-point ()
  "Provide completion for slash commands, their arguments, and @ file references."
  (when (and (matisse--in-input-region-p)
             (derived-mode-p 'matisse-shell-mode))
    (let ((input-region (matisse--get-input-region)))
      (when input-region
        (let ((input-start (car input-region)))
          (save-excursion
            (cond
             ;; Complete @ file references
             ((looking-back "@[^ \t\n]*" input-start)
              (let ((end (point))
                    (start (save-excursion
                             (re-search-backward "@" input-start t)
                             (1+ (point))))) ; Skip the @ character
                (list start end
                      #'read-file-name-internal
                      :exclusive nil
                      :annotation-function (lambda (_) " — file reference"))))

             ;; Complete slash commands at beginning of line or after whitespace
             ((looking-back "/[a-zA-Z-]*" input-start)
              ;; Find the actual start of the slash command
              (let ((end (point))
                    (start (save-excursion
                             (re-search-backward "/" input-start t)
                             (point))))
                (list start end
                      (matisse--get-available-commands)
                      :exclusive nil
                      :annotation-function #'matisse--slash-command-annotation)))

             ;; Complete /compact options
             ((looking-back "/compact\\s-+--[a-zA-Z-]*" input-start)
              (let ((start (save-excursion
                             (re-search-backward "--[a-zA-Z-]*" input-start)
                             (point)))
                    (end (point)))
                (list start end
                      (mapcar #'car matisse--compact-options)
                      :exclusive nil
                      :annotation-function #'matisse--compact-option-annotation))))))))))

(defun matisse--slash-command-annotation (command)
  "Return annotation for slash COMMAND."
  (when-let* ((desc (cdr (assoc command matisse--slash-commands))))
    (concat " — " desc)))

(defun matisse--compact-option-annotation (option)
  "Return annotation for compact OPTION."
  (when-let* ((desc (cdr (assoc option matisse--compact-options))))
    (concat " — " desc)))

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

(defun matisse--truncate-text (text max-length)
  "Truncate TEXT to MAX-LENGTH characters if needed.
Returns original text if shorter than MAX-LENGTH or if MAX-LENGTH is nil.
Adds ellipsis and character count indicator for truncated text."
  (if (and max-length (> (length text) max-length))
      (let ((num-lines (1+ (cl-count ?\n text))))
        (format "%s\n... [%d more characters, %d total lines]"
                (substring text 0 max-length)
                (- (length text) max-length)
                num-lines))
    text))

(defun matisse--debug-log (_format-str &rest args)
  "Log debug message to buffer if debugging is enabled.
FORMAT-STR is the format string for the message.
ARGS are the arguments for the format string.
Long arguments are truncated to `matisse-debug-log-max-length'."
  (when matisse-debug
    (let ((truncated-args
           (mapcar (lambda (arg)
                     (if (and (stringp arg) (> (length arg) matisse-debug-log-max-length))
                         (format "%s... [%d more chars]"
                                 (substring arg 0 matisse-debug-log-max-length)
                                 (- (length arg) matisse-debug-log-max-length))
                       arg))
                   args)))
      (message "%S" truncated-args))))

(defun matisse--handle-system-message (json-obj)
  "Handle system messages including compact_boundary and other subtypes.
JSON-OBJ is the parsed JSON system message object from Claude Code."
  (let ((subtype (alist-get 'subtype json-obj))
        (content (alist-get 'content json-obj)))
    (matisse--debug-log "Handling system message subtype: %s" subtype)
    (cond
     ((equal subtype "init")
      (setq matisse--conversation-id (alist-get 'session_id json-obj))
      (matisse--debug-log "Set conversation ID: %s" matisse--conversation-id)

      ;; Calculate initial tokens for resumed sessions
      (when matisse--resumed-session
        (let ((initial-tokens (matisse--calculate-initial-tokens-from-log matisse--conversation-id)))
          (when initial-tokens
            (setq matisse--total-tokens-used initial-tokens)
            (setq matisse--tokens-since-compact initial-tokens)
            (message "Resumed session with %d tokens used" initial-tokens))))

      ;; Extract slash commands from init message
      ;; slash_commands is a vector of strings without "/" prefix
      (let ((slash-commands (alist-get 'slash_commands json-obj)))
        (when slash-commands
          ;; Add "/" prefix to each command for consistency with completion system
          (setq matisse--available-commands
                (mapcar (lambda (cmd) (concat "/" cmd))
                        (append slash-commands nil)))))
      ;; Immediately request full commands list for more detailed info
      ;; Note: get_commands response may also include models
      (matisse--debug-log "Requesting commands after init")
      (let ((commands-sent (matisse--send-control-request "get_commands")))
        (matisse--debug-log "Commands request sent: %s" commands-sent)))

     ((equal subtype "compact_boundary")
      (let ((compact-metadata (alist-get 'compactMetadata json-obj)))
        (message "Conversation compacted: %s" content)
        (when compact-metadata
          (let ((pre-tokens (alist-get 'preTokens compact-metadata))
                (trigger (alist-get 'trigger compact-metadata)))
            (matisse--debug-log "Compact metadata - trigger: %s, preTokens: %s" trigger pre-tokens)
            (when pre-tokens
              (message "Tokens before compaction: %d" pre-tokens))))
        ;; Reset token count after successful compaction
        (matisse--reset-token-count)

        ;; Clear auto-compact flag - existing queue will automatically process next
        (when matisse--auto-compact-in-progress
          (setq matisse--auto-compact-in-progress nil))))

     (t
      (matisse--debug-log "Unknown system message subtype: %s, content: %s" subtype content)
      (when content
        (message "System: %s" content))))))

(defun matisse--handle-control-request (process request)
  "Handle control request from Claude Code.
PROCESS is the Claude Code process.
REQUEST is the parsed JSON control request."
  (let* ((request-id (alist-get 'request_id request))
         (request-data (alist-get 'request request))
         (subtype (alist-get 'subtype request-data)))

    (matisse--debug-log "Handling control request: %s (%s)" subtype request-id)

    (cond
     ;; Handle permission requests
     ((equal subtype "can_use_tool")
      (matisse--handle-can-use-tool-request process request-id request-data))

     ;; Ignore echoed get_commands request
     ;; This is a request WE sent that Claude is echoing back
     ((equal subtype "get_commands")
      (matisse--debug-log "Ignoring echoed control request: %s" subtype))

     ;; Unknown request type
     (t
      (matisse--debug-log "Unknown control request subtype: %s" subtype)
      (matisse--send-control-error process request-id
                                   (format "Unknown control request subtype: %s" subtype))))))

(defun matisse--handle-can-use-tool-request (process request-id request-data)
  "Handle can_use_tool control request.
PROCESS is the Claude Code process.
REQUEST-ID is the request identifier.
REQUEST-DATA contains tool_name, input, and permission_suggestions."
  (let* ((tool-name (alist-get 'tool_name request-data))
         (tool-input (alist-get 'input request-data))
         (suggestions (alist-get 'permission_suggestions request-data))
         (buffer-name (buffer-name)))

    (matisse--debug-log "STDIO PERMISSION: Received can_use_tool request for %s (id=%s)"
                        tool-name request-id)
    (matisse--debug-log "STDIO PERMISSION: Current mode=%s, auto-allow-flag=%s"
                        (or matisse--current-permission-mode matisse-permission-mode)
                        matisse--auto-allow-next-write-tool)

    ;; First check if tool should be auto-allowed (bypass mode or read-only tools)
    (if (matisse--should-auto-allow-tool tool-name)
        (progn
          (matisse--debug-log "STDIO PERMISSION: Auto-allowing %s" tool-name)
          ;; Auto-allowed - send response immediately without pending permission updates
          ;; (pending updates only apply to user-prompted permission decisions)
          (matisse--send-control-response process request-id
                                          `((behavior . "allow")
                                            (updatedInput . ,tool-input)))
          ;; Clear the auto-allow flag after use (if it was set for first edit after plan approval)
          (when matisse--auto-allow-next-write-tool
            (matisse--debug-log "STDIO PERMISSION: Clearing auto-allow flag after first edit")
            (setq matisse--auto-allow-next-write-tool nil)))

      ;; Not auto-allowed - prompt user based on mode
      (if matisse-in-buffer-permission-prompts
          ;; In-buffer permission flow
          (matisse--prompt-permission-in-buffer process request-id tool-name tool-input suggestions)

        ;; Minibuffer flow
        (let* ((result (matisse--decide-tool-permission-with-suggestions
                        tool-name tool-input suggestions buffer-name))
               (decision (car result))
               (updated-permissions (cdr result)))

          ;; Send response back to Claude Code with proper structure
          (if (string= decision "allow")
              ;; Allow: need behavior + updatedInput + optional updatedPermissions
              (let ((response `((behavior . "allow")
                               (updatedInput . ,tool-input))))
                ;; Include updatedPermissions from user's "always" choice
                (when updated-permissions
                  (setq response (append response `((updatedPermissions . ,updated-permissions)))))
                ;; Also include pending permission mode update if user cycled mode
                (when matisse--pending-permission-update
                  (setq response (append response
                                        `((updatedPermissions . ((permissionMode . ,matisse--pending-permission-update))))))
                  (setq matisse--pending-permission-update nil))
                (matisse--send-control-response process request-id response))
            ;; Deny: need behavior + message + interrupt
            (matisse--send-control-response process request-id
                                            `((behavior . "deny")
                                              (message . "User denied permission")
                                              (interrupt . t)))
            ;; CRITICAL: Clear waiting state and stop spinner immediately on denial
            ;; Don't wait for Claude's "result" message - it might never arrive
            (setq matisse--waiting-for-response nil)
            (matisse--stop-spinner)))))))

(defun matisse--send-control-response (process request-id response-data)
  "Send control response to Claude Code.
PROCESS is the Claude Code process.
REQUEST-ID is the original request identifier.
RESPONSE-DATA is the response payload."
  (let ((response-message
         `((type . "control_response")
           (response . ((subtype . "success")
                        (request_id . ,request-id)
                        (response . ,response-data))))))

    ;; Send JSON response with newline delimiter
    (let ((json-string (json-encode response-message)))
      (process-send-string process (concat json-string "\n")))))

(defun matisse--send-control-error (process request-id error-message)
  "Send control error response to Claude Code.
PROCESS is the Claude Code process.
REQUEST-ID is the original request identifier.
ERROR-MESSAGE describes the error."
  (let ((error-response
         `((type . "control_response")
           (response . ((subtype . "error")
                        (request_id . ,request-id)
                        (error . ,error-message))))))

    (process-send-string process
                         (concat (json-encode error-response) "\n"))))

(defun matisse--handle-control-response (json-obj)
  "Handle control response from Claude Code.
JSON-OBJ contains the response data including available commands/models."
  (let* ((response (alist-get 'response json-obj))
         (subtype (alist-get 'subtype response)))
    (matisse--debug-log "Control response subtype: %s" subtype)
    (cond
     ((equal subtype "success")
      ;; Commands and models are nested in response.response
      (let* ((response-data (alist-get 'response response))
             (commands (alist-get 'commands response-data))
             (models (alist-get 'models response-data)))
        (when commands
          ;; Extract command names from command objects and add "/" prefix
          (setq matisse--available-commands
                (mapcar (lambda (cmd)
                          (let ((name (alist-get 'name cmd)))
                            (if (string-prefix-p "/" name)
                                name
                              (concat "/" name))))
                        (append commands nil)))
          (matisse--debug-log "Discovered %d commands: %s"
                             (length matisse--available-commands)
                             matisse--available-commands))
        (when models
          (setq matisse--available-models models)
          (matisse--debug-log "Discovered %d models: %s"
                             (length models) models))))
     ((equal subtype "error")
      (let ((error-msg (alist-get 'error response))
            (request-id (alist-get 'request_id json-obj)))
        (message "Matisse: Control response error (request_id: %s): %s" request-id error-msg)
        (matisse--debug-log "Control response error (request_id: %s): %s" request-id error-msg)
        (matisse--debug-log "Full error response: %s" json-obj))))))

(defun matisse--handle-jsonrpc-notification (json-obj)
  "Handle JSON-RPC style notifications from Claude Code.
JSON-OBJ contains the notification with \\='method and \\='params fields."
  (let ((method (alist-get 'method json-obj))
        (params (alist-get 'params json-obj)))
    (matisse--debug-log "JSON-RPC notification method: %s" method)
    (cond
     ((equal method "session/update")
      (matisse--handle-session-update params))
     (t
      (matisse--debug-log "Unhandled JSON-RPC method: %s" method)))))

(defun matisse--handle-session-update (params)
  "Handle session update notification.
PARAMS contains sessionId and update fields."
  (let* ((update (alist-get 'update params))
         (session-update (alist-get 'sessionUpdate update)))
    (matisse--debug-log "Session update type: %s" session-update)
    (cond
     ((equal session-update "available_commands_update")
      (let ((commands (alist-get 'availableCommands update)))
        (when commands
          ;; Extract command names and add "/" prefix
          (setq matisse--available-commands
                (mapcar (lambda (cmd)
                          (let ((name (alist-get 'name cmd)))
                            (if (string-prefix-p "/" name)
                                name
                              (concat "/" name))))
                        (append commands nil)))
          (matisse--debug-log "Discovered %d commands: %s"
                             (length matisse--available-commands)
                             matisse--available-commands))))
     (t
      (matisse--debug-log "Unhandled session update type: %s" session-update)))))

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
                 ;; Handle JSON-RPC style notifications (e.g., session/update)
                 ((alist-get 'method json-obj)
                  (matisse--handle-jsonrpc-notification json-obj))

                 ((equal (alist-get 'type json-obj) "control_request")
                  (matisse--handle-control-request process json-obj))

                 ((equal (alist-get 'type json-obj) "control_response")
                  (matisse--handle-control-response json-obj))

                 ((equal (alist-get 'type json-obj) "system")
                  (matisse--handle-system-message json-obj))

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
                                (funcall (plist-get matisse--shell-context :write-output)
                                         progress-msg)
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

                  ;; Track token usage, but skip for /clear and /compact
                  (let ((skip-token-tracking nil))
                    ;; Show completion message for slash commands
                    (when matisse--pending-slash-command
                      (matisse--debug-log "Processing slash command completion: %s" matisse--pending-slash-command)
                      (let ((command matisse--pending-slash-command))
                        (setq matisse--pending-slash-command nil)
                        (cond
                         ((equal command "/clear")
                          (matisse--debug-log "Handling /clear completion")
                          (when (and matisse--shell-context
                                     (plist-get matisse--shell-context :write-output))
                            (condition-case err
                                (progn
                                  (matisse--debug-log "Calling write-output for clear completion")
                                  (funcall (plist-get matisse--shell-context :write-output)
                                           (concat (matisse--get-icon :command) "Conversation cleared")))
                              (error (matisse--debug-log "Error writing clear completion: %s" (error-message-string err)))))
                          ;; Reset token count after successful clear
                          (matisse--debug-log "Resetting token count after clear")
                          (matisse--reset-token-count)
                          (setq skip-token-tracking t))

                         ((equal command "/compact")
                          ;; Reset token count after successful compact
                          (matisse--debug-log "Resetting token count after compact")
                          (matisse--reset-token-count)
                          (setq skip-token-tracking t)
                          ;; Don't show message for compact - it has its own system message handling
                          nil)

                         ;; For other slash commands, show generic completion
                         ((string-match-p "^/" command)
                          (when (and matisse--shell-context
                                     (plist-get matisse--shell-context :write-output))
                            (condition-case err
                                (let ((truncated-command (matisse--truncate-text command matisse-max-progress-message-length)))
                                  (funcall (plist-get matisse--shell-context :write-output)
                                           (format "%sCommand completed: %s" (matisse--get-icon :command) truncated-command)))
                              (error (matisse--debug-log "Error writing command completion: %s" (error-message-string err)))))))))

                    ;; Track token usage (skip for /clear and /compact since we just reset the counter)
                    (unless skip-token-tracking
                      (matisse--track-tokens json-obj)))
                  ;; Show performance summary if enabled
                  (let ((perf-summary (matisse--format-performance-summary json-obj)))
                    (when (and perf-summary
                               matisse--shell-context
                               (plist-get matisse--shell-context :write-output))
                      (condition-case err
                          (funcall (plist-get matisse--shell-context :write-output)
                                   perf-summary)
                        (error (matisse--debug-log "Error writing performance summary: %s" (error-message-string err))))))
                  ;; Apply markdown overlays to the response (incremental for performance)
                  (condition-case err
                      (matisse--overlays-put t)  ; incremental=t to avoid rescanning entire buffer
                    (error (matisse--debug-log "Error applying markdown overlays: %s" (error-message-string err))))
                  ;; Clear active tools and reset state
                  (setq matisse--active-tools nil)
                  ;; Finish the current shell command before processing next
                  (when (and matisse--shell-context
                             (plist-get matisse--shell-context :finish-output))
                    (condition-case err
                        ;; Call the finish function (will be unified version if using new queue)
                        (funcall (plist-get matisse--shell-context :finish-output))
                      (error (matisse--debug-log "Error finishing output: %s" (error-message-string err)))))
                  ;; Signal matisse-shell that response is complete
                  (when (fboundp 'matisse-shell--signal-response-complete)
                    (condition-case err
                        (matisse-shell--signal-response-complete)
                      (error (matisse--debug-log "Error signaling response complete: %s" (error-message-string err)))))
                  ;; Now finish current message and process next
                  (matisse--finish-current-message)) ;; END COND CLAUSE 3

                 ((equal (alist-get 'type json-obj) "user")
                  ;; Handle user messages that contain command output or tool results
                  (let* ((message (alist-get 'message json-obj))
                         (content (and message (alist-get 'content message))))

                    ;; Check for tool_result in vector content
                    (when (vectorp content)
                      (let ((tool-result (matisse--extract-tool-result json-obj)))
                        (when tool-result
                          (let* ((tool-use-id (alist-get 'tool_use_id tool-result))
                                 ;; Find the matching tool from active-tools
                                 (tool-info (seq-find (lambda (tool)
                                                       (equal (alist-get 'id tool) tool-use-id))
                                                     matisse--active-tools)))
                            (when tool-info
                              (let ((tool-name (alist-get 'name tool-info))
                                    (tool-input (alist-get 'input tool-info)))
                                ;; For Edit tools, display the diff
                                (when (and (equal tool-name "Edit")
                                          matisse-show-file-changes
                                          matisse--shell-context
                                          (plist-get matisse--shell-context :write-output))
                                  (let* ((file-path (alist-get 'file_path tool-input))
                                         (old-string (alist-get 'old_string tool-input))
                                         (new-string (alist-get 'new_string tool-input))
                                         (diff-text (matisse--create-edit-diff file-path old-string new-string))
                                         (formatted-diff (format "\n%s\n" diff-text)))
                                    (condition-case err
                                        (funcall (plist-get matisse--shell-context :write-output)
                                                formatted-diff)
                                      (error (matisse--debug-log "Error writing diff: %s" (error-message-string err))))))
                                ;; Remove completed tool from active-tools
                                (setq matisse--active-tools
                                      (seq-remove (lambda (tool)
                                                   (equal (alist-get 'id tool) tool-use-id))
                                                 matisse--active-tools))))))))

                    (when (stringp content)
                      (cond
                       ;; Handle local command stdout/stderr
                       ((string-match-p "<local-command-std\\(out\\|err\\)>" content)
                        (let ((output (replace-regexp-in-string "<local-command-std\\(out\\|err\\)>\\(.*\\)</local-command-std\\(out\\|err\\)>" "\\2" content)))
                          (when (and (not (string-empty-p output))
                                     matisse--shell-context
                                     (plist-get matisse--shell-context :write-output))
                            (condition-case err
                                (let ((formatted-output (format "%s%s" (matisse--get-icon :command) (string-trim output))))
                                  (funcall (plist-get matisse--shell-context :write-output)
                                           formatted-output))
                              (error (matisse--debug-log "Error writing command output: %s" (error-message-string err)))))))

                       ;; Log other user message content for debugging
                       (t
                        (matisse--debug-log "User message content: %s" content))))))

                 (t
                  (matisse--debug-log "Unhandled message type: %s" (alist-get 'type json-obj))))))))))))

(defun matisse--send-control-request (subtype &optional extra-params)
  "Send a control request to Claude with SUBTYPE and EXTRA-PARAMS.
EXTRA-PARAMS should be an alist of additional parameters for the request."
  (when (and matisse--process (process-live-p matisse--process))
    (let* ((request-id (format "%d" (random 1000000000)))
           (request-data (append `((subtype . ,subtype)) extra-params))
           (control-request `((type . "control_request")
                             (request_id . ,request-id)
                             (request . ,request-data)))
           (json-string (json-encode control-request)))
      (matisse--debug-log "Sending control request: %s" json-string)
      (process-send-string matisse--process (concat json-string "\n"))
      t)))

(defun matisse-interrupt ()
  "Send soft interrupt to Claude without killing the process.
This tells Claude to stop the current operation but keeps the process alive,
allowing you to immediately send new messages without restarting.

If a message is currently being processed, marks it as cancelled in the queue.
Also pauses automatic queue processing until you send a new message.

Works globally - finds the appropriate matisse buffer if not already in one."
  (interactive)
  (if-let* ((target-buffer (matisse--get-target-buffer-or-current)))
      (with-current-buffer target-buffer
        (if (and matisse--process (process-live-p matisse--process))
      (progn
        ;; Stop UI indicators
        (matisse--stop-spinner)

        ;; Mark current message as cancelled if exists
        (when (and (boundp 'matisse--current-message-id)
                   matisse--current-message-id
                   (boundp 'matisse--message-queue))
          (when-let* ((msg (cl-find-if (lambda (m)
                                         (= (plist-get m :id) matisse--current-message-id))
                                       matisse--message-queue)))
            (plist-put msg :status 'cancelled)))

        ;; Pause automatic queue processing
        (setq matisse--queue-paused t)

        ;; Reset state variables
        (setq matisse--waiting-for-response nil
              matisse--active-tools nil
              matisse--current-message-id nil)

        ;; Send the interrupt control request
        (matisse--send-control-request "interrupt")

        ;; Count pending messages for user feedback
        (let ((pending-count (length (cl-remove-if-not
                                      (lambda (msg)
                                        (eq (plist-get msg :status) 'pending))
                                      matisse--message-queue))))
          (if (> pending-count 0)
              (message "Interrupted Claude (%d message%s paused)"
                       pending-count
                       (if (= pending-count 1) "" "s"))
            (message "Interrupted Claude"))))
    (message "No active Claude process to interrupt")))
    (user-error "No matisse session found")))

(defun matisse--graceful-shutdown ()
  "Gracefully shut down the Claude process with signal escalation.
Sends SIGINT, then SIGTERM after 2s, then SIGKILL after 3s total.
Stores session ID for potential future resume."
  (when (and matisse--process (process-live-p matisse--process))
    ;; Store session ID for potential resume
    (when matisse--conversation-id
      (setq matisse--interrupted-session-id matisse--conversation-id))

    ;; Store active tools for potential cleanup notification
    (when matisse--active-tools
      (setq matisse--interrupted-tools (copy-sequence matisse--active-tools)))

    ;; Stop UI indicators
    (matisse--stop-spinner)

    ;; Reset state variables
    (setq matisse--waiting-for-response nil
          matisse--active-tools nil)

    ;; Close stdin gracefully
    (ignore-errors
      (process-send-eof matisse--process))

    ;; Send SIGINT (Ctrl+C) for graceful interruption
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
                 matisse--process)))

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
      ;; No session to resume - start fresh process
      (progn
        (message "Ready for new conversation.")
        ;; Start a new process without resume flag
        (matisse--create-process-with-options nil nil)))))

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

(defun matisse--create-process-with-options (&optional resume-session-id continue-flag options)
  "Create Claude Code process with optional args.
RESUME-SESSION-ID: Session ID to resume.
CONTINUE-FLAG: Continue from last conversation.
OPTIONS: Plist with :model, :permission-mode, :allowed-tools,
:disallowed-tools, :add-dirs, :system-prompt, :setting-sources, :verbose.
Returns the created process object."
  ;; Clean up any existing process, whether alive or dead
  (when matisse--process
    (when (process-live-p matisse--process)
      (delete-process matisse--process))
    ;; Clear the reference even if process is dead
    (setq matisse--process nil))

  ;; Set resumed flag if continuing or resuming a session
  (when (or resume-session-id continue-flag)
    (setq matisse--resumed-session t))

  (let* ((api-key (matisse--get-api-key))
         (process-environment (cons (format "ANTHROPIC_API_KEY=%s" api-key)
                                    (cons (format "MATISSE_BUFFER_NAME=%s" (buffer-name))
                                          process-environment)))
         ;; Use permission mode from options, shell context, or default
         (current-permission-mode (or (plist-get options :permission-mode)
                                     matisse--current-permission-mode
                                     matisse-permission-mode))
         (cmd (list matisse-claude-code-path
                    "--permission-mode" current-permission-mode
                    "--permission-prompt-tool" "stdio"
                    "--input-format" "stream-json"
                    "--output-format" "stream-json")))

    ;; Add continue flag if requested
    (when continue-flag
      (setq cmd (append cmd (list "--continue"))))

    ;; Add resume flag if session ID provided
    (when resume-session-id
      (setq cmd (append cmd (list "--resume" resume-session-id))))

    ;; Add verbose flag (required for stream-json format)
    (setq cmd (append cmd (list "--verbose")))

    ;; Add model (from options or current model)
    (let ((model (or (plist-get options :model) (matisse--get-current-model))))
      (when model
        (setq cmd (append cmd (list "--model" model)))))

    ;; Add temperature and max-tokens (from customization)
    (when matisse-temperature
      (setq cmd (append cmd (list "--temperature"
                                  (number-to-string matisse-temperature)))))
    (when matisse-max-tokens
      (setq cmd (append cmd (list "--max-tokens"
                                  (number-to-string matisse-max-tokens)))))

    ;; Add allowed tools (from options or customization)
    (let ((allowed-tools (or (plist-get options :allowed-tools) matisse-allowed-tools)))
      (when allowed-tools
        (setq cmd (append cmd (list "--allowedTools" allowed-tools)))))

    ;; Add disallowed tools (new feature from options)
    (when-let* ((disallowed-tools (plist-get options :disallowed-tools)))
      (setq cmd (append cmd (list "--disallowedTools" disallowed-tools))))

    ;; Add additional directories (new feature from options)
    (when-let* ((add-dirs (plist-get options :add-dirs)))
      (dolist (dir add-dirs)
        (setq cmd (append cmd (list "--add-dir" dir)))))

    ;; Add setting sources (from options or customization)
    (let ((setting-sources (or (plist-get options :setting-sources) matisse-setting-sources)))
      (when setting-sources
        (setq cmd (append cmd (list "--setting-sources" setting-sources)))))

    ;; Add system prompt (from options or aggressive subagent prompt)
    (let ((system-prompt (or (plist-get options :system-prompt)
                            (when (and matisse-aggressive-subagent-prompt
                                      (not (string-empty-p matisse-aggressive-subagent-prompt)))
                              matisse-aggressive-subagent-prompt))))
      (when system-prompt
        (setq cmd (append cmd (list "--append-system-prompt" system-prompt)))))

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

    ;; Claude Code CLI auto-initializes on startup and sends init message
    ;; Models and commands will be requested when we receive the init message
    ;; Set permission mode if needed (must wait for init)
    (unless (string= current-permission-mode "default")
      (let ((process matisse--process)
            (buffer (current-buffer))
            (desired-mode current-permission-mode))
        (run-at-time 0.2 nil
                     (lambda ()
                       (when (and process (process-live-p process))
                         (with-current-buffer buffer
                           (matisse--send-control-request "set_permission_mode"
                                                         `((mode . ,desired-mode)))
                           (matisse--debug-log "Set initial permission mode to: %s" desired-mode)))))))

    matisse--process))

(defun matisse--start-process-with-resume (session-id)
  "Start the Claude Code process with SESSION-ID for resuming."
  (matisse--create-process-with-options session-id nil))

;;;; Process Management
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
                matisse--active-tools nil
                matisse--process nil))

         ;; Process was killed/terminated (likely interrupted)
         ((or (string-match "killed" event)
              (string-match "terminated" event))
          (matisse--stop-spinner)
          (setq matisse--waiting-for-response nil
                matisse--process nil))

         ;; Abnormal exit
         ((string-match "exited abnormally" event)
          (matisse--stop-spinner)
          (setq matisse--waiting-for-response nil
                matisse--process nil)
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
                                 (concat (substring error-output 0 197) "[…]")
                               error-output)))
                  ;; Always log to debug
                  (matisse--debug-log "Claude Code stderr: %s" error-output)
                  ;; TODO add to a matisse stderr buffer because debugging might be turned off
                  )))
            ;; Notify the shell that the command failed if there was a critical error
            (when (and found-critical-error
                       matisse--shell-context
                       (plist-get matisse--shell-context :finish-output))
              (funcall (plist-get matisse--shell-context :finish-output)))))

         ;; Other events
         (t
          (matisse--debug-log "Unhandled process event: %s" event)))))))

(defun matisse--start-process ()
  "Start the Claude Code process with streaming JSON.
Uses options from `matisse--shell-context' if available."
  (let* ((continue-flag (when matisse--shell-context
                         (plist-get matisse--shell-context :continue)))
         (resume-id (when matisse--shell-context
                     (plist-get matisse--shell-context :resume)))
         (options (when matisse--shell-context
                   (list :model (plist-get matisse--shell-context :model)
                         :permission-mode (plist-get matisse--shell-context :permission-mode)
                         :allowed-tools (plist-get matisse--shell-context :allowed-tools)
                         :disallowed-tools (plist-get matisse--shell-context :disallowed-tools)
                         :add-dirs (plist-get matisse--shell-context :add-dirs)
                         :system-prompt (plist-get matisse--shell-context :system-prompt)
                         :setting-sources (plist-get matisse--shell-context :setting-sources)
                         :verbose (plist-get matisse--shell-context :verbose)))))
    (matisse--create-process-with-options resume-id continue-flag options)))

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

(defun matisse--send-string-chunked (process string)
  "Send STRING to PROCESS in chunks to avoid pipe buffer blocking.
Sends data in chunks of `matisse-chunk-size' bytes, calling
`accept-process-output' between chunks to allow the subprocess
to read data and prevent pipe buffer from filling up."
  (let ((chunk-size matisse-chunk-size)
        (offset 0)
        (total-length (length string)))
    (while (< offset total-length)
      (let* ((end (min (+ offset chunk-size) total-length))
             (chunk (substring string offset end)))
        (matisse--debug-log "Sending chunk %d-%d of %d bytes" offset end total-length)
        (process-send-string process chunk)
        (setq offset end)
        ;; Allow subprocess to read before sending more (non-blocking check)
        (when (< offset total-length)
          (accept-process-output process 0 10))))))  ; 0 sec + 10 millisec = non-blocking

(defun matisse--send-message-internal (text)
  "Internal function to format and send TEXT message to Claude Code process.
Checks for auto-compact before sending (matches SDK's pre-API-call check)."
  ;; Auto-compact check BEFORE sending (like SDK does before API call)
  (if (and matisse-auto-compact-enabled
           (>= matisse--tokens-since-compact (matisse--auto-compact-threshold))
           (not (string-prefix-p "/" text))
           (not matisse--auto-compact-in-progress))
      ;; Trigger auto-compact instead of sending
      (progn
        (matisse--debug-log "Auto-compact threshold reached (%d >= %d), triggering before send"
                            matisse--tokens-since-compact
                            (matisse--auto-compact-threshold))
        (setq matisse--auto-compact-in-progress t)
        (when matisse--shell-context
          (funcall (plist-get matisse--shell-context :write-output)
                   (format "\n%sAuto-compacting conversation (threshold reached)...\n"
                           (matisse--get-icon :auto-compact))))
        ;; Send /compact first
        (let ((json-msg (matisse--format-user-message "/compact")))
          (when json-msg
            (process-send-string matisse--process (concat json-msg "\n"))))
        ;; Re-enqueue original message to send AFTER compact completes
        (matisse--enqueue-message text))

    ;; Normal send path
    (condition-case err
        (progn
          ;; Ensure process is still alive
          (unless (and matisse--process (process-live-p matisse--process))
            (matisse--start-process))

          (let ((json-msg (matisse--format-user-message text)))
            (if json-msg
                (progn
                  (matisse--debug-log "Sending JSON: %s" json-msg)
                  (matisse--debug-log "Process alive before send: %s" (process-live-p matisse--process))
                (let ((full-msg (concat json-msg "\n")))
                  (if (> (length full-msg) matisse-chunk-threshold)
                      (progn
                        (matisse--debug-log "Using chunked sending for large message (%d bytes)" (length full-msg))
                        (matisse--send-string-chunked matisse--process full-msg))
                    (process-send-string matisse--process full-msg)))
                  (matisse--debug-log "Process alive after send: %s" (process-live-p matisse--process)))
              ;; json-msg is nil, meaning command was handled locally
              (matisse--debug-log "Command handled locally, not sending to Claude"))))
      (error
       ;; Stop the spinner and reset state
       (matisse--stop-spinner)
       (setq matisse--waiting-for-response nil
             matisse--pending-message nil)
       ;; Display error message in echo area
       (message "Matisse error: %s" (error-message-string err))
       (matisse--debug-log "Error in matisse--send-message-internal: %s" (error-message-string err))))))

(defun matisse--send-compact-command ()
  "Send /compact command directly without auto-compact check."
  ;; Send /compact directly, bypassing auto-compact logic
  (condition-case err
      (progn
        (unless (and matisse--process (process-live-p matisse--process))
          (matisse--start-process))
        (let ((json-msg (matisse--format-user-message "/compact")))
          (when json-msg
            (process-send-string matisse--process (concat json-msg "\n")))))
    (error
     (matisse--debug-log "Error sending compact command: %s" (error-message-string err)))))

(defun matisse--send-message-async (text)
  "Asynchronously format and send TEXT message to Claude Code process."
  ;; Just send directly - existing queue system handles queueing when busy
  ;; Token tracking happens when we receive the API response (matisse--process-result-message)
  (matisse--send-message-internal text))

;;;; Selection Tracking
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
           ;; Use save-restriction + widen to get line numbers relative to full file
           ;; not narrowed region
           (start-line (save-restriction
                         (widen)
                         (line-number-at-pos start-pos)))
           (end-line (save-restriction
                       (widen)
                       (line-number-at-pos end-pos)))
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
Called from `post-command-hook' to update the last selection.
Clears selection context when in buffers without files (e.g., *scratch*),
but preserves it when in matisse shell buffers."
  (cond
   ;; In matisse shell buffer - preserve existing selection context
   ((derived-mode-p 'matisse-shell-mode)
    nil) ; Do nothing, keep matisse--last-selection

   ;; In buffer with file - track selection
   ((and matisse-send-selection-p buffer-file-name)
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
                                (matisse--update-mode-line)))))))

   ;; In buffer without file (e.g., *scratch*) - clear selection context
   ((and matisse-send-selection-p (not buffer-file-name))
    (setq matisse--last-selection nil)
    (matisse--update-mode-line))))

(defun matisse--format-selection-context ()
  "Format the last selection with file path and actual text content.
Does NOT use @ file reference syntax to avoid triggering full file reads.
Instead, sends the file path, line range, and selected text directly.
This matches the behavior of monet.el and claude-code-ide.el, which send
selection content rather than file references to avoid token bloat."
  (when (and matisse-send-selection-p matisse--last-selection)
    (let* ((file-path (alist-get 'file-path matisse--last-selection))
           (start-line (alist-get 'start-line matisse--last-selection))
           (end-line (alist-get 'end-line matisse--last-selection))
           (has-selection (alist-get 'has-selection matisse--last-selection))
           (selected-text (alist-get 'text matisse--last-selection)))
      (when file-path
        (cond
         ;; Has selected text - send file path + line info + text
         ((and has-selection (not (string-empty-p selected-text)))
          (if (= start-line end-line)
              (format "File: %s (line %d)\n\n%s"
                      file-path start-line selected-text)
            (format "File: %s (lines %d-%d)\n\n%s"
                    file-path start-line end-line selected-text)))
         ;; Just cursor position - send file path + line reference
         (t
          (if (= start-line end-line)
              (format "Current file: %s (cursor at line %d)"
                      file-path start-line)
            (format "Current file: %s (cursor at line %d)"
                    file-path start-line))))))))

(defun matisse--format-selection-status ()
  "Format selection status for mode-line display.
Returns a string like \\='@matisse.el:45\\=' or \\='@matisse.el:45-47\\='."
  (when (and matisse-send-selection-p matisse--last-selection)
    (let* ((file-path (alist-get 'file-path matisse--last-selection))
           (start-line (alist-get 'start-line matisse--last-selection))
           (end-line (alist-get 'end-line matisse--last-selection))
           (has-selection (alist-get 'has-selection matisse--last-selection)))
      (when file-path
        (let ((file-name (file-name-nondirectory file-path)))
          (if has-selection
              (if (= start-line end-line)
                  (format "@%s:%d" file-name start-line)
                (format "@%s:%d-%d" file-name start-line end-line))
            (format "@%s:%d" file-name start-line)))))))

(defun matisse--format-permission-mode ()
  "Format permission mode for mode-line display with color."
  (let ((mode (or matisse--current-permission-mode matisse-permission-mode)))
    (cond
     ((string= mode "plan")
      (propertize "[PLAN]" 'face '(:inherit success :weight 'bold)))
     ((string= mode "acceptEdits")
      (propertize "[ACCEPT]" 'face 'matisse-accept-mode-face :weight 'bold))
     ((string= mode "bypassPermissions")
      (propertize "[BYPASS]" 'face '(:inherit error :weight :bold)))
     ((string= mode "yolo")
      (propertize "[YOLO]" 'face '(:inherit warning :weight bold)))
     ((string= mode "default")
      nil)  ; Don't show anything for default mode
     (t
      (propertize (format "[%s]" (upcase mode)) 'face '(:weight bold))))))

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
       ;; Notify the shell that the command finished with an error
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

;; Integration with matisse-shell.el for shell functionality

;;;; Public Commands
;;;###autoload
(defun matisse ()
  "Create a new Matisse Claude Code shell session.
Starts in the project root if in a project, otherwise in `default-directory'."
  (interactive)
  (matisse--validate-setup)

  ;; Capture current buffer selection before switching to matisse shell
  (let ((selection-info (matisse--get-selection-info)))
    (when selection-info
      (setq matisse--last-selection selection-info)))

  ;; Get the working directory (project root or default-directory)
  (let* ((initial-dir (matisse--get-working-directory))
         (buffer-name (matisse--generate-buffer-name initial-dir))
         ;; Create shell context with buffer name and initial directory
         (shell-context (list :buffer-name buffer-name :initial-directory initial-dir))
         (buffer (matisse--shell-start buffer-name shell-context)))
    ;; Set default-directory in the new buffer to ensure process starts there
    (with-current-buffer buffer
      (setq default-directory initial-dir))
    buffer))

;;;###autoload
(defun matisse-start-with-options ()
  "Start a new Matisse session with custom options via transient menu.
Provides an interactive interface to configure all Claude Code CLI arguments
including model, permissions, working directory, and more."
  (interactive)
  (if (fboundp 'matisse-start-transient)
      (matisse-start-transient)
    (user-error "Transient package not available. Install transient.el to use this feature")))

(defun matisse--get-status-with-icon (status-text)
  "Get STATUS-TEXT formatted with appropriate icon based on status type."
  (let* ((icon-type (cond
                     ((string= status-text "Working") :status-working)
                     ((string= status-text "Awaiting permission") :status-permission)
                     ((string= status-text "Idle") :status-idle)
                     ((string= status-text "Not started") :status-not-started)
                     (t nil)))
         (icon (when icon-type (matisse--get-icon icon-type))))
    (if icon
        (concat icon status-text)
      status-text)))

(defun matisse--get-session-status (buffer)
  "Get the status string for matisse session in BUFFER."
  (with-current-buffer buffer
    (let ((status (cond
                   (matisse--pending-permission-request "Awaiting permission")
                   (matisse--waiting-for-response "Working")
                   ((and matisse--process (process-live-p matisse--process)) "Idle")
                   (t "Not started"))))
      (matisse--get-status-with-icon status))))

(defun matisse--generate-session-entries ()
  "Generate list of entries for matisse session list.
Returns list in format suitable for `tabulated-list-entries'."
  (let ((matisse-buffers (seq-filter (lambda (buf)
                                       (with-current-buffer buf
                                         (derived-mode-p 'matisse-shell-mode)))
                                     (buffer-list))))
    (mapcar (lambda (buf)
              (let* ((name (buffer-name buf))
                     (dir (with-current-buffer buf
                            (or matisse--initial-directory default-directory)))
                     (status (matisse--get-session-status buf)))
                (list buf (vector name dir status))))
            matisse-buffers)))

(defun matisse-session-list-select ()
  "Select the matisse session at point and switch to it."
  (interactive)
  (when-let* ((entry (tabulated-list-get-entry))
              (buffer (tabulated-list-get-id)))
    (quit-window)
    (switch-to-buffer buffer)))

;;;###autoload
(defun matisse-list-sessions ()
  "Display a list of all active matisse sessions.
Shows buffer name, directory, and current status for each session.
Press RET to switch to a session, `g' to refresh the list."
  (interactive)
  (let ((matisse-buffers (seq-filter (lambda (buf)
                                       (with-current-buffer buf
                                         (derived-mode-p 'matisse-shell-mode)))
                                     (buffer-list))))
    (if (null matisse-buffers)
        (message "No matisse sessions found")
      (let ((buffer (get-buffer-create "*Matisse Sessions*")))
        (with-current-buffer buffer
          (matisse-session-list-mode)
          (setq tabulated-list-entries (matisse--generate-session-entries))
          (tabulated-list-print t))
        (switch-to-buffer buffer)))))

;;;###autoload
(defun matisse-select-session ()
  "Select and switch to a matisse session, or create a new one if none exist.
Provides interactive selection when multiple sessions are available."
  (interactive)
  (let ((matisse-buffers (seq-filter (lambda (buf)
                                       (with-current-buffer buf
                                         (derived-mode-p 'matisse-shell-mode)))
                                     (buffer-list))))
    (cond
     ((null matisse-buffers)
      (message "No matisse shell buffers found, creating new one...")
      (matisse))
     ((= (length matisse-buffers) 1)
      (switch-to-buffer (car matisse-buffers)))
     (t
      ;; Multiple buffers - let user choose
      (let* ((buffer-names (mapcar #'buffer-name matisse-buffers))
             (selected (completing-read "Select matisse session: " buffer-names nil t)))
        (when selected
          (switch-to-buffer selected)))))))

;;;###autoload
(defun matisse-continue ()
  "Continue the previous Claude conversation in a new shell.
Uses the --continue flag to maintain context from the last conversation.
Starts in the project root if in a project, otherwise in `default-directory'."
  (interactive)
  (matisse--validate-setup)

  ;; Get the working directory (project root or default-directory)
  (let* ((initial-dir (matisse--get-working-directory))
         (buffer-name (matisse--generate-buffer-name initial-dir))
         ;; Create shell context with continue flag
         (shell-context (list :buffer-name buffer-name
                              :initial-directory initial-dir
                              :continue-session t))
         ;; Start the shell
         (buffer (matisse--shell-start buffer-name shell-context)))
    ;; Create shell context with continue flag
    (with-current-buffer buffer
      ;; Set default-directory to ensure process starts in the right place
      (setq default-directory initial-dir)
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
      (let ((last-message-type (matisse--replay-previous-conversation)))
        ;; Skip syntax highlighting on replay - will be applied incrementally as needed
        ;; (matisse--overlays-put)

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
(defun matisse-set-model (model)
  "Set the Claude MODEL to use for this session.
Switches the model without restarting the process if one is running.
Works globally - finds the appropriate matisse buffer if not already in one."
  (interactive
   (list (let* ((choices '(("Default" . nil)
                           ("Sonnet" . "sonnet")
                           ("Opus" . "opus")))
                (selection (completing-read "Model: " choices nil t)))
           (cdr (assoc selection choices)))))
  (if-let* ((target-buffer (matisse--get-target-buffer-or-current)))
      (with-current-buffer target-buffer
        (let ((old-model (or matisse--current-model matisse-default-model)))
          (setq matisse--current-model model)
          ;; If we have an active process, send control request to switch model
          (if (and matisse--process (process-live-p matisse--process))
              (if model
                  (progn
                    (matisse--send-control-request "set_model" `((model . ,model)))
                    (message "Switching model from %s to %s" old-model model))
                (message "Cannot switch to default model while process is running"))
            ;; No active process, just update the setting
            (message "Model set to %s for next session" (or model "default")))))
    (user-error "No matisse session found")))

(defun matisse--set-permission-mode (mode)
  "Set the permission MODE for this session.
Switches the mode without restarting the process if one is running.
Note: bypassPermissions mode can only be set at session startup via
`matisse-permission-mode' variable, not dynamically."
  ;; Reject bypassPermissions for dynamic switching
  (when (string= mode "bypassPermissions")
    (user-error "bypassPermissions mode can only be set at session startup via matisse-permission-mode variable"))

  (setq matisse--current-permission-mode mode)
  ;; Mark that we have a pending permission update to send in next control response
  (setq matisse--pending-permission-update mode)
  ;; Update mode-line
  (matisse--update-mode-line)
  ;; If we have an active process, send control request to switch mode
  (if (and matisse--process (process-live-p matisse--process))
      (progn
        (matisse--send-control-request "set_permission_mode" `((mode . ,mode)))
        (matisse--show-permission-mode-message mode))
    ;; No active process, just update the setting
    (matisse--show-permission-mode-message mode)))

(defun matisse--show-permission-mode-message (mode)
  "Display a colored message in the minibuffer showing the current MODE."
  (let ((message-text
         (cond
          ((string= mode "plan")
           (propertize "PLAN MODE" 'face '(:inherit success :weight bold)))
          ((string= mode "acceptEdits")
           (propertize "ACCEPT EDITS MODE" 'face 'matisse-accept-mode-face))
          ((string= mode "bypassPermissions")
           (propertize "BYPASS MODE" 'face '(:inherit error :weight bold)))
          ((string= mode "yolo")
           (propertize "YOLO MODE" 'face '(:inherit warning :weight bold)))
          ((string= mode "default")
           (propertize "DEFAULT MODE" 'face 'matisse-default-mode-face))
          (t
           (propertize (format "%s MODE" (upcase mode)) 'face '(:weight bold))))))
    (message "%s" message-text)))

;;;###autoload
(defun matisse-cycle-permission-mode ()
  "Cycle through permission modes.
Order: plan -> default -> acceptEdits -> yolo -> plan.
Note: bypassPermissions mode can only be set at session startup
via `matisse-permission-mode' variable.
Works globally - finds the appropriate matisse buffer if not already in one."
  (interactive)
  (if-let* ((target-buffer (matisse--get-target-buffer-or-current)))
      (with-current-buffer target-buffer
        (let* ((current (or matisse--current-permission-mode matisse-permission-mode))
               (next (cond
                      ((string= current "plan") "default")
                      ((string= current "default") "acceptEdits")
                      ((string= current "acceptEdits") "yolo")
                      ((string= current "yolo") "plan")
                      ;; If somehow in bypassPermissions (set at startup), cycle to plan
                      ((string= current "bypassPermissions") "plan")
                      (t "plan"))))
          (matisse--set-permission-mode next)))
    (user-error "No matisse session found")))

;;;###autoload
(defun matisse-toggle-performance-summary ()
  "Toggle display of performance summaries."
  (interactive)
  (setq matisse-show-performance-summary (not matisse-show-performance-summary))
  (message "Performance summaries %s"
           (if matisse-show-performance-summary "enabled" "disabled")))

;;;; Remote Control Helper Functions

(defun matisse--update-mru (buffer)
  "Update the MRU list to mark BUFFER as most recently used.
BUFFER can be a buffer object or buffer name."
  (let ((buf-name (if (bufferp buffer)
                      (buffer-name buffer)
                    buffer)))
    ;; Remove buffer from list if already present
    (setq matisse--buffer-mru-list
          (delq buf-name (delete buf-name matisse--buffer-mru-list)))
    ;; Add to front of list
    (push buf-name matisse--buffer-mru-list)))

(defun matisse--get-buffer-directory (buffer)
  "Get the initial directory for matisse BUFFER.
Returns the directory from the buffer's matisse--shell-context,
or nil if not available."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (boundp 'matisse--shell-context)
        (plist-get matisse--shell-context :initial-directory)))))

(defun matisse--find-target-buffer ()
  "Find the most appropriate matisse buffer based on directory context.
Uses the following priority:
1. Matisse buffer(s) in current `default-directory' (returns MRU)
2. Matisse buffer(s) in parent directories (walking up tree, returns MRU)
3. Most recently used matisse buffer globally
4. nil if no matisse buffers exist"
  (let* ((all-matisse-buffers
          (seq-filter (lambda (buf)
                        (with-current-buffer buf
                          (derived-mode-p 'matisse-shell-mode)))
                      (buffer-list)))
         (current-dir (expand-file-name default-directory)))

    (if (null all-matisse-buffers)
        nil

      ;; Helper to find buffer in specific directory
      (cl-labels ((find-in-directory (dir)
                    (let ((matches (seq-filter
                                   (lambda (buf)
                                     (when-let* ((buf-dir (matisse--get-buffer-directory buf)))
                                       (string-equal (expand-file-name buf-dir) dir)))
                                   all-matisse-buffers)))
                      (when matches
                        ;; Return first match in MRU order
                        (cl-find-if (lambda (buf)
                                     (member (buffer-name buf) matisse--buffer-mru-list))
                                   matches
                                   ;; If not in MRU list, return first match
                                   :default (car matches)))))
                  (parent-directory (dir)
                    (let ((parent (file-name-directory (directory-file-name dir))))
                      (unless (string-equal parent dir)
                        parent))))

        ;; Try current directory
        (or (find-in-directory current-dir)

            ;; Walk up directory tree
            (let ((dir current-dir)
                  result)
              (while (and dir (not result))
                (setq dir (parent-directory dir))
                (when dir
                  (setq result (find-in-directory dir))))
              result)

            ;; Fall back to global MRU
            (cl-find-if (lambda (buf-name)
                         (and (get-buffer buf-name)
                              (buffer-live-p (get-buffer buf-name))
                              (with-current-buffer buf-name
                                (derived-mode-p 'matisse-shell-mode))))
                       matisse--buffer-mru-list)

            ;; Last resort: first matisse buffer
            (car all-matisse-buffers))))))

(defun matisse--track-buffer-switch ()
  "Track buffer switches to maintain MRU list."
  (when (derived-mode-p 'matisse-shell-mode)
    (matisse--update-mru (current-buffer))))

;;;; Remote Control Commands
;; Commands for controlling matisse sessions from any buffer

(defun matisse--get-target-buffer-or-current ()
  "Get the target matisse buffer.
If already in a matisse buffer, returns current buffer.
Otherwise, uses directory-based selection to find appropriate buffer.
Returns nil if no matisse buffer exists."
  (if (derived-mode-p 'matisse-shell-mode)
      (current-buffer)
    (matisse--find-target-buffer)))

;;;###autoload
(defun matisse-toggle ()
  "Show or hide the appropriate matisse buffer.
Uses directory-based selection to find the most relevant matisse session.
If the buffer is visible, hides it; if hidden, shows and switches to it.
Does not create a new session if none exists."
  (interactive)
  (if-let* ((target-buffer (matisse--find-target-buffer)))
      (if-let* ((window (get-buffer-window target-buffer t)))
          ;; Buffer is visible - delete the window
          (progn
            (delete-window window)
            (message "Matisse buffer hidden"))
        ;; Buffer is not visible - show and switch to it
        (pop-to-buffer target-buffer)
        (message "Switched to matisse buffer"))
    (message "No matisse session found")))

;;;###autoload
(defun matisse-send (message)
  "Send MESSAGE to appropriate matisse buffer and submit it.
Uses directory-based selection to find the most relevant session.
Creates a new session if none exists."
  (interactive "sMessage for Matisse: ")
  (let ((matisse-buffer (or (matisse--find-target-buffer)
                            ;; Create new session if none found
                            (progn
                              (matisse)
                              ;; Return the newly created buffer
                              (matisse--find-target-buffer)))))
    (when matisse-buffer
      (with-current-buffer matisse-buffer
        ;; Track this buffer usage
        (matisse--update-mru (current-buffer))
        ;; Insert the message at the prompt
        (goto-char (point-max))
        (insert message)
        ;; Submit the message using our custom handler
        (matisse--handle-return))
      ;; Switch to the matisse buffer
      (pop-to-buffer matisse-buffer)
      ;; Position cursor at end
      (goto-char (point-max)))))

;;;; File Reference Commands
(defun matisse--format-file-reference (&optional selection-info)
  "Format current file or SELECTION-INFO as @file reference.
Returns string like @/path/to/file:LINE or @/path/to/file:START-END.
If SELECTION-INFO is nil, uses current buffer."
  (let* ((info (or selection-info (matisse--get-selection-info))))
    (when info
      (let* ((file-path (alist-get 'file-path info))
             (start-line (alist-get 'start-line info))
             (end-line (alist-get 'end-line info))
             (has-selection (alist-get 'has-selection info)))
        (when file-path
          (if (and has-selection (not (= start-line end-line)))
              (format "@%s:%d-%d" file-path start-line end-line)
            (format "@%s:%d" file-path start-line)))))))

;;;###autoload
(defun matisse-copy-file-reference ()
  "Copy current file or selection as @file reference to kill ring.
If a region is active, copies @/path/to/file:START-END format.
Otherwise, copies @/path/to/file:LINE format with cursor line."
  (interactive)
  (if-let* ((reference (matisse--format-file-reference)))
      (progn
        (kill-new reference)
        (message "Copied: %s" reference))
    (user-error "No file associated with current buffer")))

;;;###autoload
(defun matisse-insert-file-reference ()
  "Insert current file or selection as @file reference into matisse buffer.
Uses `matisse--find-target-buffer' to find the appropriate matisse session.
Creates a new session if none exists."
  (interactive)
  (if-let* ((reference (matisse--format-file-reference))
            (matisse-buffer (or (matisse--find-target-buffer)
                                ;; Create new session if none found
                                (progn
                                  (matisse)
                                  (matisse--find-target-buffer)))))
      (progn
        (with-current-buffer matisse-buffer
          ;; Track this buffer usage
          (matisse--update-mru (current-buffer))
          ;; Insert at prompt
          (goto-char (point-max))
          (insert reference))
        ;; Switch to the matisse buffer
        (pop-to-buffer matisse-buffer)
        ;; Position cursor at end of inserted reference
        (goto-char (point-max))
        (message "Inserted: %s" reference))
    (user-error "No file associated with current buffer")))

;;;###autoload
(defun matisse-insert-file-reference-with-prompt ()
  "Prompt for a file and insert as @file reference into matisse buffer.
Uses `read-file-name' to select the file interactively."
  (interactive)
  (let* ((file-path (read-file-name "File: " nil nil t))
         (absolute-path (expand-file-name file-path))
         (reference (format "@%s" absolute-path))
         (matisse-buffer (or (matisse--find-target-buffer)
                             ;; Create new session if none found
                             (progn
                               (matisse)
                               (matisse--find-target-buffer)))))
    (when matisse-buffer
      (with-current-buffer matisse-buffer
        ;; Track this buffer usage
        (matisse--update-mru (current-buffer))
        ;; Insert at prompt
        (goto-char (point-max))
        (insert reference))
      ;; Switch to the matisse buffer
      (pop-to-buffer matisse-buffer)
      ;; Position cursor at end of inserted reference
      (goto-char (point-max))
      (message "Inserted: %s" reference))))

;;;###autoload
(defun matisse-quit ()
  "Quit Matisse by killing the process and buffer.
Works globally - finds the appropriate matisse buffer if not already in one."
  (interactive)
  (if-let* ((target-buffer (matisse--get-target-buffer-or-current)))
      (kill-buffer target-buffer)
    (user-error "No matisse session found")))

;;;; Token Tracking Commands
(defun matisse-show-tokens ()
  "Show current token usage statistics.
Works globally - finds the appropriate matisse buffer if not already in one."
  (interactive)
  (if-let* ((target-buffer (matisse--get-target-buffer-or-current)))
      (with-current-buffer target-buffer
        (let* ((threshold (matisse--auto-compact-threshold))
               (percentage (if (> threshold 0)
                               (format " (%.0f%% of threshold)"
                                       (* 100.0 (/ (float matisse--tokens-since-compact)
                                                  threshold)))
                             "")))
          (message "Tokens: %d total, %d since last reset%s"
                   matisse--total-tokens-used
                   matisse--tokens-since-compact
                   percentage)))
    (user-error "No matisse session found")))

;;;###autoload
(defun matisse-clear ()
  "Clear the conversation history by restarting with a fresh session.
Works globally - finds the appropriate matisse buffer if not already in one."
  (interactive)
  (if-let* ((target-buffer (matisse--get-target-buffer-or-current)))
      (with-current-buffer target-buffer
          ;; Kill the current process if running
          (when (and matisse--process (process-live-p matisse--process))
            (delete-process matisse--process)
            (setq matisse--process nil))

          ;; Clean up session temp file directory before clearing
          (when matisse--conversation-id
            (let ((temp-dir (expand-file-name
                             (format ".temp-files/%s" matisse--conversation-id)
                             (matisse--get-project-directory))))
              (when (file-directory-p temp-dir)
                (ignore-errors (delete-directory temp-dir t))
                (matisse--debug-log "Cleaned up temp directory: %s" temp-dir))))

          ;; Clear all session state
          (setq matisse--conversation-id nil
                matisse--interrupted-session-id nil
                matisse--current-message-id nil
                matisse--message-queue nil
                matisse--pending-message nil
                matisse--pending-slash-command nil
                matisse--pending-large-paste nil
                matisse--large-paste-counter 0
                matisse--temp-files nil
                matisse--active-tools nil
                matisse--interrupted-tools nil)

          ;; Reset token counter
          (matisse--reset-token-count)

          ;; Clear buffer content and reinitialize
          (let ((inhibit-read-only t))
            (setq matisse--message-counter 0)
            (when matisse--message-sections
              (clrhash matisse--message-sections))
            (erase-buffer))

          ;; Start fresh process (no resume, no continue)
          (matisse--create-process-with-options nil nil)

          ;; Reinitialize buffer with fresh prompt
          (matisse--initialize-buffer)

        (message "Conversation cleared - starting fresh session"))
    (user-error "No matisse session found")))

;;;###autoload
(defun matisse-compact (&optional instructions)
  "Compact the conversation to save context using the /compact slash command.
With optional INSTRUCTIONS, provide specific guidance for the compaction.
Works globally - finds the appropriate matisse buffer if not already in one."
  (interactive
   (list (when current-prefix-arg
           (read-string "Compaction instructions: "))))
  (if-let* ((target-buffer (matisse--get-target-buffer-or-current)))
      (with-current-buffer target-buffer
        (let ((command (if instructions
                          (format "/compact --instructions \"%s\"" instructions)
                        "/compact")))
          (matisse--process-user-input-internal command)))
    (user-error "No matisse session found")))

;;; Session & Shell Management
;;;; Message Queue
(defun matisse--enqueue-message (text &optional type)
  "Add TEXT to the unified message queue with TYPE.
TYPE defaults to \\='user but can be \\='slash-command.
Returns the message plist.

When a new message is enqueued, clears the queue-paused flag to resume
automatic processing."
  (let* ((message-id (cl-incf matisse--message-counter))
         (is-slash (matisse--is-slash-command-p text))
         (msg-type (or type (if is-slash 'slash-command 'user)))
         (command (when is-slash (car (split-string (string-trim text) "\\s-+"))))
         (message (list :id message-id
                        :type msg-type
                        :text text
                        :command command
                        :status 'pending
                        :timestamp (current-time-string))))
    ;; Clear pause flag - user is sending new message
    (setq matisse--queue-paused nil)

    ;; Add to queue
    (setq matisse--message-queue
          (append matisse--message-queue (list message)))

    ;; Create response section
    (matisse-shell--create-response-section message-id)

    ;; Return the message
    message))

(defun matisse--dequeue-message ()
  "Remove and return the first pending message from the queue."
  (let ((pending (cl-find-if (lambda (msg)
                                (eq (plist-get msg :status) 'pending))
                              matisse--message-queue)))
    (when pending
      ;; Update status to processing
      (plist-put pending :status 'processing)
      pending)))

(defun matisse--get-current-message ()
  "Get the currently processing message from the queue."
  (cl-find-if (lambda (msg)
                (eq (plist-get msg :status) 'processing))
              matisse--message-queue))

(defun matisse--mark-message-complete (message-id)
  "Mark MESSAGE-ID as completed in the queue."
  (when-let* ((msg (cl-find-if (lambda (m)
                                  (= (plist-get m :id) message-id))
                                matisse--message-queue)))
    (plist-put msg :status 'completed)))

(defun matisse--process-queue ()
  "Process the next pending message in the unified queue.
Returns early if queue is paused or a message is already processing."
  (unless (or matisse--queue-paused ; Stop if queue is paused
              (matisse--get-current-message)) ; Don't start if one is processing
    (when-let* ((message (matisse--dequeue-message)))
      (let ((message-id (plist-get message :id))
            (text (plist-get message :text))
            (msg-type (plist-get message :type)))

        ;; Set current message ID for compatibility
        (setq matisse--current-message-id message-id)

        ;; Track slash commands for feedback
        (when (eq msg-type 'slash-command)
          (setq matisse--pending-slash-command (string-trim text)))

        ;; Set up shell context
        (setq matisse--shell-context
              (list :write-output #'matisse-shell--write-progress
                    :finish-output #'matisse-shell--finish-output-unified
                    :buffer-name (buffer-name)
                    :message-id message-id))

        ;; Send via execute-command
        (matisse--execute-command text matisse--shell-context)))))

(defun matisse-shell--finish-output-unified ()
  "Unified version of finish-output that works with the new queue."
  (matisse--debug-log "finish-output-unified called, mode=%s, msg-id=%s" major-mode matisse--current-message-id)
  (when (derived-mode-p 'matisse-shell-mode)
    ;; Mark current message as complete
    (when matisse--current-message-id
      (matisse--debug-log "Marking message %s complete" matisse--current-message-id)
      (matisse--mark-message-complete matisse--current-message-id)
      (setq matisse--current-message-id nil))

    ;; Note: Temp files are NOT cleaned up here - they persist for the session
    ;; lifetime to support follow-up questions and resume functionality.
    ;; Cleanup only happens on explicit /clear command.

    ;; Ensure proper spacing
    (save-excursion
      (goto-char (point-max))
      (let ((at-prompt (matisse--at-prompt-p)))
        (matisse--debug-log "At prompt: %s, point-max: %d" at-prompt (point-max))
        (when at-prompt
          (beginning-of-line)
          (when (and (> (point) (point-min))
                     (save-excursion
                       (backward-char 1)
                       (not (looking-at "\n"))))
            (matisse--debug-log "Adding spacing before prompt")
            (insert "\n")))))

    ;; Ensure there's a prompt at the end
    (let ((has-prompt (matisse--at-prompt-p)))
      (matisse--debug-log "Has prompt at end: %s" has-prompt)
      (unless has-prompt
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (matisse--debug-log "Inserting prompt at end")
        (matisse--insert-prompt)))

    ;; Refresh overlays
    (matisse--overlays-put)

    ;; Auto-scroll
    (matisse--auto-scroll-if-at-end (matisse--user-at-end-p) (current-buffer))

    ;; Process next message after a delay
    (run-at-time 0.5 nil #'matisse--process-queue)))

;;;; Shell Interface
;;;; Shell Custom Variables
;; Shell prompt is now dynamic based on matisse-icons-mode

(defun matisse--update-shell-prompt ()
  "Update shell prompt variables based on current icon mode."
  (let ((char (matisse--get-icon :prompt)))
    (setq matisse--shell-prompt char
          matisse--shell-prompt-regex (concat "^" (regexp-quote char)))))

;; Initialize prompt variables globally as fallback
(matisse--update-shell-prompt)

;;;; Integration Variables
(defun matisse-shell--signal-response-complete ()
  "Signal that the current response is complete and handle spacing."
  (when (eq major-mode 'matisse-shell-mode)
    (matisse-shell--finish-output)))

;;;; Shell Customization
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
    ("php" . ("php-mode"))
    ("markdown" . ("markdown-mode"))
    ("md" . ("markdown-mode")))
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

;;;; Shell Variables
;;;; Mode Detection and Shell Functions
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

(defun matisse--mode-can-load-p (mode-symbol)
  "Test if MODE-SYMBOL exists (fast check).
Returns non-nil if the mode function is defined."
  (fboundp mode-symbol))

(defun matisse--find-best-mode (language)
  "Find the best available mode for LANGUAGE, preferring tree-sitter modes.
Returns the mode symbol if found, nil otherwise."
  (when language
    (let* ((normalized (matisse--normalize-language language))
           (lang-lower (downcase (string-trim (or normalized language)))))
      ;; Debug message to see what language we're trying to find
      (let ((result
             (or
              ;; 1. Check custom preferences first
              (when-let* ((preferences (alist-get lang-lower matisse-language-mode-preferences nil nil #'string=)))
                (cl-find-if (lambda (mode-name-str)
                              (let ((mode-symbol (intern mode-name-str)))
                                (matisse--mode-can-load-p mode-symbol)))
                            preferences))
              ;; 2. Try tree-sitter variant: LANGUAGE-ts-mode
              (let ((ts-mode (intern (concat lang-lower "-ts-mode"))))
                (when (matisse--mode-can-load-p ts-mode)
                  (symbol-name ts-mode)))
              ;; 3. Try standard variant: LANGUAGE-mode
              (let ((standard-mode (intern (concat lang-lower "-mode"))))
                (when (matisse--mode-can-load-p standard-mode)
                  (symbol-name standard-mode))))))
        result))))

(defun matisse--get-cached-mode-buffer (target-mode)
  "Get or create a cached buffer with TARGET-MODE already activated.
Returns a buffer object that can be used for syntax highlighting.
The buffer is cached so TreeSitter compilation only happens once per session."
  (or (gethash target-mode matisse--mode-buffer-cache)
      (let ((buf (generate-new-buffer (format " *matisse-syntax-%s*" target-mode))))
        (with-current-buffer buf
          (let ((inhibit-message t))
            (funcall (intern target-mode)))
          (font-lock-mode 1))
        (puthash target-mode buf matisse--mode-buffer-cache)
        buf)))

(defun matisse--clear-mode-cache ()
  "Clear the mode buffer cache, killing all cached buffers.
Useful for debugging or if modes need to be reinitialized."
  (interactive)
  (maphash (lambda (_mode buf)
             (when (buffer-live-p buf)
               (kill-buffer buf)))
           matisse--mode-buffer-cache)
  (clrhash matisse--mode-buffer-cache)
  (message "Cleared matisse mode buffer cache"))


;;;; Overlay-based Highlighting
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

(defun matisse--find-patterns (pattern &optional start-pos)
  "Find all matches of PATTERN in buffer, return (start . end) pairs.
Optional START-POS limits search for incremental updates."
  (let ((matches '())
        (search-start (or start-pos (point-min))))
    (save-excursion
      (goto-char search-start)
      (while (re-search-forward pattern nil t)
        (push (cons (match-beginning 0) (match-end 0)) matches)))
    (nreverse matches)))

;;;; Markdown Support
(defun matisse--find-markdown-code-blocks (&optional start-pos)
  "Find all markdown code blocks in buffer.
Returns list of alists with keys: start, end, language, body.
Optional START-POS limits search for incremental updates."
  (let ((blocks '())
        (search-start (or start-pos (point-min))))
    (save-excursion
      (goto-char search-start)
      ;; More flexible regex that handles various formats
      (while (re-search-forward "^[ \t]*```\\([a-zA-Z0-9_+-]*\\)" nil t)
        (let* ((start-marker (match-beginning 0))
               (lang-start (match-beginning 1))
               (lang-end (match-end 1))
               (line-end (line-end-position))
               (body-start (1+ line-end)))  ; Start after the newline
          ;; Now find the closing ```
          (when (re-search-forward "^[ \t]*```[ \t]*$" nil t)
            (let ((body-end (line-beginning-position))
                  (end-start (match-beginning 0)))
              (push (list 'start (cons start-marker (+ start-marker 3))  ; Just the ```
                          'end (cons end-start (match-end 0))  ; The entire closing marker match
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
            (let ((faces-to-apply nil)
                  ;; Get cached buffer with mode already activated (TreeSitter compiled once)
                  (cached-buffer (matisse--get-cached-mode-buffer target-mode)))
              ;; Use the cached buffer for syntax highlighting
              (with-current-buffer cached-buffer
                ;; Clear the buffer and insert new code
                (erase-buffer)
                (insert code-string)

                ;; Force font-lock to run on the new content
                (font-lock-ensure)

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

                        ;; Collect face info if there's a face and we're within bounds
                        (when (and face
                                  (< orig-start body-end)
                                  (> orig-end body-start))
                          (let ((actual-start (max orig-start body-start))
                                (actual-end (min orig-end body-end)))
                            (push (list actual-start actual-end face) faces-to-apply)))

                        (goto-char next-change))))))

              ;; Apply overlays in the original buffer
              (with-current-buffer original-buffer
                (dolist (face-info faces-to-apply)
                  (let ((start (nth 0 face-info))
                        (end (nth 1 face-info))
                        (face (nth 2 face-info)))
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

    ;; Apply syntax highlighting to code content (unless skipping for performance)
    (unless matisse--skip-syntax-highlighting
      (let* ((language (when language-pos
                         (buffer-substring-no-properties (car language-pos) (cdr language-pos)))))
        (matisse--apply-syntax-highlighting body-start body-end language)))))

(defun matisse--find-markdown-headers (&optional avoid-ranges start-pos)
  "Find markdown headers, avoiding AVOID-RANGES.
Returns list of alists with start, end, level, title positions.
Optional START-POS limits search for incremental updates."
  (let ((headers '())
        (search-start (or start-pos (point-min))))
    (save-excursion
      (goto-char search-start)
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

(defun matisse--find-markdown-bolds (&optional avoid-ranges start-pos)
  "Find markdown bold text, avoiding AVOID-RANGES.
Optional START-POS limits search for incremental updates."
  (let ((bolds '())
        (search-start (or start-pos (point-min))))
    (save-excursion
      (goto-char search-start)
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

(defun matisse--find-markdown-italics (&optional avoid-ranges start-pos)
  "Find markdown italic text, avoiding AVOID-RANGES.
Optional START-POS limits search for incremental updates."
  (let ((italics '())
        (search-start (or start-pos (point-min))))
    (save-excursion
      (goto-char search-start)
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

(defun matisse--find-markdown-strikethroughs (&optional avoid-ranges start-pos)
  "Find markdown strikethrough text, avoiding AVOID-RANGES.
Optional START-POS limits search for incremental updates."
  (let ((strikethroughs '())
        (search-start (or start-pos (point-min))))
    (save-excursion
      (goto-char search-start)
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

(defun matisse--find-markdown-inline-codes (&optional avoid-ranges start-pos)
  "Find markdown inline code, avoiding AVOID-RANGES.
Optional START-POS limits search for incremental updates."
  (let ((codes '())
        (search-start (or start-pos (point-min))))
    (save-excursion
      (goto-char search-start)
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

(defun matisse--overlays-put (&optional incremental)
  "Apply all matisse overlays to the buffer.
With optional INCREMENTAL non-nil, only process content added since last update."
  (let ((start-pos (when incremental
                     matisse--last-overlay-position)))
    ;; Only remove overlays in the region we're updating
    (when start-pos
      (remove-overlays start-pos (point-max) 'category 'matisse-overlays))
    (unless start-pos
      (matisse--overlays-remove))

    ;; Message headers: [Message #123] ...
    (dolist (match (matisse--find-patterns "^\\[Message #[0-9]+\\].*$" start-pos))
    (matisse--overlay-put
     (make-overlay (car match) (cdr match))
     'face 'matisse-message-header-face
     'evaporate t))

    ;; User messages: > ...
    (dolist (match (matisse--find-patterns "^> .*$" start-pos))
    (matisse--overlay-put
     (make-overlay (car match) (cdr match))
     'face 'matisse-user-message-face
     'evaporate t))

  ;; No special overlay for active prompts - they just use default appearance

    ;; Status indicators: [PROCESSING], [COMPLETED], [ERROR]
    (dolist (match (matisse--find-patterns "\\[\\(PROCESSING\\|COMPLETED\\|ERROR\\)\\]" start-pos))
    (matisse--overlay-put
     (make-overlay (car match) (cdr match))
     'face 'matisse-status-face
     'evaporate t))

    ;; Markdown code blocks with syntax highlighting
    (condition-case err
        (dolist (block (matisse--find-markdown-code-blocks start-pos))
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
                                      (matisse--find-markdown-code-blocks start-pos)))))

      ;; Markdown headers
      (dolist (header (matisse--find-markdown-headers avoid-ranges start-pos))
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
      (dolist (bold (matisse--find-markdown-bolds avoid-ranges start-pos))
      (let ((start (plist-get bold 'start))
            (end (plist-get bold 'end))
            (text (plist-get bold 'text)))
        (when (and start end text
                   (car text) (cdr text))
          (matisse--fontify-bold
           start end
           (car text) (cdr text)))))

      ;; Markdown italic text
      (dolist (italic (matisse--find-markdown-italics avoid-ranges start-pos))
      (let ((start (plist-get italic 'start))
            (end (plist-get italic 'end))
            (text (plist-get italic 'text)))
        (when (and start end text
                   (car text) (cdr text))
          (matisse--fontify-italic
           start end
           (car text) (cdr text)))))

      ;; Markdown strikethrough text
      (dolist (strikethrough (matisse--find-markdown-strikethroughs avoid-ranges start-pos))
      (let ((start (plist-get strikethrough 'start))
            (end (plist-get strikethrough 'end))
            (text (plist-get strikethrough 'text)))
        (when (and start end text
                   (car text) (cdr text))
          (matisse--fontify-strikethrough
           start end
           (car text) (cdr text)))))

      ;; Markdown inline code
      (dolist (code (matisse--find-markdown-inline-codes avoid-ranges start-pos))
      (let ((body-pos (plist-get code 'body)))
        (when (and body-pos (car body-pos) (cdr body-pos))
          (matisse--fontify-inline-code
           (car body-pos)
           (cdr body-pos)))))

      ;; Process markdown links
      (dolist (link (matisse--find-markdown-links avoid-ranges start-pos))
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
      (dolist (list-item (matisse--find-markdown-lists avoid-ranges start-pos))
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
           (car text-pos) (cdr text-pos))))))

    ;; Update last processed position
    (setq matisse--last-overlay-position (point-max))))

(defun matisse--find-markdown-links (&optional avoid-ranges start-pos)
  "Find all markdown links [text](url) in buffer, avoiding AVOID-RANGES.
Optional START-POS limits search for incremental updates."
  (let ((links '())
        (link-regex "\\[\\([^]]+\\)\\](\\([^)]+\\))")
        (search-start (or start-pos (point-min))))
    (save-excursion
      (goto-char search-start)
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

(defun matisse--find-markdown-lists (&optional avoid-ranges start-pos)
  "Find markdown list items (bullet and numbered), avoiding AVOID-RANGES.
Only matches lists in Claude's responses, not in user input.
Optional START-POS limits search for incremental updates."
  (let ((lists '())
        (search-start (or start-pos (point-min))))
    (save-excursion
      (goto-char search-start)
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

;;;; Buffer Initialization
(defun matisse--initialize-buffer ()
  "Set up initial buffer content and markers."
  ;; Ensure marker exists
  (unless matisse--output-start-marker
    (setq matisse--output-start-marker (make-marker)))

  ;; Initialize shell prompt variables for this buffer
  (matisse--update-shell-prompt)

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

  ;; Note: Process will start lazily when first message is sent
  ;; Commands and models will be loaded after init message arrives

  ;; Insert initial prompt
  (matisse--insert-prompt))

;;;; Buffer State Management
(defun matisse-clear-buffer ()
  "Clear all messages and reset buffer."
  (interactive)
  (let ((inhibit-read-only t))
    ;; Clean up animation state
    (setq matisse--waiting-for-response nil
          matisse--pending-permission-request nil)
    (matisse--stop-spinner)

    ;; Reset state
    (setq matisse--message-counter 0
          matisse--message-queue nil  ; Clear unified queue
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

(defun matisse--shell-start (buffer-name &optional shell-context)
  "Start Matisse shell with integration to main matisse process.
BUFFER-NAME is the name of the buffer to create.
SHELL-CONTEXT contains integration information from main matisse system."
  ;; Always generate a new unique buffer, even if buffer-name already exists
  ;; This ensures each matisse-shell invocation creates a fresh session
  (let ((buffer (generate-new-buffer buffer-name)))
    (with-current-buffer buffer
      ;; Store context for integration
      (setq matisse--shell-context shell-context)

      ;; Initialize shell mode
      (matisse-shell-mode)

      ;; Set buffer-local variables from shell-context
      (when shell-context
        (when-let* ((permission-mode (plist-get shell-context :permission-mode)))
          (setq matisse--current-permission-mode permission-mode))
        (when-let* ((model (plist-get shell-context :model)))
          (setq matisse--current-model model)))

      ;; Track new buffer in MRU list
      (matisse--update-mru buffer)

      ;; Switch to the buffer
      (switch-to-buffer buffer)

      ;; Return the buffer for caller
      buffer)))

;;;; Region Management
(defun matisse--get-input-region ()
  "Return (start . end) of current input region.
Works with multiline input - finds the last prompt in buffer and goes to
end of buffer."
  (or
   ;; First try: find the most recent prompt
   (save-excursion
     (goto-char (point-max))
     (when (re-search-backward matisse--shell-prompt-regex nil t)
       (let ((start (+ (point) (length matisse--shell-prompt))) ; After prompt
             (end (point-max)))
         (when (>= end start)
           (cons start end)))))
   ;; Fallback: if point is after output marker and not in read-only region,
   ;; we're likely at a fresh input area (prompt just inserted)
   (when (and (boundp 'matisse--output-start-marker)
              matisse--output-start-marker
              (>= (point) matisse--output-start-marker)
              (not (get-text-property (point) 'read-only)))
     (cons matisse--output-start-marker (point-max)))))

;;;; Input Handling & Prompt Management
(defun matisse--insert-prompt ()
  "Insert prompt at end of buffer and set up input region."
  (matisse--debug-log "Inserting prompt at point %d (bolp=%s)" (point) (bolp))
  (condition-case err
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (unless (bolp)
          (matisse--debug-log "Not at BOL, inserting newline")
          (insert "\n"))

        ;; Insert prompt with properties - character gets special face, space doesn't
        (let ((prompt-start (point)))
          (matisse--debug-log "Inserting prompt text at %d" prompt-start)
          (insert matisse--shell-prompt)
          (let ((prompt-end (point)))
            ;; Apply face only to prompt character (exclude trailing space)
            (when (and prompt-start (> prompt-end prompt-start))
              ;; Calculate icon length by removing trailing whitespace
              (let* ((prompt-text matisse--shell-prompt)
                     (trimmed-text (string-trim-right prompt-text))
                     (icon-length (length trimmed-text)))
                ;; Only apply face if we have non-whitespace content
                (when (> icon-length 0)
                  (put-text-property prompt-start
                                   (min prompt-end (+ prompt-start icon-length))
                                   'face 'matisse-prompt-character-face)))
              ;; Make entire prompt read-only
              (put-text-property prompt-start prompt-end 'read-only t)
              (put-text-property prompt-start prompt-end 'rear-nonsticky '(read-only face))))
          (matisse--debug-log "Prompt inserted, now at point %d" (point)))

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
  (if (looking-at matisse--shell-prompt-regex)
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
  ;; Get input region once (includes prompt search) - avoid duplicate searches
  (let* ((input-region (matisse--get-input-region))
         (raw-input (if input-region
                        (string-trim (buffer-substring-no-properties
                                     (car input-region) (cdr input-region)))
                      ""))
         (input-length (length raw-input))
         ;; Check if this is a large paste
         (is-large-paste (> input-length matisse-large-paste-threshold))
         ;; Capture exact boundaries using region (no re-search needed)
         (prompt-start (when input-region
                         (save-excursion
                           (goto-char (car input-region))
                           (line-beginning-position))))
         (input-end (point-max))
         (actual-input raw-input))

    ;; Handle large pastes by creating placeholder
    (when is-large-paste
      (let* ((paste-num (cl-incf matisse--large-paste-counter))
             (input-region (matisse--get-input-region))
             ;; Count lines in raw-input (already have it)
             (num-lines (1+ (cl-count ?\n raw-input)))
             (placeholder (format "[Pasted text #%d +%d lines]" paste-num num-lines)))
        (setq matisse--pending-large-paste (list :text actual-input
                                                 :placeholder placeholder))
        ;; Replace visible text with placeholder
        (when (and prompt-start input-region)
          (let ((inhibit-read-only t))
            (delete-region (car input-region) (cdr input-region))
            (goto-char (car input-region))
            (insert placeholder)
            (setq input-end (point))))))

    ;; Disable redisplay during buffer modifications to prevent lag
    (let ((inhibit-redisplay t))
      ;; Now move to end and add newline
      (goto-char (point-max))
      (insert "\n")

      (cond
       ;; Check if responding to permission prompt
       ((and matisse--pending-permission-request
             (not (string-empty-p actual-input)))
        (matisse--handle-permission-response actual-input))

       ;; Empty input - just add new prompt
       ((string-empty-p actual-input)
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

        ;; Continue with normal processing using actual input (not display placeholder)
        (matisse--process-user-input-internal actual-input))))))

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
         ((member (string-trim (downcase input)) matisse-exit-commands)
          (when (fboundp 'matisse-quit)
            (matisse-quit)))

         ;; Normal message processing
         (t
          ;; Track this buffer usage
          (matisse--update-mru (current-buffer))

          ;; Show new prompt for async input
          (matisse--insert-prompt)

          ;; Auto-scroll after inserting new prompt (user was at end when submitting)
          (matisse--auto-scroll-if-at-end (matisse--user-at-end-p) (current-buffer))

          ;; Process message asynchronously
          (matisse--send-user-message input)

          ;; Clear large paste state after queuing message
          (setq matisse--pending-large-paste nil))))
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
    (looking-at-p matisse--shell-prompt)))

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
      ;; TODO fix "Not in input area" errors
      (message "Not in input area"))))

;;;; History Management
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

;;;; History Search
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

;;;; History Completing Read

;;;; Auto-scroll Utility
(defun matisse--user-at-end-p ()
  "Check if user is at or near the end of the buffer for scrolling purposes."
  (>= (point) (- (point-max) 1)))

(defun matisse--auto-scroll-if-at-end (at-end-condition buffer &optional force)
  "Auto-scroll to keep all typed input visible when AT-END-CONDITION is true.
BUFFER specifies which buffer to scroll.
If FORCE is non-nil, scroll immediately bypassing throttle.
Throttles scroll requests to prevent jumpy repositioning during streaming
output while ensuring prompt stays visible."
  (when at-end-condition
    (let ((shell-window (get-buffer-window buffer)))
      (when shell-window
        (with-current-buffer buffer
          ;; Check if enough time has passed since last scroll (or forced)
          (let* ((now (float-time))
                 (last-scroll (or matisse--last-scroll-time 0))
                 (elapsed-ms (* 1000 (- now last-scroll))))
            (when (or force (>= elapsed-ms matisse--scroll-throttle-ms))
              ;; Update last scroll time
              (setq matisse--last-scroll-time now)
              ;; Perform scroll
              (with-selected-window shell-window
                ;; Save cursor position to avoid interfering with movement commands
                (let ((original-point (point)))
                  (save-excursion
                    (goto-char (point-max))
                    ;; Find the prompt start to calculate input height
                    (let* ((prompt-line (save-excursion
                                          (goto-char (point-max))
                                          (if (re-search-backward matisse--shell-prompt-regex nil t)
                                              (save-restriction
                                                (widen)
                                                (line-number-at-pos))
                                            nil)))
                           (current-line (save-restriction
                                           (widen)
                                           (line-number-at-pos (point-max))))
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
                  (goto-char original-point))))))))))

;;;; Visual Design & Message Section Creation
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

;;;; Simplified Message Sending
(defun matisse--send-user-message (input)
  "Send user INPUT message directly to Claude."
  ;; Use unified queue
  (matisse--enqueue-message input)

  ;; Process queue if nothing is currently processing
  (unless (matisse--get-current-message)
    (matisse--process-queue)))

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

    ;; Ensure we're at the beginning of a line
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

      ;; Insert content at the response section (inhibit redisplay for performance)
      (let ((inhibit-redisplay t))
        (save-excursion
          (goto-char response-end)
          (let ((content-start (point))
                (inhibit-read-only t)  ; Allow inserting in read-only regions
                ;; Trim leading newlines to avoid blank lines after progress indicators
                (trimmed-content (string-trim-left content "[\n]+")))
            (insert trimmed-content)
            ;; Ensure content ends with newline for prompt separation
            (unless (or (string-suffix-p "\n" trimmed-content)
                        (eobp))
              (insert "\n"))
            ;; Explicitly remove any inactive face that might have been inherited
            ;; Use next-single-property-change for O(1) scanning instead of O(n)
            (let ((pos content-start))
              (while (< pos (point))
                (let ((next-change (or (next-single-property-change pos 'face nil (point))
                                      (point))))
                  (when (or (eq (get-text-property pos 'face) 'matisse-prompt-inactive-face)
                           (eq (get-text-property pos 'font-lock-face) 'matisse-prompt-inactive-face))
                    (remove-text-properties pos next-change '(face nil font-lock-face nil)))
                  (setq pos next-change))))
            ;; Update end marker
            (set-marker response-end (point)))))

      ;; Don't refresh overlays here - they should only be applied to specific patterns
      ;; and refreshing them after every response insertion can cause incorrect face application
      ;; (matisse--overlays-put)  ; Commented out to prevent tool messages from getting prompt faces

      ;; Auto-scroll if we were at the end, but keep prompt away from bottom edge
      (matisse--auto-scroll-if-at-end (with-current-buffer (current-buffer)
                                         (save-excursion
                                           (goto-char current-pos)
                                           (matisse--user-at-end-p))) (current-buffer)))))

(defun matisse--get-current-response-position ()
  "Get the insertion position for the current message's response.
Returns the response-end marker position if available, or point-max as fallback."
  (if (and (boundp 'matisse--current-message-id)
           matisse--current-message-id
           (boundp 'matisse--response-sections)
           matisse--response-sections)
      (let ((section (gethash matisse--current-message-id matisse--response-sections)))
        (if section
            (let ((response-end (plist-get section :response-end)))
              (if (markerp response-end)
                  (marker-position response-end)
                (point-max)))
          (point-max)))
    (point-max)))

(defun matisse-shell--write-progress (text)
  "Write progress TEXT to the shell buffer."
  ;; This function should be called from within the target shell buffer context
  (when (and (derived-mode-p 'matisse-shell-mode)
             ;; Skip if text is only whitespace
             (not (string-blank-p text)))
    (let* ((at-end (matisse--user-at-end-p))
           ;; Trim leading newlines from text to avoid double spacing
           (trimmed-text (string-trim-left text "[\n]+"))
           ;; Truncate if too long, even in verbose mode
           (display-text (matisse--truncate-text trimmed-text matisse-max-progress-message-length)))
      ;; Inhibit redisplay during progress indicator insertion for performance
      (let ((inhibit-redisplay t))
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
                  (insert display-text)
                  (unless (string-suffix-p "\n" display-text)
                    (insert "\n"))

                  ;; Explicitly remove any inactive face that might have been inherited
                  ;; Use next-single-property-change for O(1) scanning instead of O(n)
                  (let ((pos start-pos))
                    (while (< pos (point))
                      (let ((next-change (or (next-single-property-change pos 'face nil (point))
                                            (point))))
                        (when (or (eq (get-text-property pos 'face) 'matisse-prompt-inactive-face)
                                 (eq (get-text-property pos 'font-lock-face) 'matisse-prompt-inactive-face))
                          (remove-text-properties pos next-change '(face nil font-lock-face nil)))
                        (setq pos next-change))))
                  ;; Update the end marker
                  (set-marker response-end (point))))))))

      ;; Defer overlay application during streaming for performance
      ;; Schedule incremental overlay update on idle, but only if not already scheduled
      (unless matisse--overlay-update-scheduled
        (setq matisse--overlay-update-scheduled t)
        (run-with-idle-timer 0.3 nil
                             (lambda (buf)
                               (when (buffer-live-p buf)
                                 (with-current-buffer buf
                                   (matisse--overlays-put t)  ; incremental=t
                                   (setq matisse--overlay-update-scheduled nil))))
                             (current-buffer)))

      ;; Auto-scroll if we were at the end, but keep prompt away from bottom edge
      (matisse--auto-scroll-if-at-end at-end (current-buffer)))))

(defun matisse-shell--finish-output ()
  "Finish output and prepare for next prompt."
  ;; This function should be called from within the target shell buffer context
  (when (derived-mode-p 'matisse-shell-mode)
    ;; Only process if we have a current message (avoid duplicate calls)
    (when matisse--current-message-id
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

    ;; Ensure there's a prompt at the end
    (unless (matisse--at-prompt-p)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (matisse--insert-prompt))

    ;; Cancel any pending incremental overlay update
    (setq matisse--overlay-update-scheduled nil)

    ;; Refresh overlays one final time when response is complete (incremental)
    (matisse--overlays-put t)  ; incremental=t to avoid rescanning entire buffer

    ;; Auto-scroll when output is finished to show completion
    (matisse--auto-scroll-if-at-end (matisse--user-at-end-p) (current-buffer))

    ;; Process next message from unified queue if any are queued
    (run-at-time 0.1 nil #'matisse--process-queue)))

;;;; Post-command hook for smart scrolling
(defun matisse--post-command-scroll ()
  "Ensure typed text remains visible after each command.
Only scrolls when user is typing at the prompt."
  (when (and (derived-mode-p 'matisse-shell-mode)
             ;; Only scroll if we're in the input region
             (matisse--get-input-region)
             ;; And cursor is near the end
             (matisse--user-at-end-p))
    (matisse--auto-scroll-if-at-end (matisse--user-at-end-p) (current-buffer))))
;;;; Image Support Functions
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
;;; Mode Definitions, Interactive Commands & Keymaps
;;;; Keymaps
(defvar matisse-command-map
  (let ((map (make-sparse-keymap)))
    ;; Session Management
    (define-key map "s" #'matisse)
    (define-key map "N" #'matisse-start-with-options)
    (define-key map "w" #'matisse-select-session)
    (define-key map "l" #'matisse-list-sessions)
    (define-key map "r" #'matisse-resume)
    (define-key map "c" #'matisse-continue)
    (define-key map "q" #'matisse-quit)

    ;; Conversation Control
    (define-key map "e" #'matisse-send)
    (define-key map "i" #'matisse-interrupt)
    (define-key map "C" #'matisse-clear)
    (define-key map "k" #'matisse-compact)
    (define-key map "y" #'yank-media)

    ;; Settings & Display
    (define-key map "m" #'matisse-set-model)
    (define-key map "p" #'matisse-cycle-permission-mode)
    (define-key map "t" #'matisse-toggle)
    (define-key map "P" #'matisse-toggle-performance-summary)
    (define-key map "T" #'matisse-show-tokens)

    ;; File References
    (define-key map "@" #'matisse-insert-file-reference)
    (define-key map "f" #'matisse-copy-file-reference)
    (define-key map "F" #'matisse-insert-file-reference-with-prompt)

    ;; Menu
    (define-key map "?" #'matisse-menu)

    map)
  "Keymap for Matisse commands.
All commands are prefixed with `matisse-prefix-key' (default \\[matisse-prefix-key]).
Use \\[describe-keymap] to see all available commands.")

;;;; Transient Menus
(when (featurep 'transient)
  (transient-define-prefix matisse-transient-menu ()
    "Matisse Commands Menu"
    [["Session Management"
      ("s" "Start" matisse)
      ("N" "New with options..." matisse-start-with-options)
      ("w" "Select session" matisse-select-session)
      ("l" "List sessions" matisse-list-sessions)
      ("r" "Resume session" matisse-resume)
      ("c" "Continue last" matisse-continue)
      ("q" "Quit" matisse-quit)]
     ["Conversation Control"
      ("e" "Send message" matisse-send)
      ("i" "Interrupt" matisse-interrupt)
      ("C" "Clear conversation" matisse-clear)
      ("k" "Compact context" matisse-compact)
      ("y" "Yank media" yank-media)]
     ["Settings & Display"
      ("m" "Set model" matisse-set-model)
      ("p" "Cycle permission" matisse-cycle-permission-mode :transient t)
      ("t" "Toggle matisse window" matisse-toggle)
      ("P" "Toggle performance" matisse-toggle-performance-summary)
      ("T" "Show tokens" matisse-show-tokens)]
     ["File References"
      ("@" "Insert current file reference" matisse-insert-file-reference)
      ("f" "Copy file reference" matisse-copy-file-reference)
      ("F" "Insert file reference (find file)" matisse-insert-file-reference-with-prompt)]]))

  (transient-define-prefix matisse-start-transient ()
    "Start a new Matisse session with custom options."
    ["Session Type"
     ("-c" "Continue last conversation" "--continue")
     ("-r" "Resume session" "--resume=" :prompt "Session ID: ")
     ("-d" "Working directory" "--directory=" :reader transient-read-directory)]
    ["Model & Permissions"
     ("-m" "Model" "--model=" :choices ("sonnet" "opus" "haiku"))
     ("-p" "Permission mode" "--permission-mode=" :choices ("default" "plan" "acceptEdits" "bypassPermissions"))]
    ["Tool Permissions"
     ("-a" "Allowed tools" "--allowedTools=" :prompt "Allowed tools (e.g., Bash(git:*)): ")
     ("-D" "Disallowed tools" "--disallowedTools=" :prompt "Disallowed tools (e.g., Bash(rm:*)): ")]
    ["Additional Options"
     ("-A" "Additional directories" "--add-dir=" :prompt "Additional directory: ")
     ("-s" "System prompt" "--append-system-prompt=" :prompt "System prompt: ")
     ("-S" "Setting sources" "--setting-sources=" :prompt "Setting sources: " :init-value (lambda (_obj) "user,project,local"))
     ("-v" "Verbose logging" "--verbose")]
    ["Actions"
     ("s" "Start with options" matisse--start-with-transient-args)
     ("q" "Quit" transient-quit-one)])

  (defun matisse--start-with-transient-args (&optional args)
    "Start a new Matisse session using transient ARGS.
If ARGS is nil, uses `transient-args' to get current transient arguments."
    (interactive (list (transient-args 'matisse-start-transient)))
    (matisse--validate-setup)

    ;; Parse transient arguments
    (let* ((continue-flag (member "--continue" args))
           (resume-session-id nil)
           (working-dir nil)
           (model nil)
           (permission-mode nil)
           (allowed-tools nil)
           (disallowed-tools nil)
           (add-dirs nil)
           (system-prompt nil)
           (setting-sources nil)
           (verbose-flag (member "--verbose" args)))

      ;; Parse option arguments
      (dolist (arg args)
        (cond
         ((string-prefix-p "--resume=" arg)
          (setq resume-session-id (substring arg 9)))
         ((string-prefix-p "--directory=" arg)
          (setq working-dir (substring arg 12)))
         ((string-prefix-p "--model=" arg)
          (setq model (substring arg 8)))
         ((string-prefix-p "--permission-mode=" arg)
          (setq permission-mode (substring arg 18)))
         ((string-prefix-p "--allowedTools=" arg)
          (setq allowed-tools (substring arg 15)))
         ((string-prefix-p "--disallowedTools=" arg)
          (setq disallowed-tools (substring arg 18)))
         ((string-prefix-p "--add-dir=" arg)
          (push (substring arg 10) add-dirs))
         ((string-prefix-p "--append-system-prompt=" arg)
          (setq system-prompt (substring arg 23)))
         ((string-prefix-p "--setting-sources=" arg)
          (setq setting-sources (substring arg 18)))))

      ;; Capture current buffer selection before switching to matisse shell
      (let ((selection-info (matisse--get-selection-info)))
        (when selection-info
          (setq matisse--last-selection selection-info)))

      ;; Determine working directory
      (let* ((initial-dir (or working-dir (matisse--get-working-directory)))
             (buffer-name (matisse--generate-buffer-name initial-dir))
             (shell-context (list :buffer-name buffer-name
                                 :initial-directory initial-dir
                                 :model model
                                 :permission-mode permission-mode
                                 :allowed-tools allowed-tools
                                 :disallowed-tools disallowed-tools
                                 :add-dirs (nreverse add-dirs)
                                 :system-prompt system-prompt
                                 :setting-sources setting-sources
                                 :verbose verbose-flag
                                 :continue continue-flag
                                 :resume resume-session-id))
             (buffer (matisse--shell-start buffer-name shell-context)))

        ;; Set default-directory in the new buffer
        (with-current-buffer buffer
          (setq default-directory initial-dir))

        buffer)))

(defun matisse-menu ()
  "Show the Matisse transient menu.
If transient is available, shows an interactive menu.
Otherwise, displays available commands in the echo area."
  (interactive)
  (if (fboundp 'matisse-transient-menu)
      (matisse-transient-menu)
    (message "Transient not available. Commands: q-quit i-interrupt C-clear k-compact m-model M-cycle-permission P-performance T-tokens")))
;;;; Minor Mode
(defvar matisse-mode-map
  (let ((map (make-sparse-keymap)))
    (when matisse-prefix-key
      (define-key map (kbd matisse-prefix-key) matisse-command-map))
    map)
  "Keymap for `matisse-mode'.")

(defun matisse--cleanup-on-kill ()
  "Cleanup function called when a matisse buffer is killed.
Attempts graceful shutdown with fallback to hard kill."
  ;; Remove from MRU list
  (setq matisse--buffer-mru-list
        (delq (buffer-name) (delete (buffer-name) matisse--buffer-mru-list)))

  (when matisse--process
    (if (process-live-p matisse--process)
        (progn
          ;; Try graceful shutdown: close stdin, send SIGINT
          (ignore-errors
            (process-send-eof matisse--process))
          (ignore-errors
            (interrupt-process matisse--process))

          ;; Fallback to SIGTERM after 2 seconds
          (run-at-time 2 nil
                       (lambda (proc)
                         (when (and proc (process-live-p proc))
                           (signal-process proc 'SIGTERM)
                           ;; Final fallback to SIGKILL after 1 more second
                           (run-at-time 1 nil
                                        (lambda (p)
                                          (when (and p (process-live-p p))
                                            (delete-process p)))
                                        proc)))
                       matisse--process))
      ;; Process already dead, just clear reference
      (setq matisse--process nil)))

  ;; Clean up state
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

(defun matisse--kill-all-processes ()
  "Immediately kill all matisse processes on Emacs exit.
This ensures Emacs can exit promptly without waiting for cleanup timers."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (boundp 'matisse--process)
                 matisse--process
                 (process-live-p matisse--process))
        (delete-process matisse--process)))))

;; Register hook to kill all processes on Emacs exit
(add-hook 'kill-emacs-hook #'matisse--kill-all-processes)

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
        (add-hook 'post-command-hook #'matisse--track-selection-change)
        ;; Add global hook for buffer switch tracking
        (add-hook 'buffer-list-update-hook #'matisse--track-buffer-switch))
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
        (remove-hook 'post-command-hook #'matisse--track-selection-change)
        ;; Remove buffer switch tracking when no matisse buffers
        (remove-hook 'buffer-list-update-hook #'matisse--track-buffer-switch)))))

;;;###autoload
(define-minor-mode matisse-global-mode
  "Global minor mode for Matisse remote control commands.
Enables global keybindings for controlling matisse sessions from any buffer.
Commands like `matisse-toggle', `matisse-send', and `matisse-exit' work
globally using intelligent directory-based session selection."
  :global t
  :lighter ""
  :keymap (let ((map (make-sparse-keymap)))
            (when matisse-prefix-key
              (define-key map (kbd matisse-prefix-key) matisse-command-map))
            map))

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

;;;; Session List Mode
(define-derived-mode matisse-session-list-mode tabulated-list-mode "Matisse-Sessions"
  "Major mode for listing and selecting matisse sessions.
\\{matisse-session-list-mode-map}"
  (setq tabulated-list-format [("Buffer" 30 t)
                                ("Directory" 50 t)
                                ("Status" 20 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Buffer" nil))
  (add-hook 'tabulated-list-revert-hook #'matisse-list-sessions--refresh nil t)
  (tabulated-list-init-header)

  ;; Initialize timer variable
  (setq-local matisse--session-list-timer nil)

  ;; Start auto-refresh if enabled
  (when matisse-session-list-auto-refresh
    (matisse-session-list--start-auto-refresh))

  ;; Add cleanup hook
  (add-hook 'kill-buffer-hook #'matisse-session-list--stop-auto-refresh nil t))

(defun matisse-list-sessions--refresh ()
  "Refresh the matisse session list."
  (setq tabulated-list-entries (matisse--generate-session-entries)))

(defun matisse-session-list--auto-refresh ()
  "Auto-refresh function for the session list timer.
Only refreshes if the buffer is live and visible."
  (when (and (buffer-live-p (current-buffer))
             (get-buffer-window (current-buffer) t))
    (revert-buffer nil t)))

(defun matisse-session-list--start-auto-refresh ()
  "Start auto-refreshing the session list."
  (when (and matisse-session-list-auto-refresh
             (not matisse--session-list-timer))
    (setq matisse--session-list-timer
          (run-at-time matisse-session-list-refresh-interval
                       matisse-session-list-refresh-interval
                       (lambda ()
                         (when-let* ((buf (get-buffer "*Matisse Sessions*")))
                           (with-current-buffer buf
                             (matisse-session-list--auto-refresh))))))))

(defun matisse-session-list--stop-auto-refresh ()
  "Stop auto-refreshing the session list."
  (when matisse--session-list-timer
    (cancel-timer matisse--session-list-timer)
    (setq matisse--session-list-timer nil)))

(defun matisse-session-list-toggle-auto-refresh ()
  "Toggle auto-refresh for the session list."
  (interactive)
  (if matisse--session-list-timer
      (progn
        (matisse-session-list--stop-auto-refresh)
        (message "Auto-refresh disabled"))
    (progn
      (matisse-session-list--start-auto-refresh)
      (message "Auto-refresh enabled (every %.1fs)" matisse-session-list-refresh-interval))))

(define-key matisse-session-list-mode-map (kbd "RET") #'matisse-session-list-select)
(define-key matisse-session-list-mode-map (kbd "g") #'revert-buffer)
(define-key matisse-session-list-mode-map (kbd "a") #'matisse-session-list-toggle-auto-refresh)

;;;; Major Mode
(define-derived-mode matisse-shell-mode fundamental-mode "Matisse-Shell"
  "Major mode for matisse shell interactions.
Provides a clean interface for Claude interactions with visual feedback."
  ;; Buffer is read-only except for input area
  (setq buffer-read-only nil)  ; We'll manage read-only regions manually

  ;; Initialize local variables for state management
  (setq-local matisse--message-counter 0
              matisse--message-queue nil  ; Unified queue
              matisse--history nil
              matisse--history-index nil
              matisse--current-input ""
              matisse--output-start-marker (make-marker)
              matisse--message-sections (make-hash-table :test 'equal)
              matisse--pending-images nil
              matisse--pending-large-paste nil
              matisse--large-paste-counter 0
              matisse--temp-files nil
              matisse--permission-decision nil
              matisse--current-permission-message nil
              matisse--last-overlay-position nil  ; For incremental overlay updates
              matisse--overlay-update-scheduled nil)  ; For debouncing overlay updates

  ;; Key bindings using customizable keys (standard Emacs conventions)
  (local-set-key (kbd matisse-key-return) #'matisse--handle-return)
  (local-set-key (kbd matisse-key-newline) #'matisse--newline)
  (local-set-key (kbd matisse-key-history-previous) #'matisse-history-previous)
  (local-set-key (kbd matisse-key-history-next) #'matisse-history-next)
  (local-set-key (kbd matisse-key-history-previous-alt) #'matisse-history-previous)
  (local-set-key (kbd matisse-key-history-next-alt) #'matisse-history-next)
  (local-set-key (kbd matisse-key-history-search-backward) #'matisse-history-search-backward)
  (local-set-key (kbd matisse-key-history-search-forward) #'matisse-history-search-forward)
  (local-set-key (kbd matisse-key-clear-buffer) #'matisse-clear-buffer)
  (local-set-key (kbd matisse-key-beginning-of-line) #'matisse-bol)

  ;; Bind matisse-command-map to the prefix key if configured
  (when matisse-prefix-key
    (local-set-key (kbd matisse-prefix-key) matisse-command-map))

  ;; Bind interrupt command
  (local-set-key (kbd "C-c C-c") #'matisse-interrupt)

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

  ;; Update mode-line to reflect any existing selection context
  (matisse--update-mode-line)

  ;; Override mode line if configured
  (when matisse-override-mode-line
    (setq-local mode-line-format
                (list '(:eval matisse--mode-line-left)
                      'mode-line-format-right-align
                      '(:eval matisse--mode-line-right))))

  ;; Add hooks
  (add-hook 'post-command-hook #'matisse--post-command-scroll nil t)
  (add-hook 'kill-buffer-hook #'matisse--kill-buffer-hook nil t)

  ;; Enable slash command completion
  (add-hook 'completion-at-point-functions
            #'matisse--slash-command-completion-at-point nil t)

  ;; Register yank-media handler for images (Emacs 29+)
  (when (fboundp 'yank-media-handler)
    (yank-media-handler "image/.*" #'matisse--image-yank-media-handler)))

(provide 'matisse)
;;; matisse.el ends here
