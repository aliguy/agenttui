-- agenttui.lua
-- Standalone WezTerm config for AgentTUI (Claude Squad for Windows)
--
-- Architecture: Simple tab-based sessions.
--   Tab 0 = Overview (session list on left, info on right)
--   Tab 1+ = Agent sessions (Claude Code running in each tab)
--   Alt+O = open/attach to selected session's tab
--   Alt+B = back to overview tab
--   Alt+N = new session
--   Alt+J/K = navigate sessions in list

local wezterm = require("wezterm")
local act = wezterm.action

local plugin_root = wezterm.config_dir:gsub("/", "\\")
local home = wezterm.home_dir
local STATE_DIR = home .. "/.agenttui"
local SESSIONS_PATH = STATE_DIR .. "/sessions.json"
local WORKTREE_DIR = STATE_DIR .. "/worktrees"

-- ============================================================
-- UTILS
-- ============================================================
local function win_mkdir(path)
  local wp = path:gsub("/", "\\")
  wezterm.run_child_process({ "cmd", "/c", "if not exist \"" .. wp .. "\" mkdir \"" .. wp .. "\"" })
end

local function normalize_path(p)
  if not p then return "" end
  p = p:gsub("^/(%a)/", function(drive) return drive:upper() .. ":\\" end)
  p = p:gsub("/", "\\")
  return p
end

local function git_in(dir, args)
  local norm_dir = normalize_path(dir)
  local cmd = { "git", "-C", norm_dir }
  for _, a in ipairs(args) do table.insert(cmd, a) end
  local success, stdout, stderr = wezterm.run_child_process(cmd)
  if not success then
    wezterm.log_error("AgentTUI git: " .. table.concat(cmd, " ") .. " => " .. (stderr or ""))
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
-- STATE
-- ============================================================
local sessions = {}

local function state_load()
  local f = io.open(SESSIONS_PATH, "r")
  if f then
    local content = f:read("*a")
    f:close()
    if content and content ~= "" then
      local ok, parsed = pcall(wezterm.json_parse, content)
      if ok and type(parsed) == "table" then sessions = parsed end
    end
  end
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

_G.at_selected_idx = 1
_G.at_main_tab_id = nil

local function get_selected_session()
  if #sessions == 0 then return nil end
  if _G.at_selected_idx > #sessions then _G.at_selected_idx = #sessions end
  if _G.at_selected_idx < 1 then _G.at_selected_idx = 1 end
  return sessions[_G.at_selected_idx]
end

local function write_selection()
  local sel = get_selected_session()
  local f = io.open(STATE_DIR .. "/selected.txt", "w")
  if f then
    f:write(sel and sel.id or "")
    f:close()
  end
end

local function update_session(id, updates)
  for i, s in ipairs(sessions) do
    if s.id == id then
      for k, v in pairs(updates) do sessions[i][k] = v end
      state_save()
      return sessions[i]
    end
  end
end

local function find_session_by_pane(pane_id)
  for _, s in ipairs(sessions) do
    if s.pane_id == pane_id then return s end
  end
end

-- ============================================================
-- GIT WORKTREE
-- ============================================================
local function create_worktree(repo_path, title, branch_prefix)
  local ts = tostring(os.time())
  local safe = sanitize_branch(title)
  local branch = sanitize_branch((branch_prefix or "agenttui/") .. safe .. "-" .. ts)
  local wt_path = normalize_path(WORKTREE_DIR .. "/" .. safe .. "-" .. ts)

  wezterm.log_info("AgentTUI: Creating worktree: branch=" .. branch .. " path=" .. wt_path)
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

-- ============================================================
-- HELPER: switch to a tab by tab_id
-- ============================================================
local function activate_tab_by_id(window, tab_id)
  if not tab_id then return false end
  local tabs = window:mux_window():tabs()
  for _, t in ipairs(tabs) do
    if t:tab_id() == tab_id then
      t:activate()
      return true
    end
  end
  return false
end

-- ============================================================
-- HELPER: create a session (used by Alt+N flow)
-- ============================================================
local function do_create_session(window, name, repo_input)
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

  local program = user_cfg.default_program or "claude"
  local prog_args = {}
  for word in program:gmatch("%S+") do table.insert(prog_args, word) end

  -- Spawn in a new tab (this IS the session — not hidden)
  local mwin = window:mux_window()
  local new_tab, new_pane, _ = mwin:spawn_tab({
    args = prog_args,
    cwd = wt.worktree_path,
  })

  if new_tab and new_pane then
    new_tab:set_title(name)
    local id = tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
    table.insert(sessions, {
      id = id, title = name, program = program, status = "running",
      repo_path = repo, branch = wt.branch,
      worktree_path = wt.worktree_path, base_commit = wt.base_commit,
      pane_id = new_pane:pane_id(), tab_id = new_tab:tab_id(),
      diff_stats = { additions = 0, deletions = 0 },
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    })
    _G.at_selected_idx = #sessions
    write_selection()
    state_save()
    wezterm.log_info("AgentTUI: Session '" .. name .. "' created, tab_id=" .. tostring(new_tab:tab_id()))
    -- Stay on the session tab so user can interact (accept trust prompt etc.)
  else
    wezterm.log_error("AgentTUI: Failed to spawn tab")
  end
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
config.show_tab_index_in_tab_bar = false
config.window_background_opacity = 1.0
config.initial_cols = 160
config.initial_rows = 45
config.status_update_interval = 500

-- ============================================================
-- KEYBINDINGS
-- ============================================================
config.disable_default_key_bindings = true

config.keys = {
  -- Essential WezTerm bindings
  { key = "c", mods = "CTRL|SHIFT", action = act.CopyTo("Clipboard") },
  { key = "v", mods = "CTRL|SHIFT", action = act.PasteFrom("Clipboard") },
  { key = "v", mods = "CTRL", action = act.PasteFrom("Clipboard") },
  { key = "Insert", mods = "SHIFT", action = act.PasteFrom("Clipboard") },
  { key = "-", mods = "CTRL", action = act.DecreaseFontSize },
  { key = "=", mods = "CTRL", action = act.IncreaseFontSize },
  { key = "0", mods = "CTRL", action = act.ResetFontSize },
  { key = "PageUp", mods = "SHIFT", action = act.ScrollByPage(-1) },
  { key = "PageDown", mods = "SHIFT", action = act.ScrollByPage(1) },

  -- ===========================================
  -- AgentTUI: ALT+key
  -- ===========================================

  -- New session: ALT+N
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
        _G.pending_session_name = session_name
        window:perform_action(
          act.PromptInputLine({
            description = wezterm.format({
              { Attribute = { Intensity = "Bold" } },
              { Foreground = { Color = "#f9e2af" } },
              { Text = "Git repo path: " },
            }),
            action = wezterm.action_callback(function(w2, p2, repo_input)
              local name = _G.pending_session_name
              _G.pending_session_name = nil
              if not name or not repo_input or repo_input == "" then return end
              -- Defer to avoid blocking in callback
              wezterm.time.call_after(0, function()
                do_create_session(w2, name, repo_input)
              end)
            end),
          }),
          pane
        )
      end),
    }),
  },

  -- Open/Attach to selected session: ALT+O
  {
    key = "o",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      -- Sync selection from list renderer
      local f = io.open(STATE_DIR .. "/selected.txt", "r")
      if f then
        local sel_id = f:read("*a"):gsub("%s+", "")
        f:close()
        for i, s in ipairs(sessions) do
          if s.id == sel_id then _G.at_selected_idx = i; break end
        end
      end

      local sel = get_selected_session()
      wezterm.log_info("AgentTUI: Alt+O: sel=" .. tostring(sel ~= nil) .. " idx=" .. tostring(_G.at_selected_idx) .. " count=" .. tostring(#sessions))

      if not sel then
        wezterm.log_error("AgentTUI: No session selected")
        return
      end

      wezterm.log_info("AgentTUI: Opening '" .. sel.title .. "' pane_id=" .. tostring(sel.pane_id) .. " tab_id=" .. tostring(sel.tab_id))

      -- Method 1: find tab via pane
      if sel.pane_id then
        local p = wezterm.mux.get_pane(sel.pane_id)
        if p then
          local t = p:tab()
          if t then
            t:activate()
            wezterm.log_info("AgentTUI: Attached via pane lookup")
            return
          end
        end
      end

      -- Method 2: find tab by tab_id
      if activate_tab_by_id(window, sel.tab_id) then
        wezterm.log_info("AgentTUI: Attached via tab_id")
        return
      end

      wezterm.log_error("AgentTUI: Could not find tab for '" .. sel.title .. "'")
    end),
  },

  -- Back to overview: ALT+B
  {
    key = "b",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      if _G.at_main_tab_id then
        activate_tab_by_id(window, _G.at_main_tab_id)
      else
        -- Fallback: go to first tab
        window:perform_action(act.ActivateTab(0), pane)
      end
    end),
  },

  -- Navigate sessions: ALT+J (next) / ALT+K (prev)
  {
    key = "j",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      if #sessions > 0 then
        _G.at_selected_idx = math.min((_G.at_selected_idx or 1) + 1, #sessions)
        write_selection()
        -- If we're on the overview tab, stay there. Otherwise switch to the session.
        local sel = get_selected_session()
        if sel and sel.tab_id then
          local active = window:active_tab()
          if active and active:tab_id() ~= _G.at_main_tab_id then
            activate_tab_by_id(window, sel.tab_id)
          end
        end
      end
    end),
  },
  {
    key = "k",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      if #sessions > 0 then
        _G.at_selected_idx = math.max((_G.at_selected_idx or 1) - 1, 1)
        write_selection()
        local sel = get_selected_session()
        if sel and sel.tab_id then
          local active = window:active_tab()
          if active and active:tab_id() ~= _G.at_main_tab_id then
            activate_tab_by_id(window, sel.tab_id)
          end
        end
      end
    end),
  },

  -- Pause session: ALT+C
  {
    key = "c",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      local sel = get_selected_session()
      if not sel or sel.status == "paused" then return end

      local wt = sel.worktree_path
      local repo = sel.repo_path
      local branch = sel.branch
      local sid = sel.id

      -- Send exit to claude
      if sel.pane_id then
        local p = wezterm.mux.get_pane(sel.pane_id)
        if p then p:send_text("/exit\r\n") end
      end

      update_session(sid, { status = "paused", pane_id = nil, tab_id = nil })
      window:copy_to_clipboard(branch, "Clipboard")

      -- Defer git cleanup
      wezterm.time.call_after(2, function()
        if wt and wt ~= "" then
          commit_all(wt, "[agenttui] pause: " .. sel.title)
          remove_worktree(repo, wt)
          update_session(sid, { worktree_path = "" })
        end
      end)

      -- Go back to overview
      activate_tab_by_id(window, _G.at_main_tab_id)
    end),
  },

  -- Resume session: ALT+R
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
          action = wezterm.action_callback(function(w, p, id)
            if not id then return end
            local s
            for _, sess in ipairs(sessions) do
              if sess.id == id then s = sess; break end
            end
            if not s then return end

            wezterm.time.call_after(0, function()
              local ts = tostring(os.time())
              local safe = sanitize_branch(s.title)
              local wt_path = normalize_path(WORKTREE_DIR .. "/" .. safe .. "-" .. ts)
              local ok, _, stderr = git_in(s.repo_path, { "worktree", "add", wt_path, s.branch })
              if not ok then
                wezterm.log_error("AgentTUI: Resume failed: " .. (stderr or ""))
                return
              end

              local program = s.program or "claude"
              local args = {}
              for word in program:gmatch("%S+") do table.insert(args, word) end

              local mwin = w:mux_window()
              local tab, new_pane, _ = mwin:spawn_tab({ args = args, cwd = wt_path })
              if tab and new_pane then
                tab:set_title(s.title)
                update_session(s.id, {
                  status = "running", worktree_path = wt_path,
                  pane_id = new_pane:pane_id(), tab_id = tab:tab_id(),
                })
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
        table.insert(choices, { id = s.id, label = s.title .. " [" .. s.status .. "]" })
      end

      window:perform_action(
        act.InputSelector({
          title = "Delete Session (permanent!)",
          choices = choices,
          action = wezterm.action_callback(function(w, p, id)
            if not id then return end
            wezterm.time.call_after(0, function()
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
                  write_selection()
                  break
                end
              end
            end)
          end),
        }),
        pane
      )
    end),
  },

  -- Push: ALT+S
  {
    key = "s",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      local sel = get_selected_session()
      if not sel or not sel.worktree_path or sel.worktree_path == "" then return end
      wezterm.time.call_after(0, function()
        commit_all(sel.worktree_path, "[agenttui] push: " .. sel.title)
        push_branch(sel.worktree_path, sel.branch)
        wezterm.log_info("AgentTUI: Pushed " .. sel.branch)
      end)
    end),
  },

  -- Show diff: ALT+D
  {
    key = "d",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      local sel = get_selected_session()
      if not sel or not sel.worktree_path or sel.worktree_path == "" then return end
      pane:split({
        direction = "Bottom",
        size = 0.4,
        args = { "git", "-C", sel.worktree_path, "diff", "--color=always", sel.base_commit or "HEAD" },
      })
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
        "echo   Alt+N           New session",
        "echo   Alt+O           Open/attach to session",
        "echo   Alt+B           Back to overview",
        "echo   Alt+J / Alt+K   Navigate sessions",
        "echo   Alt+S           Commit + push to GitHub",
        "echo   Alt+C           Checkout (pause session)",
        "echo   Alt+R           Resume paused session",
        "echo   Alt+Shift+D     Delete session",
        "echo   Alt+D           Show git diff",
        "echo   Alt+/           This help",
        "echo   Alt+Q           Quit",
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
  { key = "q", mods = "ALT", action = act.QuitApplication },
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
  -- Check if this tab is a session
  for _, s in ipairs(sessions) do
    if s.tab_id == tab.tab_id then
      local icons = { running = "● ", ready = "● ", loading = "○ ", paused = "⏸ " }
      local icon = icons[s.status] or "? "
      local color = COLORS[s.status] or COLORS.dim
      local title = " " .. icon .. s.title .. " "
      if tab.is_active then
        return { { Background = { Color = "#313244" } }, { Foreground = { Color = color } }, { Text = title } }
      end
      return { { Background = { Color = COLORS.bg } }, { Foreground = { Color = color } }, { Text = title } }
    end
  end

  -- Overview tab or other
  if tab.tab_id == _G.at_main_tab_id then
    local title = " AgentTUI "
    if tab.is_active then
      return { { Background = { Color = "#313244" } }, { Foreground = { Color = COLORS.accent } }, { Text = title } }
    end
    return { { Background = { Color = COLORS.bg } }, { Foreground = { Color = COLORS.accent } }, { Text = title } }
  end

  return " " .. (tab.active_pane.title or "terminal") .. " "
end)

wezterm.on("update-status", function(window, pane)
  local sel = get_selected_session()

  -- Bottom menu bar
  window:set_left_status(wezterm.format({
    { Text = "  " },
    { Foreground = { Color = "#b4befe" } }, { Text = "a-n" },
    { Foreground = { Color = "#9C9494" } }, { Text = " new" },
    { Foreground = { Color = "#3C3C3C" } }, { Text = " | " },
    { Foreground = { Color = "#b4befe" } }, { Text = "a-o" },
    { Foreground = { Color = "#9C9494" } }, { Text = " open" },
    { Foreground = { Color = "#3C3C3C" } }, { Text = " | " },
    { Foreground = { Color = "#b4befe" } }, { Text = "a-b" },
    { Foreground = { Color = "#9C9494" } }, { Text = " back" },
    { Foreground = { Color = "#3C3C3C" } }, { Text = " | " },
    { Foreground = { Color = "#b4befe" } }, { Text = "a-s" },
    { Foreground = { Color = "#9C9494" } }, { Text = " push" },
    { Foreground = { Color = "#3C3C3C" } }, { Text = " | " },
    { Foreground = { Color = "#b4befe" } }, { Text = "a-c" },
    { Foreground = { Color = "#9C9494" } }, { Text = " pause" },
    { Foreground = { Color = "#3C3C3C" } }, { Text = " | " },
    { Foreground = { Color = "#7F7A7A" } }, { Text = "a-j/k" },
    { Foreground = { Color = "#9C9494" } }, { Text = " nav" },
    { Foreground = { Color = "#3C3C3C" } }, { Text = " | " },
    { Foreground = { Color = "#7F7A7A" } }, { Text = "a-q" },
    { Foreground = { Color = "#9C9494" } }, { Text = " quit " },
  }))

  -- Right status: selected session info
  if sel then
    window:set_right_status(wezterm.format({
      { Foreground = { Color = COLORS[sel.status] or COLORS.dim } }, { Text = "● " },
      { Foreground = { Color = COLORS.text } }, { Text = sel.title .. " | " .. (sel.branch or "") .. " " },
    }))
  else
    window:set_right_status(wezterm.format({
      { Foreground = { Color = COLORS.dim } }, { Text = "AgentTUI | " .. #sessions .. " sessions " },
    }))
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
  _G.at_main_tab_id = tab:tab_id()

  -- Left pane: session list (30%)
  local list_pane = right_pane:split({
    direction = "Left",
    size = 0.3,
    args = { "powershell", "-ExecutionPolicy", "Bypass", "-File", plugin_root .. "\\list_renderer.ps1" },
  })

  -- Right pane: clean prompt
  right_pane:send_text("@title AgentTUI & cls\r\n")
end)

return config
