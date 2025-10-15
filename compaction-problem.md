Look at this conversation - it seems like it's in an auto-compact endless cycle:

https://cdn.zappy.app/9e819c17bf7acff404207d73ef447cad.png

@/Users/steve/.claude/projects/-Users-steve-md-nerd/cc39835f-ed90-4ecd-83d4-8d01060adc1d.jsonl

Either the context (the token count) is genuinely huge after each compaction, or it's not resetting the token count, or something...

ultrathink about why this might be happening.
I'll analyze the conversation log to understand what's causing the auto-compact loop.
 Reading /Users/steve/.claude/projects/-Users-steve-md-nerd/cc39835f-ed90-4ecd-83d4-8d01060adc1d.jsonl…
Let me check the end of the conversation to see the recent activity:
 Running tail -100 "/Users/steve/.claude/projects/-Users……
Let me check for auto-compaction patterns and token usage:
 Running grep -c '"type":"' "/Users/steve/.claude/projec……
 Running grep -o '"input_tokens":[0-9]*' "/Users/steve/.……
 Running grep -o '"cache_read_input_tokens":[0-9]*' "/Us……
 Running grep '"Compacting conversation"' "/Users/steve/……
 Running grep -i 'compact' "/Users/steve/.claude/project……
 Running tail -1 "/Users/steve/.claude/projects/-Users-s……
 Running grep '"isSidechain":true' "/Users/steve/.claude……

 Run command?

Parameters:
{
  "command": "tail -1 \"/Users/steve/.claude/projects/-Users-steve-md-nerd/cc39835f-ed90-4ecd-83d4-8d01060adc1d.jsonl\" | jq -r '.message.usage // empty'",
  "description": "Check the last message usage"
}

Type yes or no and press RETURN:
  → ✓ Allowed
Now I can see the pattern! Let me analyze the timestamps and token flow:
 Running grep '"compact_boundary"' "/Users/steve/.claude……
 Running tail -50 "/Users/steve/.claude/projects/-Users-……
 Running grep '"msg_01RDpqbUN8vDnboESy8fJpgQ"' "/Users/s……
 Running sed -n '/2025-10-12T18:08:46/,/2025-10-12T18:11……

 Run command?

Parameters:
{
  "command": "sed -n '/2025-10-12T18:08:46/,/2025-10-12T18:11:00/p' \"/Users/steve/.claude/projects/-Users-steve-md-nerd/cc39835f-ed90-4ecd-83d4-8d01060adc1d.jsonl\" | jq -r 'select(.type==\"assistant\" or .type==\"user\" or .type==\"system\") | [.timestamp, .type, (.isSidechain // false), (.message.usage.input_tokens // \"n/a\"), (.message.usage.cache_read_input_tokens // \"n/a\")] | @tsv' | head -30",
  "description": "Analyze messages right after first compaction"
}

Type yes, no, or accept and press RETURN:
  → ✓ Allowed

 Run command?

Parameters:
{
  "command": "sed -n '/2025-10-12T18:18:00/,/2025-10-12T18:20:30/p' \"/Users/steve/.claude/projects/-Users-steve-md-nerd/cc39835f-ed90-4ecd-83d4-8d01060adc1d.jsonl\" | jq -r 'select(.type==\"assistant\") | [.timestamp, (.isSidechain // false), (.message.usage.cache_read_input_tokens // \"n/a\")] | @tsv'",
  "description": "Check cache growth leading to 2nd compaction"
}

Type yes or no and press RETURN:
  → ✓ Allowed

 Run command?

Parameters:
{
  "command": "jq -r 'select(.type==\"assistant\" and .message.usage.cache_read_input_tokens != null) | [.timestamp, (.isSidechain // false), .message.usage.cache_read_input_tokens] | @tsv' \"/Users/steve/.claude/projects/-Users-steve-md-nerd/cc39835f-ed90-4ecd-83d4-8d01060adc1d.jsonl\" | tail -50",
  "description": "Track cache growth over time"
}

Type yes or no and press RETURN:
  → ✓ Allowed
## Analysis: The Auto-Compact Endless Cycle

I found the root cause! Here's what's happening:

### The Problem

**Sidechains are accumulating massive context independently and then dumping it back into the compacted conversation.**

### Timeline of Token Growth

```
First Compaction (18:08:46):
  Pre-compact:  192,962 tokens
  Post-compact:  12,927 tokens ✓

Sidechain starts (18:09:44):
  Sidechain context: 10,017 → 12,698 → 14,605 → 18,363 → 21,954 → 26,351 → 30,661 → 32,148 tokens

Sidechain merges back (18:13:36):
  Main chain jumps to: 25,935 tokens (from ~23K)

Main chain continues growing:
  25,935 → 28,408 → 36,830 → 41,592 tokens

Second Compaction (18:20:12):
  Pre-compact: 38,316 tokens
  (Only 11.5 minutes after first compaction!)

Third Compaction (18:25:35):
  Pre-compact: 47,194 tokens
  (Only 5.4 minutes later!)

Fourth Compaction (18:28:32):
  Pre-compact: 17,712 tokens
  (Only 3 minutes later!)
```

### What's in the Sidechains?

Looking at the log, the sidechain contains **parallel tool operations** - specifically 6+ simultaneous WebSearch and WebFetch operations:
- WebSearch for "MD IO specimen PDF"  
- WebSearch for "0xProto ligatures list"
- WebFetch from GitHub releases
- WebSearch for "MonoLisa ligature spacer"
- Etc.

Each of these returns massive results (search results, full web page content, etc.) that accumulate in the sidechain's independent context.

### The Vicious Cycle

1. **Compact** main conversation (192K → 38K) ✓
2. Claude **starts parallel tool operations** (WebSearch/WebFetch) in a sidechain
3. **Sidechain accumulates** its own context (32K tokens of search results!)
4. **Sidechain merges back** into main chain, dumping all those messages
5. Main chain **balloons back up** to 38-47K tokens
6. This **triggers another compaction** need
7. **Go to step 1** and repeat

### Why This Happens

The compaction doesn't know about or compact the sidechains. When you compact:
- ✓ Main chain gets compacted and summarized
- ✗ Active sidechains continue with their own context
- ✗ Sidechain results get appended to the already-compacted conversation
- ✗ This invalidates the compaction almost immediately

### The Fix (for Claude Code developers)

Options to consider:

1. **Pause/kill sidechains during compaction** - Don't allow sidechains to merge back after compaction
2. **Compact sidechains too** - Apply the same summarization to sidechain messages
3. **Inherit compacted context** - Sidechains should use the post-compact context, not pre-compact
4. **Limit parallel operations** - Don't launch 6+ WebSearches simultaneously that will bloat context
5. **Compress tool results** - Summarize large WebSearch/WebFetch results before adding to conversation

The current behavior essentially makes compaction useless when there are active parallel tool operations.
