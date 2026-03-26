-- agenttui.lua
-- Standalone WezTerm config for AgentTUI
-- Launch with: wezterm --config-file /path/to/agenttui/src/agenttui.lua
--
-- This file is completely independent of the user's ~/.wezterm.lua
-- It will NOT affect any other WezTerm windows.

local wezterm = require("wezterm")
local act = wezterm.action

-- Resolve plugin root relative to this config file
local plugin_root = wezterm.config_dir

-- Load our modules (prefixed with at_ to avoid name clashes)
package.path = plugin_root .. "/?.lua;" .. package.path
local at_config = require("at_config")
local at_state = require("at_state")
local at_session = require("at_session")
local at_ui = require("at_ui")
local at_keybindings = require("at_keybindings")
local at_daemon = require("at_daemon")

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
  -- Spawn the main window — right pane is the "preview" area
  local tab, right_pane, window = wezterm.mux.spawn_window({})
  window:set_title("AgentTUI")
  tab:set_title("AgentTUI")

  -- Split left pane for the session list (30% width)
  local list_pane = right_pane:split({
    direction = "Left",
    size = 0.3,
    args = { "powershell", "-ExecutionPolicy", "Bypass", "-File", plugin_root .. "/list_renderer.ps1" },
  })

  -- The right pane shows a welcome message
  right_pane:send_text('cls\r\n')
  wezterm.time.call_after(0.5, function()
    right_pane:send_text('echo.\r\n')
    right_pane:send_text('echo     === AgentTUI ===\r\n')
    right_pane:send_text('echo.\r\n')
    right_pane:send_text('echo     No agents running yet.\r\n')
    right_pane:send_text('echo     Press CTRL+A then n to create a new session.\r\n')
    right_pane:send_text('echo.\r\n')
  end)
end)

return config
