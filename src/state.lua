-- state.lua
-- Session state persistence to ~/.agenttui/sessions.json

local wezterm = require("wezterm")

local M = {}

local STATE_DIR = wezterm.home_dir .. "/.agenttui"
local SESSIONS_PATH = STATE_DIR .. "/sessions.json"
local WORKTREE_DIR = STATE_DIR .. "/worktrees"

-- In-memory session list
local sessions = {}

function M.init()
  wezterm.run_child_process({ "mkdir", "-p", STATE_DIR })
  wezterm.run_child_process({ "mkdir", "-p", WORKTREE_DIR })
  M.load()
end

function M.new_session(opts)
  local id = tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
  local s = {
    id = id,
    title = opts.title or "untitled",
    program = opts.program or "claude",
    status = "ready",
    repo_path = opts.repo_path or "",
    branch = opts.branch or "",
    worktree_path = "",
    base_commit = "",
    is_existing_branch = opts.is_existing_branch or false,
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    pane_id = nil,
    tab_id = nil,
    diff_stats = { additions = 0, deletions = 0 },
    prompt = opts.prompt or nil,
  }
  table.insert(sessions, s)
  M.save()
  return s
end

function M.get_sessions()
  return sessions
end

function M.get_session_by_id(id)
  for _, s in ipairs(sessions) do
    if s.id == id then return s end
  end
  return nil
end

function M.get_session_by_pane(pane_id)
  for _, s in ipairs(sessions) do
    if s.pane_id == pane_id then return s end
  end
  return nil
end

function M.get_session_by_tab(tab_id)
  for _, s in ipairs(sessions) do
    if s.tab_id == tab_id then return s end
  end
  return nil
end

function M.get_active_sessions()
  local active = {}
  for _, s in ipairs(sessions) do
    if s.status ~= "paused" then
      table.insert(active, s)
    end
  end
  return active
end

function M.get_running_sessions()
  local running = {}
  for _, s in ipairs(sessions) do
    if s.status == "running" or s.status == "ready" then
      table.insert(running, s)
    end
  end
  return running
end

function M.update_session(id, updates)
  for i, s in ipairs(sessions) do
    if s.id == id then
      for k, v in pairs(updates) do
        sessions[i][k] = v
      end
      sessions[i].updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
      M.save()
      return sessions[i]
    end
  end
  return nil
end

function M.remove_session(id)
  for i, s in ipairs(sessions) do
    if s.id == id then
      table.remove(sessions, i)
      M.save()
      return true
    end
  end
  return false
end

function M.count()
  return #sessions
end

function M.load()
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

function M.save()
  local f = io.open(SESSIONS_PATH, "w")
  if f then
    f:write(wezterm.json_encode(sessions))
    f:close()
  end
end

function M.worktree_dir()
  return WORKTREE_DIR
end

function M.sessions_path()
  return SESSIONS_PATH
end

return M
