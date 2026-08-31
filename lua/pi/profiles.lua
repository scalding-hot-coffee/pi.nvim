--- Session profile management for pi.nvim.

local M = {}

local Config = require("pi.config")
local Dialog = require("pi.ui.dialog")
local Sessions = require("pi.sessions.manager")

---@return table<string, pi.Profile>
local function get_profiles()
  local config = Config.options
  return config.profiles or {}
end

---@param profile pi.Profile
local function apply_profile(profile)
  -- Change cwd if specified
  if profile.cwd then
    vim.cmd("cd " .. vim.fn.expand(profile.cwd))
  end

  -- Start session with profile args
  local extra_args = {}
  if profile.model then
    table.insert(extra_args, "--model")
    table.insert(extra_args, profile.model)
  end
  if profile.thinking then
    table.insert(extra_args, "--thinking")
    table.insert(extra_args, profile.thinking)
  end
  if profile.exclude_tools then
    table.insert(extra_args, "--exclude-tools")
    table.insert(extra_args, table.concat(profile.exclude_tools, ","))
  end
  if profile.append_prompt then
    table.insert(extra_args, "--append-system-prompt")
    table.insert(extra_args, profile.append_prompt)
  end

  Sessions.get_or_create({ extra_args = extra_args })
end

---@param profile_name string
function M.create_with_profile(profile_name)
  local profiles = get_profiles()
  local profile = profiles[profile_name]
  if not profile then
    vim.notify("Profile '" .. profile_name .. "' not found", vim.log.levels.ERROR)
    return
  end

  -- Create new tab for profile session
  vim.cmd("tabnew")
  apply_profile(profile)
end

function M.select_profile()
  local profiles = get_profiles()
  local names = {}
  local descriptions = {}

  for name, profile in pairs(profiles) do
    table.insert(names, name)
    table.insert(descriptions, profile.desc or name)
  end

  if #names == 0 then
    vim.notify("No profiles configured", vim.log.levels.INFO)
    return
  end

  Dialog.select({
    title = "Select Profile",
    options = descriptions,
    shortcuts = {
      ["<CR>"] = "confirm",
      ["<Esc>"] = "cancel",
    },
  }, function(choice)
    if not choice then
      return
    end
    for i, desc in ipairs(descriptions) do
      if desc == choice then
        M.create_with_profile(names[i])
        return
      end
    end
  end)
end

return M
