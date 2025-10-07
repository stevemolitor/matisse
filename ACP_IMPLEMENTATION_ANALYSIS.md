# ACP Implementation Analysis for Matisse

**Question**: Should Matisse adopt the Agent Client Protocol (ACP)?

---

## Quick Answer

**Async Queueing**: ✓ YES - ACP supports it via `Pushable` input streams
**Simplify/Complicate**: BOTH - Less context code, but more protocol code
**Lose Features**: SOME - Would need ACP protocol extensions
**Recommendation**: **Not worth it** - Current implementation is simpler

---

## What is ACP?

Agent Client Protocol (ACP) by Zed Industries - standardizes communication between code editors and AI coding agents.

**Current users**: Zed, Neovim (CodeCompanion, Avante), Emacs (agent-shell.el), marimo

**Protocol**: JSON-RPC over stdin/stdout (similar to Matisse's current approach)

---

## Architecture Comparison

### Current Matisse
```
matisse.el (6100 lines)
    ↓ spawns process
Claude Code CLI
    ↓ stream-json I/O
Bidirectional message stream
    ↓
matisse.el processes messages, manages state
```

### Matisse with ACP
```
matisse.el (ACP client - would need ~1000-1500 lines)
    ↓ spawns process
claude-code-acp (536 lines)
    ↓ uses as library
Claude Agent SDK
    ↓ API calls
Anthropic API
```

---

## Async Message Queueing - YES! ✓

### How ACP Handles It

**Line 49 (acp-agent.js)**:
```javascript
const input = new Pushable();  // Create pushable async iterator
```

**Line 121**:
```javascript
const q = query({ prompt: input, options });  // SDK consumes from stream
```

**Line 178 (in prompt() method)**:
```javascript
input.push(promptToClaude(params));  // Push new prompt any time!
```

**The `Pushable` class** (utils.js:6-44):
- Queue for pending items
- Resolvers for waiting consumers
- Can `push()` items at any time
- SDK's `query()` consumes asynchronously

**Result**: ✓ Multiple prompts can be queued while Claude is working - **SAME as Matisse's current feature**!

---

## What Would Simplify

### SDK Features "For Free"

If Matisse used ACP/SDK, we could **remove** our new code:

#### 1. Token Estimation - NOT NEEDED
- **Current**: `matisse--estimate-tokens` (9 lines)
- **ACP**: SDK handles internally
- **Savings**: Small, but one less thing to maintain

#### 2. Proactive Token Tracking - NOT NEEDED
- **Current**: Track before sending (11 lines in send function)
- **ACP**: SDK tracks internally
- **Savings**: Small

#### 3. Auto-Compact Logic - NOT NEEDED
- **Current**: State flags, queue, trigger logic (~80 lines)
- **ACP**: SDK's `Is2()` runs automatically
- **Savings**: Moderate

#### 4. Message Queue During Compact - NOT NEEDED
- **Current**: `matisse--pending-user-message`, queue handling (~30 lines)
- **ACP**: `Pushable` handles queueing naturally
- **Savings**: Moderate

**Total Savings**: ~130 lines of context management code we just wrote!

---

## What Would Complicate

### New Code Required

#### 1. ACP Protocol Client (~500-800 lines)

Need to implement in Emacs Lisp:
- JSON-RPC message format
- Protocol methods: `initialize`, `newSession`, `prompt`, `cancel`, `setMode`
- Notification handling: `sessionUpdate` events
- Spawning and managing `claude-code-acp` process

Similar to current `matisse--process-filter` but more structured.

#### 2. ACP Message Conversion (~200-300 lines)

Convert between:
- Emacs UI events → ACP prompt requests
- ACP notifications → Matisse buffer updates
- Tool use/results → ACP format
- Images, context, etc.

#### 3. Session Management (~100-200 lines)

ACP is session-based:
- Track session IDs
- Handle session lifecycle
- Coordinate with Emacs buffers

**Total New Code**: ~800-1300 lines

---

## Net Code Change

| Category | Remove | Add | Net |
|----------|--------|-----|-----|
| Context management | -130 | - | -130 |
| ACP protocol client | - | +800-1300 | +800-1300 |
| **Total** | **-130** | **+800-1300** | **+670-1170** |

**Result**: MORE code, not less!

---

## Features We'd Lose (Without Extensions)

### 1. Direct CLI Control
- **Current**: Matisse spawns CLI with custom flags
- **ACP**: Fixed configuration in claude-code-acp
- **Impact**: Less flexibility for debugging, custom models, etc.

### 2. Streaming JSON Access
- **Current**: Direct access to all message types
- **ACP**: Abstracted through protocol
- **Impact**: Harder to debug, less transparent

### 3. Custom Permission Handling
- **Current**: Full control over permission UI
- **ACP**: Goes through MCP permission server
- **Impact**: Different UX, might not match Matisse's current behavior

### 4. Slash Command Direct Access
- **Current**: Can detect and handle `/compact`, `/clear`, etc.
- **ACP**: Abstracted (see acp-agent.js:223-224 - even has bugs with slash command output)
- **Impact**: Less control

### 5. Fine-Grained State Management
- **Current**: Know exactly what's happening at each step
- **ACP**: More opaque (async iteration hides details)
- **Impact**: Harder to show detailed progress

---

## Features We'd Gain

### 1. Automatic SDK Feature Updates
- **Current**: Need to track SDK changes and reimplement
- **ACP**: Get new SDK features automatically
- **Value**: Medium - but SDK is stable

### 2. Compatibility with Other Editors
- **Current**: Matisse-specific
- **ACP**: Could share code/approaches with Zed users
- **Value**: Low - different audiences

### 3. Cleaner Context Management
- **Current**: Just implemented ~130 lines
- **ACP**: Handled by SDK
- **Value**: Medium - but we already implemented it

---

## Complexity Comparison

### Current Matisse Complexity
```
HIGH: Full client implementation
LOW: Context management (just finished implementing)
MEDIUM: Permission system
MEDIUM: UI rendering
```

### Matisse with ACP
```
MEDIUM: ACP protocol client (new code)
NONE: Context management (SDK handles)
HIGH: Protocol abstraction (conversion layers)
MEDIUM: Permission system (via MCP, different)
MEDIUM: UI rendering
```

**Net**: Similar total complexity, just shifted around.

---

## The Async Queueing Question

### Current Matisse (as of today)
```elisp
;; User types while Claude is working
(when matisse--auto-compact-in-progress
  (setq matisse--pending-user-message text))

;; After compact, send queued message
(run-at-time 0.5 nil
  (lambda () (matisse--send-message-internal queued-message)))
```

**Limitation**: Only queues ONE message during auto-compact.

### ACP Approach
```javascript
// Line 49: Create pushable stream
const input = new Pushable();

// Line 178: Push ANY TIME
input.push(promptToClaude(params));
```

**Advantage**: Can queue UNLIMITED messages, SDK processes them in order.

**But**: Would need to implement `Pushable` equivalent in Emacs Lisp, or manage queue separately.

---

## Recommendation: **Stick with Current Implementation**

### Reasons NOT to Switch to ACP:

1. **More Code Overall** (+670-1170 lines vs current)
2. **Just Implemented Context Management** (would throw away fresh code)
3. **Matisse Already Works Well** (current architecture is proven)
4. **ACP Protocol Still Evolving** ("under heavy development")
5. **Would Lose Flexibility** (custom flags, direct CLI access)
6. **Different UI Paradigm** (ACP assumes editor manages UI differently)

### Reasons TO Switch to ACP:

1. **Automatic SDK Feature Updates** (but how often do they change?)
2. **Standard Protocol** (but Matisse is the only Emacs client)
3. **Cleaner Context Management** (but we just built it)

**Trade-off doesn't favor switching.**

---

## Alternative: Hybrid Approach

Could Matisse adopt ACP concepts **without** full protocol?

### Option: Implement Pushable Input Queue

Add to Matisse (similar to ACP's Pushable):

```elisp
(defvar-local matisse--message-queue nil
  "Queue of pending user messages to send.")

(defun matisse--push-message (text)
  "Queue TEXT for sending, process asynchronously."
  (push text matisse--message-queue)
  (matisse--process-queue))

(defun matisse--process-queue ()
  "Send queued messages when ready."
  (when (and matisse--message-queue
             (not matisse--waiting-for-response))
    (let ((next-message (pop matisse--message-queue)))
      (matisse--send-message-internal next-message))))
```

**Benefit**: Unlimited message queueing (like ACP)
**Cost**: ~50 lines of code
**Complexity**: Low

This would give us ACP's queueing without the protocol overhead!

---

## Conclusion

### Should Matisse Implement ACP?

**NO** - for these reasons:

1. **Net increase in code** (~800-1300 lines)
2. **Just finished implementing SDK features** (would waste that work)
3. **Current architecture works well** (proven, stable)
4. **Would lose flexibility** (direct CLI control)
5. **Limited benefit** (SDK is stable, doesn't change often)
6. **Async queueing already works** (and could be enhanced without ACP)

### Should Matisse Adopt ACP Ideas?

**MAYBE** - Consider:

1. **Pushable-style unlimited queue** (vs current 1-message limit)
2. **Session-based architecture** (cleaner state management)
3. **Protocol documentation approach** (well-defined message types)

These could be adopted **without** full ACP implementation.

---

## Alternative: Enhance Current Implementation

Instead of ACP, enhance Matisse's queueing:

```elisp
;; Unlimited message queue (like ACP's Pushable)
(defvar-local matisse--message-queue nil)

;; Push messages while busy
(defun matisse--queue-or-send-message (text)
  (if matisse--waiting-for-response
      (push text matisse--message-queue)
    (matisse--send-and-process-queue text)))

;; After each response, send next queued message
(defun matisse--process-next-queued ()
  (when matisse--message-queue
    (let ((next (pop matisse--message-queue)))
      (matisse--send-message-internal next))))
```

**Benefit**: ACP-like queueing without protocol overhead
**Cost**: ~50 lines
**Compatibility**: Keeps current architecture

---

## Final Verdict

**Keep current implementation. Optionally add unlimited message queue.**

The work we just did implementing SDK-style context management is valuable and works well. Switching to ACP would:
- Add complexity (protocol implementation)
- Remove flexibility (locked into ACP/SDK)
- Provide minimal benefit (we already have the features)

**Best path forward**: Enhance current queueing to support multiple messages (easy addition), keep everything else as-is.
