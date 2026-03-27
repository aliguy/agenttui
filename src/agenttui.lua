-- agenttui.lua
-- Standalone WezTerm config for AgentTUI
-- Everything in one file to avoid module loading issues on Windows.

local wezterm = require("wezterm")
local act = wezterm.action

local plugin_root = wezterm.config_dir:gsub("/", "\\")
local home = wezterm.home_dir
local STATE_DIR = home .. "/.agenttui"
local SESSIONS_PATH = STATE_DIR .. "/sessions.json"
local WORKTREE_DIR = STATE_DIR .. "/worktrees"

-- ============================================================
-- CONFIG
-- ============================================================
local DEFAULT_PROGRAM = "claude"
local MAX_SESSIONS = 10

local function win_mkdir(path)
  local wp = path:gsub("/", "\\")
  wezterm.run_child_process({ "cmd", "/c", "if not exist \"" .. wp .. "\" mkdir \"" .. wp .. "\"" })
end

local function load_user_config()
  local f = io.open(STATE_DIR .. "/config.json", "r")
  if f then
    local content = f:read("*a")
    f:close()
    local ok, parsed = pcall(wezterm.json_parse, content)
    if ok and parsed then return parsed end
  end
  return { default_program = "claude", auto_yes = false, branch_prefix = "agenttui/" }
end

-- ============================================================
-- STATE (in-memory + JSON persistence)
-- ============================================================
local sessions = {}

local function state_load()
  local f = io.open(SESSIONS_PATH, "r")
  if f then
    local content = f:read("*a")
    f:close()
    if content and content ~= "" then
      local ok, parsed = pcall(wezterm.json_parse, content)
      if ok and type(parsed) == "table" then
        sessions = parsed
        return
      end
    end
  end
  sessions = {}
end

local function state_save()
  local f = io.open(SESSIONS_PATH, "w")
  if f then
    f:write(wezterm.json_encode(sessions))
    f:close()
  end
end

local function state_init()
  win_mkdir(STATE_DIR)
  win_mkdir(WORKTREE_DIR)
  state_load()
end

local function find_session_by_pane(pane_id)
  for _, s in ipairs(sessions) do
    if s.pane_id == pane_id then return s end
  end
  return nil
end

local function find_session_by_tab(tab_id)
  for _, s in ipairs(sessions) do
    if s.tab_id == tab_id then return s end
  end
  return nil
end

local function update_session(id, updates)
  for i, s in ipairs(sessions) do
    if s.id == id then
      for k, v in pairs(updates) do
        sessions[i][k] = v
      end
      state_save()
      return sessions[i]
    end
  end
  return nil
end

-- Selected session index (1-based)
_G.at_selected_idx = 1

local function get_selected_session()
  if #sessions == 0 then return nil end
  if _G.at_selected_idx > #sessions then _G.at_selected_idx = #sessions end
  if _G.at_selected_idx < 1 then _G.at_selected_idx = 1 end
  return sessions[_G.at_selected_idx]
end

-- Write selected index to file for list_renderer to read
local function write_selection()
  local sel = get_selected_session()
  local f = io.open(STATE_DIR .. "/selected.txt", "w")
  if f then
    f:write(sel and sel.id or "")
    f:close()
  end
end

-- Sync selection from list renderer (reads selected.txt)
local function sync_selection_from_list()
  local f = io.open(STATE_DIR .. "/selected.txt", "r")
  if f then
    local sel_id = f:read("*a")
    f:close()
    if sel_id then
      sel_id = sel_id:gsub("%s+", "")
      for i, s in ipairs(sessions) do
        if s.id == sel_id and i ~= _G.at_selected_idx then
          _G.at_selected_idx = i
          break
        end
      end
    end
  end
end

-- Refresh the preview pane with the selected session's terminal output
function refresh_preview()
  local preview_pane = _G.at_preview_pane_id and wezterm.mux.get_pane(_G.at_preview_pane_id)
  if not preview_pane then return end

  -- Sync selection from list renderer (in case user navigated there with j/k)
  sync_selection_from_list()
  -- Also reload sessions in case they changed
  state_load()

  local sel = get_selected_session()
  if not sel or not sel.pane_id then
    -- No session selected — show empty state
    preview_pane:inject_output("\x1b[2J\x1b[H")  -- clear screen
    preview_pane:inject_output("\r\n  No session selected.\r\n")
    return
  end

  -- Get the session's actual pane
  local session_pane = wezterm.mux.get_pane(sel.pane_id)
  if not session_pane then return end

  -- Capture the session's terminal output with full escape sequences (colors, formatting)
  local text = session_pane:get_lines_as_escapes(50)
  if text then
    -- Clear preview and inject captured output with escapes
    preview_pane:inject_output("\x1b[2J\x1b[H")  -- clear
    preview_pane:inject_output(text)
  end
end

-- Start periodic preview refresh
local function start_preview_timer()
  wezterm.time.call_after(1, function()
    refresh_preview()
    start_preview_timer()  -- reschedule
  end)
end

-- ============================================================
-- GIT WORKTREE
-- ============================================================
-- Convert /c/Users/... or /C/Users/... to C:\Users\...
local function normalize_path(p)
  if not p then return "" end
  -- Convert MSYS-style /c/ to C:\
  p = p:gsub("^/(%a)/", function(drive) return drive:upper() .. ":\\" end)
  -- Convert remaining forward slashes to backslashes
  p = p:gsub("/", "\\")
  return p
end

local function git_in(dir, args)
  local norm_dir = normalize_path(dir)
  local cmd = { "git", "-C", norm_dir }
  for _, a in ipairs(args) do table.insert(cmd, a) end
  local success, stdout, stderr = wezterm.run_child_process(cmd)
  if not success then
    wezterm.log_error("AgentTUI git failed: " .. table.concat(cmd, " ") .. " => " .. (stderr or ""))
  end
  return success, (stdout or ""):gsub("%s+$", ""), (stderr or ""):gsub("%s+$", "")
end

local function sanitize_branch(name)
  return name:gsub("[^%w%-_/.]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
end

local function detect_repo(path)
  local norm = normalize_path(path or ".")
  local ok, stdout = git_in(norm, { "rev-parse", "--show-toplevel" })
  if ok and stdout ~= "" then return normalize_path(stdout) end
  return nil
end

local function create_worktree(repo_path, title, branch_prefix)
  local ts = tostring(os.time())
  local safe = sanitize_branch(title)
  local branch = sanitize_branch((branch_prefix or "agenttui/") .. safe .. "-" .. ts)
  local wt_path = normalize_path(WORKTREE_DIR .. "/" .. safe .. "-" .. ts)

  wezterm.log_info("AgentTUI: Creating worktree: repo=" .. repo_path .. " branch=" .. branch .. " path=" .. wt_path)

  local ok, _, stderr = git_in(repo_path, { "worktree", "add", "-b", branch, wt_path })
  if not ok then return nil, "Worktree failed: " .. stderr end

  local _, base = git_in(repo_path, { "rev-parse", "HEAD" })
  return { worktree_path = wt_path, branch = branch, base_commit = base or "" }, nil
end

local function remove_worktree(repo_path, wt_path)
  git_in(repo_path, { "worktree", "remove", wt_path, "--force" })
  git_in(repo_path, { "worktree", "prune" })
end

local function delete_branch(repo_path, branch)
  git_in(repo_path, { "branch", "-D", branch })
end

local function commit_all(wt_path, msg)
  git_in(wt_path, { "add", "-A" })
  git_in(wt_path, { "commit", "-m", msg, "--allow-empty" })
end

local function push_branch(wt_path, branch)
  return git_in(wt_path, { "push", "-u", "origin", branch })
end

local function get_diff_stats(wt_path, base)
  git_in(wt_path, { "add", "-N", "." })
  local ok, stdout
  if base and base ~= "" then
    ok, stdout = git_in(wt_path, { "diff", "--stat", base })
  else
    ok, stdout = git_in(wt_path, { "diff", "--stat" })
  end
  local a = (stdout or ""):match("(%d+) insertion") or "0"
  local d = (stdout or ""):match("(%d+) deletion") or "0"
  return { additions = tonumber(a), deletions = tonumber(d) }
end

-- ============================================================
-- BUILD CONFIG
-- ============================================================
local config = wezterm.config_builder()

config.window_decorations = "TITLE | RESIZE"
config.color_scheme = "Catppuccin Mocha"
config.font = wezterm.font("JetBrains Mono", { weight = "Medium" })
config.font_size = 11.0
config.window_padding = { left = 4, right = 4, top = 4, bottom = 4 }
config.use_fancy_tab_bar = false
config.tab_bar_at_bottom = true
config.hide_tab_bar_if_only_one_tab = true
config.show_tab_index_in_tab_bar = false
config.window_background_opacity = 1.0
config.initial_cols = 160
config.initial_rows = 45
config.status_update_interval = 500

-- ============================================================
-- KEYBINDINGS
-- Disable WezTerm defaults to avoid conflicts, then define our own.
-- Using ALT+key for AgentTUI actions (doesn't conflict with terminal)
-- ============================================================
config.disable_default_key_bindings = true

-- Re-add essential WezTerm bindings
config.keys = {
  -- Clipboard (both CTRL+C/V and CTRL+SHIFT+C/V)
  { key = "c", mods = "CTRL|SHIFT", action = act.CopyTo("Clipboard") },
  { key = "v", mods = "CTRL|SHIFT", action = act.PasteFrom("Clipboard") },
  { key = "v", mods = "CTRL", action = act.PasteFrom("Clipboard") },
  { key = "Insert", mods = "SHIFT", action = act.PasteFrom("Clipboard") },
  -- Font size
  { key = "-", mods = "CTRL", action = act.DecreaseFontSize },
  { key = "=", mods = "CTRL", action = act.IncreaseFontSize },
  { key = "0", mods = "CTRL", action = act.ResetFontSize },
  -- Scroll
  { key = "PageUp", mods = "SHIFT", action = act.ScrollByPage(-1) },
  { key = "PageDown", mods = "SHIFT", action = act.ScrollByPage(1) },
  -- Pane navigation
  { key = "LeftArrow", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Left") },
  { key = "RightArrow", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Right") },
  { key = "UpArrow", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Up") },
  { key = "DownArrow", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Down") },
  -- Tab navigation (Ctrl+Tab / Ctrl+Shift+Tab)
  { key = "Tab", mods = "CTRL", action = act.ActivateTabRelative(1) },
  { key = "Tab", mods = "CTRL|SHIFT", action = act.ActivateTabRelative(-1) },
  -- Close tab
  { key = "w", mods = "CTRL|SHIFT", action = act.CloseCurrentTab({ confirm = true }) },

  -- ===========================================
  -- AgentTUI bindings: ALT+key
  -- ===========================================

  -- New session: ALT+N
  -- Two prompts: 1) session name, 2) repo path
  {
    key = "n",
    mods = "ALT",
    action = act.PromptInputLine({
      description = wezterm.format({
        { Attribute = { Intensity = "Bold" } },
        { Foreground = { Color = "#89b4fa" } },
        { Text = "New session name: " },
      }),
      action = wezterm.action_callback(function(window, pane, session_name)
        if not session_name or session_name == "" then return end
        -- Capture mux_window now — it gets lost in nested callbacks
        local mux_win = window:mux_window()
        _G.pending_session_name = session_name
        _G.pending_mux_window = mux_win
        window:perform_action(
          act.PromptInputLine({
            description = wezterm.format({
              { Attribute = { Intensity = "Bold" } },
              { Foreground = { Color = "#f9e2af" } },
              { Text = "Git repo path: " },
            }),
            action = wezterm.action_callback(function(w2, p2, repo_input)
              local name = _G.pending_session_name
              local mwin = _G.pending_mux_window
              _G.pending_session_name = nil
              _G.pending_mux_window = nil
              if not name then return end
              if not repo_input or repo_input == "" then
                wezterm.log_error("AgentTUI: No repo path provided")
                return
              end

              -- Defer git ops out of callback
              wezterm.time.call_after(0, function()
                local repo = detect_repo(repo_input)
                if not repo then
                  wezterm.log_error("AgentTUI: '" .. repo_input .. "' is not a git repo")
                  return
                end

                local user_cfg = load_user_config()
                local wt, err = create_worktree(repo, name, user_cfg.branch_prefix or "agenttui/")
                if not wt then
                  wezterm.log_error("AgentTUI: " .. (err or "worktree error"))
                  return
                end

                local id = tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
                local program = user_cfg.default_program or "claude"
                local prog_args = {}
                for word in program:gmatch("%S+") do table.insert(prog_args, word) end

                -- Spawn agent in a HIDDEN TAB (not the preview pane)
                local new_tab, new_pane, _ = mwin:spawn_tab({
                  args = prog_args,
                  cwd = wt.worktree_path,
                })

                if new_tab and new_pane then
                  new_tab:set_title(name)
                  table.insert(sessions, {
                    id = id, title = name, program = program, status = "running",
                    repo_path = repo, branch = wt.branch,
                    worktree_path = wt.worktree_path, base_commit = wt.base_commit,
                    pane_id = new_pane:pane_id(),
                    tab_id = new_tab:tab_id(),
                    diff_stats = { additions = 0, deletions = 0 },
                    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                  })
                  -- Select the new session
                  _G.at_selected_idx = #sessions
                  write_selection()
                  state_save()

                  -- Switch back to the main tab (list + preview)
                  wezterm.time.call_after(0.5, function()
                    local main_tab_id = _G.at_main_tab_id
                    if main_tab_id then
                      local tabs = mwin:tabs()
                      for _, t in ipairs(tabs) do
                        if t:tab_id() == main_tab_id then
                          t:activate()
                          break
                        end
                      end
                    end
                  end)

                  wezterm.log_info("AgentTUI: Session '" .. name .. "' created on branch " .. wt.branch)
                else
                  wezterm.log_error("AgentTUI: Failed to spawn tab")
                end
              end)
            end),
          }),
          pane
        )
      end),
    }),
  },

  -- New session with prompt: ALT+SHIFT+N
  {
    key = "n",
    mods = "ALT|SHIFT",
    action = act.PromptInputLine({
      description = wezterm.format({
        { Attribute = { Intensity = "Bold" } },
        { Foreground = { Color = "#89b4fa" } },
        { Text = "New session name: " },
      }),
      action = wezterm.action_callback(function(window, pane, line)
        if not line or line == "" then return end

        window:perform_action(
          act.PromptInputLine({
            description = wezterm.format({
              { Attribute = { Intensity = "Bold" } },
              { Foreground = { Color = "#f9e2af" } },
              { Text = "Prompt for agent: " },
            }),
            action = wezterm.action_callback(function(w2, p2, prompt)
              local cwd_url = p2:get_current_working_dir()
              local cwd = cwd_url and (cwd_url.file_path or "") or ""
              cwd = cwd:gsub("/$", "")
              local repo = detect_repo(cwd)
              if not repo then return end

              local user_cfg = load_user_config()
              local wt, err = create_worktree(repo, line, user_cfg.branch_prefix)
              if not wt then return end

              local program = user_cfg.default_program or "claude"
              local args = {}
              for w in program:gmatch("%S+") do table.insert(args, w) end

              local tab, new_pane, _ = w2:mux_window():spawn_tab({
                args = args,
                cwd = wt.worktree_path,
              })

              if tab and new_pane then
                tab:set_title(line)
                local id = tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
                table.insert(sessions, {
                  id = id, title = line, program = program, status = "running",
                  repo_path = repo, branch = wt.branch,
                  worktree_path = wt.worktree_path, base_commit = wt.base_commit,
                  pane_id = new_pane:pane_id(), tab_id = tab:tab_id(),
                  diff_stats = { additions = 0, deletions = 0 },
                  created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                })
                state_save()

                if prompt and prompt ~= "" then
                  wezterm.time.call_after(2, function()
                    new_pane:send_text(prompt .. "\n")
                  end)
                end
              end
            end),
          }),
          pane
        )
      end),
    }),
  },

  -- Pause current session: ALT+C (checkout)
  {
    key = "c",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      local s = find_session_by_pane(pane:pane_id())
      if not s then
        local tab = pane:tab()
        if tab then s = find_session_by_tab(tab:tab_id()) end
      end
      if not s or s.status == "paused" then return end

      local wt = s.worktree_path
      local repo = s.repo_path
      local branch = s.branch

      -- Send exit to the agent, then defer git ops
      pane:send_text("/exit\r\n")
      update_session(s.id, { status = "paused", pane_id = nil, tab_id = nil })

      wezterm.time.call_after(2, function()
        if wt and wt ~= "" then
          commit_all(wt, "[agenttui] pause: " .. s.title .. " " .. os.date("%Y-%m-%d %H:%M:%S"))
          remove_worktree(repo, wt)
          update_session(s.id, { worktree_path = "" })
        end
      end)

      -- Copy branch to clipboard
      window:copy_to_clipboard(branch, "Clipboard")

      -- Show paused message in the pane
      wezterm.time.call_after(3, function()
        pane:send_text("echo Session '" .. s.title .. "' paused. Branch: " .. branch .. "\r\n")
      end)
    end),
  },

  -- Resume a paused session: ALT+R
  {
    key = "r",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      local paused = {}
      for _, s in ipairs(sessions) do
        if s.status == "paused" then
          table.insert(paused, { id = s.id, label = s.title .. " [" .. (s.branch or "") .. "]" })
        end
      end
      if #paused == 0 then return end

      window:perform_action(
        act.InputSelector({
          title = "Resume Session",
          choices = paused,
          action = wezterm.action_callback(function(w, p, id, label)
            if not id then return end
            local s
            for _, sess in ipairs(sessions) do
              if sess.id == id then s = sess; break end
            end
            if not s then return end

            -- Defer git ops
            local mwin = w:mux_window()
            wezterm.time.call_after(0, function()
              -- Recreate worktree from existing branch
              local ts = tostring(os.time())
              local safe = sanitize_branch(s.title)
              local wt_path = normalize_path(WORKTREE_DIR .. "/" .. safe .. "-" .. ts)

              local ok, _, stderr = git_in(s.repo_path, { "worktree", "add", wt_path, s.branch })
              if not ok then
                wezterm.log_error("AgentTUI: Resume failed: " .. (stderr or ""))
                return
              end

              -- Launch agent in the preview pane
              local preview_pane = _G.at_preview_pane_id and wezterm.mux.get_pane(_G.at_preview_pane_id)
              if preview_pane then
                local program = s.program or "claude"
                local cmd = "cd /d " .. wt_path .. " && " .. program
                preview_pane:send_text(cmd .. "\r\n")

                update_session(s.id, {
                  status = "running", worktree_path = wt_path,
                  pane_id = preview_pane:pane_id(),
                  tab_id = preview_pane:tab() and preview_pane:tab():tab_id() or nil,
                })
                wezterm.log_info("AgentTUI: Resumed session '" .. s.title .. "'")
              end
            end)
          end),
        }),
        pane
      )
    end),
  },

  -- Delete session: ALT+SHIFT+D
  {
    key = "d",
    mods = "ALT|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      if #sessions == 0 then return end
      local choices = {}
      for _, s in ipairs(sessions) do
        local icon = s.status == "paused" and "[paused]" or "[active]"
        table.insert(choices, { id = s.id, label = s.title .. " " .. icon })
      end

      window:perform_action(
        act.InputSelector({
          title = "Delete Session (permanent!)",
          choices = choices,
          action = wezterm.action_callback(function(w, p, id)
            if not id then return end
            for i, s in ipairs(sessions) do
              if s.id == id then
                if s.pane_id then
                  local mp = wezterm.mux.get_pane(s.pane_id)
                  if mp then mp:send_text("exit\r\n") end
                end
                if s.worktree_path and s.worktree_path ~= "" then
                  remove_worktree(s.repo_path, s.worktree_path)
                end
                if s.branch and s.branch ~= "" then
                  delete_branch(s.repo_path, s.branch)
                end
                table.remove(sessions, i)
                state_save()
                break
              end
            end
          end),
        }),
        pane
      )
    end),
  },

  -- Attach to selected session: ALT+ENTER (switch to session's tab for direct interaction)
  {
    key = "Enter",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      local sel = get_selected_session()
      if not sel or not sel.tab_id then return end

      -- Find and activate the session's tab
      local tabs = window:mux_window():tabs()
      for _, t in ipairs(tabs) do
        if t:tab_id() == sel.tab_id then
          t:activate()
          wezterm.log_info("AgentTUI: Attached to '" .. sel.title .. "'")
          return
        end
      end
    end),
  },

  -- Detach from session: ALT+ESCAPE (return to main overview tab)
  {
    key = "Escape",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      local main_tab_id = _G.at_main_tab_id
      if not main_tab_id then return end

      local tabs = window:mux_window():tabs()
      for _, t in ipairs(tabs) do
        if t:tab_id() == main_tab_id then
          t:activate()
          wezterm.log_info("AgentTUI: Detached to overview")
          return
        end
      end
    end),
  },

  -- Submit PR / Push changes: ALT+S
  {
    key = "s",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      local s = find_session_by_pane(pane:pane_id())
      if not s then
        local tab = pane:tab()
        if tab then s = find_session_by_tab(tab:tab_id()) end
      end
      if not s or not s.worktree_path or s.worktree_path == "" then return end

      local wt = s.worktree_path
      local branch = s.branch
      local title = s.title
      wezterm.time.call_after(0, function()
        local msg = "[agenttui] update from '" .. title .. "' " .. os.date("%Y-%m-%d %H:%M:%S")
        commit_all(wt, msg)
        local ok, _, stderr = push_branch(wt, branch)
        if ok then
          wezterm.log_info("AgentTUI: Pushed " .. branch)
        else
          wezterm.log_error("AgentTUI: Push failed: " .. (stderr or ""))
        end
      end)
    end),
  },

  -- Show diff: ALT+D
  {
    key = "d",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      local s = find_session_by_pane(pane:pane_id())
      if not s then
        local tab = pane:tab()
        if tab then s = find_session_by_tab(tab:tab_id()) end
      end
      if not s or not s.worktree_path or s.worktree_path == "" then return end
      pane:split({
        direction = "Right",
        size = 0.5,
        args = { "git", "-C", s.worktree_path, "diff", "--color=always", s.base_commit or "HEAD" },
      })
    end),
  },

  -- Open terminal in worktree: ALT+T
  {
    key = "t",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      local s = find_session_by_pane(pane:pane_id())
      if not s then
        local tab = pane:tab()
        if tab then s = find_session_by_tab(tab:tab_id()) end
      end
      if not s or not s.worktree_path or s.worktree_path == "" then return end
      window:perform_action(act.SpawnCommandInNewTab({ cwd = s.worktree_path }), pane)
    end),
  },

  -- Navigate sessions: ALT+J (down) / ALT+K (up)
  {
    key = "j",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      if #sessions > 0 then
        _G.at_selected_idx = (_G.at_selected_idx or 1) + 1
        if _G.at_selected_idx > #sessions then _G.at_selected_idx = #sessions end
        write_selection()
        refresh_preview()
      end
    end),
  },
  {
    key = "k",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      if #sessions > 0 then
        _G.at_selected_idx = (_G.at_selected_idx or 1) - 1
        if _G.at_selected_idx < 1 then _G.at_selected_idx = 1 end
        write_selection()
        refresh_preview()
      end
    end),
  },

  -- Help: ALT+/
  {
    key = "/",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      local help_pane = pane:split({ direction = "Bottom", size = 0.4 })
      local lines = {
        "echo ========================================",
        "echo            AgentTUI Help",
        "echo ========================================",
        "echo.",
        "echo   Session Management:",
        "echo     Alt+N           New session",
        "echo     Alt+Shift+N     New session with prompt",
        "echo     Alt+Shift+D     Delete a session",
        "echo.",
        "echo   Actions:",
        "echo     Alt+S           Commit and push to GitHub",
        "echo     Alt+C           Checkout (pause session)",
        "echo     Alt+R           Resume a paused session",
        "echo.",
        "echo   Navigation:",
        "echo     Alt+J / Alt+K   Next / Previous session",
        "echo.",
        "echo   Views:",
        "echo     Alt+D           Show git diff",
        "echo     Alt+T           Open terminal in worktree",
        "echo.",
        "echo   Other:",
        "echo     Alt+/           This help",
        "echo     Alt+Q           Quit AgentTUI",
        "echo ========================================",
        "pause",
        "exit",
      }
      for _, l in ipairs(lines) do
        help_pane:send_text(l .. "\r\n")
      end
    end),
  },

  -- Quit: ALT+Q
  {
    key = "q",
    mods = "ALT",
    action = act.QuitApplication,
  },
}

-- ============================================================
-- UI: Tab titles + status bar
-- ============================================================
local COLORS = {
  running = "#a6e3a1", ready = "#89b4fa", loading = "#f9e2af",
  paused = "#6c7086", green = "#a6e3a1", red = "#f38ba8",
  text = "#cdd6f4", dim = "#585b70", accent = "#89b4fa", bg = "#1e1e2e",
}

wezterm.on("format-tab-title", function(tab, tabs, panes, cfg, hover, max_width)
  local s = find_session_by_tab(tab.tab_id)
  if not s then s = find_session_by_pane(tab.active_pane.pane_id) end

  if s then
    local icons = { running = "● ", ready = "● ", loading = "○ ", paused = "⏸ " }
    local icon = icons[s.status] or "? "
    local color = COLORS[s.status] or COLORS.dim
    local diff = ""
    if s.diff_stats and (s.diff_stats.additions > 0 or s.diff_stats.deletions > 0) then
      diff = string.format(" +%d -%d", s.diff_stats.additions, s.diff_stats.deletions)
    end
    local title = " " .. icon .. s.title .. diff .. " "
    if tab.is_active then
      return { { Background = { Color = "#313244" } }, { Foreground = { Color = color } }, { Text = title } }
    end
    return { { Background = { Color = COLORS.bg } }, { Foreground = { Color = color } }, { Text = title } }
  end

  local title = " " .. (tab.active_pane.title or "terminal") .. " "
  if tab.is_active then
    return { { Background = { Color = "#313244" } }, { Foreground = { Color = COLORS.text } }, { Text = title } }
  end
  return title
end)

wezterm.on("update-status", function(window, pane)
  local s = get_selected_session()

  -- Bottom menu bar (Claude Squad style)
  window:set_left_status(wezterm.format({
    { Text = "  " },
    { Foreground = { Color = "#b4befe" } }, { Text = "a-n" },
    { Foreground = { Color = "#9C9494" } }, { Text = " new" },
    { Foreground = { Color = "#3C3C3C" } }, { Text = " | " },
    { Foreground = { Color = "#b4befe" } }, { Text = "a-D" },
    { Foreground = { Color = "#9C9494" } }, { Text = " kill" },
    { Foreground = { Color = "#3C3C3C" } }, { Text = " | " },
    { Foreground = { Color = "#b4befe" } }, { Text = "a-s" },
    { Foreground = { Color = "#9C9494" } }, { Text = " submit PR" },
    { Foreground = { Color = "#3C3C3C" } }, { Text = " | " },
    { Foreground = { Color = "#b4befe" } }, { Text = "a-c" },
    { Foreground = { Color = "#9C9494" } }, { Text = " checkout" },
    { Foreground = { Color = "#3C3C3C" } }, { Text = " | " },
    { Foreground = { Color = "#b4befe" } }, { Text = "a-Ret" },
    { Foreground = { Color = "#9C9494" } }, { Text = " attach" },
    { Foreground = { Color = "#3C3C3C" } }, { Text = " | " },
    { Foreground = { Color = "#b4befe" } }, { Text = "a-Esc" },
    { Foreground = { Color = "#9C9494" } }, { Text = " detach" },
    { Foreground = { Color = "#3C3C3C" } }, { Text = " | " },
    { Foreground = { Color = "#7F7A7A" } }, { Text = "a-j/k" },
    { Foreground = { Color = "#9C9494" } }, { Text = " nav" },
    { Foreground = { Color = "#3C3C3C" } }, { Text = " | " },
    { Foreground = { Color = "#7F7A7A" } }, { Text = "a-q" },
    { Foreground = { Color = "#9C9494" } }, { Text = " quit " },
  }))

  -- Right: session info
  if s then
    local info = (s.title or "") .. " | " .. (s.branch or "")
    window:set_right_status(wezterm.format({
      { Foreground = { Color = COLORS[s.status] or COLORS.dim } }, { Text = "● " },
      { Foreground = { Color = COLORS.text } }, { Text = info .. " " },
    }))
  else
    window:set_right_status(wezterm.format({
      { Foreground = { Color = COLORS.dim } }, { Text = "AgentTUI | " .. #sessions .. " sessions " },
    }))
  end

  -- Update diff stats for running sessions
  for _, sess in ipairs(sessions) do
    if (sess.status == "running" or sess.status == "ready") and sess.worktree_path and sess.worktree_path ~= "" then
      local stats = get_diff_stats(sess.worktree_path, sess.base_commit)
      if stats then sess.diff_stats = stats end
    end
  end
end)

-- ============================================================
-- STARTUP
-- ============================================================
state_init()

-- Global pane references for the split layout
_G.at_list_pane_id = nil
_G.at_preview_pane_id = nil
_G.at_main_tab_id = nil

wezterm.on("gui-startup", function(cmd)
  local tab, right_pane, window = wezterm.mux.spawn_window({})
  window:set_title("AgentTUI")
  tab:set_title("AgentTUI")

  -- Left pane: session list (30%)
  local list_pane = right_pane:split({
    direction = "Left",
    size = 0.3,
    args = { "powershell", "-ExecutionPolicy", "Bypass", "-File", plugin_root .. "\\list_renderer.ps1" },
  })

  -- Store pane IDs for later
  _G.at_list_pane_id = list_pane:pane_id()
  _G.at_preview_pane_id = right_pane:pane_id()
  _G.at_main_tab_id = tab:tab_id()

  -- Right pane: clean prompt for preview
  right_pane:send_text("@title AgentTUI Preview & cls\r\n")

  -- Start preview refresh timer
  start_preview_timer()
end)

return config
