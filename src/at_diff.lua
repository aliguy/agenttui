-- diff.lua
-- Git diff display and formatting utilities

local wezterm = require("wezterm")
local worktree = require("at_worktree")

local M = {}

-- Get a color-coded diff for display
function M.get_colored_diff(worktree_path, base_commit)
  return worktree.get_diff(worktree_path, base_commit)
end

-- Get diff stats summary string
function M.format_stats(stats)
  if not stats then return "" end
  local parts = {}
  if stats.additions > 0 then
    table.insert(parts, "+" .. stats.additions)
  end
  if stats.deletions > 0 then
    table.insert(parts, "-" .. stats.deletions)
  end
  if #parts == 0 then
    return "no changes"
  end
  return table.concat(parts, " ")
end

-- Spawn a diff viewer pane
function M.show_in_pane(parent_pane, worktree_path, base_commit)
  if not worktree_path or worktree_path == "" then
    return nil
  end

  local args
  if base_commit and base_commit ~= "" then
    args = { "git", "-C", worktree_path, "diff", "--color=always", base_commit }
  else
    args = { "git", "-C", worktree_path, "diff", "--color=always" }
  end

  -- Spawn git diff directly (scrollback handles scrolling)
  local diff_pane = parent_pane:split({
    direction = "Right",
    size = 0.5,
    args = args,
  })

  return diff_pane
end

return M
