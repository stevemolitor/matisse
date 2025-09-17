#!/bin/bash

# Example demonstrating that slash commands don't work with streaming JSON mode
# This sends the /compact command in the XML format discovered in Claude's conversation history
# but it doesn't actually execute - Claude just responds with explanations instead

# The XML format we found in Claude's terminal UI conversation history:
# <command-name>/compact</command-name>
# <command-message>compact</command-message>
# <command-args></command-args>

# Test 1: Send /compact command with XML format via streaming JSON
echo "Test 1: Sending /compact with XML format through streaming JSON API:"
echo '{"type":"user","message":{"role":"user","content":"<command-name>/compact</command-name>\n            <command-message>compact</command-message>\n            <command-args></command-args>"}}' | \
  claude --input-format stream-json --output-format stream-json -p bypassPermissions --verbose 2>&1 | \
  head -30

echo ""
echo "---"
echo ""

# Test 2: For comparison, send /compact as plain text
echo "Test 2: Sending /compact as plain text (also doesn't work):"
echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"/compact"}]}}' | \
  claude --input-format stream-json --output-format stream-json -p bypassPermissions --verbose 2>&1 | \
  head -30

echo ""
echo "---"
echo ""
echo "Result: In both cases, Claude responds with explanations about the /compact command"
echo "rather than actually executing it. This shows that slash commands are not supported"
echo "in the streaming JSON API mode, only in the interactive terminal UI."
echo ""
echo "The expected behavior would be a system message with type 'compact_boundary'"
echo "but instead we get assistant messages explaining what /compact does."