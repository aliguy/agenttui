-- ui.lua
-- Status bar, tab title formatting, and visual indicators

local wezterm = require("wezterm")
local state = require("at_state")
local worktree = require("at_worktree")

local M = {}

local user_config = {}

-- Status icons
local ICONS = {
  running = wezterm.nerdfonts.cod_circle_filled,    -- ●
  ready = wezterm.nerdfonts.cod_circle_filled,       -- ●
  loading = wezterm.nerdfonts.cod_loading,           -- loading
  paused = wezterm.nerdfonts.cod_debug_pause,        -- ⏸
}

-- Status colors
local COLORS = {
  running = "#a6e3a1",   -- green
  ready = "#89b4fa",     -- blue
  loading = "#f9e2af",   -- yellow
  paused = "#6c7086",    -- gray
  additions = "#a6e3a1", -- green
  deletions = "#f38ba8", -- red
  title = "#cdd6f4",     -- text
  dim = "#585b70",       -- surface2
  accent = "#7aa2f7",    -- blue accent
  bg = "#1e1e2e",        -- base
}

function M.setup(cfg)
  user_config = cfg

  -- Format tab titles with session info
  wezterm.on("format-tab-title", function(tab, tabs, panes, config, hover, max_width)
    local pane = tab.active_pane
    local s = state.get_session_by_pane(pane.pane_id)

    if not s then
      s = state.get_session_by_tab(tab.tab_id)
    end

    if s then
      local icon = ICONS[s.status] or "?"
      local color = COLORS[s.status] or COLORS.dim

      local diff_text = ""
      if s.diff_stats and (s.diff_stats.additions > 0 or s.diff_stats.deletions > 0) then
        diff_text = string.format(" +%d -%d", s.diff_stats.additions, s.diff_stats.deletions)
      end

      local title = string.format(" %s %s%s ", icon, s.title, diff_text)

      if tab.is_active then
        return {
          { Background = { Color = "#313244" } },
          { Foreground = { Color = color } },
          { Text = title },
        }
      else
        return {
          { Background = { Color = COLORS.bg } },
          { Foreground = { Color = color } },
          { Text = title },
        }
      end
    end

    -- Non-session tab (e.g., home tab)
    local title = " " .. (tab.active_pane.title or "terminal") .. " "
    if tab.is_active then
      return {
        { Background = { Color = "#313244" } },
        { Foreground = { Color = COLORS.title } },
        { Text = title },
      }
    end
    return title
  end)

  -- Status bar: left = menu hints, right = session info
  wezterm.on("update-status", function(window, pane)
    local active_tab = window:active_tab()
    local s = nil
    if active_tab then
      s = state.get_session_by_tab(active_tab:tab_id())
    end
    if not s then
      s = state.get_session_by_pane(pane:pane_id())
    end

    -- Left status: keybinding hints
    local left_items = {
      { Foreground = { Color = COLORS.dim } },
      { Text = " " },
      { Foreground = { Color = COLORS.accent } },
      { Attribute = { Intensity = "Bold" } },
      { Text = "^A" },
      { Attribute = { Intensity = "Normal" } },
      { Foreground = { Color = COLORS.dim } },
      { Text = " then: " },
      { Foreground = { Color = COLORS.title } },
      { Text = "n" },
      { Foreground = { Color = COLORS.dim } },
      { Text = " new  " },
      { Foreground = { Color = COLORS.title } },
      { Text = "N" },
      { Foreground = { Color = COLORS.dim } },
      { Text = " +prompt  " },
      { Foreground = { Color = COLORS.title } },
      { Text = "c" },
      { Foreground = { Color = COLORS.dim } },
      { Text = " pause  " },
      { Foreground = { Color = COLORS.title } },
      { Text = "r" },
      { Foreground = { Color = COLORS.dim } },
      { Text = " resume  " },
      { Foreground = { Color = COLORS.title } },
      { Text = "p" },
      { Foreground = { Color = COLORS.dim } },
      { Text = " push  " },
      { Foreground = { Color = COLORS.title } },
      { Text = "D" },
      { Foreground = { Color = COLORS.dim } },
      { Text = " delete  " },
      { Foreground = { Color = COLORS.title } },
      { Text = "d" },
      { Foreground = { Color = COLORS.dim } },
      { Text = " diff  " },
      { Foreground = { Color = COLORS.title } },
      { Text = "t" },
      { Foreground = { Color = COLORS.dim } },
      { Text = " term  " },
      { Foreground = { Color = COLORS.title } },
      { Text = "?" },
      { Foreground = { Color = COLORS.dim } },
      { Text = " help " },
    }
    window:set_left_status(wezterm.format(left_items))

    -- Right status: session info
    local right_items = {}
    if s then
      local status_color = COLORS[s.status] or COLORS.dim
      local diff_info = ""
      if s.diff_stats then
        if s.diff_stats.additions > 0 then
          diff_info = diff_info .. " +" .. s.diff_stats.additions
        end
        if s.diff_stats.deletions > 0 then
          diff_info = diff_info .. " -" .. s.diff_stats.deletions
        end
      end

      right_items = {
        { Foreground = { Color = status_color } },
        { Text = (ICONS[s.status] or "?") .. " " },
        { Foreground = { Color = COLORS.title } },
        { Attribute = { Intensity = "Bold" } },
        { Text = s.title },
        { Attribute = { Intensity = "Normal" } },
        { Foreground = { Color = COLORS.dim } },
        { Text = " | " },
        { Foreground = { Color = COLORS.accent } },
        { Text = s.branch or "" },
      }

      if diff_info ~= "" then
        table.insert(right_items, { Foreground = { Color = COLORS.dim } })
        table.insert(right_items, { Text = " |" })
        table.insert(right_items, { Foreground = { Color = COLORS.additions } })
        table.insert(right_items, { Text = diff_info })
      end

      table.insert(right_items, { Foreground = { Color = COLORS.dim } })
      table.insert(right_items, { Text = " " })
    else
      local session_count = state.count()
      right_items = {
        { Foreground = { Color = COLORS.dim } },
        { Text = "AgentTUI | " .. session_count .. " sessions " },
      }
    end
    window:set_right_status(wezterm.format(right_items))

    -- Periodically update diff stats for running sessions
    M.update_diff_stats()
  end)
end

-- Update diff stats for all running sessions
function M.update_diff_stats()
  for _, s in ipairs(state.get_running_sessions()) do
    if s.worktree_path and s.worktree_path ~= "" then
      local stats = worktree.get_diff_stats(s.worktree_path, s.base_commit)
      if stats then
        state.update_session(s.id, { diff_stats = stats })
      end
    end
  end
end

return M
