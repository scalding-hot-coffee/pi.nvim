--- Floating picker for named model categories.
---
--- Activating a category writes its members to pi's global `enabledModels`,
--- so :PiCycleModel cycles within that group. Editing categories themselves
--- (create, rename, delete) happens here too.

local M = {}

local Categories = require("pi.model_categories")
local Ft = require("pi.filetypes")
local Notify = require("pi.notify")
local Scoped = require("pi.scoped_models")
local WINHIGHLIGHT = require("pi.ui.highlights").DIALOG_WINHIGHLIGHT

local FOOTER = " <CR> activate · n new · r rename · d delete · q close "

--- Prompt for a category name. Returns nil when cancelled or left blank.
---@param prompt string
---@param default? string
---@return string?
local function ask(prompt, default)
    local ok, input = pcall(vim.fn.input, prompt, default or "")
    if not ok then
        return nil
    end
    input = vim.trim(input or "")
    return input ~= "" and input or nil
end

--- Open the category picker.
---@param all table[] available models from get_available_models
function M.open(all)
    local names = {}
    local counts = {}

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = Ft.dialog

    local editor_w = vim.o.columns
    local editor_h = vim.o.lines - vim.o.cmdheight
    local width = math.max(52, math.min(math.floor(editor_w * 0.5), vim.fn.strdisplaywidth(FOOTER) + 2))

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.floor(editor_h * 0.25),
        col = math.floor((editor_w - width) / 2),
        width = width,
        height = 8,
        style = "minimal",
        border = require("pi.config").options.dialog.border,
        title = " Model categories ",
        title_pos = "center",
        footer = FOOTER,
        footer_pos = "center",
    })
    vim.wo[win].winhighlight = WINHIGHLIGHT
    vim.wo[win].cursorline = true
    vim.wo[win].wrap = false

    ---@return string? name
    local function current()
        if not vim.api.nvim_win_is_valid(win) then
            return nil
        end
        return names[vim.api.nvim_win_get_cursor(win)[1]]
    end

    ---@param keep? string
    local function redraw(keep)
        local categories = Categories.read() or {}
        names = vim.tbl_keys(categories)
        table.sort(names)

        -- Count only models the backend still offers, so a category padded with
        -- stale entries doesn't look bigger than it will actually cycle.
        counts = {}
        local lines = {}
        for i, name in ipairs(names) do
            local available = 0
            for _, key in ipairs(categories[name]) do
                if Scoped.find(key, all) then
                    available = available + 1
                end
            end
            counts[name] = available
            local total = #categories[name]
            local suffix = total > available and string.format("%d of %d available", available, total)
                or string.format("%d model%s", available, available == 1 and "" or "s")
            lines[i] = string.format("%-24s %s", name, suffix)
        end
        if #lines == 0 then
            lines = { "  No categories yet — press n to create one" }
        end

        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false

        if not vim.api.nvim_win_is_valid(win) then
            return
        end
        local row = 1
        for i, name in ipairs(names) do
            if name == keep then
                row = i
                break
            end
        end
        vim.api.nvim_win_set_cursor(win, { math.min(row, math.max(#lines, 1)), 0 })
        vim.api.nvim_win_set_config(win, {
            height = math.max(3, math.min(#lines + 1, math.floor(editor_h * 0.5))),
        })
    end

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    ---@param key string
    ---@param handler fun()
    local function map(key, handler)
        vim.keymap.set("n", key, handler, { buffer = buf, nowait = true, silent = true })
    end

    map("<CR>", function()
        local name = current()
        if not name then
            return
        end
        close()
        Categories.activate(name, all)
    end)

    map("n", function()
        local name = ask("New category: ")
        if name and Categories.create(name) then
            redraw(name)
        end
    end)

    map("r", function()
        local name = current()
        if not name then
            return
        end
        local to = ask("Rename '" .. name .. "' to: ", name)
        if to and to ~= name and Categories.rename(name, to) then
            redraw(to)
        end
    end)

    map("d", function()
        local name = current()
        if not name then
            return
        end
        local count = counts[name] or 0
        local prompt = string.format("Delete category '%s' (%d model%s)? [y/N]: ", name, count, count == 1 and "" or "s")
        local ok, answer = pcall(vim.fn.input, prompt)
        if ok and (answer or ""):lower():sub(1, 1) == "y" then
            -- Deleting a category never touches the models themselves.
            Categories.delete(name)
            redraw(nil)
        end
    end)

    map("q", close)
    map("<Esc>", close)

    redraw(nil)
    if #all == 0 then
        Notify.warn("No models available")
    end
end

--- Assign or unassign one model, chosen from the existing categories.
--- Offers to create a category when none exist yet.
---@param key string model key, `provider/id`
---@param on_done? fun()
function M.assign(key, on_done)
    local names = Categories.names()

    local function finish()
        if on_done then
            on_done()
        end
    end

    if #names == 0 then
        local name = ask("No categories yet. New category: ")
        if name and Categories.create(name) then
            Categories.toggle_member(name, key)
            Notify.info("Added to '" .. name .. "'")
        end
        finish()
        return
    end

    local member_of = {}
    for _, name in ipairs(Categories.for_model(key)) do
        member_of[name] = true
    end

    local labels = {}
    for i, name in ipairs(names) do
        labels[i] = (member_of[name] and "✓ " or "  ") .. name
    end
    labels[#labels + 1] = "+ New category…"

    vim.ui.select(labels, { prompt = "Categories for " .. key }, function(choice)
        if not choice then
            finish()
            return
        end
        if choice == "+ New category…" then
            local name = ask("New category: ")
            if name and Categories.create(name) then
                Categories.toggle_member(name, key)
                Notify.info("Added to '" .. name .. "'")
            end
            finish()
            return
        end
        local name = choice:sub(3)
        Categories.toggle_member(name, key)
        Notify.info((member_of[name] and "Removed from '" or "Added to '") .. name .. "'")
        finish()
    end)
end

return M
