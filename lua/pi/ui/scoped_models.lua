--- Floating selector for the scoped model set.
---
--- Neovim's counterpart to the TUI's `/scoped-models` screen. Every change is
--- written straight to pi's global settings.json -- there is no session-only
--- tier here, because the set is global by definition.
---
--- Display order is fixed when the picker opens and only ever changes when the
--- user reorders explicitly, so toggling never moves anything under the cursor.
--- That order is also the cycle order: what gets persisted is the enabled
--- subset of it, in display order.

local M = {}

local Ft = require("pi.filetypes")
local Notify = require("pi.notify")
local Scoped = require("pi.scoped_models")
local WINHIGHLIGHT = require("pi.ui.highlights").DIALOG_WINHIGHLIGHT

local FOOTER = " <CR> toggle · p provider · a all · x clear · J/K reorder · / filter · q close "

--- Open the selector for the models the backend currently offers.
---@param all table[] available models from get_available_models
function M.open(all)
    if #all == 0 then
        Notify.warn("No models available")
        return
    end

    ---@type table<string, table> key -> backend model
    local models = {}
    ---@type table<string, true>
    local available = {}
    for _, model in ipairs(all) do
        models[Scoped.key(model)] = model
        available[Scoped.key(model)] = true
    end

    -- Fixed display order: the configured set first, in cycle order, then
    -- everything else. Patterns that no longer match a live model are kept so
    -- they stay visible rather than vanishing on the next write.
    local order = {}
    local placed = {}
    for _, key in ipairs(Scoped.read() or {}) do
        local model = Scoped.find(key, all)
        local canonical = model and Scoped.key(model) or key
        if not placed[canonical] then
            placed[canonical] = true
            order[#order + 1] = canonical
        end
    end
    for _, model in ipairs(all) do
        local key = Scoped.key(model)
        if not placed[key] then
            placed[key] = true
            order[#order + 1] = key
        end
    end

    ---@type table<string, true>
    local selected = {}
    --- Adopt the on-disk set. No stored set means every model is enabled.
    local function load_selection()
        local stored = Scoped.read()
        selected = {}
        if not stored then
            for key in pairs(available) do
                selected[key] = true
            end
            return
        end
        for _, pattern in ipairs(stored) do
            local model = Scoped.find(pattern, all)
            selected[model and Scoped.key(model) or pattern] = true
        end
    end
    load_selection()

    --- True when nothing is narrowed, i.e. every available model is enabled.
    local function covers_all()
        for key in pairs(available) do
            if not selected[key] then
                return false
            end
        end
        return true
    end

    local query = ""
    local visible = {}

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = Ft.dialog

    local editor_w = vim.o.columns
    local editor_h = vim.o.lines - vim.o.cmdheight
    local width = math.max(60, math.min(math.floor(editor_w * 0.6), vim.fn.strdisplaywidth(FOOTER) + 2))
    local height = math.max(8, math.min(#order, math.floor(editor_h * 0.7)))

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.floor((editor_h - height) / 2),
        col = math.floor((editor_w - width) / 2),
        width = width,
        height = height,
        style = "minimal",
        border = require("pi.config").options.dialog.border,
        title = " Scoped models ",
        title_pos = "center",
        footer = FOOTER,
        footer_pos = "center",
    })
    vim.wo[win].winhighlight = WINHIGHLIGHT
    vim.wo[win].cursorline = true
    vim.wo[win].wrap = false

    ---@param key string
    ---@param unscoped boolean
    ---@return string
    local function render(key, unscoped)
        -- No marks while unscoped: nothing is excluded, so a column of ticks
        -- would only suggest a selection the user has not made yet.
        local mark = unscoped and "  " or (selected[key] and "✓ " or "✗ ")
        local model = models[key]
        if not model then
            return mark .. key .. "  [unavailable]"
        end
        return mark .. model.id .. "  [" .. model.provider .. "]"
    end

    ---@return string? key
    local function current()
        if not vim.api.nvim_win_is_valid(win) then
            return nil
        end
        return visible[vim.api.nvim_win_get_cursor(win)[1]]
    end

    --- Redraw in place. The scroll position is preserved, and the cursor
    --- follows `keep_key` when given, so a toggle never shifts the view.
    ---@param keep_key string?
    local function redraw(keep_key)
        local view = vim.api.nvim_win_is_valid(win) and vim.fn.winsaveview() or nil

        visible = order
        if query ~= "" then
            local entries = {}
            for _, key in ipairs(order) do
                local model = models[key]
                entries[#entries + 1] = {
                    key = key,
                    search = model and (model.id .. " " .. model.provider .. " " .. (model.name or "")) or key,
                }
            end
            local ok, matched = pcall(vim.fn.matchfuzzy, entries, query, { key = "search" })
            visible = {}
            for _, entry in ipairs((ok and matched) or {}) do
                visible[#visible + 1] = entry.key
            end
        end

        local unscoped = covers_all()
        local lines = {}
        for i, key in ipairs(visible) do
            lines[i] = render(key, unscoped)
        end
        if #lines == 0 then
            lines = { "  No matching models" }
        end

        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false

        if not vim.api.nvim_win_is_valid(win) then
            return
        end
        if view then
            vim.fn.winrestview(view)
        end
        if keep_key then
            for i, key in ipairs(visible) do
                if key == keep_key then
                    vim.api.nvim_win_set_cursor(win, { i, 0 })
                    break
                end
            end
        end
        -- Clamp in case the filter shortened the list under the cursor.
        local row = vim.api.nvim_win_get_cursor(win)[1]
        local last = math.max(#lines, 1)
        if row > last then
            vim.api.nvim_win_set_cursor(win, { last, 0 })
        end

        local count = 0
        for key in pairs(available) do
            if selected[key] then
                count = count + 1
            end
        end
        vim.api.nvim_win_set_config(win, {
            title = unscoped and " Scoped models — all enabled "
                or string.format(" Scoped models — %d/%d enabled ", count, #all),
            title_pos = "center",
        })
    end

    --- Persist the enabled subset, in display order, then re-adopt what landed
    --- on disk so the view always reflects the real state.
    local function save()
        local list = {}
        for _, key in ipairs(order) do
            if selected[key] then
                list[#list + 1] = key
            end
        end
        Scoped.write(list, all)
        load_selection()
    end

    ---@param key string
    ---@param handler fun()
    local function map(key, handler)
        vim.keymap.set("n", key, handler, { buffer = buf, nowait = true, silent = true })
    end

    ---@param mutate fun()
    local function apply(mutate)
        local keep = current()
        mutate()
        save()
        redraw(keep)
    end

    --- Toggling while unscoped narrows to just that model, as the TUI does --
    --- otherwise the first click on a full list would do nothing visible.
    ---@param key string
    local function toggle(key)
        if covers_all() then
            selected = { [key] = true }
        elseif selected[key] then
            selected[key] = nil
        else
            selected[key] = true
        end
    end

    local function toggle_current()
        local key = current()
        if key then
            apply(function()
                toggle(key)
            end)
        end
    end
    map("<CR>", toggle_current)
    map("<Space>", toggle_current)

    map("p", function()
        local key = current()
        local model = key and models[key]
        if not model then
            return
        end
        apply(function()
            local keys = {}
            local all_on = true
            for _, candidate in ipairs(all) do
                if candidate.provider == model.provider then
                    local candidate_key = Scoped.key(candidate)
                    keys[#keys + 1] = candidate_key
                    all_on = all_on and selected[candidate_key] ~= nil
                end
            end
            -- Narrowing from "all enabled" starts from just this provider.
            if covers_all() then
                selected = {}
                all_on = false
            end
            for _, candidate_key in ipairs(keys) do
                selected[candidate_key] = (not all_on) or nil
            end
        end)
    end)

    map("a", function()
        apply(function()
            if query == "" then
                for key in pairs(available) do
                    selected[key] = true
                end
            else
                for _, key in ipairs(visible) do
                    selected[key] = true
                end
            end
        end)
    end)

    map("x", function()
        apply(function()
            if query == "" then
                selected = {}
            else
                for _, key in ipairs(visible) do
                    selected[key] = nil
                end
            end
        end)
    end)

    --- Move the model under the cursor within the display order, which is the
    --- cycle order. Only meaningful once a set exists.
    ---@param delta integer
    local function reorder(delta)
        local key = current()
        if not key or covers_all() then
            return
        end
        local index
        for i, candidate in ipairs(order) do
            if candidate == key then
                index = i
                break
            end
        end
        local target = index and index + delta
        if not target or target < 1 or target > #order then
            return
        end
        order[index], order[target] = order[target], order[index]
        save()
        redraw(key)
    end

    map("K", function()
        reorder(-1)
    end)
    map("J", function()
        reorder(1)
    end)
    map("<M-Up>", function()
        reorder(-1)
    end)
    map("<M-Down>", function()
        reorder(1)
    end)

    map("/", function()
        local ok, input = pcall(vim.fn.input, "Filter: ", query)
        if ok then
            query = input or ""
            redraw(current())
        end
    end)

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end
    map("q", close)
    map("<Esc>", function()
        if query ~= "" then
            query = ""
            redraw(current())
        else
            close()
        end
    end)

    redraw(nil)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

return M
