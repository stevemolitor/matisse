# Matisse - Emacs Comint Interface to Claude Code

![Matisse Self-Potrait](https://upload.wikimedia.org/wikipedia/commons/f/f8/Henri_Matisse%2C_1918%2C_Portrait_du_peintre_%28Autoportrait%2C_Self-portrait%29%2C_oil_on_canvas%2C_65_x_54_cm%2C_Matisse_Museum_%28Le_Cateau%29.jpg?20131002122047)

<sub>Portrait du peintre, 1918 by Henri Matisse.  Source: Wikimedia Commons</sub>

_Warning: this is an experimental, alpha package. It almost certainly has bugs and the interface will change._

## Description
Matisse provides a comint-based interface to Claude using [shell-maker](https://github.com/xenodium/shell-maker). This provides a native Emacs experience for interacting with Claude Code, avoiding the issues running Claude inside Emacs terminal emulators like vterm or eat. OTOH matisse does not have all the niceties that the Claude Code CLI provides. Some of these things we can build into matisse; others may prove challenging. We'll see how it goes.

![Matisse Screenshot](https://github.com/stevemolitor/images/blob/main/matisse.png)

## Requirements

- Emacs 30.1 or later (older versions _might_ work)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and accessible
- [shell-maker](https://github.com/xenodium/shell-maker) package (version 0.78.2 or later)
- An Anthropic API key

## Installation

### Using use-package with :vc (Emacs 30+)

```elisp
(use-package matisse
  :vc (:url "https://github.com/stevemolitor/matisse" :rev :newest))
```

### Using straight.el

```elisp
(straight-use-package
 '(matisse :type git :host github :repo "stevemolitor/matisse"))
```

### Manual Installation

Install [shell-maker](https://github.com/xenodium/shell-maker). Then:

1. Clone this repository:
   ```bash
   git clone https://github.com/stevemolitor/matisse.git
   ```

2. Add to your Emacs configuration:
   ```elisp
   (add-to-list 'load-path "/path/to/matisse")
   (require 'matisse)
   ```

## Configuration

### Basic Setup

Set your API key (choose one method):

```elisp
;; Method 1: Direct configuration (not recommended for public configs)
(setq matisse-api-key "your-api-key-here")

;; Method 2: Using a function
(setq matisse-api-key (lambda () (getenv "ANTHROPIC_API_KEY")))

;; Method 3: Using auth-source (recommended)
;; Add to ~/.authinfo.gpg:
;; machine anthropic.com login apikey password your-api-key-here
```

### Optional Configuration

```elisp
;; Set the path to Claude Code executable if not in PATH
(setq matisse-claude-code-path "/usr/local/bin/claude")

;; Choose default model
(setq matisse-default-model "claude-sonnet-4-20250514")  ; default

;; Set temperature (0.0 to 1.0)
(setq matisse-temperature 0.7)

;; Set max tokens for responses
(setq matisse-max-tokens 4096)

;; Set a system prompt
(setq matisse-system-prompt "You are a helpful assistant.")

;; Disable streaming (not recommended)
(setq matisse-streaming nil)

;; Enable/disable automatic selection context (default: t)
(setq matisse-send-selection-p t)

;; Adjust spinner/blink speed (default: 0.15 seconds)
(setq matisse-spinner-interval 0.2)  ; Slower blinking
(setq matisse-spinner-interval 0.1)  ; Faster blinking
```

### Permission Modes

Matisse supports several permission modes that control how Claude's tool usage is authorized. You can cycle through modes with `M-x matisse-cycle-permission-mode`:

| Mode | Description |
|------|-------------|
| `default` | Normal permissions with confirmation prompts |
| `plan` | Plan mode for planning tasks |
| `acceptEdits` | Auto-accept file edits (Edit, Write, MultiEdit) |
| `yolo` | Client-side auto-allow all permissions (opt-in, see below) |
| `bypassPermissions` | Skip all permission checks (startup only) |

The default cycle order is: **plan -> default -> acceptEdits -> plan**.

```elisp
;; Set the initial permission mode (default: "default")
(setq matisse-permission-mode "default")
```

#### YOLO Mode

YOLO mode auto-approves all permission requests client-side. Unlike `bypassPermissions`, the Claude Code CLI still runs in `default` mode and sends permission requests over the STDIO protocol -- Matisse simply auto-responds "allow" to all of them. This means the permission protocol is still flowing and you can toggle YOLO off mid-session to return to prompted mode.

YOLO mode is excluded from the permission cycle by default. To include it:

```elisp
(setq matisse-enable-yolo-mode t)
```

With this enabled, the cycle becomes: **plan -> default -> acceptEdits -> yolo -> plan**.

### Selection Context Tracking

Matisse automatically tracks your text selections and cursor position, providing Claude with context about what code you're working on. This feature is enabled by default and works seamlessly in the background.

#### How It Works

- **Automatic Detection**: Matisse monitors your selections across all file buffers (but not matisse shell buffers)
- **Smart Context**: When you send a message to Claude, your current selection context is automatically appended
- **VSCode-Style References**: Selection context is formatted as `@/path/to/file.txt#L5:10-L9:25` (line:character positions)
- **Mode-line Display**: The matisse mode-line shows your current context:
  - `🤖 in matisse.el` - when cursor is positioned in a file
  - `🤖 2 lines selected` - when text is selected
  - `🤖⠋ in matisse.el` - with spinner animation during requests

#### Configuration

```elisp
;; Enable selection context tracking (default: t)
(setq matisse-send-selection-p t)

;; Disable selection context tracking
(setq matisse-send-selection-p nil)
```

#### Examples

When you select code and send a message to Claude:

```
Your message here

@/Users/steve/repos/matisse/matisse.el#L528:15-L538:20 - (defun matisse--update-mode-line ()
  "Update the mode line with current spinner state and selection info."
  (let* ((spinner-part (if matisse--waiting-for-response
                           (concat " 🤖" (nth matisse--spinner-index matisse--spinner-chars))
                         " 🤖"))
         (selection-part (matisse--format-selection-status)))
    (setq matisse--mode-line-format
          (if selection-part
              (concat spinner-part " " selection-part)
            spinner-part))
    (force-mode-line-update t)))
```

Claude receives both your message and the selected code context, making it easier to provide targeted assistance.

### Modeline Spinner

Matisse adds spinner to the mode line when waiting for a response from Claude. If you have a custom modeline configuration and you don't see the spinner, you can add it to your modeline:

```elisp
(setq-default
 mode-line-format
 (list
  ;; matisse lighter
  '(:eval (when (bound-and-true-p matisse-mode) matisse--mode-line-format))

  ;; the rest of your modeline format...
  ))
```

## Usage

### Starting a Session

```
M-x matisse-shell
```

This opens a new Matisse buffer where you can interact with Claude Code.

### Basic Commands

- Type your message and press `RET` to send
- Use shift-return to enter a newline without sending.
- `exit` - Exit the matisse session and close its buffer
- Type `help` - Show available commands
- Type `clear` - Clear the conversation
- `C-c C-c` - Interrupt current request
- `C-c C-o` - Clear the buffer
- `C-x C-s` - Save session transcript
- `M-p` - Cycle backwards through input history

The matisse buffer is a regular Emacs buffer, so things like `M-/` (`dabbrev-expand`), marking, selecting, etc work like normal. 

### Model Management

```elisp
;; Switch models interactively
M-x matisse-set-model

;; Set temperature
M-x matisse-set-temperature
```

### Key Bindings

The Matisse shell inherits key bindings from comint-mode and adds:

- `RET` - Send input to Claude
- `S-RET` - Insert newline without sending
- `C-c C-c` - Interrupt current generation
- `C-c C-o` - Clear the buffer
- `C-x C-s` - Save session transcript
- `M-p` - Previous input from history
- `M-n` - Next input from history
- `C-c C-r` - Search input history

## Progress Context Display

Matisse provides real-time visibility into Claude's internal operations through smart progress indicators:

### Features

**Tool Usage Indicators**: See what Claude is doing in real-time
- 📖 Reading README.md...
- ✏️ Editing config.json...
- 💻 Running npm install...
- 🔍 Searching for "function"...

**File Change Summaries**: Get notified when files are modified
- ✅ Updated README.md
- ✅ File written successfully

**Performance Metrics**: Track timing, cost, and token usage
- ⏱️ Completed in 12.3s, $0.045, 342 tokens

### Configuration

```elisp
;; Enable/disable progress indicators (default: t)
(setq matisse-show-progress-indicators t)

;; Enable/disable file change summaries (default: t)  
(setq matisse-show-file-changes t)

;; Enable/disable performance summaries (default: nil)
(setq matisse-show-performance-summary nil)

;; Configure icon display mode (default: 'ascii)
;; Options: 'emoji (emoji icons), 'nerd-icons (Nerd Font icons), 'ascii (simple "-")
(setq matisse-progress-icons-mode 'nerd-icons)

;; Adjust icon size (default: 1.0)
(setq matisse-icons-scale-factor 1.2)
```

### Interactive Commands

```elisp
;; Toggle progress display options
M-x matisse-toggle-progress-indicators
M-x matisse-toggle-file-changes
M-x matisse-toggle-performance-summary
M-x matisse-toggle-progress-icons
```

### Customizing Icon Colors

#### Using ef-themes Integration

If you use [ef-themes](https://github.com/protesilaos/ef-themes), you can integrate Matisse progress icon colors with your theme's color palette. This ensures the icons adapt automatically when you switch between ef-themes:

```elisp
(defun my-matisse-ef-themes-integration ()
  "Customize Matisse progress icon faces using ef-themes colors."
  (ef-themes-with-colors
    (custom-set-faces
     ;; File operations
     `(matisse-nerd-icon-read-face ((,c :foreground ,blue-cooler)))
     `(matisse-nerd-icon-write-face ((,c :foreground ,green)))
     `(matisse-nerd-icon-edit-face ((,c :foreground ,yellow-warmer)))
     `(matisse-nerd-icon-multiedit-face ((,c :foreground ,yellow)))
     
     ;; Command and search operations  
     `(matisse-nerd-icon-bash-face ((,c :foreground ,magenta)))
     `(matisse-nerd-icon-grep-face ((,c :foreground ,red-cooler)))
     `(matisse-nerd-icon-glob-face ((,c :foreground ,red-warmer)))
     
     ;; Task and web operations
     `(matisse-nerd-icon-task-face ((,c :foreground ,cyan)))
     `(matisse-nerd-icon-webfetch-face ((,c :foreground ,blue)))
     `(matisse-nerd-icon-todowrite-face ((,c :foreground ,magenta-cooler)))
     
     ;; Status indicators
     `(matisse-nerd-icon-success-face ((,c :foreground ,green-warmer)))
     `(matisse-nerd-icon-performance-face ((,c :foreground ,cyan-warmer)))
     `(matisse-nerd-icon-default-face ((,c :foreground ,fg-dim)))
     )))

;; Hook the function to ef-themes
(add-hook 'ef-themes-post-load-hook #'my-matisse-ef-themes-integration)

;; Set progress icons mode to see the colors
(setq matisse-progress-icons-mode 'nerd-icons)
```

#### Manual Color Customization

You can also manually customize individual icon faces:

```elisp
(custom-set-faces
 '(matisse-nerd-icon-read-face ((t :foreground "#6A9FB5")))
 '(matisse-nerd-icon-write-face ((t :foreground "#90A959")))
 '(matisse-nerd-icon-edit-face ((t :foreground "#D4843E")))
 ;; ... customize other faces as needed
 )

## Buffer Display Configuration

To position Matisse buffers in a side window (recommended for a better coding workflow), add this to your Emacs configuration:

```elisp
(add-to-list 'display-buffer-alist
             '("^\\*matisse"
               (display-buffer-in-side-window)
               (side . right)
               (window-width . 0.33)
               (no-delete-other-windows . t)))
```

This configuration:
- Opens Matisse buffers in a side window on the right side of the frame
- Sets the width to 33% of the frame width
- Prevents the window from being deleted when using `delete-other-windows`
- Keeps your main coding buffers visible while interacting with Claude

## How It Works

Matisse using the [Claude Code SDK](https://docs.anthropic.com/en/docs/claude-code/sdk#streaming-json-input) with streaming JSON input and output

1. **User Input**: Your messages are formatted as JSON lines and sent to the Claude Code process
2. **Streaming Output**: Claude's responses are streamed back as JSON objects
3. **Real-time Display**: Responses are parsed and displayed in real-time as they arrive
4. **Session Management**: The shell-maker framework handles history, transcripts, and buffer management

### Streaming JSON Protocol

User messages are sent in this format:
```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Your message here"}]}}
```

Claude Code streams back various JSON message types:

**System messages** (initialization and other system events):
```json
{"type":"system","subtype":"init","session_id":"..."}
```

**Assistant messages** (Claude's responses and tool usage):
```json
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Response text"},{"type":"tool_use","name":"Read","input":{"file_path":"..."}}]}}
```

**User messages** (tool results from Claude's internal tool operations):
```json
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"...","content":"..."}]}}
```

**Result messages** (completion with performance metrics):
```json
{"type":"result","duration_ms":1234,"total_cost_usd":0.045,"usage":{"output_tokens":342}}
```

Matisse parses these messages and displays:
- Progress indicators with icons (📖 Reading file.txt...)
- File change summaries (✅ Updated config.json)
- Performance metrics (⏱️ Completed in 12.3s, $0.045, 342 tokens)

## Troubleshooting

### Claude Code not found

Ensure Claude Code is installed and accessible:
```bash
which claude
```

If not in PATH, set the full path:
```elisp
(setq matisse-claude-code-path "/full/path/to/claude")
```

### API Key Issues

Verify your API key is correctly configured:
```elisp
M-: (matisse--get-api-key)
```

### Process Issues

If the Claude process becomes unresponsive, start a new session:

```elisp
M-x matisse-shell
```

### Debug Mode

Enable logging for troubleshooting:
```elisp
(setq shell-maker-logging t)
```

Check the log buffer: `*matisse-log*`

## Missing Features / TODO

- [ ] Support --continue
- [ ] Support --resume
- [ ] compact, clear
- [ ] Matisse session management
- [ ] Commands to send context to Claude
- [ ] Hook support, or at least a note in the README explaining how to create hooks using `emacsclient --eval {elisp}`
- [ ] MCP server support, to implement at least some of the IDE integration that tools  [Monet](https://github.com/stevemolitor/monet) provide
- [ ] Diff display of changes
- [ ] Support pasting images
- [ ] better permissions checking, perhaps by using a [custom permissions prompt tool](https://docs.anthropic.com/en/docs/claude-code/sdk#custom-permission-prompt-tool)
- [ ] and more…

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- Built on top of [shell-maker](https://github.com/xenodium/shell-maker) by Álvaro Ramírez
- Inspired by [chatgpt-shell](https://github.com/xenodium/chatgpt-shell)
- Powered by [Claude](https://www.anthropic.com/claude) from Anthropic

## Author

Steve Molitor

## See Also

- [Claude Code Documentation](https://docs.anthropic.com/en/docs/claude-code)
- [shell-maker](https://github.com/xenodium/shell-maker)
- [chatgpt-shell](https://github.com/xenodium/chatgpt-shell)
