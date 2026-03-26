-- session.lua
-- Session lifecycle: create, pause, resume, delete
-- Orchestrates worktree, state, and WezTerm pane management

local wezterm = require("wezterm")
local act = wezterm.action
local state = require("at_state")
local worktree = require("at_worktree")

local M = {}

local user_config = {}

function M.setup(cfg)
  user_config = cfg

  -- Event: Create new session
  wezterm.on("cs:new-session", function(window, pane)
    if state.count() >= (user_config.max_sessions or 10) then
      wezterm.log_error("AgentTUI: Max session limit reached (" .. user_config.max_sessions .. ")")
      return
    end

    window:perform_action(
      act.PromptInputLine({
        description = wezterm.format({
          { Attribute = { Intensity = "Bold" } },
          { Foreground = { Color = "#7aa2f7" } },
          { Text = "Session name: " },
        }),
        action = wezterm.action_callback(function(inner_window, inner_pane, line)
          if not line or line == "" then return end
          M.create_session(inner_window, {
            title = line,
            program = user_config.default_program or "claude",
          })
        end),
      }),
      pane
    )
  end)

  -- Event: Create new session with prompt
  wezterm.on("cs:new-session-prompt", function(window, pane)
    if state.count() >= (user_config.max_sessions or 10) then
      wezterm.log_error("AgentTUI: Max session limit reached")
      return
    end

    window:perform_action(
      act.PromptInputLine({
        description = wezterm.format({
          { Attribute = { Intensity = "Bold" } },
          { Foreground = { Color = "#7aa2f7" } },
          { Text = "Session name: " },
        }),
        action = wezterm.action_callback(function(w1, p1, name)
          if not name or name == "" then return end

          -- Ask for prompt to send to agent
          w1:perform_action(
            act.PromptInputLine({
              description = wezterm.format({
                { Attribute = { Intensity = "Bold" } },
                { Foreground = { Color = "#f7c67a" } },
                { Text = "Prompt for agent: " },
              }),
              action = wezterm.action_callback(function(w2, p2, prompt)
                M.create_session(w2, {
                  title = name,
                  program = user_config.default_program or "claude",
                  prompt = prompt,
                })
              end),
            }),
            p1
          )
        end),
      }),
      pane
    )
  end)

  -- Event: Pause current session
  wezterm.on("cs:pause-session", function(window, pane)
    local pane_id = pane:pane_id()
    local s = state.get_session_by_pane(pane_id)
    if not s then
      -- Try finding by tab
      local tab = pane:tab()
      if tab then
        s = state.get_session_by_tab(tab:tab_id())
      end
    end
    if not s then
      wezterm.log_error("AgentTUI: No session found for current pane")
      return
    end
    M.pause_session(window, s.id)
  end)

  -- Event: Resume selected session (uses InputSelector)
  wezterm.on("cs:resume-session", function(window, pane)
    local paused = {}
    for _, s in ipairs(state.get_sessions()) do
      if s.status == "paused" then
        table.insert(paused, s)
      end
    end

    if #paused == 0 then
      wezterm.log_error("AgentTUI: No paused sessions to resume")
      return
    end

    local choices = {}
    for _, s in ipairs(paused) do
      table.insert(choices, {
        id = s.id,
        label = s.title .. " [" .. s.branch .. "]",
      })
    end

    window:perform_action(
      act.InputSelector({
        title = "Resume Session",
        choices = choices,
        action = wezterm.action_callback(function(w, p, id, label)
          if id then
            M.resume_session(w, id)
          end
        end),
      }),
      pane
    )
  end)

  -- Event: Delete session
  wezterm.on("cs:delete-session", function(window, pane)
    local sessions = state.get_sessions()
    if #sessions == 0 then return end

    local choices = {}
    for _, s in ipairs(sessions) do
      local status_icon = s.status == "paused" and "[paused]" or "[active]"
      table.insert(choices, {
        id = s.id,
        label = s.title .. " " .. status_icon .. " [" .. s.branch .. "]",
      })
    end

    window:perform_action(
      act.InputSelector({
        title = "Delete Session (permanent!)",
        choices = choices,
        action = wezterm.action_callback(function(w, p, id, label)
          if id then
            M.delete_session(w, id)
          end
        end),
      }),
      pane
    )
  end)

  -- Event: Push session changes
  wezterm.on("cs:push-session", function(window, pane)
    local pane_id = pane:pane_id()
    local s = state.get_session_by_pane(pane_id)
    if not s then
      local tab = pane:tab()
      if tab then s = state.get_session_by_tab(tab:tab_id()) end
    end
    if not s then
      wezterm.log_error("AgentTUI: No session found for current pane")
      return
    end
    M.push_session(s.id)
  end)

  -- Event: Navigate to next session
  wezterm.on("cs:next-session", function(window, pane)
    M.navigate_session(window, 1)
  end)

  -- Event: Navigate to previous session
  wezterm.on("cs:prev-session", function(window, pane)
    M.navigate_session(window, -1)
  end)

  -- Event: Show diff for current session
  wezterm.on("cs:show-diff", function(window, pane)
    local s = M.find_session_for_pane(pane)
    if not s then return end
    if s.worktree_path == "" then return end

    -- Spawn a new pane with the diff
    local tab = window:active_tab()
    local diff_pane = pane:split({
      direction = "Right",
      size = 0.5,
      args = { "git", "-C", s.worktree_path, "diff", "--color=always", s.base_commit or "HEAD" },
    })
  end)

  -- Event: Open terminal in worktree
  wezterm.on("cs:open-terminal", function(window, pane)
    local s = M.find_session_for_pane(pane)
    if not s then return end
    if s.worktree_path == "" then return end

    window:perform_action(
      act.SpawnCommandInNewTab({
        cwd = s.worktree_path,
      }),
      pane
    )
  end)
end

-- Find session associated with a pane (checks pane_id then tab_id)
function M.find_session_for_pane(pane)
  local s = state.get_session_by_pane(pane:pane_id())
  if s then return s end
  local tab = pane:tab()
  if tab then
    return state.get_session_by_tab(tab:tab_id())
  end
  return nil
end

-- Create a new session and spawn the agent
function M.create_session(window, opts)
  -- Detect repo from current working directory
  local active_pane = window:active_pane()
  local cwd = ""
  if active_pane then
    local url = active_pane:get_current_working_dir()
    if url then
      cwd = url.file_path or url.path or ""
    end
  end

  local repo_path = worktree.detect_repo(cwd)
  if not repo_path then
    wezterm.log_error("AgentTUI: Not in a git repository. Navigate to a repo first.")
    return nil
  end

  -- Create worktree
  local wt, err = worktree.create(
    repo_path,
    opts.title,
    user_config.branch_prefix or "agenttui/",
    opts.existing_branch
  )

  if not wt then
    wezterm.log_error("AgentTUI: " .. (err or "Failed to create worktree"))
    return nil
  end

  -- Create session state
  local s = state.new_session({
    title = opts.title,
    program = opts.program or user_config.default_program or "claude",
    repo_path = repo_path,
    branch = wt.branch,
    is_existing_branch = wt.is_existing_branch,
    prompt = opts.prompt,
  })

  -- Update with worktree info
  state.update_session(s.id, {
    worktree_path = wt.worktree_path,
    base_commit = wt.base_commit,
    status = "loading",
  })

  -- Spawn agent in a new tab
  local tab, pane, _ = window:mux_window():spawn_tab({
    args = M.build_command(s.program),
    cwd = wt.worktree_path,
  })

  if tab and pane then
    state.update_session(s.id, {
      pane_id = pane:pane_id(),
      tab_id = tab:tab_id(),
      status = "running",
    })

    -- Set tab title
    tab:set_title(s.title)

    -- If a prompt was provided, send it after a short delay
    if opts.prompt and opts.prompt ~= "" then
      wezterm.time.call_after(2, function()
        pane:send_text(opts.prompt .. "\n")
      end)
    end
  end

  return s
end

-- Build the command args for spawning
function M.build_command(program)
  -- Split program string into args
  local args = {}
  for word in program:gmatch("%S+") do
    table.insert(args, word)
  end
  if #args == 0 then
    args = { "claude" }
  end
  return args
end

-- Pause a session: commit changes, close pane, remove worktree
function M.pause_session(window, session_id)
  local s = state.get_session_by_id(session_id)
  if not s then return end

  -- Commit any uncommitted work
  local msg = "[agenttui] pause: " .. s.title .. " at " .. os.date("%Y-%m-%d %H:%M:%S")
  worktree.commit_all(s.worktree_path, msg)

  -- Close the pane if it exists
  if s.pane_id then
    local mux_pane = wezterm.mux.get_pane(s.pane_id)
    if mux_pane then
      -- Send exit to gracefully close the agent
      mux_pane:send_text("exit\n")
      -- Give it a moment then force close
      wezterm.time.call_after(1, function()
        -- The pane should close when the process exits
      end)
    end
  end

  -- Remove worktree (keeps branch)
  worktree.remove(s.repo_path, s.worktree_path)

  -- Copy branch name to clipboard
  if window then
    window:copy_to_clipboard(s.branch, "Clipboard")
  end

  -- Update state
  state.update_session(session_id, {
    status = "paused",
    pane_id = nil,
    tab_id = nil,
    worktree_path = "",
  })
end

-- Resume a paused session
function M.resume_session(window, session_id)
  local s = state.get_session_by_id(session_id)
  if not s or s.status ~= "paused" then return end

  -- Check branch isn't checked out elsewhere
  if worktree.is_branch_checked_out(s.repo_path, s.branch) then
    wezterm.log_error("AgentTUI: Branch '" .. s.branch .. "' is checked out elsewhere")
    return
  end

  -- Recreate worktree from existing branch
  local wt, err = worktree.create(s.repo_path, s.title, "", s.branch)
  if not wt then
    wezterm.log_error("AgentTUI: " .. (err or "Failed to recreate worktree"))
    return
  end

  -- Update state
  state.update_session(session_id, {
    worktree_path = wt.worktree_path,
    status = "loading",
  })

  -- Spawn agent in new tab
  local tab, pane, _ = window:mux_window():spawn_tab({
    args = M.build_command(s.program),
    cwd = wt.worktree_path,
  })

  if tab and pane then
    state.update_session(session_id, {
      pane_id = pane:pane_id(),
      tab_id = tab:tab_id(),
      status = "running",
    })
    tab:set_title(s.title)
  end
end

-- Delete a session permanently
function M.delete_session(window, session_id)
  local s = state.get_session_by_id(session_id)
  if not s then return end

  -- Close pane if active
  if s.pane_id then
    local mux_pane = wezterm.mux.get_pane(s.pane_id)
    if mux_pane then
      mux_pane:send_text("exit\n")
    end
  end

  -- Remove worktree if exists
  if s.worktree_path and s.worktree_path ~= "" then
    worktree.remove(s.repo_path, s.worktree_path)
  end

  -- Delete branch if we created it
  if not s.is_existing_branch and s.branch ~= "" then
    worktree.delete_branch(s.repo_path, s.branch)
  end

  -- Remove from state
  state.remove_session(session_id)
end

-- Push session changes to remote
function M.push_session(session_id)
  local s = state.get_session_by_id(session_id)
  if not s or s.worktree_path == "" then return end

  local msg = "[agenttui] update from '" .. s.title .. "' at " .. os.date("%Y-%m-%d %H:%M:%S")
  worktree.commit_all(s.worktree_path, msg)
  local ok, stdout, stderr = worktree.push(s.worktree_path, s.branch)
  if not ok then
    wezterm.log_error("AgentTUI: Push failed: " .. (stderr or ""))
  end
end

-- Navigate between session tabs
function M.navigate_session(window, direction)
  local sessions = state.get_active_sessions()
  if #sessions == 0 then return end

  local current_tab = window:active_tab()
  if not current_tab then return end
  local current_tab_id = current_tab:tab_id()

  -- Find current index
  local current_idx = nil
  for i, s in ipairs(sessions) do
    if s.tab_id == current_tab_id then
      current_idx = i
      break
    end
  end

  if not current_idx then
    -- Not on a session tab, go to first session
    local first = sessions[1]
    if first and first.tab_id then
      local tabs = window:mux_window():tabs()
      for _, t in ipairs(tabs) do
        if t:tab_id() == first.tab_id then
          t:activate()
          return
        end
      end
    end
    return
  end

  -- Navigate
  local next_idx = current_idx + direction
  if next_idx < 1 then next_idx = #sessions end
  if next_idx > #sessions then next_idx = 1 end

  local next_s = sessions[next_idx]
  if next_s and next_s.tab_id then
    local tabs = window:mux_window():tabs()
    for _, t in ipairs(tabs) do
      if t:tab_id() == next_s.tab_id then
        t:activate()
        return
      end
    end
  end
end

return M
