--- The scoped model set: which models `:PiCycleModel` cycles through.
---
--- Mirrors the TUI's `/scoped-models` selector. The set is stored globally in
--- pi's settings.json under `enabledModels`, as an ordered array of
--- `provider/id` strings. Order is the cycle order. An absent key means "all
--- models enabled", which is a distinct state from "every model listed".

local M = {}

local Notify = require("pi.notify")
local Settings = require("pi.global_settings")

local SETTINGS_KEY = "enabledModels"

--- Canonical key for a backend model object.
---@param model table
---@return string
function M.key(model)
    return model.provider .. "/" .. model.id
end

--- Resolve one `provider/id` pattern against available models.
---
--- Mirrors pi's findExactModelReferenceMatch: canonical `provider/id` first,
--- then provider + id split on the *first* slash (so `openrouter/openai/gpt-5.1`
--- resolves), then a bare id. Ambiguous matches are rejected, as upstream does.
---@param pattern string
---@param all table[]
---@return table? model
function M.find(pattern, all)
    local needle = vim.trim(pattern):lower()
    if needle == "" then
        return nil
    end

    local canonical = vim.tbl_filter(function(m)
        return M.key(m):lower() == needle
    end, all)
    if #canonical > 0 then
        return #canonical == 1 and canonical[1] or nil
    end

    local slash = needle:find("/", 1, true)
    if slash then
        local provider, id = needle:sub(1, slash - 1), needle:sub(slash + 1)
        if provider ~= "" and id ~= "" then
            local split = vim.tbl_filter(function(m)
                return m.provider:lower() == provider and m.id:lower() == id
            end, all)
            if #split > 0 then
                return #split == 1 and split[1] or nil
            end
        end
    end

    local bare = vim.tbl_filter(function(m)
        return m.id:lower() == needle
    end, all)
    return #bare == 1 and bare[1] or nil
end

--- The configured set, or nil when every model is enabled.
---@return string[]? enabled
function M.read()
    local settings, err = Settings.read()
    if not settings then
        Notify.warn(err or "Could not read pi settings")
        return nil
    end
    local value = settings[SETTINGS_KEY]
    if type(value) ~= "table" or value == Settings.EMPTY_ARRAY then
        return nil
    end
    local keys = {}
    for _, entry in ipairs(value) do
        if type(entry) == "string" then
            keys[#keys + 1] = entry
        end
    end
    return #keys > 0 and keys or nil
end

--- Persist the set. nil, or a set covering every available model, removes the
--- key -- matching what the TUI writes when everything is enabled.
---@param enabled string[]?
---@param all table[] available models, to detect a full set
---@return boolean ok
function M.write(enabled, all)
    local value = enabled
    if value and #value == #all then
        local available = {}
        for _, model in ipairs(all) do
            available[M.key(model)] = true
        end
        local covers_all = true
        for _, key in ipairs(value) do
            if not available[key] then
                covers_all = false
                break
            end
        end
        if covers_all then
            value = nil
        end
    end
    if value and #value == 0 then
        value = nil
    end

    local ok, err = Settings.set(SETTINGS_KEY, value)
    if not ok then
        Notify.warn(err or "Could not write pi settings")
    end
    return ok
end

--- Resolve the set into backend model objects, in cycle order.
--- Returns every available model when no set is configured.
---@param all table[]
---@return table[] models
function M.resolve(all)
    local enabled = M.read()
    if not enabled then
        return all
    end
    local models, seen = {}, {}
    for _, pattern in ipairs(enabled) do
        local model = M.find(pattern, all)
        if model and not seen[M.key(model)] then
            seen[M.key(model)] = true
            models[#models + 1] = model
        end
    end
    return models
end

return M
