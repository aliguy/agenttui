-- config.lua
-- Loads and saves ~/.agenttui/config.json

local wezterm = require("wezterm")

local M = {}

local STATE_DIR = wezterm.home_dir .. "/.agenttui"
local CONFIG_PATH = STATE_DIR .. "/config.json"

local DEFAULT_CONFIG = {
  default_program = "claude",
  auto_yes = false,
  daemon_poll_interval = 1000,
  branch_prefix = "",
  max_sessions = 10,
  profiles = {},
}

-- Ensure state directory exists
local function ensure_dir()
  local success, stdout, stderr = wezterm.run_child_process({ "mkdir", "-p", STATE_DIR })
  return success
end

-- Detect current username for default branch prefix
local function get_username()
  local success, stdout, stderr = wezterm.run_child_process({ "whoami" })
  if success and stdout then
    local name = stdout:gsub("%s+$", "")
    -- On Windows, whoami returns DOMAIN\user
    local user = name:match("\\(.+)$") or name
    return user
  end
  return "user"
end

function M.load()
  ensure_dir()

  local f = io.open(CONFIG_PATH, "r")
  if f then
    local content = f:read("*a")
    f:close()
    local ok, parsed = pcall(wezterm.json_parse, content)
    if ok and parsed then
      -- Merge with defaults (so new fields get defaults)
      local merged = {}
      for k, v in pairs(DEFAULT_CONFIG) do
        merged[k] = v
      end
      for k, v in pairs(parsed) do
        merged[k] = v
      end
      -- Set default branch prefix if empty
      if merged.branch_prefix == "" then
        merged.branch_prefix = get_username() .. "/"
      end
      return merged
    end
  end

  -- No config file or parse error — create default
  local cfg = {}
  for k, v in pairs(DEFAULT_CONFIG) do
    cfg[k] = v
  end
  cfg.branch_prefix = get_username() .. "/"
  M.save(cfg)
  return cfg
end

function M.save(cfg)
  ensure_dir()
  local f = io.open(CONFIG_PATH, "w")
  if f then
    f:write(wezterm.json_encode(cfg))
    f:close()
    return true
  end
  return false
end

function M.state_dir()
  return STATE_DIR
end

return M
