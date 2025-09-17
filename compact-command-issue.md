# Slash Commands Don't Work in Streaming JSON Mode

## Issue Summary
Slash commands like `/compact`, `/cost`, `/clear`, and `/context` do not execute when using `--input-format stream-json --output-format stream-json`. Instead, Claude responds with explanations about what the commands do.

## Expected Behavior
When sending `/compact`, the system should:
1. Compress the conversation history
2. Return a system message with type `compact_boundary`
3. Reset the context while maintaining conversation continuity

## Actual Behavior
Claude responds with assistant messages explaining the command rather than executing it.

## Reproduction

### One-liner test command:
```bash
echo '{"type":"user","message":{"role":"user","content":"<command-name>/compact</command-name>\n            <command-message>compact</command-message>\n            <command-args></command-args>"}}' | claude --input-format stream-json --output-format stream-json -p bypassPermissions --verbose
```

### What happens:
Instead of executing the command, Claude responds with something like:
```
"I understand you're trying to use the `/compact` command, but as your documentation shows, it's not currently working properly..."
```

## Additional Tests Performed

1. **Plain text format**: `{"content":[{"type":"text","text":"/compact"}]}`
2. **XML format from terminal UI**: The format shown above (discovered in conversation history)
3. **System message type**: Tried sending as system message instead of user message

None of these approaches trigger the actual slash command execution.

## Environment
- claude-code CLI version: 1.0.120
- Using streaming JSON input/output format
- Permission mode: bypassPermissions

## Impact
This prevents programmatic tools (like Emacs integrations) from managing context efficiently. We cannot:
- Trigger compaction when approaching token limits
- Clear conversations programmatically
- Get cost information via `/cost`
- View context usage via `/context`

## Workaround
Currently, users must switch to the interactive terminal UI to use slash commands, which breaks automation workflows.

## Request
Please enable slash command execution in streaming JSON mode, or provide an alternative API for these operations (e.g., special message types or control messages).