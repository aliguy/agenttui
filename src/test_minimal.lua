-- test_minimal.lua
-- Minimal test: does ALT+N -> PromptInputLine -> spawn tab work at all?
local wezterm = require("wezterm")
local act = wezterm.action
local config = wezterm.config_builder()

config.color_scheme = "Catppuccin Mocha"
config.disable_default_key_bindings = true

config.keys = {
  { key = "v", mods = "CTRL", action = act.PasteFrom("Clipboard") },
  { key = "c", mods = "CTRL|SHIFT", action = act.CopyTo("Clipboard") },

  -- TEST 1: ALT+N with PromptInputLine -> spawn tab
  {
    key = "n",
    mods = "ALT",
    action = act.PromptInputLine({
      description = "Type a name and press Enter:",
      action = wezterm.action_callback(function(window, pane, line)
        if not line or line == "" then return end
        wezterm.log_info("TEST: Got name: " .. line)

        -- Try spawning a tab directly
        local tab, new_pane, _ = window:mux_window():spawn_tab({})
        if tab then
          tab:set_title(line)
          new_pane:send_text("echo Session " .. line .. " created!\r\n")
          wezterm.log_info("TEST: Tab spawned OK")
        else
          wezterm.log_error("TEST: spawn_tab returned nil")
        end
      end),
    }),
  },

  -- TEST 2: ALT+G - test git via run_child_process
  {
    key = "g",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      wezterm.log_info("TEST: ALT+G pressed, testing git...")
      local ok, stdout, stderr = wezterm.run_child_process({"git", "--version"})
      wezterm.log_info("TEST: git ok=" .. tostring(ok) .. " stdout=" .. (stdout or "nil"))

      -- Test detect repo
      local ok2, stdout2, stderr2 = wezterm.run_child_process({
        "git", "-C", "C:\\Users\\Alex Saunders\\agenttui", "rev-parse", "--show-toplevel"
      })
      wezterm.log_info("TEST: repo ok=" .. tostring(ok2) .. " stdout=" .. (stdout2 or "nil"))

      -- Show result in pane
      pane:send_text("echo git=" .. tostring(ok) .. " repo=" .. tostring(ok2) .. "\r\n")
    end),
  },

  -- TEST 3: ALT+W - test worktree creation
  {
    key = "w",
    mods = "ALT",
    action = wezterm.action_callback(function(window, pane)
      wezterm.log_info("TEST: ALT+W pressed, testing worktree...")

      wezterm.time.call_after(0, function()
        local ts = tostring(os.time())
        local wt_path = "C:\\Users\\Alex Saunders\\.agenttui\\worktrees\\test-" .. ts
        local branch = "agenttui/test-" .. ts
        local repo = "C:\\Users\\Alex Saunders\\agenttui"

        local ok, stdout, stderr = wezterm.run_child_process({
          "git", "-C", repo, "worktree", "add", "-b", branch, wt_path
        })
        wezterm.log_info("TEST: worktree ok=" .. tostring(ok) .. " stderr=" .. (stderr or "nil"))

        if ok then
          -- Now spawn a tab in the worktree
          local tab, new_pane, _ = window:mux_window():spawn_tab({
            cwd = wt_path,
          })
          if tab then
            tab:set_title("test-worktree")
            new_pane:send_text("echo Worktree created at " .. wt_path .. "\r\n")
            wezterm.log_info("TEST: worktree tab spawned OK")
          else
            wezterm.log_error("TEST: spawn_tab in worktree failed")
          end
        end
      end)
    end),
  },
}

wezterm.on("gui-startup", function()
  local tab, pane, window = wezterm.mux.spawn_window({})
  window:set_title("AgentTUI TEST")
  pane:send_text("echo === MINIMAL TEST ===\r\n")
  pane:send_text("echo ALT+N = test prompt+spawn, ALT+G = test git, ALT+W = test worktree\r\n")
end)

return config
