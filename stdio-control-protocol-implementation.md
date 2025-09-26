# Matisse: Using Control Messages for Permission Handling

## Executive Summary

This document outlines the implementation plan for replacing the current PreToolUse hook-based permission system in matisse.el with control messages. Since matisse already uses `--input-format stream-json --output-format stream-json` for bidirectional JSON communication, we simply need to:
1. Change from `--settings` with hooks to `--permission-prompt-tool stdio`
2. Handle `control_request` messages in the existing process filter
3. Send `control_response` messages back

This ensures permission checks occur at the correct time (after user settings checks) and eliminates unnecessary permission prompts.

## Problem Statement

### Current Issue
- PreToolUse hooks run **before** Claude Code checks user settings (allow/deny rules)
- This causes matisse to prompt for permissions even when users have already granted them in settings.json
- The external hook mechanism (shell script → emacsclient) adds complexity and latency

### Root Cause
The PreToolUse hook executes at the wrong point in the permission evaluation chain:
1. PreToolUse Hooks (current implementation - too early!)
2. Deny Rules
3. Permission Mode Check
4. Allow Rules
5. `canUseTool` Callback (where we should be)
6. PostToolUse Hooks

## Solution: Control Messages via Existing JSON Streaming

### How It Works

Matisse already has bidirectional JSON communication. We just need to:

1. **Tell Claude Code** to use stdio for permissions via `--permission-prompt-tool stdio`
2. **Detect** `control_request` messages (already coming via stdout in our JSON stream)
3. **Respond** with `control_response` messages (send via stdin like we do with user input)
4. This happens at the `canUseTool` stage, after user settings are checked

### Protocol Messages

#### Request from Claude Code (stdout):
```json
{
  "type": "control_request",
  "request_id": "req_abc123",
  "request": {
    "subtype": "can_use_tool",
    "tool_name": "Bash",
    "input": {
      "command": "npm install"
    },
    "permission_suggestions": ["allow", "deny"]
  }
}
```

#### Response from Matisse (stdin):
```json
{
  "type": "control_response",
  "response": {
    "subtype": "success",
    "request_id": "req_abc123",
    "response": {
      "decision": "allow"
    }
  }
}
```

## Implementation Plan

### Phase 1: Minimal Changes Required (Priority: High)

#### 1.1 Modify Process Startup
**File:** `matisse.el`
**Function:** `matisse--start-claude-code-process`

```elisp
;; Simple change: replace hooks with stdio permission handling
(defun matisse--start-claude-code-process (&optional continue-flag)
  "Start the Claude Code process..."
  (let* ((default-directory (or default-directory (expand-file-name "~/")))
         (process-environment process-environment) ; Remove MATISSE_BUFFER_NAME - no longer needed
         (cmd (list matisse-claude-code-path
                    "--permission-prompt-tool" "stdio"  ; CHANGE: Use stdio instead of hooks
                    "--permission-mode" matisse-permission-mode
                    "--input-format" "stream-json"      ; Already using JSON streaming!
                    "--output-format" "stream-json")))

    ;; Remove the entire hook settings block
    ;; No more external scripts or emacsclient!

    ;; ... rest of function unchanged ...
    ))
```

#### 1.2 Add Control Request Detection
**File:** `matisse.el`
**Function:** `matisse--process-filter`

```elisp
(defun matisse--process-filter (process output)
  "Process filter for handling OUTPUT from Claude Code PROCESS."
  (let ((buffer (process-get process 'matisse-buffer)))
    (when (and buffer (buffer-live-p buffer))
      (with-current-buffer buffer
        ;; ... existing line processing ...
        (when json-obj
          (cond
           ;; NEW: Handle control requests
           ((equal (alist-get 'type json-obj) "control_request")
            (matisse--handle-control-request process json-obj))

           ;; Existing handlers
           ((equal (alist-get 'type json-obj) "system")
            (matisse--handle-system-message json-obj))
           ((equal (alist-get 'type json-obj) "assistant")
            ;; ... existing assistant handling ...
            )))))))
```

### Phase 2: Control Protocol Handlers (Priority: High)

#### 2.1 Control Request Handler
**New Function:** `matisse--handle-control-request`

```elisp
(defun matisse--handle-control-request (process request)
  "Handle control request from Claude Code.
PROCESS is the Claude Code process.
REQUEST is the parsed JSON control request."
  (let* ((request-id (alist-get 'request_id request))
         (request-data (alist-get 'request request))
         (subtype (alist-get 'subtype request-data)))

    (cond
     ;; Handle permission requests
     ((equal subtype "can_use_tool")
      (matisse--handle-can-use-tool-request process request-id request-data))

     ;; Handle hook callbacks (if still needed for PostToolUse)
     ((equal subtype "hook_callback")
      (matisse--handle-hook-callback process request-id request-data))

     ;; Unknown request type
     (t
      (matisse--send-control-error process request-id
                                   (format "Unknown control request subtype: %s" subtype))))))
```

#### 2.2 Permission Request Handler
**New Function:** `matisse--handle-can-use-tool-request`

```elisp
(defun matisse--handle-can-use-tool-request (process request-id request-data)
  "Handle can_use_tool control request.
PROCESS is the Claude Code process.
REQUEST-ID is the request identifier.
REQUEST-DATA contains tool_name, input, and permission_suggestions."
  (let* ((tool-name (alist-get 'tool_name request-data))
         (tool-input (alist-get 'input request-data))
         (suggestions (alist-get 'permission_suggestions request-data))
         (buffer-name (buffer-name))
         ;; Use existing permission decision logic
         (decision (matisse--decide-tool-permission-stdio tool-name tool-input buffer-name)))

    ;; Log the decision
    (matisse--log-permission-decision buffer-name tool-name decision)

    ;; Send response back to Claude Code
    (matisse--send-control-response process request-id
                                     `((decision . ,decision)))))
```

#### 2.3 Response Sender
**New Function:** `matisse--send-control-response`

```elisp
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
    (process-send-string process
                         (concat (json-encode response-message) "\n"))

    ;; Log for debugging
    (matisse--debug-log "Sent control response: %s"
                        (json-encode response-message))))
```

#### 2.4 Error Response Handler
**New Function:** `matisse--send-control-error`

```elisp
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
                         (concat (json-encode error-response) "\n"))

    (matisse--debug-log "Sent control error: %s" error-message)))
```

### Phase 3: Permission Decision Logic (Priority: High)

#### 3.1 Adapt Permission Decision for stdio
**Reuse Existing Function:** `matisse--decide-tool-permission-shell`

Note: You can likely reuse most of the existing `matisse--decide-tool-permission-shell` function!
The main difference is it should return `"allow"` or `"deny"` (strings) instead of symbols.

```elisp
(defun matisse--decide-tool-permission-stdio (tool-name tool-input buffer-name)
  "Decide whether to allow TOOL-NAME with TOOL-INPUT via stdio protocol.
This is mostly the same as matisse--decide-tool-permission-shell but returns strings.
BUFFER-NAME is the matisse buffer making the request.
Returns \"allow\" or \"deny\"."

  ;; Can likely just call the existing function and convert result
  (let ((decision (matisse--decide-tool-permission-shell
                   tool-name tool-input nil buffer-name)))
    (if (eq decision 'allow) "allow" "deny")))
```

Alternative: Just modify the existing function to return strings when using stdio mode.

#### 3.2 Enhanced Permission Prompt
**Modified Function:** `matisse--prompt-for-permission`

```elisp
(defun matisse--prompt-for-permission (tool-name &optional command buffer-name)
  "Prompt user for permission to use TOOL-NAME.
Optional COMMAND for Bash tool.
BUFFER-NAME for context in prompt.
Returns t for allow, nil for deny."
  (let* ((prompt (if command
                     (format "[%s] Allow %s: %s? (y/n) "
                             (or buffer-name "Matisse")
                             tool-name
                             command)
                   (format "[%s] Allow %s tool? (y/n) "
                           (or buffer-name "Matisse")
                           tool-name))))
    (y-or-n-p prompt)))
```

### Phase 4: Cleanup & Migration (Priority: Medium)

#### 4.1 Remove Hook-Related Code
- Remove `matisse--generate-hook-settings`
- Remove `matisse-handle-pretooluse-hook`
- Remove `matisse-handle-posttooluse-hook`
- Remove `matisse-hook-wrapper.sh` file
- Remove hook-related custom variables

#### 4.2 Add Configuration Variables
```elisp
(defcustom matisse-auto-allow-tools '("Read" "Grep" "Glob")
  "List of tools to automatically allow without prompting."
  :type '(repeat string)
  :group 'matisse)

(defcustom matisse-use-stdio-permissions t
  "Use stdio control protocol for permissions instead of hooks."
  :type 'boolean
  :group 'matisse)
```

### Phase 5: Testing & Validation (Priority: High)

#### 5.1 Test Scenarios
1. **Basic Permission Flow**
   - Tool request triggers control_request
   - User approval/denial works correctly
   - Decision is properly communicated back

2. **Settings Integration**
   - Tools allowed in settings.json are not prompted
   - Tools denied in settings.json are blocked
   - Only uncovered cases trigger prompts

3. **Edge Cases**
   - Multiple rapid permission requests
   - Malformed control requests
   - Process termination during permission prompt

4. **Backwards Compatibility**
   - Add feature flag to revert to hooks if needed
   - Test with different Claude Code versions

#### 5.2 Debug Logging
```elisp
(defun matisse--log-control-protocol (direction type data)
  "Log control protocol messages for debugging.
DIRECTION is 'in' or 'out'.
TYPE is the message type.
DATA is the message content."
  (when matisse-debug
    (with-current-buffer (get-buffer-create "*matisse-control-log*")
      (goto-char (point-max))
      (insert (format "[%s] %s %s: %s\n"
                      (format-time-string "%H:%M:%S.%3N")
                      direction
                      type
                      (json-encode data))))))
```

## Implementation Timeline

### Quick Implementation (2-3 days)
- [ ] Day 1: Change startup flag and add control message detection
- [ ] Day 2: Implement response handlers and adapt existing permission logic
- [ ] Day 3: Test and remove old hook code

This is a relatively small change since the infrastructure already exists!

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Breaking changes in Claude Code protocol | High | Add version detection and compatibility layer |
| Race conditions in bidirectional communication | Medium | Implement request queuing and timeouts |
| User confusion during migration | Low | Provide clear migration guide and fallback option |
| Performance impact of synchronous prompts | Low | Cache recent decisions, add batch approval option |

## Success Criteria

1. **Functional Requirements**
   - Permission prompts only appear for tools not covered by settings.json
   - All existing permission features continue to work
   - Response time for permission decisions < 100ms

2. **User Experience**
   - Fewer permission prompts (50%+ reduction)
   - Clearer permission context in prompts
   - No degradation in overall performance

3. **Code Quality**
   - Removal of external dependencies (shell scripts, emacsclient)
   - Simplified codebase with clear separation of concerns
   - Comprehensive error handling and logging

## Future Enhancements

1. **Permission Caching**
   - Cache decisions for session duration
   - Add "Remember for this session" option

2. **Batch Permissions**
   - Group similar permission requests
   - Allow "approve all similar" option

3. **Permission Profiles**
   - Create named permission profiles
   - Quick switching between restrictive/permissive modes

4. **Visual Improvements**
   - Better formatting of permission requests
   - Show tool input preview in minibuffer

## Appendix: Reference Implementation

The TypeScript SDK implementation in `/Users/steve/temp/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs` provides the reference for:
- Line 6940-6947: canUseTool callback handling
- Line 6902-6931: Control request processing
- Line 7021-7038: Request/response messaging

## Conclusion

This implementation will align matisse.el with the official Claude Code SDKs, providing a cleaner, more efficient permission system that respects user settings while maintaining security and user control.