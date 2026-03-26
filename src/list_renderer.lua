#!/usr/bin/env lua
-- list_renderer.lua
-- Standalone process that renders the session list in a WezTerm pane.
-- Communicates with the main plugin via the state file and user variables.
-- This script runs as the left panel in the Claude Squad-style layout.

-- We run this as a WezTerm foreground process; it reads state and renders ANSI output.

local ESCAPE = "\27"
local CSI = ESCAPE .. "["

-- ANSI helpers
local function fg(r, g, b) return CSI .. "38;2;" .. r .. ";" .. g .. ";" .. b .. "m" end
local function bg(r, g, b) return CSI .. "48;2;" .. r .. ";" .. g .. ";" .. b .. "m" end
local function reset() return CSI .. "0m" end
local function bold() return CSI .. "1m" end
local function dim() return CSI .. "2m" end
local function clear_screen() return CSI .. "2J" .. CSI .. "H" end
local function move_to(row, col) return CSI .. row .. ";" .. col .. "H" end
local function hide_cursor() return CSI .. "?25l" end
local function show_cursor() return CSI .. "?25h" end
local function clear_line() return CSI .. "2K" end
local function enable_alt_screen() return CSI .. "?1049h" end
local function disable_alt_screen() return CSI .. "?1049l" end

-- Colors (Catppuccin Mocha)
local C = {
  base     = { 30, 30, 46 },
  surface0 = { 49, 50, 68 },
  surface1 = { 69, 71, 90 },
  surface2 = { 88, 91, 112 },
  text     = { 205, 214, 244 },
  subtext0 = { 166, 173, 200 },
  green    = { 166, 227, 161 },
  red      = { 243, 139, 168 },
  blue     = { 137, 180, 250 },
  yellow   = { 249, 226, 175 },
  mauve    = { 203, 166, 247 },
  overlay0 = { 108, 112, 134 },
  selected = { 49, 50, 68 },
}

local function color(c) return fg(c[1], c[2], c[3]) end
local function bgcolor(c) return bg(c[1], c[2], c[3]) end

-- State
local state_dir = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
state_dir = state_dir:gsub("\\", "/")
local STATE_FILE = state_dir .. "/.agenttui/sessions.json"

local selected_idx = 1
local sessions = {}
local width = 40
local height = 40
local active_view = "preview" -- preview | diff | terminal

-- Simple JSON parser for our flat session objects
local function parse_json_file(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  if not content or content == "" or content == "[]" then return {} end

  -- Use a basic approach: decode the JSON array of objects
  -- This is simplified - handles our known session format
  local items = {}
  -- Match each {...} object in the array
  for obj_str in content:gmatch("{([^{}]+)}") do
    local item = {}
    -- Match "key":"value" pairs (string values)
    for k, v in obj_str:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
      item[k] = v
    end
    -- Match "key":number pairs
    for k, v in obj_str:gmatch('"([^"]+)"%s*:%s*(%d+%.?%d*)') do
      item[k] = tonumber(v)
    end
    -- Match "key":true/false
    for k, v in obj_str:gmatch('"([^"]+)"%s*:%s*(true)') do
      item[k] = true
    end
    for k, v in obj_str:gmatch('"([^"]+)"%s*:%s*(false)') do
      item[k] = false
    end
    -- Match nested diff_stats
    local ds = obj_str:match('"diff_stats"%s*:%s*{([^}]*)}')
    if ds then
      item.diff_stats = {}
      for k, v in ds:gmatch('"(%w+)"%s*:%s*(%d+)') do
        item.diff_stats[k] = tonumber(v)
      end
    end
    if item.id then
      table.insert(items, item)
    end
  end
  return items
end

local function load_sessions()
  sessions = parse_json_file(STATE_FILE)
end

local function get_terminal_size()
  -- Try to get terminal size
  local handle
  handle = io.popen("tput cols 2>/dev/null || echo 40")
  if handle then
    width = tonumber(handle:read("*a"):match("%d+")) or 40
    handle:close()
  end
  handle = io.popen("tput lines 2>/dev/null || echo 40")
  if handle then
    height = tonumber(handle:read("*a"):match("%d+")) or 40
    handle:close()
  end
end

-- Render the session list
local function render()
  local out = {}

  -- Header
  table.insert(out, move_to(1, 1))
  table.insert(out, clear_screen())
  table.insert(out, hide_cursor())

  -- Title bar
  table.insert(out, move_to(2, 1))
  table.insert(out, bgcolor(C.mauve))
  table.insert(out, fg(30, 30, 46))
  table.insert(out, bold())
  local title = " Instances "
  local padding = string.rep(" ", math.max(0, width - #title))
  table.insert(out, title .. padding)
  table.insert(out, reset())

  -- Empty state
  if #sessions == 0 then
    table.insert(out, move_to(5, 3))
    table.insert(out, color(C.overlay0))
    table.insert(out, "No sessions yet.")
    table.insert(out, move_to(7, 3))
    table.insert(out, "Press ")
    table.insert(out, color(C.mauve))
    table.insert(out, bold())
    table.insert(out, "^A n")
    table.insert(out, reset())
    table.insert(out, color(C.overlay0))
    table.insert(out, " to create one.")
    table.insert(out, reset())
    io.write(table.concat(out))
    io.flush()
    return
  end

  -- Session items
  local row = 4
  for i, s in ipairs(sessions) do
    local is_selected = (i == selected_idx)

    -- Background for selected item
    if is_selected then
      -- Fill two lines with selected background
      table.insert(out, move_to(row, 1))
      table.insert(out, bgcolor(C.selected))
      table.insert(out, string.rep(" ", width))
      table.insert(out, move_to(row + 1, 1))
      table.insert(out, string.rep(" ", width))
      table.insert(out, move_to(row + 2, 1))
      table.insert(out, string.rep(" ", width))
    end

    -- Line 1: index + title + status icon
    table.insert(out, move_to(row, 1))
    if is_selected then
      table.insert(out, bgcolor(C.selected))
    end

    -- Index
    table.insert(out, color(C.overlay0))
    local idx_str = string.format(" %d. ", i)
    table.insert(out, idx_str)

    -- Title
    if is_selected then
      table.insert(out, color(C.text))
      table.insert(out, bold())
    else
      table.insert(out, color(C.text))
    end

    local title_text = s.title or "untitled"
    local max_title_w = width - #idx_str - 5
    if #title_text > max_title_w then
      title_text = title_text:sub(1, max_title_w - 3) .. "..."
    end
    table.insert(out, title_text)
    table.insert(out, reset())
    if is_selected then table.insert(out, bgcolor(C.selected)) end

    -- Status icon (right-aligned)
    local status = s.status or "ready"
    local icon, icon_color
    if status == "running" then
      icon = " \xe2\x97\x8f" -- ●
      icon_color = C.green
    elseif status == "ready" then
      icon = " \xe2\x97\x8f" -- ●
      icon_color = C.blue
    elseif status == "paused" then
      icon = " \xe2\x8f\xb8" -- ⏸
      icon_color = C.overlay0
    elseif status == "loading" then
      icon = " \xe2\x97\x8b" -- ○
      icon_color = C.yellow
    else
      icon = " ?"
      icon_color = C.overlay0
    end
    table.insert(out, color(icon_color))
    table.insert(out, icon)
    table.insert(out, reset())

    -- Line 2: branch + diff stats
    row = row + 1
    table.insert(out, move_to(row, 1))
    if is_selected then table.insert(out, bgcolor(C.selected)) end

    local branch_prefix = string.rep(" ", #idx_str) .. "\xea\xae\xa7-" -- Ꮧ character
    table.insert(out, color(C.overlay0))
    table.insert(out, branch_prefix)

    local branch = s.branch or ""
    local stats_str = ""
    if s.diff_stats then
      local a = s.diff_stats.additions or 0
      local d = s.diff_stats.deletions or 0
      if a > 0 or d > 0 then
        stats_str = string.format("+%d,-%d", a, d)
      end
    end

    local max_branch_w = width - #branch_prefix - #stats_str - 3
    if #branch > max_branch_w and max_branch_w > 3 then
      branch = branch:sub(1, max_branch_w - 3) .. "..."
    end

    if is_selected then
      table.insert(out, color(C.subtext0))
    else
      table.insert(out, color(C.overlay0))
    end
    table.insert(out, branch)

    -- Diff stats
    if stats_str ~= "" then
      local spaces = math.max(1, width - #branch_prefix - #branch - #stats_str - 2)
      table.insert(out, string.rep(" ", spaces))
      -- Green for additions part
      local add_part = stats_str:match("(%+%d+)")
      local del_part = stats_str:match("(%-%d+)")
      if add_part then
        table.insert(out, color(C.green))
        table.insert(out, add_part)
      end
      if del_part then
        table.insert(out, color(C.overlay0))
        table.insert(out, ",")
        table.insert(out, color(C.red))
        table.insert(out, del_part)
      end
    end

    table.insert(out, reset())
    row = row + 2 -- gap between items
  end

  io.write(table.concat(out))
  io.flush()
end

-- Write selected session ID to a file for the plugin to read
local function write_selection()
  local sel = sessions[selected_idx]
  if not sel then return end
  local f = io.open(state_dir .. "/.agenttui/selected.txt", "w")
  if f then
    f:write(sel.id or "")
    f:close()
  end
end

-- Set up raw terminal input (Unix)
local function setup_raw_mode()
  os.execute("stty raw -echo 2>/dev/null")
end

local function restore_terminal()
  os.execute("stty sane 2>/dev/null")
  io.write(show_cursor())
  io.write(disable_alt_screen())
  io.flush()
end

-- Main loop
local function main()
  io.write(enable_alt_screen())
  io.write(hide_cursor())
  io.flush()

  setup_raw_mode()

  -- Initial load and render
  get_terminal_size()
  load_sessions()
  render()
  write_selection()

  -- Input loop
  local last_reload = os.time()
  while true do
    -- Non-blocking read with timeout approach
    local char = io.read(1)

    if char then
      if char == "q" or char == "\27" then
        -- Check for escape sequences
        if char == "\27" then
          local seq1 = io.read(1)
          if seq1 == "[" then
            local seq2 = io.read(1)
            if seq2 == "A" then -- Up arrow
              if selected_idx > 1 then
                selected_idx = selected_idx - 1
                write_selection()
              end
            elseif seq2 == "B" then -- Down arrow
              if selected_idx < #sessions then
                selected_idx = selected_idx + 1
                write_selection()
              end
            end
          else
            -- Bare escape = quit
            break
          end
        else
          break
        end
      elseif char == "k" then
        if selected_idx > 1 then
          selected_idx = selected_idx - 1
          write_selection()
        end
      elseif char == "j" then
        if selected_idx < #sessions then
          selected_idx = selected_idx + 1
          write_selection()
        end
      end

      render()
    end

    -- Periodically reload state
    local now = os.time()
    if now - last_reload >= 1 then
      load_sessions()
      get_terminal_size()
      render()
      last_reload = now
    end
  end

  restore_terminal()
end

-- Cleanup on exit
local ok, err = pcall(main)
restore_terminal()
if not ok then
  io.stderr:write("list_renderer error: " .. tostring(err) .. "\n")
  os.exit(1)
end
