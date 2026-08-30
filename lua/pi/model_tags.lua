--- Tags: names attached to models, for finding them.
---
--- Tags are metadata and nothing else. They never touch pi's `enabledModels`,
--- so :PiCycleModel and the scoped-models workflow behave identically whether
--- you have no tags or fifty. Tagging organises how you *find* a model; the
--- scoped set decides what you *cycle* through. The two are independent.
---
--- Membership is many-to-many: a model may carry any number of tags, and
--- deleting a tag removes it from every model that carried it without
--- affecting those models in any other way.
---
--- Stored apart from pi's settings.json, which is schema-validated on load --
--- unknown keys parked there are not guaranteed to survive a version bump.

local M = {}

local Notify = require("pi.notify")

---@return string
function M.path()
    local configured = (require("pi.config").options.model_tags or {}).path
    if configured and configured ~= "" then
        return vim.fn.expand(configured)
    end
    return vim.fs.joinpath(vim.fn.stdpath("data"), "pi", "model-tags.json")
end

--- Read every tag. Absent file yields an empty table; an unparseable one
--- yields nil, so callers never overwrite tags they failed to read.
---@return table<string, string[]>? tags
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
    local tags = {}
    for name, members in pairs(decoded) do
        if type(members) == "table" then
            local keys = {}
            for _, key in ipairs(members) do
                if type(key) == "string" then
                    keys[#keys + 1] = key
                end
            end
            tags[name] = keys
        end
    end
    return tags, nil
end

---@param tags table<string, string[]>
---@return boolean ok
function M.write(tags)
    local path = M.path()
    local dir = vim.fs.dirname(path)
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end

    -- Encoded by hand so an empty tag stays `[]`; an empty Lua table would
    -- otherwise round-trip to `{}`.
    local names = vim.tbl_keys(tags)
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
        local members = {}
        for i, key in ipairs(tags[name]) do
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
    local tags = M.read() or {}
    local names = vim.tbl_keys(tags)
    table.sort(names)
    return names
end

--- Model keys carrying a tag, in the order they were added.
---@param name string
---@return string[]
function M.members(name)
    return (M.read() or {})[name] or {}
end

--- Tags on a model, sorted.
---@param key string
---@return string[]
function M.for_model(key)
    local tags = M.read() or {}
    local names = {}
    for name, members in pairs(tags) do
        if vim.tbl_contains(members, key) then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

--- key -> "cheap, fast", for rendering many models at once without
--- re-reading the file per row.
---@return table<string, string>
function M.labels()
    local tags = M.read() or {}
    local names = vim.tbl_keys(tags)
    table.sort(names)
    local by_model = {}
    for _, name in ipairs(names) do
        for _, key in ipairs(tags[name]) do
            by_model[key] = by_model[key] or {}
            table.insert(by_model[key], name)
        end
    end
    local labels = {}
    for key, list in pairs(by_model) do
        labels[key] = table.concat(list, ", ")
    end
    return labels
end

--- Add or remove one model from one tag. Many-to-many, so this never affects
--- the model's other tags.
---@param name string
---@param key string
---@return boolean ok
function M.toggle_member(name, key)
    local tags, err = M.read()
    if not tags then
        Notify.warn(err or "Could not read tags")
        return false
    end
    local out, removed = {}, false
    for _, member in ipairs(tags[name] or {}) do
        if member == key then
            removed = true
        else
            out[#out + 1] = member
        end
    end
    if not removed then
        out[#out + 1] = key
    end
    tags[name] = out
    return M.write(tags)
end

---@param name string
---@return boolean ok
function M.create(name)
    local tags, err = M.read()
    if not tags then
        Notify.warn(err or "Could not read tags")
        return false
    end
    if tags[name] then
        Notify.warn("Tag already exists: " .. name)
        return false
    end
    tags[name] = {}
    return M.write(tags)
end

--- Delete a tag. It disappears from every model that carried it -- that is
--- all a tag is -- and the models themselves are untouched.
---@param name string
---@return boolean ok
function M.delete(name)
    local tags, err = M.read()
    if not tags then
        Notify.warn(err or "Could not read tags")
        return false
    end
    tags[name] = nil
    return M.write(tags)
end

---@param from string
---@param to string
---@return boolean ok
function M.rename(from, to)
    local tags, err = M.read()
    if not tags then
        Notify.warn(err or "Could not read tags")
        return false
    end
    if not tags[from] then
        return false
    end
    if tags[to] then
        Notify.warn("Tag already exists: " .. to)
        return false
    end
    tags[to] = tags[from]
    tags[from] = nil
    return M.write(tags)
end

return M
