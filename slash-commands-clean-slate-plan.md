# Matisse Slash Commands - Clean Slate Implementation Plan

## Current State
- All previous slash command code has been removed
- Token tracking functionality is preserved and working
- Ready for a fresh implementation approach

## Key Lessons Learned

### What Works
1. **Message Format**: Slash commands work with JSON array format:
   ```json
   {
     "type": "user",
     "message": {
       "role": "user",
       "content": [{"type": "text", "text": "/cost"}]
     }
   }
   ```

2. **Response Format**: Claude returns output in `<local-command-stdout>` tags:
   ```
   <local-command-stdout>
   Cost breakdown here...
   </local-command-stdout>
   ```

3. **No New Process Needed**: We can send slash commands through the existing matisse shell process, just like regular messages

## Simplified Implementation Plan

### Phase 1: Core Infrastructure
1. **Add slash command formatter** (after `matisse--format-user-message`):
   ```elisp
   (defun matisse--format-slash-command-message (command)
     "Format slash COMMAND as a JSON message for Claude Code."
     (json-encode
      `((type . "user")
        (message . ((role . "user")
                    (content . ,(vector (list (cons 'type "text")
                                            (cons 'text command)))))))))
   ```

2. **Update process filter** to handle slash command responses:
   - In the `"user"` case, detect `<local-command-stdout>` tags
   - Extract and clean the output (handle escaped newlines)
   - Route to shell using `matisse--route-to-shell`

### Phase 2: Command Implementation
1. **Create unified slash command sender**:
   ```elisp
   (defun matisse--send-slash-command (command)
     "Send a slash COMMAND through the matisse shell."
     ;; Ensure in shell buffer
     ;; Check for clear input
     ;; Insert command visually at prompt
     ;; Send through existing message pipeline with slash format
     ;; Let normal infrastructure handle the response
   )
   ```

2. **Implement specific commands**:
   ```elisp
   (defun matisse-cost ()
     "Send /cost command to show session cost."
     (interactive)
     (matisse--send-slash-command "/cost"))

   (defun matisse-compact ()
     "Send /compact command to compress history."
     (interactive)
     (matisse--send-slash-command "/compact"))
   ```

### Phase 3: Integration Points

1. **Visual Feedback**:
   - Insert command at prompt (e.g., "λ /cost")
   - Use inactive prompt face during processing
   - Add to command history for up-arrow recall

2. **Message Pipeline Integration**:
   - Use existing message queue system
   - Leverage current shell context infrastructure
   - Reuse spinner and progress indicators

3. **Response Handling**:
   - Route through `matisse--route-to-shell`
   - Display in shell buffer like any response
   - Create new prompt after completion

## Implementation Order

1. **Start with formatter function** - Simple, isolated change
2. **Add process filter handler** - Detect and route slash command output
3. **Create generic sender** - Unified way to send any slash command
4. **Add specific commands** - matisse-cost and matisse-compact
5. **Test thoroughly** - Ensure commands work in various states

## Key Design Decisions

### Why Reuse Existing Infrastructure
- **Simpler**: No parallel process management
- **Consistent**: Same queuing, context, and error handling
- **Maintainable**: Less code duplication
- **Reliable**: Proven message pipeline

### Why Visual Command Insertion
- **User Feedback**: Users see what's happening
- **History Support**: Commands accessible via up-arrow
- **Familiar UX**: Looks like typed commands
- **Debugging**: Easy to see what was sent

## Testing Strategy

1. **Basic Functionality**:
   - Start matisse shell
   - Run `/cost` - verify output appears
   - Run `/compact` - verify compression works

2. **Edge Cases**:
   - Run with existing input in prompt
   - Run from non-shell buffer
   - Run multiple commands quickly
   - Run during active response

3. **Integration**:
   - Verify history contains commands
   - Check prompt restoration
   - Ensure proper face changes
   - Confirm spinner behavior

## Success Criteria

- [ ] `/cost` displays cost breakdown in shell
- [ ] `/compact` compresses history and updates counters
- [ ] Commands appear in command history
- [ ] Visual feedback during command execution
- [ ] Clean error handling for edge cases
- [ ] No interference with regular messages

## Next Steps

1. Review this plan
2. Implement Phase 1 (core infrastructure)
3. Test basic functionality
4. Implement Phase 2 (commands)
5. Full integration testing
6. Document final implementation