# Claude Squad TUI Reimplementation in WezTerm

## Goal

Replace Claude Squad's tmux + Bubble Tea TUI with a native WezTerm-based experience. WezTerm's Lua API gives us pane management, process spawning, status bars, key tables, and event hooks — everything needed to replicate Claude Squad's feature set without tmux, and with native Windows support.

---

## Architecture Overview

```
agenttui/
├── wezterm-plugin/          # WezTerm Lua plugin (new)
│   ├── plugin.lua           # Entry point, event wiring
│   ├── session.lua          # Session lifecycle (create/pause/resume/delete)
│   ├── worktree.lua         # Git worktree operations
│   ├── ui.lua               # Status bar, tab formatting, overlays
│   ├── keybindings.lua      # Key tables and leader-key bindings
│   ├── daemon.lua           # AutoYes polling loop
│   ├── config.lua           # Config loading/saving (~/.claude-squad/config.json)
│   ├── diff.lua             # Git diff capture and formatting
│   └── state.lua            # Instance persistence (JSON read/write)
├── wezterm/                 # WezTerm source (reference)
└── ...                      # Original Claude Squad source (reference)
```

The plugin is **opt-in and isolated** — it never touches the user's existing `wezterm.lua`. Instead, it ships its own launcher config that starts a dedicated WezTerm window.

---

## Isolation Strategy (No Conflict with Running WezTerm)

The user's existing WezTerm installation and config remain untouched. We achieve this by:

1. **Dedicated config file**: `agenttui/wezterm-plugin/agenttui.lua` is a standalone WezTerm config that includes all our plugin logic. It is NOT the user's `~/.wezterm.lua`.

2. **Launcher script**: `agenttui/launch.sh` (and `launch.ps1` for Windows) starts WezTerm with our custom config:
   ```bash
   wezterm --config-file /path/to/agenttui/wezterm-plugin/agenttui.lua
   ```
   This runs a completely separate WezTerm window with its own config, keybindings, and behavior.

3. **Separate state directory**: We use `~/.agenttui/` instead of `~/.claude-squad/` for our state, avoiding any collision.

4. **No global WezTerm modifications**: No changes to `~/.wezterm.lua`, `~/.config/wezterm/`, or any system-level config.

---

## Phase 1: Core Session Management

**Goal**: Spawn and manage Claude Code sessions in WezTerm panes without tmux.

### 1.1 Session Data Model

Reuse Claude Squad's JSON schema (`~/.claude-squad/instances.json`):

```lua
-- session.lua
Session = {
  id = "",            -- unique ID
  title = "",         -- user-provided name
  program = "claude", -- agent command
  status = "ready",   -- ready | running | loading | paused
  repo_path = "",     -- original repo path
  branch = "",        -- git branch name
  worktree_path = "", -- git worktree directory
  base_commit = "",   -- SHA for diff baseline
  is_existing_branch = false,
  created_at = "",
  updated_at = "",
  pane_id = nil,      -- WezTerm pane ID (when active)
  tab_id = nil,       -- WezTerm tab ID (when active)
}
```

### 1.2 Session Lifecycle

| Action | Implementation |
|--------|---------------|
| **Create** | `window:spawn_tab{}` with `args = {program}`, `cwd = worktree_path` |
| **Attach** | `pane:activate()` on the session's pane |
| **Pause** | `git add -A && git commit` in worktree, then close the pane, remove worktree |
| **Resume** | Recreate worktree, `window:spawn_tab{}` again, restore branch |
| **Delete** | Close pane, remove worktree, delete branch, remove from state |

### 1.3 Git Worktree Integration

```lua
-- worktree.lua
-- Shell out to git via wezterm.run_child_process()

function create_worktree(repo_path, branch, worktree_dir)
  -- git worktree add <worktree_dir> -b <branch>
  wezterm.run_child_process({ "git", "-C", repo_path, "worktree", "add", worktree_dir, "-b", branch })
end

function remove_worktree(repo_path, worktree_dir)
  wezterm.run_child_process({ "git", "-C", repo_path, "worktree", "remove", worktree_dir, "--force" })
end

function get_diff(repo_path, worktree_dir, base_commit)
  -- git diff <base_commit> -- .
  local success, stdout, stderr = wezterm.run_child_process({
    "git", "-C", worktree_dir, "diff", base_commit
  })
  return stdout
end
```

### 1.4 State Persistence

```lua
-- state.lua
-- Read/write ~/.claude-squad/instances.json using wezterm.read_dir / io operations
-- Serialize sessions to JSON with wezterm.serde.json_encode/json_decode
```

---

## Phase 2: UI Layout — The Session List

**Goal**: Replicate Claude Squad's left panel (session list) + right panel (preview/diff/terminal).

### 2.1 Layout Strategy

Use WezTerm's split pane system:

```
┌─────────────────────┬──────────────────────────────────────┐
│  SESSION LIST PANE  │  ACTIVE SESSION PANE                 │
│  (30% width)        │  (70% width)                         │
│                     │                                      │
│  ● task-auth [run]  │  claude> I'll update the auth...     │
│  ⏸ fix-bug   [pau]  │  ...                                 │
│  ● refactor  [rdy]  │                                      │
│                     │                                      │
├─────────────────────┴──────────────────────────────────────┤
│  [n] new  [D] delete  [c] pause  [r] resume  [p] push     │
└────────────────────────────────────────────────────────────┘
```

**Left pane**: A small Lua-driven TUI script that renders the session list. Runs as a custom process in its own pane.

**Right pane**: The actual agent process (Claude Code, etc.) running in a real terminal pane.

**Bottom status bar**: WezTerm's native `update-status` event.

### 2.2 Session List Pane

The session list is a lightweight Lua script (`list_renderer.lua`) that:
1. Reads instance state from JSON
2. Renders a formatted list to stdout with ANSI colors
3. Accepts keyboard input (j/k/enter/n/D/c/r/p)
4. Communicates with the plugin via WezTerm user variables (`OSC 1337`)

Alternatively, use `pane:inject_output()` to render the list directly into a pane controlled by the plugin, avoiding a separate process.

### 2.3 Tab Formatting

```lua
-- ui.lua
wezterm.on("format-tab-title", function(tab, tabs, panes, config, hover, max_width)
  local session = find_session_by_pane(tab.active_pane.pane_id)
  if session then
    local icon = session.status == "running" and "●" or "⏸"
    return { { Text = icon .. " " .. session.title } }
  end
end)
```

### 2.4 Status Bar (Menu)

```lua
-- ui.lua
wezterm.on("update-status", function(window, pane)
  local session = get_active_session(pane)
  local left = wezterm.format({
    { Foreground = { Color = "#7aa2f7" } },
    { Text = " [n] new  [N] new+prompt  [D] delete  [c] pause  [r] resume  [p] push  [?] help " },
  })
  window:set_left_status(left)

  local right = wezterm.format({
    { Text = session and (session.title .. " | " .. session.branch) or "No session" },
  })
  window:set_right_status(right)
end)
```

---

## Phase 3: Key Bindings and Navigation

**Goal**: Map all Claude Squad keybindings to WezTerm key tables.

### 3.1 Leader Key + Key Table

```lua
-- keybindings.lua
config.leader = { key = "a", mods = "CTRL", timeout_milliseconds = 1000 }

config.keys = {
  -- Session management (leader + key)
  { key = "n", mods = "LEADER", action = wezterm.action.EmitEvent("cs:new-session") },
  { key = "N", mods = "LEADER|SHIFT", action = wezterm.action.EmitEvent("cs:new-session-prompt") },
  { key = "D", mods = "LEADER|SHIFT", action = wezterm.action.EmitEvent("cs:delete-session") },
  { key = "c", mods = "LEADER", action = wezterm.action.EmitEvent("cs:pause-session") },
  { key = "r", mods = "LEADER", action = wezterm.action.EmitEvent("cs:resume-session") },
  { key = "p", mods = "LEADER", action = wezterm.action.EmitEvent("cs:push-session") },

  -- Navigation
  { key = "j", mods = "LEADER", action = wezterm.action.EmitEvent("cs:next-session") },
  { key = "k", mods = "LEADER", action = wezterm.action.EmitEvent("cs:prev-session") },

  -- Tabs (Preview / Diff / Terminal)
  { key = "Tab", mods = "LEADER", action = wezterm.action.EmitEvent("cs:cycle-view") },

  -- Help
  { key = "?", mods = "LEADER|SHIFT", action = wezterm.action.EmitEvent("cs:show-help") },
}
```

### 3.2 Event Handlers

```lua
-- plugin.lua
wezterm.on("cs:new-session", function(window, pane)
  -- 1. Prompt for session name via wezterm.action.PromptInputLine
  -- 2. Create worktree
  -- 3. Spawn new tab with agent process
  -- 4. Save state
end)

wezterm.on("cs:pause-session", function(window, pane)
  -- 1. Find session for active pane
  -- 2. Commit changes in worktree
  -- 3. Close the pane
  -- 4. Remove worktree (keep branch)
  -- 5. Update state
end)
```

### 3.3 Input Prompts

Use `wezterm.action.PromptInputLine` for:
- Session name input
- Branch name input
- Confirmation dialogs (delete)

```lua
wezterm.action.PromptInputLine {
  description = "Session name:",
  action = wezterm.action_callback(function(window, pane, line)
    if line then create_session(window, line) end
  end),
}
```

---

## Phase 4: Preview, Diff, and Terminal Views

**Goal**: Replicate the three-tab view from Claude Squad.

### 4.1 View Switching Strategy

Three approaches, pick one:

**Option A — Pane Zooming (Recommended)**
- Each session has 1 tab with potentially multiple panes
- "Preview" = the agent pane (default, zoomed)
- "Diff" = a second pane showing `git diff` output, toggled via zoom
- "Terminal" = a shell pane in the worktree, toggled via zoom

**Option B — Multiple Tabs per Session**
- Each session gets 3 tabs (Preview, Diff, Terminal)
- Tab titles prefixed with session name
- `cs:cycle-view` switches between the 3 tabs

**Option C — Single Pane with Content Switching**
- Use `pane:inject_output()` to render diff content into the preview pane
- Toggle between live agent output and rendered diff
- Most complex but closest to original UX

### 4.2 Diff View

```lua
-- diff.lua
function show_diff(window, session)
  local diff_text = get_diff(session.repo_path, session.worktree_path, session.base_commit)
  -- Either inject into a pane or spawn a pane running: git diff <base> | less -R
  local tab = window:active_tab()
  local diff_pane = tab:spawn_pane({
    direction = "Right",
    size = 0.7,
    args = { "git", "-C", session.worktree_path, "diff", "--color=always", session.base_commit },
  })
end
```

### 4.3 Terminal View

```lua
function show_terminal(window, session)
  -- Spawn interactive shell in worktree
  window:spawn_tab({
    cwd = session.worktree_path,
    args = { os.getenv("SHELL") or "bash" },
  })
end
```

---

## Phase 5: Daemon / AutoYes Mode

**Goal**: Auto-accept agent prompts without user interaction.

### 5.1 Polling via WezTerm Events

```lua
-- daemon.lua
-- Use a recurring timer via wezterm.time.call_after()

function start_autoyes_polling()
  wezterm.time.call_after(1, function()
    for _, session in ipairs(get_running_sessions()) do
      local pane = wezterm.mux.get_pane(session.pane_id)
      if pane then
        local text = pane:get_lines_as_text(50) -- last 50 lines
        if detect_prompt(text) then
          pane:send_text("\n") -- press Enter
        end
      end
    end
    start_autoyes_polling() -- reschedule
  end)
end
```

### 5.2 Prompt Detection

Port the prompt detection patterns from Claude Squad:
- Claude Code: `Do you want to proceed?`, `Allow?`, tool approval prompts
- Aider: `Add .* to the chat?`
- Gemini: approval patterns
- Configurable via regex list in config

---

## Phase 6: Configuration and Profiles

### 6.1 Config File

Reuse `~/.claude-squad/config.json`:

```lua
-- config.lua
function load_config()
  local f = io.open(wezterm.home_dir .. "/.claude-squad/config.json", "r")
  if f then
    local content = f:read("*a")
    f:close()
    return wezterm.serde.json_decode(content)
  end
  return default_config()
end
```

### 6.2 Profile Switching

```lua
-- Profile picker using InputSelector
wezterm.action.InputSelector {
  title = "Select Profile",
  choices = profiles_to_choices(config.profiles),
  action = wezterm.action_callback(function(window, pane, id, label)
    -- Set selected profile for new session
  end),
}
```

---

## Phase 7: Polish and Parity

### 7.1 Clipboard Integration
- Copy branch name on pause: `window:copy_to_clipboard(branch_name)`

### 7.2 Notifications
- Use `wezterm.emit("bell")` or native toast notifications when agent finishes

### 7.3 Help Overlay
- Render help text via `pane:inject_output()` or spawn a temporary pane with help content

### 7.4 Session Limit
- Enforce max 10 sessions in `create_session()`

### 7.5 Error Display
- Show errors in status bar with auto-clear timer

---

## Implementation Order

| Phase | What | Effort | Depends On |
|-------|------|--------|------------|
| **1** | Core session management (create/pause/resume/delete) + git worktree | High | — |
| **2** | UI layout (session list pane + status bar + tab titles) | High | Phase 1 |
| **3** | Key bindings and input prompts | Medium | Phase 1 |
| **4** | Preview/Diff/Terminal view switching | Medium | Phase 2 |
| **5** | AutoYes daemon polling | Low | Phase 1 |
| **6** | Config loading + profile switching | Low | Phase 1 |
| **7** | Polish (clipboard, notifications, help, errors) | Low | Phase 2-4 |

---

## Key Advantages Over tmux-based Approach

| | Claude Squad (tmux) | WezTerm Implementation |
|---|---|---|
| **Windows support** | Requires WSL | Native |
| **GPU rendering** | No | Yes (WebGPU) |
| **Font rendering** | Basic | Ligatures, color emoji, fallback chains |
| **Configuration** | JSON | Lua (programmable) |
| **Plugin ecosystem** | None | WezTerm plugins |
| **Process management** | tmux sessions | Native panes (no extra dependency) |
| **Scrollback** | tmux scrollback buffer | Native terminal scrollback |
| **Image support** | Limited | Kitty, iTerm2, Sixel protocols |

---

## Open Questions

1. **Session list rendering**: Separate process vs. `inject_output()` vs. a dedicated "command palette" approach using `InputSelector`?
2. **Backward compatibility**: Should we maintain the `~/.claude-squad/` state format for interop with the original tool?
3. **Multi-window**: Should sessions span across WezTerm windows or stay in one?
4. **Workspace integration**: Use WezTerm workspaces to group sessions by repo?
