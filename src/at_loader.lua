-- at_loader.lua
-- Module loader for AgentTUI - works around WezTerm's require() on Windows
-- All modules use AT_LOAD(name) instead of require(name)

local wezterm = require("wezterm")

-- Cache loaded modules
local loaded = {}
local plugin_root = wezterm.config_dir:gsub("/", "\\")

function AT_LOAD(name)
  if loaded[name] then
    return loaded[name]
  end
  local path = plugin_root .. "\\" .. name .. ".lua"
  local mod = dofile(path)
  loaded[name] = mod
  return mod
end

-- Also make wezterm globally accessible for dofile'd modules
AT_WEZTERM = wezterm

return true
