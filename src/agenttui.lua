-- agenttui.lua
-- Standalone WezTerm config for AgentTUI
-- Launch with: wezterm --config-file /path/to/agenttui/src/agenttui.lua
--
-- This file is completely independent of the user's ~/.wezterm.lua
-- It will NOT affect any other WezTerm windows.

local wezterm = require("wezterm")
local act = wezterm.action

-- Set up global module loader (WezTerm's require doesn't work with custom paths on Windows)
local plugin_root = wezterm.config_dir:gsub("/", "\\")
dofile(plugin_root .. "\\at_loader.lua")

-- Load our modules
local at_config = AT_LOAD("at_config")
local at_state = AT_LOAD("at_state")
local at_session = AT_LOAD("at_session")
local at_ui = AT_LOAD("at_ui")
local at_keybindings = AT_LOAD("at_keybindings")
local at_daemon = AT_LOAD("at_daemon")

-- Build config
local config = wezterm.config_builder()

-- Window appearance - distinct from user's normal WezTerm
config.window_decorations = "TITLE | RESIZE"
config.color_scheme = "Catppuccin Mocha"
config.font = wezterm.font("JetBrains Mono", { weight = "Medium" })
config.font_size = 11.0
config.window_padding = { left = 4, right = 4, top = 4, bottom = 4 }
config.use_fancy_tab_bar = false
config.tab_bar_at_bottom = true
config.hide_tab_bar_if_only_one_tab = false
config.window_background_opacity = 0.97
config.initial_cols = 160
config.initial_rows = 45

-- Status update interval for our status bar
config.status_update_interval = 500

-- Apply keybindings
at_keybindings.apply(config)

-- Initialize state directory
at_state.init()

-- Load user's agenttui config
local user_config = at_config.load()

-- Wire up UI events
at_ui.setup(user_config)

-- Wire up session events
at_session.setup(user_config)

-- Start daemon if auto_yes enabled
if user_config.auto_yes then
  at_daemon.start(user_config)
end

-- Startup event: Claude Squad-style layout
wezterm.on("gui-startup", function(cmd)
  local tab, right_pane, window = wezterm.mux.spawn_window({})
  window:set_title("AgentTUI")
  tab:set_title("AgentTUI")

  -- Split left pane for session list (30%)
  local list_pane = right_pane:split({
    direction = "Left",
    size = 0.3,
    args = { "powershell", "-ExecutionPolicy", "Bypass", "-File", plugin_root .. "\\list_renderer.ps1" },
  })

  -- Welcome message in right pane
  right_pane:send_text('cls\r\n')
  wezterm.time.call_after(0.5, function()
    right_pane:send_text('echo.\r\n')
    right_pane:send_text('echo     === AgentTUI ===\r\n')
    right_pane:send_text('echo.\r\n')
    right_pane:send_text('echo     No agents running yet.\r\n')
    right_pane:send_text('echo     Press CTRL+S then n to create a new session.\r\n')
    right_pane:send_text('echo.\r\n')
  end)
end)

return config
