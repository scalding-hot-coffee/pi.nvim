--- Tag browser: pick a tag, see its models, switch to one.
---
--- Selecting a model here sets the session model and nothing else. Tags never
--- write pi's `enabledModels`, so :PiCycleModel keeps cycling the scoped set
--- exactly as it did before any tag existed.

local M = {}

local Ft = require("pi.filetypes")
local Models = require("pi.models")
local Notify = require("pi.notify")
local Scoped = require("pi.scoped_models")
local Tags = require("pi.model_tags")
local WINHIGHLIGHT = require("pi.ui.highlights").DIALOG_WINHIGHLIGHT

local TAG_FOOTER = " <CR> open · n new · r rename · d delete · q close "
local MODEL_FOOTER = " <CR> use model · x untag · <BS> back · q close "

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

--- Shared floating window for both levels of the browser.
---@param title string
---@param footer string
---@return integer buf, integer win
local function open_float(title, footer)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = Ft.dialog

    local editor_w = vim.o.columns
    local editor_h = vim.o.lines - vim.o.cmdheight
    local width = math.max(56, math.min(math.floor(editor_w * 0.55), vim.fn.strdisplaywidth(MODEL_FOOTER) + 4))

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.floor(editor_h * 0.2),
        col = math.floor((editor_w - width) / 2),
        width = width,
        height = 8,
        style = "minimal",
        border = require("pi.config").options.dialog.border,
        title = title,
        title_pos = "center",
        footer = footer,
        footer_pos = "center",
    })
    vim.wo[win].winhighlight = WINHIGHLIGHT
    vim.wo[win].cursorline = true
    vim.wo[win].wrap = false
    return buf, win
end

---@param win integer
---@param lines string[]
local function fit(win, lines)
    if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_config(win, {
            height = math.max(3, math.min(#lines, math.floor((vim.o.lines - vim.o.cmdheight) * 0.6))),
        })
    end
end

--- Second level: the models carrying one tag.
---@param name string
---@param session pi.Session
---@param all table[]
---@param on_back fun()
local function open_models(name, session, all, on_back)
    local buf, win = open_float(" Tag: " .. name .. " ", MODEL_FOOTER)
    local keys = {}

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    local function redraw()
        keys = Tags.members(name)
        local lines = {}
        for i, key in ipairs(keys) do
            local model = Scoped.find(key, all)
            lines[i] = model and ("  " .. model.id .. "  [" .. model.provider .. "]")
                or ("  " .. key .. "  [unavailable]")
        end
        if #lines == 0 then
            lines = { "  No models tagged '" .. name .. "' yet" }
        end
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        fit(win, lines)
    end

    ---@return string?
    local function current()
        if not vim.api.nvim_win_is_valid(win) then
            return nil
        end
        return keys[vim.api.nvim_win_get_cursor(win)[1]]
    end

    ---@param lhs string
    ---@param handler fun()
    local function map(lhs, handler)
        vim.keymap.set("n", lhs, handler, { buffer = buf, nowait = true, silent = true })
    end

    map("<CR>", function()
        local key = current()
        if not key then
            return
        end
        local model = Scoped.find(key, all)
        if not model then
            Notify.warn("Model is not available: " .. key)
            return
        end
        close()
        -- Only sets the model. The scoped set, and therefore cycling, is
        -- deliberately left alone.
        Models.set(session, model)
    end)

    map("x", function()
        local key = current()
        if key then
            Tags.toggle_member(name, key)
            redraw()
        end
    end)

    local function back()
        close()
        on_back()
    end
    map("<BS>", back)
    map("<Esc>", back)
    map("q", close)

    redraw()
end

--- First level: the tag list.
---@param session pi.Session
---@param all table[] available models
function M.open(session, all)
    local buf, win = open_float(" Model tags ", TAG_FOOTER)
    local names = {}

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    ---@param keep? string
    local function redraw(keep)
        local tags = Tags.read() or {}
        names = vim.tbl_keys(tags)
        table.sort(names)

        local lines = {}
        for i, name in ipairs(names) do
            -- Count against live models, so a tag holding a stale entry does
            -- not claim more than it can actually offer.
            local available = 0
            for _, key in ipairs(tags[name]) do
                if Scoped.find(key, all) then
                    available = available + 1
                end
            end
            local total = #tags[name]
            local suffix = total > available and string.format("%d of %d available", available, total)
                or string.format("%d model%s", total, total == 1 and "" or "s")
            lines[i] = string.format("%-22s %s", name, suffix)
        end
        if #lines == 0 then
            lines = { "  No tags yet — press n to create one" }
        end

        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        fit(win, lines)

        if vim.api.nvim_win_is_valid(win) then
            local row = 1
            for i, name in ipairs(names) do
                if name == keep then
                    row = i
                    break
                end
            end
            vim.api.nvim_win_set_cursor(win, { math.min(row, math.max(#lines, 1)), 0 })
        end
    end

    ---@return string?
    local function current()
        if not vim.api.nvim_win_is_valid(win) then
            return nil
        end
        return names[vim.api.nvim_win_get_cursor(win)[1]]
    end

    ---@param lhs string
    ---@param handler fun()
    local function map(lhs, handler)
        vim.keymap.set("n", lhs, handler, { buffer = buf, nowait = true, silent = true })
    end

    map("<CR>", function()
        local name = current()
        if not name then
            return
        end
        close()
        open_models(name, session, all, function()
            M.open(session, all)
        end)
    end)

    map("n", function()
        local name = ask("New tag: ")
        if name and Tags.create(name) then
            redraw(name)
        end
    end)

    map("r", function()
        local name = current()
        if not name then
            return
        end
        local to = ask("Rename '" .. name .. "' to: ", name)
        if to and to ~= name and Tags.rename(name, to) then
            redraw(to)
        end
    end)

    map("d", function()
        local name = current()
        if not name then
            return
        end
        local count = #Tags.members(name)
        local prompt = count > 0
                and string.format("Delete tag '%s'? It will be removed from %d model%s. [y/N]: ", name, count, count == 1 and "" or "s")
            or string.format("Delete tag '%s'? [y/N]: ", name)
        local ok, answer = pcall(vim.fn.input, prompt)
        if ok and (answer or ""):lower():sub(1, 1) == "y" then
            Tags.delete(name)
            redraw(nil)
        end
    end)

    map("q", close)
    map("<Esc>", close)

    redraw(nil)
end

--- Toggle tags on one model. Used for the session's current model and from
--- the scoped-models selector.
---@param key string model key, `provider/id`
---@param label string human label for the prompt
---@param on_done? fun()
function M.edit(key, label, on_done)
    local function finish()
        if on_done then
            on_done()
        end
    end

    local names = Tags.names()
    if #names == 0 then
        local name = ask("No tags yet. New tag: ")
        if name and Tags.create(name) then
            Tags.toggle_member(name, key)
            Notify.info("Tagged '" .. name .. "'")
        end
        finish()
        return
    end

    local member_of = {}
    for _, name in ipairs(Tags.for_model(key)) do
        member_of[name] = true
    end

    local items, labels = {}, {}
    for i, name in ipairs(names) do
        items[i] = name
        labels[i] = (member_of[name] and "✓ " or "  ") .. name
    end
    items[#items + 1] = false
    labels[#labels + 1] = "+ New tag…"

    vim.ui.select(labels, { prompt = "Tags for " .. label }, function(choice, index)
        if not choice then
            finish()
            return
        end
        local name = items[index]
        if name == false then
            local created = ask("New tag: ")
            if created and Tags.create(created) then
                Tags.toggle_member(created, key)
                Notify.info("Tagged '" .. created .. "'")
            end
            finish()
            return
        end
        Tags.toggle_member(name, key)
        Notify.info((member_of[name] and "Removed tag '" or "Tagged '") .. name .. "'")
        finish()
    end)
end

return M
