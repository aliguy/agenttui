-- worktree.lua
-- Git worktree and branch operations via shell commands

local wezterm = AT_WEZTERM or require("wezterm")
local state = AT_LOAD("at_state")

local M = {}

-- Run a git command and return success, stdout, stderr
local function git(args)
  local cmd = { "git" }
  for _, a in ipairs(args) do
    table.insert(cmd, a)
  end
  local success, stdout, stderr = wezterm.run_child_process(cmd)
  return success, (stdout or ""):gsub("%s+$", ""), (stderr or ""):gsub("%s+$", "")
end

-- Run git in a specific directory
local function git_in(dir, args)
  local cmd = { "git", "-C", dir }
  for _, a in ipairs(args) do
    table.insert(cmd, a)
  end
  local success, stdout, stderr = wezterm.run_child_process(cmd)
  return success, (stdout or ""):gsub("%s+$", ""), (stderr or ""):gsub("%s+$", "")
end

-- Sanitize a string for use as a branch name
local function sanitize_branch(name)
  return name:gsub("[^%w%-_/]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
end

-- Get the current HEAD commit SHA
function M.get_head_sha(repo_path)
  local ok, sha = git_in(repo_path, { "rev-parse", "HEAD" })
  if ok then return sha end
  return nil
end

-- Check if a branch exists locally
function M.branch_exists_local(repo_path, branch)
  local ok = git_in(repo_path, { "rev-parse", "--verify", "refs/heads/" .. branch })
  return ok
end

-- Check if a branch exists on remote
function M.branch_exists_remote(repo_path, branch)
  local ok = git_in(repo_path, { "rev-parse", "--verify", "refs/remotes/origin/" .. branch })
  return ok
end

-- List local branches
function M.list_branches(repo_path)
  local ok, stdout = git_in(repo_path, { "branch", "--format=%(refname:short)" })
  if not ok then return {} end
  local branches = {}
  for line in stdout:gmatch("[^\n]+") do
    table.insert(branches, line)
  end
  return branches
end

-- Create a new worktree with a new branch
function M.create(repo_path, session_title, branch_prefix, existing_branch)
  local worktree_base = state.worktree_dir()
  local timestamp = tostring(os.time())
  local safe_title = sanitize_branch(session_title)

  local branch
  local is_existing = false
  local worktree_path = worktree_base .. "/" .. safe_title .. "-" .. timestamp

  if existing_branch and existing_branch ~= "" then
    -- Use existing branch
    branch = existing_branch
    is_existing = true

    -- Check if it exists locally, if not try remote
    if not M.branch_exists_local(repo_path, branch) then
      if M.branch_exists_remote(repo_path, branch) then
        -- Create local tracking branch
        git_in(repo_path, { "branch", "--track", branch, "origin/" .. branch })
      else
        return nil, "Branch '" .. branch .. "' not found locally or on remote"
      end
    end

    local ok, _, stderr = git_in(repo_path, { "worktree", "add", worktree_path, branch })
    if not ok then
      return nil, "Failed to create worktree: " .. stderr
    end
  else
    -- Create new branch from HEAD
    branch = branch_prefix .. safe_title
    local ok, _, stderr = git_in(repo_path, { "worktree", "add", "-b", branch, worktree_path })
    if not ok then
      return nil, "Failed to create worktree: " .. stderr
    end
  end

  local base_commit = M.get_head_sha(repo_path) or ""

  return {
    worktree_path = worktree_path,
    branch = branch,
    base_commit = base_commit,
    is_existing_branch = is_existing,
  }, nil
end

-- Remove a worktree (keeps the branch)
function M.remove(repo_path, worktree_path)
  -- Force remove in case there are uncommitted changes
  local ok, _, stderr = git_in(repo_path, { "worktree", "remove", worktree_path, "--force" })
  if not ok then
    -- Try pruning stale worktrees first
    git_in(repo_path, { "worktree", "prune" })
    return false, stderr
  end
  return true, nil
end

-- Delete a branch
function M.delete_branch(repo_path, branch)
  local ok, _, stderr = git_in(repo_path, { "branch", "-D", branch })
  return ok, stderr
end

-- Commit all changes in a worktree
function M.commit_all(worktree_path, message)
  git_in(worktree_path, { "add", "-A" })
  local ok, _, stderr = git_in(worktree_path, { "commit", "-m", message, "--allow-empty" })
  return ok, stderr
end

-- Push branch to origin
function M.push(worktree_path, branch)
  local ok, stdout, stderr = git_in(worktree_path, { "push", "-u", "origin", branch })
  return ok, stdout, stderr
end

-- Get diff between base commit and current worktree state
function M.get_diff(worktree_path, base_commit)
  -- Stage untracked files so they appear in diff
  git_in(worktree_path, { "add", "-N", "." })

  local ok, stdout
  if base_commit and base_commit ~= "" then
    ok, stdout = git_in(worktree_path, { "diff", "--color=always", base_commit })
  else
    ok, stdout = git_in(worktree_path, { "diff", "--color=always" })
  end

  if ok then return stdout end
  return ""
end

-- Get diff stats (additions, deletions)
function M.get_diff_stats(worktree_path, base_commit)
  git_in(worktree_path, { "add", "-N", "." })

  local ok, stdout
  if base_commit and base_commit ~= "" then
    ok, stdout = git_in(worktree_path, { "diff", "--stat", base_commit })
  else
    ok, stdout = git_in(worktree_path, { "diff", "--stat" })
  end

  local additions = 0
  local deletions = 0
  if ok and stdout then
    -- Parse the summary line: "X files changed, Y insertions(+), Z deletions(-)"
    local a = stdout:match("(%d+) insertion")
    local d = stdout:match("(%d+) deletion")
    additions = tonumber(a) or 0
    deletions = tonumber(d) or 0
  end

  return { additions = additions, deletions = deletions }
end

-- Check if a branch is currently checked out somewhere
function M.is_branch_checked_out(repo_path, branch)
  local ok, stdout = git_in(repo_path, { "worktree", "list", "--porcelain" })
  if not ok then return false end
  return stdout:find("branch refs/heads/" .. branch) ~= nil
end

-- Get current repo path from cwd
function M.detect_repo(path)
  local ok, stdout = git_in(path or ".", { "rev-parse", "--show-toplevel" })
  if ok and stdout ~= "" then
    return stdout
  end
  return nil
end

return M
