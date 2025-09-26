# Matisse.el Reorganization Plan

**Status:** Ready for Implementation
**Date:** 2025
**Breaking Changes:** Yes (icon variable renames)

## Executive Summary

Reorganize matisse.el from 45+ fragmented top-level sections to 7 clear, logical sections while eliminating all forward declarations and reducing code duplication by ~100+ lines.

## Current State Analysis

### Problems
- **45+ top-level sections** - Excessive fragmentation makes navigation difficult
- **10+ forward declarations** - Scattered at lines 40-44, 4018-4022, 4101-4104 with duplicates
- **~100 lines of duplicated code** - 8 nearly identical icon getter functions
- **Poor organization** - State variables scattered, related functions separated
- **Misleading names** - `matisse-progress-icons-*` used for more than just progress

### Statistics
- Total lines: ~6,164
- Functions: 197 `defun`
- Customization variables: ~100 `defcustom`
- Icon variables: ~52 (emoji, nerd, ASCII)
- Buffer-local variables: ~35

## New Section Structure

### Top-Level Sections (7)

```elisp
;;; matisse.el --- Emacs interface to Claude Code -*- lexical-binding: t -*-

;;; Commentary:
;;; Code:

;; Package requires
;; External function declarations (auth-source-search)

;;; Configuration & Customization
;;;; Core Settings
;;;; Icon Configuration
;;;;; Icon Mode & Appearance
;;;;; Emoji Icons
;;;;; Nerd Font Icons & Faces
;;;;; ASCII Icons
;;;; Display & Behavior
;;;; Keybindings
;;;; Advanced Settings

;;; Variables & Constants
;;;; Internal Constants
;;;; Dynamic Variables & Data Structures
;;;; Buffer-Local State Variables
;;;; Global State Variables

;;; Core Utilities
;;;; Utility Functions
;;;; Icon & Formatting Functions

;;; Process & Protocol
;;;; Process Management
;;;; JSON Protocol
;;;; Control Requests & Responses
;;;; Slash Commands

;;; Permission System
;;;; Permission Logic
;;;; In-Buffer Prompts
;;;; Permission State Management

;;; Session & Shell Management
;;;; Session Operations
;;;; Token Tracking
;;;; Shell Interface
;;;; History Management
;;;; Message Queue

;;; Mode Definitions & Public API
;;;; Minor Mode
;;;; Major Mode
;;;; Public Commands & Interactive Functions

;;; matisse.el ends here
```

## Detailed Section Content

### Section 1: Configuration & Customization (~850 lines)

**Purpose:** All user-facing customization in one place for easy discovery.

**Scope:** User-customizable elements only (defgroup, defcustom, defface, command-map).
Internal constants (defconst), state variables (defvar-local), and non-customizable
variables (defvar) belong in Section 2, even if they're configuration-related.

**Principle:** "What users see in `M-x customize-group RET matisse`"

**Contents:**
- `defgroup matisse`
- **Core Settings** (~100 lines)
  - API key configuration
  - Model selection (default-model, temperature, max-tokens)
  - Permission mode
  - System prompt
- **Icon Configuration** (~500 lines)
  - Icon mode selection: `matisse-icons-mode` (renamed from `matisse-progress-icons-mode`)
  - Icon scale factor
  - Emoji icons (16 variables: read, write, edit, bash, grep, glob, task, webfetch, todowrite, default, success, performance, command, permission, allow, deny)
  - Nerd icons (16 icon variables + 16 face customization variables)
  - Nerd icon face definitions (11 defface: blue, green, orange, purple, etc.)
  - ASCII icons (3 variables: permission, allow, deny)
- **Display & Behavior** (~100 lines)
  - Progress indicators, file changes, performance summary
  - Verbose mode, debug mode
  - Token usage display, auto-compact threshold
  - Mode-line override, spinner interval
- **Keybindings** (~100 lines)
  - Key binding customization variables (matisse-key-*)
  - `matisse-command-map` - User-facing command keymap (defines matisse-prefix-key bindings)
  - `matisse-transient-menu` - Transient menu definition (if available)
  - Note: Mode keymaps (matisse-mode-map, matisse-shell-mode-map) belong in Section 6
- **Advanced Settings** (~50 lines)
  - Chunk sizes, thresholds
  - Buffer naming function
  - Allowed tools
  - Selection context

### Section 2: Variables & Constants (~210 lines)

**Purpose:** All variable and constant declarations in one place. Eliminates forward declarations.

**Scope:** Data declarations only (defconst, defvar, defvar-local). No functions.

**Contents:**
- **Internal Constants** (~10 lines)
  - `matisse--spinner-chars` - Spinner animation characters
  - `matisse--mode-line-separator` - Mode line separator string
  - `matisse--scroll-throttle-ms` - Scroll throttle timing
  - Other `defconst matisse--*` declarations

- **Dynamic Variables & Data Structures** (~30 lines)
  - `matisse--shell-prompt` - Dynamic prompt string (updated by `matisse--update-shell-prompt`)
  - `matisse--shell-prompt-regex` - Dynamic prompt regex (updated by `matisse--update-shell-prompt`)
  - `matisse--slash-commands` - Slash command completion data
  - `matisse--compact-options` - Compact command options data
  - Other non-customizable `defvar` declarations

- **Buffer-Local State Variables** (~150 lines)
  - Process state: `matisse--process`, `matisse--pending-json`
  - Conversation state: `matisse--conversation-id`, `matisse--message-count`
  - UI state: `matisse--waiting-for-response`, `matisse--spinner-timer`, `matisse--spinner-index`
  - Permission state: `matisse--pending-permission-request`
  - Shell context: `matisse--shell-context`, `matisse--initial-directory`
  - Message queue: `matisse--message-queue`, `matisse--message-counter`, `matisse--current-message-id`
  - Message sections: `matisse--message-sections`, `matisse--response-sections`
  - Tool tracking: `matisse--active-tools`, `matisse--interrupted-tools`
  - Token tracking: `matisse--total-tokens-used`, `matisse--tokens-since-compact`
  - Mode line: `matisse--mode-line-left`, `matisse--mode-line-right`
  - Session management: `matisse--interrupted-session-id`
  - Large content: `matisse--pending-images`, `matisse--pending-large-paste`, `matisse--temp-files`
  - Model/commands: `matisse--current-model`, `matisse--available-commands`, `matisse--available-models`

- **Global State Variables** (~20 lines)
  - `matisse--config`
  - `matisse--last-selection`
  - `matisse--selection-timer`

### Section 3: Core Utilities (~380 lines)

**Purpose:** Foundational utility functions used throughout the codebase.

**Scope:** Helper functions only. No variable declarations.

**Contents:**
- **Utility Functions** (~200 lines)
  - `matisse--debug-log` - Debug logging
  - Buffer name generation: `matisse--default-buffer-name`, `matisse--generate-buffer-name`
  - Project/directory: `matisse--get-working-directory`, `matisse--get-project-directory`, `matisse--get-session-file`
  - Configuration: `matisse--get-api-key`, `matisse--validate-setup`
  - Text processing: `matisse--truncate-text`, `matisse--at-end-of-line-p`
  - Mode line management: `matisse--update-mode-line`, `matisse--update-shell-prompt`
  - Spinner: `matisse--start-spinner`, `matisse--stop-spinner`, `matisse--make-spinner-tick`, `matisse--finish-current-message`
  - Cleanup: `matisse--cleanup-on-kill`, `matisse--kill-all-processes`

- **Icon & Formatting Functions** (~180 lines, CONSOLIDATED)
  - **NEW:** `matisse--get-icon` - Unified icon getter
  - **NEW:** `matisse--get-icon-data` - Icon data helper
  - `matisse--apply-icon-face-properties` - Icon styling
  - Format functions:
    - `matisse--format-progress-indicator`
    - `matisse--format-file-change-summary`
    - `matisse--format-performance-summary`
    - `matisse--format-selection-context`
    - `matisse--format-selection-status`
    - `matisse--format-permission-mode`
    - `matisse--format-token-status`
    - `matisse--format-permission-prompt`

### Section 4: Process & Protocol (~1,200 lines)

**Purpose:** Process management and Claude Code communication protocol.

**Contents:**
- **Process Management** (~400 lines)
  - `matisse--create-process-with-options`
  - `matisse--start-process-with-resume`
  - `matisse--process-filter`
  - `matisse--enhanced-process-sentinel`
  - `matisse--send-message`
  - `matisse--send-message-async`
  - `matisse--send-string-chunked`
  - `matisse--graceful-shutdown`
  - `matisse-interrupt`

- **JSON Protocol** (~300 lines)
  - `matisse--parse-json-line`
  - `matisse--extract-assistant-text`
  - `matisse--extract-tool-use`
  - `matisse--extract-tool-result`
  - `matisse--format-user-message`
  - `matisse--add-pending-image`
  - `matisse--handle-system-message`
  - `matisse--handle-jsonrpc-notification`
  - `matisse--handle-session-update`

- **Control Requests & Responses** (~300 lines)
  - `matisse--send-control-request`
  - `matisse--send-control-response`
  - `matisse--send-control-error`
  - `matisse--handle-control-request`
  - `matisse--handle-can-use-tool-request`
  - `matisse--handle-control-response`

- **Slash Commands** (~200 lines)
  - `matisse--is-slash-command-p`
  - `matisse--parse-slash-command`
  - `matisse--tokenize-arguments`
  - `matisse--parse-command-arguments`
  - `matisse--format-slash-command`
  - `matisse--handle-local-command`
  - `matisse--show-help`, `matisse--show-command-help`
  - Slash command completion: `matisse--slash-command-completion-at-point`
  - `matisse--get-available-commands`
  - Temp file handling: `matisse--get-temp-file-directory`, `matisse--write-arg-to-temp-file`, `matisse--maybe-convert-to-file-reference`

### Section 5: Permission System (~700 lines)

**Purpose:** Tool permission management and user prompts.

**Contents:**
- **Permission Logic** (~200 lines)
  - `matisse--should-auto-allow-tool`
  - `matisse--decide-tool-permission-shell`
  - `matisse--decide-tool-permission-with-suggestions` (to be merged)
  - `matisse--log-permission-decision`

- **In-Buffer Prompts** (~400 lines)
  - `matisse--prompt-permission-in-buffer`
  - `matisse--handle-permission-response`
  - `matisse--process-permission-response`
  - `matisse--show-permission-decision`
  - Diff generation: `matisse--find-string-line-number`, `matisse--create-edit-diff`

- **Permission State Management** (~100 lines)
  - Permission mode management
  - Request/response tracking

### Section 6: Session & Shell Management (~2,000 lines)

**Purpose:** Session lifecycle, shell interface, history, and message queue.

**Contents:**
- **Session Operations** (~500 lines)
  - `matisse-resume`
  - `matisse-replay-previous-conversation`
  - `matisse--replay-conversation-from-file`
  - `matisse--resume-affixation`
  - `matisse--count-session-messages`
  - `matisse--get-session-preview`

- **Token Tracking** (~100 lines)
  - `matisse--track-tokens`
  - `matisse--suggest-compaction`
  - `matisse--reset-token-count`
  - `matisse-show-tokens`

- **Shell Interface** (~900 lines)
  - Buffer initialization: `matisse--initialize-buffer`
  - Input handling: `matisse--process-user-input`, `matisse--handle-return`, `matisse--handle-newline`
  - Prompt management: `matisse--insert-prompt`, `matisse--at-prompt-p`, `matisse--get-input-region`
  - Region management: `matisse--get-current-response-position`
  - Response handling: `matisse-shell--handle-response`, `matisse-shell--write-progress`, `matisse-shell--finish-output`
  - Response sections: `matisse-shell--create-response-section`
  - Auto-scroll: `matisse--auto-scroll-if-at-end`, `matisse--user-at-end-p`
  - Mode detection: `matisse--detect-language-mode`
  - Overlay highlighting: `matisse--overlays-put`, `matisse--remove-overlays`
  - Face definitions for shell

- **History Management** (~300 lines)
  - `matisse--add-to-history`
  - `matisse--history-previous`, `matisse--history-next`
  - `matisse--history-search-backward`, `matisse--history-search-forward`
  - `matisse-history-complete`
  - `matisse-history-show`

- **Message Queue** (~200 lines)
  - `matisse--enqueue-message`
  - `matisse--dequeue-message`
  - `matisse--get-current-message`
  - `matisse--mark-message-complete`
  - `matisse--process-queue`
  - `matisse-shell--finish-output-unified`

### Section 7: Mode Definitions & Public API (~800 lines)

**Purpose:** Mode definitions and all public interactive commands.

**Contents:**
- **Minor Mode** (~150 lines)
  - `define-minor-mode matisse-mode`
  - Mode hooks and activation

- **Major Mode** (~100 lines)
  - `define-derived-mode matisse-shell-mode`
  - Keymap
  - Mode setup

- **Public Commands & Interactive Functions** (~550 lines)
  - Session management:
    - `matisse` (main entry point, autoloaded)
    - `matisse-shell` (alias)
    - `matisse-start-in-directory`
    - `matisse-continue`
    - `matisse-resume`
    - `matisse-clear`
    - `matisse-compact`
    - `matisse-quit`

  - Configuration & settings:
    - `matisse-set-model`
    - `matisse-cycle-permission-mode`
    - `matisse-set-temperature`
    - `matisse-set-icons-mode` (renamed from matisse-set-progress-icons-mode)

  - Display toggles:
    - `matisse-toggle-progress-indicators`
    - `matisse-toggle-file-changes`
    - `matisse-toggle-performance-summary`

  - Utilities & debug:
    - `matisse-show-tokens`
    - `matisse-show-stderr`
    - `matisse-history-show`
    - `matisse-history-complete`
    - `matisse-menu`
    - `matisse-transient-menu`

## Breaking Changes

### Icon Variable Renames

**Required for accuracy** - these icons are used for more than just progress indicators.

| Old Name | New Name | References |
|----------|----------|------------|
| `matisse-progress-icons` (defgroup) | `matisse-icons` | ~10 `:group` declarations |
| `matisse-progress-icons-mode` (defcustom) | `matisse-icons-mode` | ~16 code references |

**Migration for users:**
```elisp
;; Before
(setq matisse-progress-icons-mode 'emoji)

;; After
(setq matisse-icons-mode 'emoji)
```

### No Other Breaking Changes
- All other variable names preserved
- All function names preserved
- All public API preserved

## Code Consolidation: Icon Functions

### Current Implementation (Lines 2063-2167, ~105 lines)

Eight nearly identical functions with duplicated `pcase` logic:

```elisp
(defun matisse--get-tool-icon (tool-name)
  "Get the appropriate icon for TOOL-NAME based on current icon mode."
  (pcase matisse-progress-icons-mode
    ('emoji (let ((icon (pcase tool-name ...))) ...))
    ('nerd-icons (let ((icon-and-face (pcase tool-name ...))) ...))
    ('ascii "- ")
    (_ "")))

(defun matisse--get-success-icon ()
  "Get the appropriate success icon based on current icon mode."
  (pcase matisse-progress-icons-mode
    ('emoji (concat (matisse--apply-icon-face-properties matisse-emoji-icon-success) " "))
    ('nerd-icons (concat (matisse--apply-icon-face-properties matisse-nerd-icon-success matisse-nerd-icon-success-face) " "))
    ('ascii "- ")
    (_ "")))

;; ... 6 more nearly identical functions
```

**Problems:**
- Duplicated `pcase matisse-progress-icons-mode` structure 8 times
- Changes to icon mode handling require 8 edits
- ~100 lines of repetitive code

### New Implementation (Estimated ~50 lines, saves 55 lines)

Unified icon getter with helper functions:

```elisp
;; Core icon data structure
;; Returns: (emoji-icon nerd-icon nerd-face ascii-icon)
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
       ;; ... other tools
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
           nil matisse-ascii-shell-prompt))))

;; Unified icon getter
(defun matisse--get-icon (icon-type &optional tool-name)
  "Get formatted icon for ICON-TYPE based on current icon mode.
For :tool icons, TOOL-NAME specifies which tool.
Icon types: :tool, :success, :performance, :command, :permission, :allow, :deny, :prompt."
  (let ((icon-data (matisse--get-icon-data icon-type tool-name)))
    (pcase matisse-icons-mode  ; Single pcase location!
      ('emoji
       (let ((icon (nth 0 icon-data)))
         (concat (matisse--apply-icon-face-properties icon) " ")))
      ('nerd-icons
       (let ((icon (nth 1 icon-data))
             (face (nth 2 icon-data)))
         (concat (matisse--apply-icon-face-properties icon face) " ")))
      ('ascii
       (let ((text (nth 3 icon-data)))
         (if (string-empty-p text) "" (concat text " "))))
      (_ ""))))

;; Convenience wrappers (optional, for backward compatibility during refactor)
(defun matisse--get-tool-icon (tool-name)
  "Get icon for TOOL-NAME."
  (matisse--get-icon :tool tool-name))

(defun matisse--get-success-icon ()
  "Get success icon."
  (matisse--get-icon :success))

;; ... etc for other icon types (can be inline replaced later)
```

**Benefits:**
- Single `pcase matisse-icons-mode` statement in entire codebase
- Adding new icon type: ~4 lines (one entry in data function)
- Adding new icon mode: ~3 lines (one new pcase clause)
- Reduces ~105 lines to ~50 lines (saves 55 lines)
- Easier to maintain and extend

### Update Strategy

**Phase 1:** Add new unified functions alongside old ones (no breakage)
**Phase 2:** Update call sites incrementally: `(matisse--get-success-icon)` → `(matisse--get-icon :success)`
**Phase 3:** Remove old wrapper functions once all call sites updated

## Phased Implementation Plan

### Phase 0: Preparation (30 minutes)

**Goal:** Set up for safe refactoring.

**Tasks:**
1. ✅ Create this REORGANIZATION_PLAN.md document
2. Create backup branch: `git checkout -b backup/pre-reorganization`
3. Ensure clean working tree: `git status`
4. Run baseline checks:
   ```bash
   make checkdoc  # Document baseline warnings
   make compile   # Ensure current code compiles
   ```
5. Create test script to verify basic functionality after each phase

**Safety checks:**
- [ ] Backup branch created
- [ ] Working tree clean
- [ ] Baseline compilation successful
- [ ] Baseline checkdoc output documented

**Rollback:** Checkout backup branch if issues arise.

---

### Phase 0.5: Fix Naming Conventions (30 minutes)

**Goal:** Ensure all private functions and variables use double-dash (matisse--*) prefix per Emacs conventions.

**Tasks:**

1. Remove autoload markers from 5 non-interactive functions
2. Rename 9 functions: matisse-* → matisse--*
3. Rename 2 variables: matisse-* → matisse--*

Functions to rename:
- matisse-get-latest-conversation-file → matisse--get-latest-conversation-file
- matisse-replay-previous-conversation → matisse--replay-previous-conversation  
- matisse-shell-start → matisse--shell-start
- matisse-test-mode → matisse--test-mode
- matisse-set-model → matisse--set-model
- matisse-set-permission-mode → matisse--set-permission-mode
- matisse-set-progress-icons-mode → matisse--set-progress-icons-mode
- matisse-send → matisse--send
- matisse-start-in-directory → matisse--start-in-directory

Variables to rename:
- matisse-shell-prompt → matisse--shell-prompt
- matisse-shell-prompt-regex → matisse--shell-prompt-regex
### Phase 1: Rename Icon Variables (1 hour)

**Goal:** Rename `matisse-progress-icons-*` → `matisse-icons-*` (breaking change).

**Why first:** Get breaking change out of the way, easier to find/replace before reorganization.

**Tasks:**

1. **Search and document all references:**
   ```bash
   grep -n "matisse-progress-icons" matisse.el | tee /tmp/icon-refs.txt
   # Expected: ~16 references
   ```

2. **Rename defgroup:**
   - Line ~159: `(defgroup matisse-progress-icons` → `(defgroup matisse-icons`
   - Update docstring: "Progress indicator icons" → "Icon display settings"

3. **Rename defcustom:**
   - Line ~174: `(defcustom matisse-progress-icons-mode` → `(defcustom matisse-icons-mode`
   - Update docstring references

4. **Update :group declarations:**
   - Change `:group 'matisse-progress-icons` → `:group 'matisse-icons`
   - Locations: ~10 child defgroup and defcustom declarations

5. **Update code references:**
   - All `pcase matisse-progress-icons-mode` → `pcase matisse-icons-mode`
   - All `(eq matisse-progress-icons-mode` → `(eq matisse-icons-mode`
   - Estimated: ~16 locations in icon getter functions

6. **Update defgroup parent references:**
   - Child groups: `:group 'matisse-progress-icons` → `:group 'matisse-icons`

7. **Verify changes:**
   ```bash
   # Should return 0 matches
   grep -c "matisse-progress-icons" matisse.el

   # Should return ~16 matches (same count as before)
   grep -c "matisse-icons" matisse.el
   ```

8. **Test compilation:**
   ```bash
   make clean
   make compile
   # Should compile without errors
   ```

9. **Test basic functionality:**
   - Load matisse.el in Emacs
   - Check customization group: `M-x customize-group RET matisse-icons RET`
   - Verify `matisse-icons-mode` variable exists
   - Start a matisse session, verify icons display correctly

**Deliverable:**
- Commit: "refactor: rename matisse-progress-icons to matisse-icons"
- Message should note breaking change and migration path

**Safety checks:**
- [ ] Zero references to `matisse-progress-icons` remain
- [ ] Byte compilation successful
- [ ] Checkdoc passes (no new warnings)
- [ ] Customization group accessible
- [ ] Icons display correctly in test session

**Rollback:** `git reset --hard HEAD~1` if issues found.

---

### Phase 2: Create Variables & Constants and Core Utilities Sections (2 hours)

**Goal:** Create two new sections for data declarations (Section 2) and utility functions (Section 3), eliminating forward declarations.

**Why second:** Foundation for reorganization, clear separation of data and code, no functional changes, easy to verify.

**Tasks:**

1. **Create Section 2: Variables & Constants (~line 850):**
   ```elisp
   ;;; Variables & Constants
   ```

2. **Create Section 3: Core Utilities (~line 1060):**
   ```elisp
   ;;; Core Utilities
   ```

3. **Identify all buffer-local variables:**
   ```bash
   grep -n "^(defvar-local" matisse.el | tee /tmp/buffer-local-vars.txt
   # Expected: ~35 variables
   ```

4. **Identify all global state variables:**
   ```bash
   grep -n "^(defvar matisse--" matisse.el | grep -v forward | tee /tmp/global-vars.txt
   ```

5. **Populate Section 2 (Variables & Constants):**
   - Add subsection header: `;;;; Internal Constants`
   - Move all `defconst matisse--*` declarations:
     - matisse--spinner-chars (line ~717)
     - matisse--mode-line-separator (line ~768)
     - matisse--scroll-throttle-ms (line ~5688)
     - Other defconst declarations

   - Add subsection header: `;;;; Dynamic Variables & Data Structures`
   - Move non-customizable `defvar` declarations:
     - matisse-shell-prompt (dynamically updated by matisse--update-shell-prompt)
     - matisse-shell-prompt-regex (dynamically updated by matisse--update-shell-prompt)
     - matisse--slash-commands (completion data, line ~2615)
     - matisse--compact-options (completion data, line ~2630)
   - Note: matisse-command-map stays in Section 1 (user-facing configuration)

   - Add subsection header: `;;;; Buffer-Local State Variables`
   - Copy all `defvar-local` declarations in logical groups:
     - Process state (process, pending-json)
     - Conversation state (conversation-id, message-count)
     - UI state (waiting-for-response, spinner-timer, spinner-index)
     - Shell context (shell-context, initial-directory)
     - Message queue (message-queue, message-counter, current-message-id)
     - Message sections (message-sections, response-sections)
     - And so on...

   - Add subsection header: `;;;; Global State Variables`
   - Copy global state variables:
     - matisse--config
     - matisse--last-selection
     - matisse--selection-timer

6. **Populate Section 3 (Core Utilities):**
   - Add subsection header: `;;;; Utility Functions`
   - Move all utility functions (currently scattered):
     - matisse--debug-log
     - matisse--default-buffer-name, matisse--generate-buffer-name
     - matisse--get-working-directory, matisse--get-project-directory, matisse--get-session-file
     - matisse--get-api-key, matisse--validate-setup
     - matisse--truncate-text, matisse--at-end-of-line-p
     - matisse--update-mode-line, matisse--update-shell-prompt
     - matisse--start-spinner, matisse--stop-spinner, matisse--make-spinner-tick, matisse--finish-current-message
     - matisse--cleanup-on-kill, matisse--kill-all-processes

   - Add subsection header: `;;;; Icon & Formatting Functions`
   - Move all icon and format functions:
     - matisse--apply-icon-face-properties
     - All matisse--get-*-icon functions (will be consolidated in Phase 4)
     - All matisse--format-* functions

7. **Remove old variable and function declarations:**
   - Comment out (don't delete yet) old declarations at:
     - Lines ~40-44 (forward declarations)
     - Lines ~683-770 (scattered defvar-local and defconst)
     - Lines ~928-1400 (utility functions scattered in this range)
     - Lines ~2035-2265 (icon and format functions)
     - Lines ~2615-2630 (slash command data structures)
     - Lines ~4018-4022 (duplicate forward declarations)
     - Lines ~4101-4104 (more duplicates)
     - Lines ~4256-4265 (shell-specific duplicates)
     - Lines ~4322-4352 (more shell duplicates)

8. **Remove forward declaration comments:**
   - Delete lines 40-44 completely (the explicit forward declarations)
   - These are now unnecessary as all variables are declared early

9. **Verify no regressions:**
   ```bash
   make clean
   make compile
   # Should compile without errors
   ```

10. **Verify all variables declared exactly once:**
    ```bash
    # Check for duplicate declarations
    for var in $(grep "^(defvar-local matisse--" matisse.el | awk '{print $2}' | sort); do
      count=$(grep -c "^(defvar-local $var" matisse.el)
      if [ $count -gt 1 ]; then
        echo "DUPLICATE: $var ($count times)"
      fi
    done
    ```

11. **Test basic functionality:**
   - Load matisse.el
   - Start session
   - Verify all features work (history, tokens, queue, etc.)

**Deliverable:**
- Commit: "refactor: create Variables & Constants and Core Utilities sections"
- Message should note split of Section 2 into data declarations (Variables & Constants) and helper functions (Core Utilities), eliminating forward declarations

**Safety checks:**
- [ ] All variables declared exactly once
- [ ] No forward declarations remain
- [ ] Byte compilation successful
- [ ] Checkdoc passes
- [ ] All features functional in test session

**Rollback:** `git reset --hard HEAD~1` if compilation fails.

---

### Phase 3: Reorganize Into New Section Structure (3 hours)

**Goal:** Move all code into the 6 new top-level sections without changing any function implementations.

**Why third:** Pure reorganization, no logic changes, can be verified by git diff showing only moved code.

**Approach:** Work section by section, move code blocks, verify compilation after each section.

**Tasks:**

#### 3.1: Organize Section 1 (Configuration) - 30 min

1. **Add subsection headers:**
   ```elisp
   ;;; Configuration & Customization
   ;;;; Core Settings
   ```

2. **Group core settings** (lines ~55-158):
   - Main defgroup matisse
   - API key, model, temperature, max-tokens
   - Permission mode, system prompt
   - Debug, streaming

3. **Already done:** Icon Configuration (from Phase 1)
   - Add subsection headers:
     ```elisp
     ;;;; Icon Configuration
     ;;;;; Icon Mode & Appearance
     ;;;;; Emoji Icons
     ;;;;; Nerd Font Icons & Faces
     ;;;;; ASCII Icons
     ```

4. **Group Display & Behavior:**
   - Add subsection: `;;;; Display & Behavior`
   - Move: show-progress-indicators, show-file-changes, show-performance-summary
   - Move: verbose-mode, max-progress-message-length
   - Move: show-token-usage, auto-compact-threshold, override-mode-line
   - Move: spinner-interval

5. **Group Keybindings:**
   - Add subsection: `;;;; Keybindings`
   - Move: All `matisse-key-*` defcustom
   - Move: matisse-prefix-key
   - Keep: matisse-command-map definition here (it's configuration)

6. **Group Advanced:**
   - Add subsection: `;;;; Advanced Settings`
   - Move: chunk-size, chunk-threshold, large-paste-threshold
   - Move: debug-log-max-length, large-prompt-threshold
   - Move: buffer-name-function
   - Move: allowed-tools, send-selection-p
   - Move: exit-commands, in-buffer-permission-prompts
   - Move: history-delete-duplicates, language-mode-preferences

7. **Verify compilation:**
   ```bash
   make clean && make compile
   ```

#### 3.2: Organize Section 2 (Infrastructure) - Already partly done in Phase 2

1. **Already done:** State Variables (Phase 2)

2. **Add Core Utilities subsection:**
   - Add header: `;;;; Core Utilities`
   - Move utility functions:
     - matisse--debug-log
     - matisse--default-buffer-name, matisse--generate-buffer-name
     - matisse--get-working-directory, matisse--get-project-directory
     - matisse--get-session-file, matisse-get-latest-conversation-file
     - matisse--get-api-key, matisse--validate-setup
     - matisse--truncate-text, matisse--at-end-of-line-p
     - matisse--update-mode-line, matisse--update-shell-prompt
     - matisse--start-spinner, matisse--stop-spinner, matisse--make-spinner-tick
     - matisse--finish-current-message
     - matisse--cleanup-on-kill, matisse--kill-all-processes

3. **Add Icon & Formatting Functions:**
   - Add header: `;;;; Icon & Formatting Functions`
   - Move: matisse--apply-icon-face-properties
   - Move: All current icon getters (will be consolidated in Phase 4)
   - Move: All format functions (matisse--format-*)

4. **Verify compilation:**
   ```bash
   make clean && make compile
   ```

#### 3.3: Organize Section 3 (Process & Protocol) - 45 min

1. **Add section header:**
   ```elisp
   ;;; Process & Protocol
   ```

2. **Add Process Management subsection:**
   - Header: `;;;; Process Management`
   - Move: matisse--create-process-with-options
   - Move: matisse--start-process-with-resume
   - Move: matisse--process-filter (main dispatcher)
   - Move: matisse--enhanced-process-sentinel
   - Move: matisse--send-message, matisse--send-message-async
   - Move: matisse--send-string-chunked
   - Move: matisse--graceful-shutdown
   - Move: matisse-interrupt

3. **Add JSON Protocol subsection:**
   - Header: `;;;; JSON Protocol`
   - Move: matisse--parse-json-line
   - Move: matisse--extract-assistant-text, matisse--extract-tool-use, matisse--extract-tool-result
   - Move: matisse--format-user-message
   - Move: matisse--add-pending-image
   - Move: matisse--handle-system-message
   - Move: matisse--handle-jsonrpc-notification
   - Move: matisse--handle-session-update
   - Move: matisse--track-tokens, matisse--suggest-compaction, matisse--reset-token-count

4. **Add Control Requests subsection:**
   - Header: `;;;; Control Requests & Responses`
   - Move: matisse--send-control-request
   - Move: matisse--send-control-response
   - Move: matisse--send-control-error
   - Move: matisse--handle-control-request
   - Move: matisse--handle-can-use-tool-request
   - Move: matisse--handle-control-response

5. **Add Slash Commands subsection:**
   - Header: `;;;; Slash Commands`
   - Move: matisse--is-slash-command-p
   - Move: matisse--parse-slash-command, matisse--tokenize-arguments, matisse--parse-command-arguments
   - Move: matisse--format-slash-command
   - Move: matisse--handle-local-command
   - Move: matisse--show-help, matisse--show-command-help
   - Move: matisse--slash-commands, matisse--compact-options (defvar)
   - Move: matisse--slash-command-completion-at-point
   - Move: matisse--get-available-commands
   - Move: matisse--get-temp-file-directory, matisse--write-arg-to-temp-file, matisse--maybe-convert-to-file-reference

6. **Verify compilation:**
   ```bash
   make clean && make compile
   ```

#### 3.4: Organize Section 4 (Permission System) - 30 min

1. **Add section header:**
   ```elisp
   ;;; Permission System
   ```

2. **Add Permission Logic subsection:**
   - Header: `;;;; Permission Logic`
   - Move: matisse--should-auto-allow-tool
   - Move: matisse--decide-tool-permission-shell
   - Move: matisse--decide-tool-permission-with-suggestions
   - Move: matisse--log-permission-decision
   - Move: matisse--show-permission-decision

3. **Add In-Buffer Prompts subsection:**
   - Header: `;;;; In-Buffer Prompts`
   - Move: matisse--prompt-permission-in-buffer
   - Move: matisse--handle-permission-response
   - Move: matisse--process-permission-response
   - Move: matisse--find-string-line-number
   - Move: matisse--create-edit-diff

4. **Verify compilation:**
   ```bash
   make clean && make compile
   ```

#### 3.5: Organize Section 5 (Session & Shell) - 60 min

1. **Add section header:**
   ```elisp
   ;;; Session & Shell Management
   ```

2. **Add Session Operations subsection:**
   - Header: `;;;; Session Operations`
   - Move: matisse-resume
   - Move: matisse-replay-previous-conversation
   - Move: matisse--replay-conversation-from-file
   - Move: matisse--resume-affixation
   - Move: matisse--count-session-messages
   - Move: matisse--get-session-preview

3. **Add Token Tracking subsection:**
   - Header: `;;;; Token Tracking`
   - Move: matisse-show-tokens
   - Note: Core token functions already in Process section

4. **Add Shell Interface subsection:**
   - Header: `;;;; Shell Interface`
   - Move: matisse--initialize-buffer
   - Move: matisse--process-user-input, matisse--process-user-input-internal
   - Move: matisse--handle-return, matisse--handle-newline
   - Move: matisse--insert-prompt, matisse--at-prompt-p
   - Move: matisse--get-input-region, matisse--get-current-response-position
   - Move: matisse-shell--handle-response
   - Move: matisse-shell--write-progress
   - Move: matisse-shell--finish-output, matisse-shell--finish-output-unified
   - Move: matisse-shell--signal-response-complete
   - Move: matisse-shell--create-response-section
   - Move: matisse--auto-scroll-if-at-end, matisse--user-at-end-p
   - Move: matisse--detect-language-mode
   - Move: matisse--overlays-put, matisse--remove-overlays
   - Move: Face definitions (matisse-*-face defface)

5. **Add History Management subsection:**
   - Header: `;;;; History Management`
   - Move: matisse--add-to-history
   - Move: matisse--history-previous, matisse--history-next
   - Move: matisse--history-search-backward, matisse--history-search-forward
   - Move: matisse-history-complete
   - Move: matisse-history-show

6. **Add Message Queue subsection:**
   - Header: `;;;; Message Queue`
   - Move: matisse--enqueue-message
   - Move: matisse--dequeue-message
   - Move: matisse--get-current-message
   - Move: matisse--mark-message-complete
   - Move: matisse--process-queue

7. **Verify compilation:**
   ```bash
   make clean && make compile
   ```

#### 3.6: Organize Section 6 (Modes & API) - 30 min

1. **Add section header:**
   ```elisp
   ;;; Mode Definitions & Public API
   ```

2. **Add Minor Mode subsection:**
   - Header: `;;;; Minor Mode`
   - Move: matisse-mode-map defvar
   - Move: define-minor-mode matisse-mode
   - Move: Mode activation/deactivation hooks

3. **Add Major Mode subsection:**
   - Header: `;;;; Major Mode`
   - Move: matisse-shell-mode-map
   - Move: define-derived-mode matisse-shell-mode
   - Move: matisse-shell-start

4. **Add Public Commands & Interactive Functions subsection:**
   - Header: `;;;; Public Commands & Interactive Functions`
   - Move session management commands:
     - matisse (autoload)
     - matisse-shell (defalias)
     - matisse-start-in-directory
     - matisse-continue
     - matisse-resume
     - matisse-clear
     - matisse-compact
     - matisse-quit
   - Move configuration commands:
     - matisse-set-model
     - matisse-cycle-permission-mode
     - matisse-set-temperature
     - matisse-set-icons-mode (will be renamed from matisse-set-progress-icons-mode in Phase 1)
   - Move display toggle commands:
     - matisse-toggle-progress-indicators
     - matisse-toggle-file-changes
     - matisse-toggle-performance-summary
   - Move utility commands:
     - matisse-show-tokens
     - matisse-show-stderr
     - matisse-history-show
     - matisse-history-complete
     - matisse-menu
     - matisse-transient-menu

5. **Move matisse--route-to-shell:**
   - Currently at line 45 (top of file)
   - Move to Shell Interface subsection (Section 5)
   - This eliminates the last functional forward dependency

7. **Verify compilation:**
   ```bash
   make clean && make compile
   ```

#### 3.7: Final verification - 15 min

1. **Check section count:**
   ```bash
   grep -c "^;;; " matisse.el
   # Should be ~9 (including Commentary, Code, ends here)
   # So 7 functional sections
   ```

2. **Check no forward declarations:**
   ```bash
   grep -c "Forward declaration" matisse.el
   # Should be 0
   ```

3. **Full test:**
   ```bash
   make clean
   make checkdoc
   make compile
   ```

4. **Functional test:**
   - Load matisse.el
   - Start new session: `M-x matisse`
   - Test resume: `M-x matisse-resume`
   - Test permissions: Send message requiring permission
   - Test history: Navigate with M-p / M-n
   - Test slash commands: `/compact`, `/clear`
   - Test tokens: `M-x matisse-show-tokens`

**Deliverable:**
- Commit: "refactor: reorganize into 6 top-level sections"
- Message should list the new section structure

**Safety checks:**
- [ ] Exactly 6 functional sections
- [ ] Zero forward declarations
- [ ] Byte compilation successful
- [ ] Checkdoc passes
- [ ] All features functional

**Rollback:** `git reset --hard HEAD~1` if major issues found.

---

### Phase 4: Consolidate Icon Functions (2 hours)

**Goal:** Replace 8 duplicate icon getter functions with unified implementation.

**Why fourth:** After reorganization, safe to refactor implementation details.

**Strategy:** Add new functions alongside old ones, update incrementally, remove old ones.

**Tasks:**

#### 4.1: Add new unified icon functions - 30 min

1. **In Section 2 (State Variables & Infrastructure), Icon & Formatting subsection:**

2. **Add icon data function:**
   ```elisp
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
          ;; ... all other tools ...
          (_ (list matisse-emoji-icon-default matisse-nerd-icon-default
                   matisse-nerd-icon-default-face "- "))))
       (:success
        (list matisse-emoji-icon-success matisse-nerd-icon-success
              matisse-nerd-icon-success-face "- "))
       ;; ... all other icon types ...
       ))
   ```

3. **Add unified icon getter:**
   ```elisp
   (defun matisse--get-icon (icon-type &optional tool-name)
     "Get formatted icon for ICON-TYPE based on current icon mode.
   For :tool icons, TOOL-NAME specifies which tool.
   Icon types: :tool, :success, :performance, :command, :permission, :allow, :deny, :prompt."
     (let ((icon-data (matisse--get-icon-data icon-type tool-name)))
       (pcase matisse-icons-mode
         ('emoji
          (let ((icon (nth 0 icon-data)))
            (concat (matisse--apply-icon-face-properties icon) " ")))
         ('nerd-icons
          (let ((icon (nth 1 icon-data))
                (face (nth 2 icon-data)))
            (concat (matisse--apply-icon-face-properties icon face) " ")))
         ('ascii
          (let ((text (nth 3 icon-data)))
            (if (string-empty-p text) "" (concat text " "))))
         (_ ""))))
   ```

4. **Keep old functions temporarily as wrappers:**
   ```elisp
   ;; Backward compatibility wrappers (temporary)
   (defun matisse--get-tool-icon (tool-name)
     "Get icon for TOOL-NAME. DEPRECATED: Use (matisse--get-icon :tool tool-name)."
     (matisse--get-icon :tool tool-name))

   (defun matisse--get-success-icon ()
     "Get success icon. DEPRECATED: Use (matisse--get-icon :success)."
     (matisse--get-icon :success))

   ;; ... etc for all 8 functions
   ```

5. **Verify compilation:**
   ```bash
   make clean && make compile
   # Should compile without warnings (wrappers ensure compatibility)
   ```

#### 4.2: Update call sites incrementally - 60 min

1. **Find all call sites:**
   ```bash
   grep -n "matisse--get-.*-icon" matisse.el | grep -v "^[0-9]*:(defun" | tee /tmp/icon-call-sites.txt
   # Expected: ~50-60 call sites
   ```

2. **Update by icon type** (safer than by location):

   **Success icons:**
   ```bash
   # Find all
   grep -n "(matisse--get-success-icon)" matisse.el
   # Replace each with (matisse--get-icon :success)
   ```

   **Performance icons:**
   ```bash
   grep -n "(matisse--get-performance-icon)" matisse.el
   # Replace with (matisse--get-icon :performance)
   ```

   **Command icons:**
   ```bash
   grep -n "(matisse--get-command-icon)" matisse.el
   # Replace with (matisse--get-icon :command)
   ```

   **Permission icons:**
   ```bash
   grep -n "(matisse--get-permission-icon)" matisse.el
   # Replace with (matisse--get-icon :permission)
   ```

   **Allow icons:**
   ```bash
   grep -n "(matisse--get-allow-icon)" matisse.el
   # Replace with (matisse--get-icon :allow)
   ```

   **Deny icons:**
   ```bash
   grep -n "(matisse--get-deny-icon)" matisse.el
   # Replace with (matisse--get-icon :deny)
   ```

   **Shell prompt:**
   ```bash
   grep -n "(matisse--get-shell-prompt-character)" matisse.el
   # Replace with (matisse--get-icon :prompt)
   ```

   **Tool icons:**
   ```bash
   grep -n "(matisse--get-tool-icon" matisse.el
   # Replace with (matisse--get-icon :tool tool-name)
   # Note: Keep the tool-name argument!
   ```

3. **After each icon type, verify compilation:**
   ```bash
   make clean && make compile
   ```

4. **Verify all old call sites updated:**
   ```bash
   # Should return 0 (or only the defun lines)
   grep -c "matisse--get-.*-icon)" matisse.el | grep -v defun
   ```

#### 4.3: Remove old wrapper functions - 15 min

1. **Delete old function definitions:**
   - Remove `defun matisse--get-tool-icon`
   - Remove `defun matisse--get-success-icon`
   - Remove `defun matisse--get-performance-icon`
   - Remove `defun matisse--get-command-icon`
   - Remove `defun matisse--get-permission-icon`
   - Remove `defun matisse--get-allow-icon`
   - Remove `defun matisse--get-deny-icon`
   - Remove `defun matisse--get-shell-prompt-character`

2. **Verify no references remain:**
   ```bash
   # Should return 2 matches (the new unified functions)
   grep -c "defun matisse--get.*icon" matisse.el
   ```

3. **Full verification:**
   ```bash
   make clean
   make compile
   make checkdoc
   ```

4. **Functional test:**
   - Start session
   - Verify all icons display correctly:
     - Tool icons (read, write, bash, etc.)
     - Success icons (after operations)
     - Permission icons (in permission prompts)
     - Shell prompt icon
   - Test all three icon modes:
     - `M-x matisse-set-progress-icons-mode RET emoji`
     - `M-x matisse-set-progress-icons-mode RET nerd-icons`
     - `M-x matisse-set-progress-icons-mode RET ascii`

**Deliverable:**
- Commit: "refactor: consolidate icon getter functions"
- Message should note ~55 lines saved, single pcase location for icon modes

**Safety checks:**
- [ ] All old icon functions removed
- [ ] All call sites updated to new API
- [ ] Byte compilation successful
- [ ] All icons display correctly in all modes
- [ ] No visual regressions

**Rollback:** `git reset --hard HEAD~1` if icon display breaks.

---

### Phase 5: Final Cleanup & Documentation (1 hour)

**Goal:** Clean up any remaining issues, update documentation.

**Tasks:**

1. **Check for stale comments:**
   ```bash
   grep -n "TODO\|FIXME\|XXX\|HACK" matisse.el
   # Review and update any stale comments
   ```

2. **Update file header commentary:**
   - Update line counts in internal comments if any
   - Verify Commentary section is accurate

3. **Run full quality checks:**
   ```bash
   make clean
   make checkdoc
   make compile
   ```

4. **Update CLAUDE.md project instructions:**
   - Document new section structure
   - Update line number references
   - Note breaking changes

5. **Create migration guide for users:**
   - Document icon variable rename
   - Provide before/after examples

6. **Final functional test:**
   - Full workflow test:
     - Start new session
     - Send messages
     - Use permissions (accept/deny)
     - Use history
     - Use slash commands
     - Resume session
     - Check tokens
     - Clear session
   - Test all icon modes
   - Test all permission modes

7. **Performance check:**
   ```bash
   # Load time benchmark
   emacs --batch -l matisse.el --eval "(message \"Load successful\")"
   ```

**Deliverable:**
- Commit: "docs: update documentation for reorganization"
- Update REORGANIZATION_PLAN.md status to "Completed"

**Safety checks:**
- [ ] All quality checks pass
- [ ] Full workflow test successful
- [ ] Documentation updated
- [ ] No performance regression

---

## Risk Mitigation

### Compilation Failures
- **Prevention:** Compile after each phase
- **Detection:** `make compile` returns non-zero
- **Recovery:** `git reset --hard HEAD~1`, review error, fix, retry

### Functional Regressions
- **Prevention:** Test basic functionality after each phase
- **Detection:** Feature doesn't work in test session
- **Recovery:** `git reset --hard HEAD~1`, review changes, fix, retry

### Icon Display Issues (Phase 4)
- **Prevention:** Update call sites incrementally by icon type, test each
- **Detection:** Icons missing or displaying incorrectly
- **Recovery:** `git reset --hard HEAD~1`, review call site updates, fix, retry

### Performance Regression
- **Prevention:** Keep implementation changes minimal (only icon consolidation)
- **Detection:** Noticeable slowdown in load time or operation
- **Recovery:** Profile with `M-x profiler-start`, identify issue, revert if needed

### Data Loss During Session
- **Prevention:** Don't modify session storage logic
- **Detection:** History or resume not working
- **Recovery:** Session files are untouched, can resume with old code

## Success Criteria

### Code Quality
- [ ] Byte compilation: 0 errors, 0 warnings
- [ ] Checkdoc: 0 new warnings
- [ ] Section count: 7 functional sections (down from 45+)
- [ ] Forward declarations: 0 (down from 10+)
- [ ] Lines saved: ~55+ (from icon consolidation)

### Functionality
- [ ] All existing features work identically
- [ ] No visual regressions (icons, prompts, display)
- [ ] No performance regressions (< 5% load time increase acceptable)
- [ ] Session resume works correctly
- [ ] History preserved

### Documentation
- [ ] CLAUDE.md updated with new structure
- [ ] Breaking changes documented
- [ ] Migration guide provided
- [ ] Code comments updated

### User Impact
- [ ] Single breaking change: Icon variable rename (documented)
- [ ] Simple migration: 2 variable renames in user config
- [ ] Benefit: Better organized customization groups
- [ ] No data loss: All sessions preserved

## Timeline Estimate

| Phase | Duration | Cumulative |
|-------|----------|------------|
| Phase 0: Preparation | 30 min | 30 min |
| Phase 0.5: Fix Naming Conventions | 30 min | 30 min |
| Phase 1: Rename Icons | 1 hour | 1.5 hours |
| Phase 2: State Variables | 1.5 hours | 3 hours |
| Phase 3: Reorganize Sections | 3 hours | 6 hours |
| Phase 4: Consolidate Icons | 2 hours | 8 hours |
| Phase 5: Cleanup & Docs | 1 hour | 9 hours |

**Total: ~10 hours** (one full work day)

## Post-Implementation

### Monitoring
- Watch for user reports of issues
- Monitor GitHub issues for icon-related problems
- Check for any unexpected compilation issues

### Future Improvements
- Consider consolidating format functions (similar pattern to icons)
- Consider merging duplicate permission decision functions
- Evaluate if any sections can be further simplified

### Documentation Updates
- Update README with new structure
- Update contributor guide
- Create architecture diagram showing 6 sections

---

**End of Plan**
