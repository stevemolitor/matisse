# Using the Image Analyzer Subagent for Efficient Visual Debugging

## Problem

When you send images directly in a conversation, they consume massive amounts of context tokens:
- A single screenshot: 30K-70K tokens
- Multiple screenshots: Can fill 50%+ of your entire conversation context
- Once sent, images persist in context for the entire conversation

## Solution: Use the `image-analyzer` Subagent

The `image-analyzer` subagent analyzes images in a **separate context window**, returning only a text summary to your main conversation.

### Benefits

1. **Isolated context**: Image tokens don't count against your main conversation
2. **Automatic cleanup**: Once analysis completes, the image context is discarded
3. **Text summaries only**: You get descriptions instead of raw image data
4. **Token savings**: 30K-70K tokens reduced to 1K-2K token summaries

### Example: Font Rendering Debug Session

#### ❌ Old Way (Context-Expensive)

```
user: Here are screenshots of my font rendering issue
[Attaches 3 images: ~90K tokens consumed]

assistant: I can see the ligatures aren't rendering...
```

Result: 90K tokens added to conversation permanently.

#### ✅ New Way (Context-Efficient)

```
user: I have screenshots of font rendering issues at /tmp/screenshot1.png,
/tmp/screenshot2.png, and /tmp/screenshot3.png. Can you analyze each one
and describe what you see regarding ligature rendering, character spacing,
and any visual artifacts?

assistant: I'll use the image-analyzer agent to analyze each screenshot
separately and provide detailed descriptions.

[Claude launches 3 image-analyzer subagents in parallel]
```

Result: Only the text summaries (~5K tokens total) added to main conversation.

## Usage Patterns

### Pattern 1: Single Image Analysis

```
user: Analyze this screenshot and describe the button layout: /tmp/ui-screenshot.png

assistant: I'll use the image-analyzer agent to analyze this screenshot.
[Launches subagent with specific prompt about button layout]
[Returns text description: "I can see 5 buttons arranged vertically..."]
```

### Pattern 2: Multiple Images in Parallel

```
user: Compare these three screenshots of different states:
- /tmp/state1.png (initial state)
- /tmp/state2.png (after click)
- /tmp/state3.png (final state)

Please describe the visual differences between each state.

assistant: I'll analyze all three screenshots in parallel using the
image-analyzer agent.
[Launches 3 subagents simultaneously]
[Returns comparative analysis in text form]
```

### Pattern 3: Iterative Visual Debugging

```
user: I'm debugging font rendering. I'll be sending several screenshots
as I test different configurations. For each screenshot at /tmp/font-test-N.png,
please describe:
1. Are ligatures rendering correctly? (fi, fl, ff, ffi, ffl)
2. Is character spacing consistent?
3. Are there any visual artifacts or corruption?
4. Overall rendering quality (1-10)

assistant: Perfect! I'll use the image-analyzer agent for each screenshot
you provide. This will keep our conversation focused on the text analysis
rather than filling context with image data.

user: Please analyze /tmp/font-test-1.png

assistant: [Launches image-analyzer subagent]
Analysis of font-test-1.png:
1. Ligatures: fi and fl are rendering correctly, ffi shows slight overlap
2. Character spacing: Consistent except around 'f' characters
3. Artifacts: Minor aliasing on curved glyphs
4. Quality: 7/10

user: Now check /tmp/font-test-2.png after I adjusted the settings

assistant: [Launches image-analyzer subagent]
Analysis of font-test-2.png:
1. Ligatures: All ligatures rendering perfectly now
2. Character spacing: Fully consistent
3. Artifacts: None detected
4. Quality: 9/10 - significant improvement!
```

## How to Request Image Analysis

### Template

```
Please analyze [image location] and describe:
- [Specific aspect 1]
- [Specific aspect 2]
- [Specific aspect 3]
```

### Good Prompts

**For UI/Layout Issues:**
```
Analyze /tmp/screenshot.png and describe:
- Button positions and alignment
- Color scheme and contrast
- Any overlapping or cutoff elements
- Overall layout quality
```

**For Font/Text Rendering:**
```
Analyze /tmp/font-render.png and describe:
- Ligature rendering (fi, fl, ff, ffi, ffl)
- Character spacing and kerning
- Baseline alignment
- Any visual artifacts or corruption
- Anti-aliasing quality
```

**For Visual Bugs:**
```
Analyze /tmp/bug-screenshot.png and identify:
- What looks broken or incorrect?
- What should it look like instead?
- Are there any error indicators visible?
- Specific pixels or regions with issues
```

## Technical Details

### How It Works

1. **You request image analysis** with specific instructions
2. **Claude Code launches image-analyzer subagent** using the Task tool
3. **Subagent downloads/reads the image** in its own context window
4. **Subagent analyzes** according to your instructions
5. **Subagent returns text summary** to main conversation
6. **Subagent context is discarded** including the image data

### Context Math

**Sending 5 screenshots directly:**
- 5 images × ~35K tokens avg = ~175K tokens
- Result: Conversation context exhausted quickly

**Using image-analyzer for 5 screenshots:**
- 5 text summaries × ~1.5K tokens avg = ~7.5K tokens
- Result: 96% token savings!

## Best Practices

### ✅ Do

- Store images in accessible locations (/tmp/, project directories)
- Provide specific analysis instructions
- Use parallel analysis for multiple images
- Request structured output (bullet points, numbered lists)
- Keep images for reference in case re-analysis needed

### ❌ Don't

- Send images directly in long conversations
- Request overly broad analysis without specific questions
- Assume the agent can see things not in the image
- Delete source images immediately after analysis

## Integration with Matisse

When implementing image support in Matisse, consider:

1. **Auto-detect image attachments** and prompt user:
   ```
   "This appears to be an image. Would you like to:
   [1] Send directly (uses ~35K tokens)
   [2] Use image-analyzer subagent (uses ~1.5K tokens)"
   ```

2. **Save images to temp location** and use file paths

3. **Provide image analysis template prompts** for common use cases

4. **Show token savings** in user feedback:
   ```
   "✅ Image analyzed via subagent (saved ~33.5K tokens)"
   ```

## Real-World Example: Your Font Debug Session

**What happened (context-expensive):**
- Line 177: 2 images = 68K tokens
- 7 more images throughout = 52K tokens
- **Total: 120K tokens (56% of conversation!)**

**What could have happened (context-efficient):**
```
user: I have 9 screenshots showing font rendering issues:
/tmp/font-debug-1.png through /tmp/font-debug-9.png

Please analyze each one and describe the ligature rendering quality,
any visual artifacts, and rate the overall quality 1-10.

assistant: I'll analyze all 9 screenshots using the image-analyzer agent...

[Returns 9 text summaries: ~13.5K tokens total]
```

**Savings: 106.5K tokens (89% reduction!)**

## Conclusion

The image-analyzer subagent is essential for any visual debugging work in Claude Code. It provides the same analytical power as sending images directly, but with **90%+ token savings** and **no persistent context pollution**.

For Matisse users: Request image analysis via subagent rather than attaching screenshots directly to preserve your conversation context for actual debugging work!
