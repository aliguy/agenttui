-- keybindings.lua
-- Leader key + key table bindings for AgentTUI

local wezterm = AT_WEZTERM or require("wezterm")
local act = wezterm.action

local M = {}

function M.apply(config)
  -- Leader key: CTRL+S
  config.leader = { key = "s", mods = "CTRL", timeout_milliseconds = 2000 }

  config.keys = {
    -- =====================
    -- Session management
    -- =====================

    -- New session
    {
      key = "n",
      mods = "LEADER",
      action = act.EmitEvent("cs:new-session"),
    },

    -- New session with prompt
    {
      key = "n",
      mods = "LEADER|SHIFT",
      action = act.EmitEvent("cs:new-session-prompt"),
    },

    -- Pause current session (checkout)
    {
      key = "c",
      mods = "LEADER",
      action = act.EmitEvent("cs:pause-session"),
    },

    -- Resume a paused session
    {
      key = "r",
      mods = "LEADER",
      action = act.EmitEvent("cs:resume-session"),
    },

    -- Push changes
    {
      key = "p",
      mods = "LEADER",
      action = act.EmitEvent("cs:push-session"),
    },

    -- Delete session
    {
      key = "d",
      mods = "LEADER|SHIFT",
      action = act.EmitEvent("cs:delete-session"),
    },

    -- =====================
    -- Navigation
    -- =====================

    -- Next session tab
    {
      key = "j",
      mods = "LEADER",
      action = act.EmitEvent("cs:next-session"),
    },

    -- Previous session tab
    {
      key = "k",
      mods = "LEADER",
      action = act.EmitEvent("cs:prev-session"),
    },

    -- Also support bracket navigation
    {
      key = "]",
      mods = "LEADER",
      action = act.EmitEvent("cs:next-session"),
    },
    {
      key = "[",
      mods = "LEADER",
      action = act.EmitEvent("cs:prev-session"),
    },

    -- =====================
    -- Views
    -- =====================

    -- Show diff for current session
    {
      key = "d",
      mods = "LEADER",
      action = act.EmitEvent("cs:show-diff"),
    },

    -- Open terminal in worktree
    {
      key = "t",
      mods = "LEADER",
      action = act.EmitEvent("cs:open-terminal"),
    },

    -- =====================
    -- Help
    -- =====================
    {
      key = "/",
      mods = "LEADER|SHIFT",
      action = act.EmitEvent("cs:show-help"),
    },

    -- =====================
    -- Tab navigation (standard WezTerm)
    -- =====================
    {
      key = "1",
      mods = "LEADER",
      action = act.ActivateTab(0),
    },
    {
      key = "2",
      mods = "LEADER",
      action = act.ActivateTab(1),
    },
    {
      key = "3",
      mods = "LEADER",
      action = act.ActivateTab(2),
    },
    {
      key = "4",
      mods = "LEADER",
      action = act.ActivateTab(3),
    },
    {
      key = "5",
      mods = "LEADER",
      action = act.ActivateTab(4),
    },
    {
      key = "6",
      mods = "LEADER",
      action = act.ActivateTab(5),
    },
    {
      key = "7",
      mods = "LEADER",
      action = act.ActivateTab(6),
    },
    {
      key = "8",
      mods = "LEADER",
      action = act.ActivateTab(7),
    },
    {
      key = "9",
      mods = "LEADER",
      action = act.ActivateTab(8),
    },

    -- Send CTRL+S to the terminal (press leader twice)
    {
      key = "s",
      mods = "LEADER|CTRL",
      action = act.SendKey({ key = "s", mods = "CTRL" }),
    },
  }

  -- Help overlay event
  wezterm.on("cs:show-help", function(window, pane)
    local help_text = [[
╔══════════════════════════════════════════════════╗
║                 AgentTUI Help                    ║
╠══════════════════════════════════════════════════╣
║                                                  ║
║  Leader key: CTRL+S                              ║
║                                                  ║
║  Session Management:                             ║
║    ^S n     Create new session                   ║
║    ^S N     Create new session with prompt        ║
║    ^S c     Pause current session (checkout)     ║
║    ^S r     Resume a paused session              ║
║    ^S p     Push changes to remote               ║
║    ^S D     Delete a session                     ║
║                                                  ║
║  Navigation:                                     ║
║    ^S j/]   Next session                         ║
║    ^S k/[   Previous session                     ║
║    ^S 1-9   Jump to tab by number                ║
║                                                  ║
║  Views:                                          ║
║    ^S d     Show git diff for session            ║
║    ^S t     Open terminal in worktree            ║
║                                                  ║
║  Other:                                          ║
║    ^S ?     Show this help                       ║
║    ^S ^S    Send CTRL+S to terminal              ║
║                                                  ║
╚══════════════════════════════════════════════════╝
]]

    -- Show help by injecting text into a bottom split
    local help_pane = pane:split({
      direction = "Bottom",
      size = 0.4,
    })
    -- Send the help text line by line using Windows-compatible echo
    for line in help_text:gmatch("[^\n]+") do
      help_pane:send_text("echo " .. line .. "\r\n")
    end
    help_pane:send_text("echo.\r\necho Press any key to close... && pause >nul && exit\r\n")
  end)
end

return M
