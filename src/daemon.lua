-- daemon.lua
-- AutoYes polling: detect agent prompts and auto-accept them

local wezterm = require("wezterm")
local state = require("state")

local M = {}

local polling = false
local poll_interval_ms = 1000

-- Prompt patterns to detect (agent is waiting for input)
local PROMPT_PATTERNS = {
  -- Claude Code
  "Do you want to proceed",
  "Allow this action",
  "Would you like me to",
  "Do you want me to",
  "Proceed%?",
  "approve",
  "Allow%?",
  "Y/n",
  "y/N",
  -- Aider
  "Add .+ to the chat%?",
  "Create new file .+%?",
  -- Generic
  "%(y/n%)",
  "%(Y/n%)",
  "%(yes/no%)",
  "%[y/N%]",
  "%[Y/n%]",
}

-- Check if text contains a prompt pattern
local function has_prompt(text)
  if not text or text == "" then return false end
  -- Check last portion of text (prompts appear at the end)
  local tail = text:sub(-500)
  for _, pattern in ipairs(PROMPT_PATTERNS) do
    if tail:find(pattern) then
      return true
    end
  end
  return false
end

-- Poll all running sessions for prompts
local function poll()
  if not polling then return end

  for _, s in ipairs(state.get_running_sessions()) do
    if s.pane_id then
      local pane = wezterm.mux.get_pane(s.pane_id)
      if pane then
        -- Get recent terminal output
        local text = pane:get_lines_as_text(30)
        if has_prompt(text) then
          -- Auto-accept by sending Enter
          pane:send_text("\n")
          wezterm.log_info("AgentTUI: Auto-accepted prompt in session '" .. s.title .. "'")
        end
      end
    end
  end

  -- Reschedule
  wezterm.time.call_after(poll_interval_ms / 1000, poll)
end

function M.start(cfg)
  if polling then return end
  poll_interval_ms = (cfg and cfg.daemon_poll_interval) or 1000
  polling = true
  wezterm.log_info("AgentTUI: AutoYes daemon started (interval: " .. poll_interval_ms .. "ms)")
  wezterm.time.call_after(poll_interval_ms / 1000, poll)
end

function M.stop()
  polling = false
  wezterm.log_info("AgentTUI: AutoYes daemon stopped")
end

function M.is_running()
  return polling
end

-- Toggle autoyes on/off
function M.toggle(cfg)
  if polling then
    M.stop()
  else
    M.start(cfg)
  end
  return polling
end

return M
