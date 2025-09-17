# Plan: Show Diffs Before Applying Edits

## Understanding the Problem
To show diffs before applying edits, we need to access the `old_string` and `new_string` from the Edit tool, or the `edits` array from MultiEdit tool in the PreToolUse hook.

## Implementation Plan

### 1. **Extract Edit Information from tool_input**
In `matisse--prompt-for-file-permission`, we'll extract:
- For Edit tool: `old_string` and `new_string`
- For MultiEdit tool: `edits` array containing multiple old/new pairs
- The `file_path` to read current content if needed

### 2. **Generate Diff Display**
Create a new function `matisse--generate-edit-diff` that:
- Takes the file path, old string, and new string
- Creates a unified diff format string
- For MultiEdit, concatenates multiple diffs

### 3. **Enhanced Permission Prompt**
Modify `matisse--prompt-for-file-permission` to:
- Check if tool is Edit or MultiEdit
- Generate the diff preview
- Show expanded prompt options:
  - `y` - apply edit
  - `n` - reject edit
  - `d` - show diff in buffer
  - `?` - show help

### 4. **Display Diff in Buffer** (optional)
Create `matisse--show-diff-in-buffer` function that:
- Creates a temporary buffer with diff-mode
- Shows the diff with syntax highlighting
- Allows user to review before returning to prompt

### 5. **Configuration Options**
Add customization variables:
- `matisse-show-diff-inline` - show diff in minibuffer echo area
- `matisse-max-diff-preview-lines` - limit diff size in minibuffer
- `matisse-auto-show-diff-buffer` - automatically pop up diff buffer

## Key Benefits
- Users can see exactly what will change before approving
- Prevents accidental approvals of unwanted changes
- Maintains context while reviewing changes
- Works with both Edit and MultiEdit tools

## Technical Considerations

### Available Data in tool_input
The PreToolUse hook receives JSON with tool_input containing:
- **Edit tool**:
  - `file_path`: The file to edit
  - `old_string`: The text to replace
  - `new_string`: The replacement text
  - `replace_all`: Boolean for replacing all occurrences

- **MultiEdit tool**:
  - `file_path`: The file to edit
  - `edits`: Array of edit objects, each containing:
    - `old_string`: Text to replace
    - `new_string`: Replacement text
    - `replace_all`: Optional boolean

### Diff Generation Approaches

1. **String-based diff**: Compare old_string with new_string directly
2. **Context-aware diff**: Read file, apply changes in memory, generate full file diff
3. **Incremental diff**: For MultiEdit, show each edit as a separate diff section

### User Interface Options

1. **Minibuffer prompt with inline preview**:
   ```
   Edit file.el:
   - oldFunction()
   + newFunction()
   Allow? (y/n/d/?):
   ```

2. **Pop-up buffer with diff-mode**:
   - Full syntax highlighting
   - Navigation between hunks
   - Side-by-side or unified view

3. **Transient interface**:
   - Show diff preview
   - Multiple action buttons
   - Keyboard shortcuts

## Implementation Priority

1. **Phase 1**: Basic diff extraction and display in prompt
2. **Phase 2**: Pop-up buffer with diff-mode
3. **Phase 3**: Configuration options and customization
4. **Phase 4**: Advanced features (context expansion, side-by-side view)