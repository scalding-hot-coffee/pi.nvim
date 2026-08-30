--- Read and write pi's global settings.json (~/.pi/agent/settings.json).
---
--- This is the same file the TUI writes when you press ctrl+s in the
--- /scoped-models selector, so a model set edited here is the one the TUI
--- sees, and vice versa. pi merges only its own modified fields when it
--- saves, so a key written from Neovim survives a concurrent write by a
--- running pi session.

local M = {}

local uv = vim.uv or vim.loop

--- Sentinel for a JSON `[]`, which is indistinguishable from `{}` after a
--- decode into Lua. Preserved so unrelated settings keys survive a rewrite.
local EMPTY_ARRAY = {}
M.EMPTY_ARRAY = EMPTY_ARRAY

--- pi resolves its agent dir from $PI_CODING_AGENT_DIR, else ~/.pi/agent.
---@return string
function M.agent_dir()
    local env = vim.env.PI_CODING_AGENT_DIR
    if env and env ~= "" then
        return vim.fn.expand(env)
    end
    return uv.os_homedir() .. "/.pi/agent"
end

---@return string
function M.path()
    return M.agent_dir() .. "/settings.json"
end

---@param path string
---@return string?
local function read_file(path)
    local fd = io.open(path, "r")
    if not fd then
        return nil
    end
    local raw = fd:read("*a")
    fd:close()
    return raw
end

--- Decode settings.json.
---
--- A missing or empty file yields an empty table -- pi creates it on demand.
--- A file that fails to parse yields nil plus a message, so callers never
--- clobber settings they could not read.
---@return table? settings
---@return string? err
function M.read()
    local path = M.path()
    local raw = read_file(path)
    if not raw or raw:match("^%s*$") then
        return {}, nil
    end
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return nil, "Could not parse " .. path
    end
    -- Re-tag top-level keys that were written as `[]` so encoding round-trips.
    for key, value in pairs(decoded) do
        if type(value) == "table" and next(value) == nil then
            if raw:find('"' .. vim.pesc(key) .. '"%s*:%s*%[') then
                decoded[key] = EMPTY_ARRAY
            end
        end
    end
    return decoded, nil
end

---@param t table
---@return boolean
local function is_list(t)
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" then
            return false
        end
        count = count + 1
    end
    return count == #t
end

--- Encode with 2-space indentation, matching pi's `JSON.stringify(x, null, 2)`.
---@param value any
---@param depth integer
---@return string
local function encode(value, depth)
    if value == EMPTY_ARRAY then
        return "[]"
    end
    if type(value) ~= "table" then
        return vim.json.encode(value)
    end
    if next(value) == nil then
        return "{}"
    end

    local pad = string.rep("  ", depth + 1)
    local close_pad = string.rep("  ", depth)
    local parts = {}

    if is_list(value) then
        for _, item in ipairs(value) do
            parts[#parts + 1] = pad .. encode(item, depth + 1)
        end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. close_pad .. "]"
    end

    local keys = vim.tbl_keys(value)
    table.sort(keys)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = pad .. vim.json.encode(tostring(key)) .. ": " .. encode(value[key], depth + 1)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. close_pad .. "}"
end

--- Set one top-level key in settings.json, preserving everything else.
--- Passing nil removes the key.
---@param key string
---@param value any
---@return boolean ok
---@return string? err
function M.set(key, value)
    local settings, err = M.read()
    if not settings then
        return false, err
    end
    settings[key] = value

    local dir = M.agent_dir()
    if not uv.fs_stat(dir) then
        return false, "pi agent directory not found: " .. dir
    end

    local path = M.path()
    local tmp = path .. ".nvim.tmp"
    local fd = io.open(tmp, "w")
    if not fd then
        return false, "Could not write " .. tmp
    end
    fd:write(encode(settings, 0) .. "\n")
    fd:close()

    local ok, rename_err = uv.fs_rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return false, rename_err or ("Could not replace " .. path)
    end
    return true, nil
end

return M
