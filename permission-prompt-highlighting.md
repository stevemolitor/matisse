# Permission Prompt Syntax Highlighting

## Problem

Permission prompts were displaying without syntax highlighting, making it difficult for users to review code changes and tool parameters before accepting/rejecting. The user reported that highlighting only appeared AFTER responding to the prompt, which was too late.

## Root Cause

While the code was correctly generating syntax-highlighted text (with face properties), the Emacs display was not being refreshed immediately after inserting the permission prompt. This caused a delay in rendering the faces, making them invisible until the next display update (which happened after the user responded).

## Solution

### 1. Force Immediate Display Refresh (matisse.el:2026)

Added explicit `(redisplay t)` call after inserting permission prompts:

```elisp
;; Force redisplay so syntax highlighting is visible immediately
(redisplay t)
```

This ensures that all face properties are rendered BEFORE the user sees the prompt.

### 2. Add JSON Syntax Highlighting for Tool Parameters (matisse.el:1910-1965)

Created new helper function `matisse--format-tool-params-with-highlighting` that:
- Converts tool parameters to pretty-printed JSON
- Applies syntax highlighting using cached json-mode buffer
- Extracts and preserves face properties
- Returns a fully propertized string

This provides detailed, syntax-highlighted parameter views for tools like:
- **Bash**: Shows command, timeout, description with JSON highlighting
- **Write**: Shows file_path, content with JSON highlighting
- **WebFetch**: Shows url, prompt with JSON highlighting
- **NotebookEdit**: Shows all parameters with JSON highlighting

### 3. Enhanced Permission Prompt Formatting (matisse.el:2013-2031)

Updated `matisse--format-permission-prompt` to show syntax-highlighted parameters:

```elisp
;; Show parameters as syntax-highlighted JSON for detailed view
(params-display (if (and tool-input
                         ;; Only show detailed params for certain tools
                         (member tool-name '("Bash" "Write" "NotebookEdit" "WebFetch")))
                    (concat "\n\nParameters:\n"
                           (matisse--format-tool-params-with-highlighting tool-input)
                           "\n")
                  ""))
```

## Features

### Syntax Highlighting for Different Tool Types

**Edit Tool**:
- Shows full diff with syntax highlighting
- Line numbers for context
- Color-coded additions (green), deletions (red), context (white)
- File path and separators

**Bash, Write, WebFetch, NotebookEdit Tools**:
- Shows action header (e.g., "Run command", "Write file: path/to/file")
- Displays all tool parameters as pretty-printed, syntax-highlighted JSON
- JSON strings shown in string face color
- JSON property names highlighted
- JSON numbers, booleans shown in appropriate colors

**Other Tools** (MultiEdit, etc.):
- Simple format without detailed JSON
- Icon and brief description only

### Performance Considerations

**No Performance Regression**:
- Uses existing cached mode buffers (`matisse--get-cached-mode-buffer`)
- JSON-mode buffer cached once, reused for all JSON highlighting
- Diff-mode is lightweight (no TreeSitter compilation)
- Only applies to interactive prompts (not during replay)
- Respects `matisse--skip-syntax-highlighting` flag for replay performance

**Efficient Implementation**:
- Face extraction happens once in temporary buffer
- Properties applied to string before insertion
- No repeated mode activations
- TreeSitter query compilation only happens once per session

## Files Modified

### matisse.el

1. **Lines 1910-1965**: New function `matisse--format-tool-params-with-highlighting`
   - Formats tool parameters as syntax-highlighted JSON
   - Uses cached json-mode buffer for performance

2. **Lines 2013-2031**: Updated "Other tools" section in `matisse--format-permission-prompt`
   - Shows syntax-highlighted JSON parameters for Bash, Write, WebFetch, NotebookEdit
   - Maintains simple format for other tools

3. **Line 2026**: Added `(redisplay t)` call in `matisse--prompt-permission-in-buffer`
   - Forces immediate display refresh
   - Ensures faces are visible before user responds

## Testing

Created comprehensive tests to verify functionality:

### test-diff-highlighting.el
- Verifies diff text properties are preserved
- Confirms faces exist in buffer after insertion

### test-permission-display.el
- Simulates exact permission prompt flow
- Tests Edit tool with diff highlighting
- Verifies faces are preserved through read-only property application

### test-all-permission-prompts.el
- Tests all tool types: Edit, Bash, Write, WebFetch, MultiEdit
- Verifies syntax highlighting for each tool
- Confirms 498+ characters with face properties applied
- Tests 14+ unique face types

**Test Results**:
```
Total chars with faces: 498
Unique faces found: 14
Face list: (font-lock-number-face font-lock-string-face font-lock-delimiter-face
           font-lock-property-use-face font-lock-bracket-face help-key-binding
           diff-added diff-indicator-added diff-removed diff-indicator-removed
           diff-context bold shadow ...)
✓ SUCCESS: All permission prompts have syntax highlighting!
```

## User Experience

**Before**:
- Permission prompts showed plain text without colors
- Code diffs were hard to read
- Tool parameters were difficult to parse
- Highlighting only appeared after responding (too late)

**After**:
- Permission prompts show syntax highlighting IMMEDIATELY
- Code diffs have color-coded additions/deletions
- JSON parameters are pretty-printed with syntax colors
- Users can properly review changes BEFORE accepting/rejecting
- Consistent highlighting across all tool types

## Related Documentation

- `performance-fixes.md`: Documents the conversation replay performance optimizations that this change respects
- `matisse.el`: Main implementation file with all syntax highlighting logic
