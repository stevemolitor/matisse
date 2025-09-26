# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Matisse is an Emacs package that provides a comint-based interface to Claude Code using streaming JSON I/O. It creates a native Emacs experience for interacting with Claude Code, avoiding issues with terminal emulators like vterm or eat.

## Development Commands

### Building and Testing

```bash
# Run all checks (checkdoc, compile, test)
make all

# Run checkdoc on all elisp files
make checkdoc

# Byte compile elisp files
make compile

# Clean compiled files
make clean
```

### Loading and Testing in Emacs

```bash
# Byte compile and check for errors
/Applications/Emacs.app/Contents/MacOS/bin/emacs --batch -L . --eval "(setq sentence-end-double-space nil)" -f batch-byte-compile matisse.el

# Evaluate elisp code (emacsclient must be used with -n to avoid blocking)
/Applications/Emacs.app/Contents/MacOS/bin/emacsclient -n -e '(+ 2 2)'

# Load the file in a running Emacs instance
/Applications/Emacs.app/Contents/MacOS/bin/emacsclient -n -e '(load-file "/Users/steve/repos/matisse/main/matisse.el")'
```

**Important**: Always use `emacsclient -n` (non-blocking) for command-line elisp evaluation. The `$EMACS` environment variable points to a GUI app and is not suitable for command-line use.

## Architecture

### Core Components

1. **matisse.el** - Single-file package containing all functionality:
   - Process management for Claude Code CLI
   - Streaming JSON protocol implementation
   - Shell mode with comint-style interface
   - Permission system with multiple modes
   - Progress indicators and file change tracking
   - Session management (new, continue, resume)

### Communication Protocol

Matisse communicates with Claude Code CLI using the streaming JSON protocol (`--input-format stream-json --output-format stream-json`):

**User messages sent to Claude**:
```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Your message"}]}}
```

**Message types received from Claude**:
- `{"type":"system","subtype":"init","session_id":"..."}` - Initialization
- `{"type":"assistant","message":{...}}` - Claude's responses and tool usage
- `{"type":"user","message":{...}}` - Tool results from internal operations
- `{"type":"result","duration_ms":...,"total_cost_usd":...}` - Completion metrics
- `{"type":"control_request","request_id":"..."}` - Permission requests (STDIO protocol)
- `{"type":"control_response","response":{...}}` - Responses to control commands

### Process Management

**Process creation**: `matisse--create-process-with-options` (line 2615)
- Creates Claude Code process with options: `--permission-mode`, `--permission-prompt-tool stdio`, `--input-format stream-json`, `--output-format stream-json`
- Supports `--continue` and `--resume SESSION-ID` flags
- Sets `ANTHROPIC_API_KEY` and `MATISSE_BUFFER_NAME` environment variables

**Process filter**: `matisse--process-filter`
- Parses streaming JSON output line by line
- Routes messages based on type: system, assistant, user, result, control_request, control_response
- Handles partial JSON lines with buffer accumulation

**Process sentinel**: `matisse--enhanced-process-sentinel` (line 2711)
- Handles process exit, interruption, and abnormal termination

### Permission System

**Permission modes** (configurable via `matisse-permission-mode`):
- `"default"` - Normal permissions with y-or-n-p prompts
- `"bypassPermissions"` - Skip all permission checks
- `"plan"` - Plan mode for planning tasks
- `"acceptEdits"` - Auto-accept file edit operations

**Permission decisions**:
- `matisse--decide-tool-permission-with-suggestions` (line 1321) - Main permission logic with support for "always allow" suggestions from Claude
- `matisse--decide-tool-permission-shell` (line 1251) - Simple y-or-n-p based decisions
- Read-only tools (Read, Grep, Glob, WebSearch, WebFetch) are always allowed
- Write tools (Bash, Write, Edit, MultiEdit) require permission unless in bypass mode

**STDIO Control Protocol**:
- Claude sends `control_request` with `subtype: "can_use_tool"`
- Matisse responds with `control_response` containing `behavior: "allow"` or `"deny"`
- Can include `updatedPermissions` to persistently change permission mode

### Shell Implementation

**Buffer structure**:
- Uses `fundamental-mode` as base (not comint-mode)
- Manual read-only region management for output vs input areas
- Response sections tracked in `matisse--message-sections` hash table
- Each message has start/end markers for later manipulation

**Key entry points**:
- `matisse-shell` (line 2991) - Create new session
- `matisse-shell-switch` (line 3011) - Switch between existing sessions
- `matisse-continue` (line 3032) - Continue previous conversation with `--continue`
- `matisse-resume` - Resume specific session with `--resume SESSION-ID`

**Message queue**:
- `matisse--message-queue` - Unified queue for user messages and responses
- Messages sent via `matisse--send-message-unified`
- Queue processing ensures proper sequencing

**Response handling**:
- `matisse-shell--handle-response` (line 5044) - Main response handler
- Accumulates streaming text in response sections
- Progress indicators for tool usage
- File change summaries after Write/Edit operations

### Progress Indicators

**Icon modes** (`matisse-progress-icons-mode`):
- `'ascii` - Simple ASCII characters (default)
- `'emoji` - Emoji icons (📖, ✏️, 💻, etc.)
- `'nerd-icons` - Nerd Font icons with customizable faces

**Display features** (customizable):
- `matisse-show-progress-indicators` - Tool usage indicators (e.g., "📖 Reading file.txt...")
- `matisse-show-file-changes` - File change summaries (e.g., "✅ Updated config.json")
- `matisse-show-performance-summary` - Performance metrics (timing, cost, tokens)

### Session Management

**Session tracking**:
- `matisse--conversation-id` - Current session ID from Claude
- Sessions are stored by Claude Code CLI in `~/.config/claude`
- Session history available via `matisse-shell-list` with `M-x matisse-resume`

**Continue vs Resume**:
- `--continue` - Continue from last conversation (any session)
- `--resume SESSION-ID` - Resume specific session by ID

### Selection Context

**Automatic context tracking**:
- `matisse-send-selection-p` - Enable/disable automatic selection context (default: t)
- Tracks cursor position and text selections across file buffers
- Appends context to user messages in VSCode-style format: `@/path/to/file.txt#L5:10-L9:25`
- Mode-line indicator shows current context: "🤖 in matisse.el" or "🤖 2 lines selected"

## Emacs Lisp Guidelines

### Vector and Backquote Syntax

**CRITICAL**: Literal vector syntax `[...]` does NOT support comma interpolation in backquotes.

```elisp
;; WRONG - will not interpolate variable
`((content . [((type . "text") (text . ,variable))]))

;; RIGHT - use (vector ...) for interpolation
`((content . ,(vector (list (cons 'type "text") (cons 'text variable)))))

;; OK - literal vectors work for static content only
[("string1" "string2")]
```

This issue causes malformed JSON that can crash Claude Code when using the streaming JSON protocol.

### API Key Management

```elisp
;; Priority order for API key:
;; 1. matisse-api-key variable (string or function)
;; 2. auth-source (machine: anthropic.com, login: apikey)
;; 3. ANTHROPIC_API_KEY environment variable
```

### Process Environment

The Claude Code process runs with these environment variables:
- `ANTHROPIC_API_KEY` - API key for Claude
- `MATISSE_BUFFER_NAME` - Current buffer name for context

## Key Variables and State

### Buffer-local variables:
- `matisse--process` - Claude Code process object
- `matisse--conversation-id` - Current session ID
- `matisse--message-counter` - Message ID generator
- `matisse--message-queue` - Queue of pending messages
- `matisse--message-sections` - Hash table tracking response sections
- `matisse--current-permission-mode` - Current permission mode
- `matisse--pending-images` - Queue of images to send with next message
- `matisse--shell-context` - Shell integration context (buffer-name, initial-directory, etc.)

### Global state:
- `matisse--available-commands` - Discovered slash commands from Claude CLI
- `matisse--available-models` - Discovered models from Claude CLI

## Common Patterns

### Sending messages to Claude

```elisp
;; Format message as JSON and send
(let ((message `((type . "user")
                 (message . ((role . "user")
                            (content . ,(vector (list (cons 'type "text")
                                                     (cons 'text "Your message")))))))))
  (process-send-string matisse--process
                      (concat (json-encode message) "\n")))
```

### Handling streaming responses

```elisp
;; Process filter accumulates partial JSON lines
(defun matisse--process-filter (process output)
  ;; Append to buffer
  ;; Split on newlines
  ;; Parse each complete JSON line
  ;; Route based on message type)
```

### Managing read-only regions

```elisp
;; Temporarily allow writes to read-only buffer
(let ((inhibit-read-only t))
  (insert "Some text")
  (set-marker matisse--output-start-marker (point)))
```

## Testing and Debugging

### Enable debug logging

```elisp
(setq matisse-debug t)  ;; Enable debug messages
(setq shell-maker-logging t)  ;; Enable shell-maker logging (if applicable)
```

Debug messages appear in *Messages* buffer.

### Check process status

```elisp
M-: (process-live-p matisse--process)
M-: (process-status matisse--process)
```

### View process buffers

- ` *matisse-process-BUFFER-NAME*` - Process stdout
- ` *matisse-stderr-BUFFER-NAME*` - Process stderr

## Notes

- Server must be running for hook callbacks: Matisse auto-starts Emacs server on load
- Single file architecture: All code in matisse.el (no separate files)
- No external dependencies beyond shell-maker package
- Uses native Emacs JSON parsing (json.el)
