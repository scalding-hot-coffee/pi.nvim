--- Named groups of models, layered over the scoped model set.
---
--- A category is a named list of `provider/id` strings. Activating one writes
--- its members to pi's global `enabledModels`, so cycling narrows to that
--- group without any of the cycling code needing to know categories exist.
---
--- Membership is many-to-many: a model may belong to any number of categories,
--- and removing a category never touches the models themselves.
---
--- Stored separately from pi's settings.json. This is Neovim-only state, and
--- pi validates its own settings against a schema on load -- unknown keys
--- parked there are not guaranteed to survive a version bump.

local M = {}

local Notify = require("pi.notify")
local Scoped = require("pi.scoped_models")

---@return string
function M.path()
    local configured = (require("pi.config").options.model_categories or {}).path
    if configured and configured ~= "" then
        return vim.fn.expand(configured)
    end
    return vim.fs.joinpath(vim.fn.stdpath("data"), "pi", "model-categories.json")
end

--- Read every category. Returns an empty table when the file is absent.
--- A file that exists but cannot be parsed returns nil, so callers never
--- overwrite categories they failed to read.
---@return table<string, string[]>? categories
---@return string? err
function M.read()
    local path = M.path()
    local fd = io.open(path, "r")
    if not fd then
        return {}, nil
    end
    local raw = fd:read("*a")
    fd:close()
    if not raw or raw:match("^%s*$") then
        return {}, nil
    end

    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return nil, "Could not parse " .. path
    end

    ---@type table<string, string[]>
    local categories = {}
    for name, members in pairs(decoded) do
        if type(members) == "table" then
            local keys = {}
            for _, key in ipairs(members) do
                if type(key) == "string" then
                    keys[#keys + 1] = key
                end
            end
            categories[name] = keys
        end
    end
    return categories, nil
end

---@param categories table<string, string[]>
---@return boolean ok
function M.write(categories)
    local path = M.path()
    local dir = vim.fs.dirname(path)
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end

    -- Encode by hand so an empty category stays `[]` rather than becoming `{}`,
    -- which is what an empty Lua table round-trips to.
    local names = vim.tbl_keys(categories)
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
        local members = {}
        for i, key in ipairs(categories[name]) do
            members[i] = "    " .. vim.json.encode(key)
        end
        local body = #members > 0 and ("[\n" .. table.concat(members, ",\n") .. "\n  ]") or "[]"
        parts[#parts + 1] = "  " .. vim.json.encode(name) .. ": " .. body
    end
    local encoded = #parts > 0 and ("{\n" .. table.concat(parts, ",\n") .. "\n}") or "{}"

    local tmp = path .. ".tmp"
    local fd = io.open(tmp, "w")
    if not fd then
        Notify.warn("Could not write " .. tmp)
        return false
    end
    fd:write(encoded .. "\n")
    fd:close()

    local ok, err = (vim.uv or vim.loop).fs_rename(tmp, path)
    if not ok then
        os.remove(tmp)
        Notify.warn(err or ("Could not replace " .. path))
        return false
    end
    return true
end

---@return string[] names sorted
function M.names()
    local categories = M.read() or {}
    local names = vim.tbl_keys(categories)
    table.sort(names)
    return names
end

--- Categories the given model key belongs to, sorted.
---@param key string
---@return string[]
function M.for_model(key)
    local categories = M.read() or {}
    local names = {}
    for name, members in pairs(categories) do
        if vim.tbl_contains(members, key) then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

--- Add or remove one model from one category. Membership is many-to-many, so
--- this never affects the model's other categories.
---@param name string
---@param key string
---@return boolean ok
function M.toggle_member(name, key)
    local categories, err = M.read()
    if not categories then
        Notify.warn(err or "Could not read categories")
        return false
    end
    local members = categories[name] or {}
    local out, removed = {}, false
    for _, member in ipairs(members) do
        if member == key then
            removed = true
        else
            out[#out + 1] = member
        end
    end
    if not removed then
        out[#out + 1] = key
    end
    categories[name] = out
    return M.write(categories)
end

---@param name string
---@return boolean ok
function M.create(name)
    local categories, err = M.read()
    if not categories then
        Notify.warn(err or "Could not read categories")
        return false
    end
    if categories[name] then
        Notify.warn("Category already exists: " .. name)
        return false
    end
    categories[name] = {}
    return M.write(categories)
end

---@param name string
---@return boolean ok
function M.delete(name)
    local categories, err = M.read()
    if not categories then
        Notify.warn(err or "Could not read categories")
        return false
    end
    categories[name] = nil
    return M.write(categories)
end

---@param from string
---@param to string
---@return boolean ok
function M.rename(from, to)
    local categories, err = M.read()
    if not categories then
        Notify.warn(err or "Could not read categories")
        return false
    end
    if not categories[from] then
        return false
    end
    if categories[to] then
        Notify.warn("Category already exists: " .. to)
        return false
    end
    categories[to] = categories[from]
    categories[from] = nil
    return M.write(categories)
end

--- Make a category the scoped model set: its members become `enabledModels`,
--- so :PiCycleModel cycles within it.
---@param name string
---@param all table[] available models
---@return boolean ok
function M.activate(name, all)
    local categories, err = M.read()
    if not categories then
        Notify.warn(err or "Could not read categories")
        return false
    end
    local members = categories[name]
    if not members then
        Notify.warn("No such category: " .. name)
        return false
    end

    -- Only models the backend actually offers; a stale entry would otherwise
    -- silently shrink the cycle without saying why.
    local resolved, missing = {}, 0
    for _, key in ipairs(members) do
        local model = Scoped.find(key, all)
        if model then
            resolved[#resolved + 1] = Scoped.key(model)
        else
            missing = missing + 1
        end
    end

    if #resolved == 0 then
        Notify.warn("Category '" .. name .. "' has no available models")
        return false
    end

    Scoped.write(resolved, all)
    local suffix = missing > 0 and string.format(" (%d unavailable)", missing) or ""
    Notify.info(string.format("Scoped to '%s': %d model%s%s", name, #resolved, #resolved == 1 and "" or "s", suffix))
    return true
end

return M
