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

-- ============================================================
-- GIT WORKTREE
-- ============================================================
local function git_in(dir, args)
  local cmd = { "git", "-C", dir }
  for _, a in ipairs(args) do table.insert(cmd, a) end
  local success, stdout, stderr = wezterm.run_child_process(cmd)
  return success, (stdout or ""):gsub("%s+$", ""), (stderr or ""):gsub("%s+$", "")
end

local function sanitize_branch(name)
  return name:gsub("[^%w%-_/]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
end

local function detect_repo(path)
  local ok, stdout = git_in(path or ".", { "rev-parse", "--show-toplevel" })
  if ok and stdout ~= "" then return stdout end
  return nil
end

local function create_worktree(repo_path, title, branch_prefix)
  local ts = tostring(os.time())
  local safe = sanitize_branch(title)
  local branch = (branch_prefix or "agenttui/") .. safe
  local wt_path = WORKTREE_DIR .. "/" .. safe .. "-" .. ts

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
config.hide_tab_bar_if_only_one_tab = false
config.window_background_opacity = 1.0
config.initial_cols = 160
config.initial_rows = 45
config.status_update_interval = 500

-- ============================================================
-- KEYBINDINGS (CTRL+SHIFT+key — no leader key needed)
-- ============================================================
config.keys = {
  -- New session: CTRL+SHIFT+N
  {
    key = "n",
    mods = "CTRL|SHIFT",
    action = act.PromptInputLine({
      description = wezterm.format({
        { Attribute = { Intensity = "Bold" } },
        { Foreground = { Color = "#89b4fa" } },
        { Text = "New session name: " },
      }),
      action = wezterm.action_callback(function(window, pane, line)
        if not line or line == "" then return end

        -- Detect repo from current pane
        local cwd_url = pane:get_current_working_dir()
        local cwd = cwd_url and (cwd_url.file_path or "") or ""
        cwd = cwd:gsub("/$", "")
        local repo = detect_repo(cwd)
        if not repo then
          wezterm.log_error("AgentTUI: Not in a git repo")
          return
        end

        local user_cfg = load_user_config()
        local wt, err = create_worktree(repo, line, user_cfg.branch_prefix or "agenttui/")
        if not wt then
          wezterm.log_error("AgentTUI: " .. (err or "worktree error"))
          return
        end

        local id = tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
        local program = user_cfg.default_program or "claude"
        local args = {}
        for w in program:gmatch("%S+") do table.insert(args, w) end

        local tab, new_pane, _ = window:mux_window():spawn_tab({
          args = args,
          cwd = wt.worktree_path,
        })

        if tab and new_pane then
          tab:set_title(line)
          local s = {
            id = id,
            title = line,
            program = program,
            status = "running",
            repo_path = repo,
            branch = wt.branch,
            worktree_path = wt.worktree_path,
            base_commit = wt.base_commit,
            pane_id = new_pane:pane_id(),
            tab_id = tab:tab_id(),
            diff_stats = { additions = 0, deletions = 0 },
            created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          }
          table.insert(sessions, s)
          state_save()
        end
      end),
    }),
  },

  -- New session with prompt
  {
    key = "n",
    mods = "CTRL|ALT|SHIFT",
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

  -- Pause current session
  {
    key = "c",
    mods = "CTRL|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local s = find_session_by_pane(pane:pane_id())
      if not s then
        local tab = pane:tab()
        if tab then s = find_session_by_tab(tab:tab_id()) end
      end
      if not s then return end

      local msg = "[agenttui] pause: " .. s.title .. " " .. os.date("%Y-%m-%d %H:%M:%S")
      commit_all(s.worktree_path, msg)
      pane:send_text("exit\r\n")
      wezterm.time.call_after(1, function()
        remove_worktree(s.repo_path, s.worktree_path)
      end)
      window:copy_to_clipboard(s.branch, "Clipboard")
      update_session(s.id, { status = "paused", pane_id = nil, tab_id = nil, worktree_path = "" })
    end),
  },

  -- Resume a paused session
  {
    key = "r",
    mods = "CTRL|SHIFT",
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

            local wt, err = create_worktree(s.repo_path, s.title, "")
            if not wt then return end

            local args = {}
            for word in (s.program or "claude"):gmatch("%S+") do table.insert(args, word) end

            local tab, new_pane, _ = w:mux_window():spawn_tab({
              args = args, cwd = wt.worktree_path,
            })
            if tab and new_pane then
              tab:set_title(s.title)
              update_session(s.id, {
                status = "running", worktree_path = wt.worktree_path,
                pane_id = new_pane:pane_id(), tab_id = tab:tab_id(),
              })
            end
          end),
        }),
        pane
      )
    end),
  },

  -- Delete session
  {
    key = "d",
    mods = "CTRL|ALT|SHIFT",
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

  -- Push changes
  {
    key = "p",
    mods = "CTRL|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local s = find_session_by_pane(pane:pane_id())
      if not s then
        local tab = pane:tab()
        if tab then s = find_session_by_tab(tab:tab_id()) end
      end
      if not s or not s.worktree_path or s.worktree_path == "" then return end
      local msg = "[agenttui] update from '" .. s.title .. "' " .. os.date("%Y-%m-%d %H:%M:%S")
      commit_all(s.worktree_path, msg)
      push_branch(s.worktree_path, s.branch)
    end),
  },

  -- Show diff
  {
    key = "d",
    mods = "CTRL|SHIFT",
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

  -- Open terminal in worktree
  {
    key = "t",
    mods = "CTRL|SHIFT",
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

  -- Navigate sessions
  { key = "j", mods = "CTRL|SHIFT", action = act.ActivateTabRelative(1) },
  { key = "k", mods = "CTRL|SHIFT", action = act.ActivateTabRelative(-1) },
  { key = "]", mods = "CTRL|SHIFT", action = act.ActivateTabRelative(1) },
  { key = "[", mods = "CTRL|SHIFT", action = act.ActivateTabRelative(-1) },

  -- Tab numbers
  { key = "1", mods = "CTRL|SHIFT", action = act.ActivateTab(0) },
  { key = "2", mods = "CTRL|SHIFT", action = act.ActivateTab(1) },
  { key = "3", mods = "CTRL|SHIFT", action = act.ActivateTab(2) },
  { key = "4", mods = "CTRL|SHIFT", action = act.ActivateTab(3) },
  { key = "5", mods = "CTRL|SHIFT", action = act.ActivateTab(4) },
  { key = "6", mods = "CTRL|SHIFT", action = act.ActivateTab(5) },
  { key = "7", mods = "CTRL|SHIFT", action = act.ActivateTab(6) },
  { key = "8", mods = "CTRL|SHIFT", action = act.ActivateTab(7) },
  { key = "9", mods = "CTRL|SHIFT", action = act.ActivateTab(8) },


  -- Help: CTRL+SHIFT+/
  {
    key = "/",
    mods = "CTRL|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local help_pane = pane:split({ direction = "Bottom", size = 0.4 })
      local lines = {
        "echo ========================================",
        "echo            AgentTUI Help",
        "echo ========================================",
        "echo.",
        "echo   Session Management:",
        "echo     Ctrl+Shift+N       New session",
        "echo     Ctrl+Shift+Alt+N   New session with prompt",
        "echo     Ctrl+Shift+C       Pause current session",
        "echo     Ctrl+Shift+R       Resume a paused session",
        "echo     Ctrl+Shift+P       Push changes to remote",
        "echo     Ctrl+Shift+Alt+D   Delete a session",
        "echo.",
        "echo   Navigation:",
        "echo     Ctrl+Shift+J       Next session",
        "echo     Ctrl+Shift+K       Previous session",
        "echo.",
        "echo   Views:",
        "echo     Ctrl+Shift+D       Show git diff",
        "echo     Ctrl+Shift+T       Open terminal in worktree",
        "echo.",
        "echo   Ctrl+Shift+/        This help",
        "echo ========================================",
        "pause",
        "exit",
      }
      for _, l in ipairs(lines) do
        help_pane:send_text(l .. "\r\n")
      end
    end),
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
  local s = nil
  local active_tab = window:active_tab()
  if active_tab then s = find_session_by_tab(active_tab:tab_id()) end
  if not s then s = find_session_by_pane(pane:pane_id()) end

  -- Left: keybinding hints (Ctrl+Shift+key)
  window:set_left_status(wezterm.format({
    { Foreground = { Color = COLORS.accent } }, { Attribute = { Intensity = "Bold" } },
    { Text = " Ctrl+Shift+" }, { Attribute = { Intensity = "Normal" } },
    { Foreground = { Color = COLORS.text } }, { Text = "N" },
    { Foreground = { Color = COLORS.dim } }, { Text = " new  " },
    { Foreground = { Color = COLORS.text } }, { Text = "C" },
    { Foreground = { Color = COLORS.dim } }, { Text = " pause  " },
    { Foreground = { Color = COLORS.text } }, { Text = "R" },
    { Foreground = { Color = COLORS.dim } }, { Text = " resume  " },
    { Foreground = { Color = COLORS.text } }, { Text = "P" },
    { Foreground = { Color = COLORS.dim } }, { Text = " push  " },
    { Foreground = { Color = COLORS.text } }, { Text = "D" },
    { Foreground = { Color = COLORS.dim } }, { Text = " diff  " },
    { Foreground = { Color = COLORS.text } }, { Text = "/" },
    { Foreground = { Color = COLORS.dim } }, { Text = " help " },
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

wezterm.on("gui-startup", function(cmd)
  local tab, right_pane, window = wezterm.mux.spawn_window({})
  window:set_title("AgentTUI")
  tab:set_title("AgentTUI")

  -- Left pane: session list
  local list_pane = right_pane:split({
    direction = "Left",
    size = 0.3,
    args = { "powershell", "-ExecutionPolicy", "Bypass", "-File", plugin_root .. "\\list_renderer.ps1" },
  })

  -- Right pane: welcome via a one-shot PowerShell command (clean output, no prompt noise)
  -- We close the default cmd pane and replace with a clean powershell welcome
  right_pane:send_text("powershell -NoProfile -Command \"cls; Write-Host; Write-Host; Write-Host '         === AgentTUI ===' -ForegroundColor Cyan; Write-Host; Write-Host '     No agents running yet.' -ForegroundColor Gray; Write-Host; Write-Host '  Press Ctrl+Shift+N to create' -ForegroundColor Gray; Write-Host '  a new session.' -ForegroundColor Gray; Write-Host; Read-Host 'Press Enter to dismiss'\"\r\n")
end)

return config
