# Matisse: Dynamic Command and Model Discovery

## Executive Summary

This document outlines how to add dynamic command and model discovery to matisse.el using control messages. Since matisse already has bidirectional JSON communication, we can send an `initialize` control request at startup to discover available commands and models, eliminating hardcoded lists.

## Current Limitations

### Hardcoded Commands
- Matisse currently has a static list of slash commands in `matisse--slash-commands`
- No awareness of command availability based on Claude Code version
- No command descriptions or parameter information
- Commands may be outdated or missing new additions

### Model Selection
- No dynamic model discovery
- Users cannot easily switch between available models
- No awareness of model capabilities or limits

## Solution: Use Existing Control Message Infrastructure

### Protocol Flow

1. **Matisse sends initialization request** (right after starting process with JSON streaming):
```json
{
  "type": "control_request",
  "request_id": "init_123",
  "request": {
    "subtype": "initialize",
    "hooks": {},
    "sdkMcpServers": []
  }
}
```

2. **Claude Code responds with capabilities**:
```json
{
  "type": "control_response",
  "response": {
    "subtype": "success",
    "request_id": "init_123",
    "response": {
      "commands": [
        {
          "name": "/help",
          "description": "Get help with using Claude Code",
          "parameters": []
        },
        {
          "name": "/add-dir",
          "description": "Add a directory to the working set",
          "parameters": ["path"]
        }
      ],
      "models": [
        {
          "id": "claude-3-5-sonnet-20241022",
          "name": "Claude 3.5 Sonnet",
          "capabilities": ["code", "vision"]
        }
      ],
      "version": "1.0.0",
      "features": ["mcp", "vision", "artifacts"]
    }
  }
}
```

## Implementation Plan

### Phase 1: Add to Existing Infrastructure

#### 1.1 Add Initialization State Variables
```elisp
(defvar-local matisse--initialization-complete nil
  "Whether initialization with Claude Code is complete.")

(defvar-local matisse--available-commands nil
  "List of available slash commands from Claude Code.")

(defvar-local matisse--available-models nil
  "List of available models from Claude Code.")

(defvar-local matisse--claude-features nil
  "Features supported by this Claude Code instance.")

(defvar-local matisse--initialization-promise nil
  "Promise-like structure for initialization completion.")
```

#### 1.2 Initialization Request Function
```elisp
(defun matisse--send-initialization-request (process)
  "Send initialization request to Claude Code PROCESS.
  Uses the same process-send-string we already use for user input."
  (let* ((request-id (format "init_%s" (matisse--generate-request-id)))
         (init-request
          `((type . "control_request")
            (request_id . ,request-id)
            (request . ((subtype . "initialize")
                       (hooks . ,(make-hash-table))  ; Empty for now
                       (sdkMcpServers . []))))))

    ;; Store pending initialization
    (setq matisse--initialization-promise
          (cons request-id nil))  ; (request-id . callback)

    ;; Send request
    (process-send-string process
                         (concat (json-encode init-request) "\n"))

    (matisse--debug-log "Sent initialization request: %s" request-id)))
```

#### 1.3 Handle Initialization Response
```elisp
(defun matisse--handle-initialization-response (response-data)
  "Process initialization response from Claude Code.
RESPONSE-DATA is the response portion of the control response."
  (let ((commands (alist-get 'commands response-data))
        (models (alist-get 'models response-data))
        (features (alist-get 'features response-data))
        (version (alist-get 'version response-data)))

    ;; Store available commands
    (setq matisse--available-commands
          (mapcar (lambda (cmd)
                    (list :name (alist-get 'name cmd)
                          :description (alist-get 'description cmd)
                          :parameters (alist-get 'parameters cmd)))
                  commands))

    ;; Store available models
    (setq matisse--available-models
          (mapcar (lambda (model)
                    (list :id (alist-get 'id model)
                          :name (alist-get 'name model)
                          :capabilities (alist-get 'capabilities model)))
                  models))

    ;; Store features
    (setq matisse--claude-features features)

    ;; Mark initialization complete
    (setq matisse--initialization-complete t)

    (matisse--debug-log "Initialization complete. Commands: %d, Models: %d, Version: %s"
                        (length matisse--available-commands)
                        (length matisse--available-models)
                        version)

    ;; Update completion functions
    (matisse--update-completion-data)))
```

### Phase 2: Enhanced Command Completion

#### 2.1 Dynamic Completion Function
```elisp
(defun matisse--slash-command-completion-at-point ()
  "Provide completion for slash commands at point.
Uses dynamically discovered commands from initialization."
  (when (and matisse--initialization-complete
             (matisse--at-command-position-p))
    (let* ((bounds (matisse--command-bounds-at-point))
           (start (car bounds))
           (end (cdr bounds))
           (prefix (buffer-substring-no-properties start end))
           (commands (matisse--get-matching-commands prefix)))

      (list start end
            (mapcar #'car commands)
            :annotation-function
            (lambda (cmd)
              (when-let ((desc (matisse--get-command-description cmd)))
                (concat " — " (truncate-string-to-width desc 50))))
            :company-docsig
            (lambda (cmd)
              (matisse--get-command-signature cmd))))))

(defun matisse--get-matching-commands (prefix)
  "Get commands matching PREFIX from available commands."
  (cl-remove-if-not
   (lambda (cmd)
     (string-prefix-p prefix (plist-get cmd :name)))
   matisse--available-commands))

(defun matisse--get-command-description (command-name)
  "Get description for COMMAND-NAME."
  (when-let ((cmd (cl-find command-name matisse--available-commands
                            :key (lambda (c) (plist-get c :name))
                            :test #'string=)))
    (plist-get cmd :description)))

(defun matisse--get-command-signature (command-name)
  "Get signature with parameters for COMMAND-NAME."
  (when-let ((cmd (cl-find command-name matisse--available-commands
                            :key (lambda (c) (plist-get c :name))
                            :test #'string=)))
    (let ((params (plist-get cmd :parameters)))
      (if params
          (format "%s %s" command-name
                  (mapconcat (lambda (p) (format "<%s>" p)) params " "))
        command-name))))
```

#### 2.2 Command Parameter Hints
```elisp
(defun matisse--show-command-parameter-hint ()
  "Show parameter hints for the command at point."
  (when-let* ((cmd-bounds (matisse--get-current-command-bounds))
              (cmd-text (buffer-substring-no-properties
                        (car cmd-bounds) (cdr cmd-bounds)))
              (cmd-parts (split-string cmd-text " "))
              (cmd-name (car cmd-parts))
              (cmd-info (matisse--get-command-info cmd-name))
              (params (plist-get cmd-info :parameters)))
    (when params
      (let* ((provided-args (length (cdr cmd-parts)))
             (current-param (nth provided-args params))
             (hint (when current-param
                     (format "Next parameter: <%s>" current-param))))
        (when hint
          (message hint))))))
```

### Phase 3: Model Management

#### 3.1 Model Selection Interface
```elisp
(defun matisse-select-model ()
  "Interactively select a model from available models."
  (interactive)
  (unless matisse--initialization-complete
    (error "Initialization not complete. Please wait..."))

  (let* ((models matisse--available-models)
         (choices (mapcar (lambda (model)
                           (cons (format "%s (%s)"
                                       (plist-get model :name)
                                       (plist-get model :id))
                                 (plist-get model :id)))
                         models))
         (selection (completing-read "Select model: " choices nil t)))
    (when-let ((model-id (cdr (assoc selection choices))))
      (matisse--set-model model-id))))

(defun matisse--set-model (model-id)
  "Set the current model to MODEL-ID."
  (matisse--send-control-request
   matisse--process
   "set_model"
   `((model . ,model-id)))
  (message "Model set to: %s" model-id))
```

#### 3.2 Model Display in Mode Line
```elisp
(defun matisse--get-current-model-display ()
  "Get current model for mode line display."
  (if matisse--current-model-id
      (when-let ((model (cl-find matisse--current-model-id
                                matisse--available-models
                                :key (lambda (m) (plist-get m :id))
                                :test #'string=)))
        (format " [%s]" (or (plist-get model :name)
                           matisse--current-model-id)))
    ""))

(defun matisse--update-mode-line ()
  "Update mode line with model info."
  (setq mode-line-process
        (format " Claude%s%s"
                (matisse--get-current-model-display)
                (if matisse--process-busy " ⟳" ""))))
```

### Phase 4: Feature Detection

#### 4.1 Capability Checking
```elisp
(defun matisse--supports-feature-p (feature)
  "Check if Claude Code supports FEATURE."
  (and matisse--initialization-complete
       (member feature matisse--claude-features)))

(defun matisse--supports-vision-p ()
  "Check if current model supports vision/images."
  (when-let ((model (matisse--get-current-model)))
    (member "vision" (plist-get model :capabilities))))

(defun matisse--supports-mcp-p ()
  "Check if MCP servers are supported."
  (matisse--supports-feature-p "mcp"))

(defun matisse--supports-artifacts-p ()
  "Check if artifacts are supported."
  (matisse--supports-feature-p "artifacts"))
```

#### 4.2 Conditional Features
```elisp
(defun matisse--maybe-enable-image-paste ()
  "Enable image paste if vision is supported."
  (when (matisse--supports-vision-p)
    (local-set-key (kbd "C-c C-v") #'matisse-paste-image)
    (message "Vision enabled - use C-c C-v to paste images")))

(defun matisse--maybe-show-mcp-servers ()
  "Show MCP server status if supported."
  (when (matisse--supports-mcp-p)
    (matisse--request-mcp-status)))
```

### Phase 5: Process Startup Integration

#### 5.1 Modified Process Start
```elisp
(defun matisse--start-claude-code-process (&optional continue-flag)
  "Start the Claude Code process with initialization."
  ;; ... existing process creation code ...

  ;; After process is created:
  (when matisse--process
    ;; Send initialization request immediately
    (matisse--send-initialization-request matisse--process)

    ;; Set a timeout for initialization
    (run-with-timer 5 nil
                    (lambda ()
                      (unless matisse--initialization-complete
                        (message "Warning: Initialization timeout - some features may be unavailable")))))

  matisse--process)
```

#### 5.2 Control Response Router Update
```elisp
(defun matisse--handle-control-response (process response)
  "Route control responses including initialization."
  (let* ((response-data (alist-get 'response response))
         (request-id (alist-get 'request_id response-data))
         (subtype (alist-get 'subtype response-data)))

    (cond
     ;; Check if this is our initialization response
     ((and matisse--initialization-promise
           (string= (car matisse--initialization-promise) request-id))
      (matisse--handle-initialization-response
       (alist-get 'response response-data)))

     ;; Other control responses
     (t
      (matisse--handle-other-control-response process response)))))
```

## Benefits

### Immediate Benefits
1. **Accurate Command List**: Always shows exactly what commands are available
2. **Better Completion**: Includes descriptions and parameter hints
3. **Version Compatibility**: Automatically adapts to Claude Code version
4. **Model Awareness**: Know which models are available and their capabilities

### Future Benefits
1. **Feature Gates**: Enable/disable UI elements based on capabilities
2. **Smart Defaults**: Choose appropriate model based on task
3. **Better Error Messages**: Know why a command might not work
4. **Extension Point**: Easy to add new capability-dependent features

## Testing Strategy

### Test Scenarios
1. **Initialization Success**
   - Commands and models are populated
   - Completion works with new commands

2. **Initialization Timeout**
   - Fallback to basic functionality
   - User warned but can continue

3. **Version Changes**
   - New commands appear automatically
   - Removed commands don't show in completion

4. **Model Switching**
   - Can select from available models
   - Model capabilities affect features

## Implementation Timeline

- **Day 1**: Core initialization protocol
- **Day 2**: Command discovery and completion
- **Day 3**: Model management
- **Day 4**: Feature detection and conditional UI
- **Day 5**: Testing and refinement

## Success Metrics

1. Zero hardcoded command lists
2. Completion includes all available commands
3. Model switching works seamlessly
4. Features adapt to capabilities
5. Initialization completes in < 1 second