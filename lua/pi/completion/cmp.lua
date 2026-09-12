--- nvim-cmp source for /commands and @-mentions.
---
--- Mirrors pi's TUI popup: typing `/` on the first line lists slash commands
--- with their descriptions, typing `@` completes project paths, prefix matches
--- are ranked before fuzzy ones, and accepting a `/command` can submit it in the
--- same keystroke (see the `pi-chat-prompt` cmp filetype config in the docs).
---
--- Register it like any other source. `is_available` scopes it to the π prompt
--- buffer, so it is inert everywhere else:
---
---     sources = { { name = "pi", module = "pi.completion.cmp" }, ... }
---
--- cmp ranks entries by its own match score ahead of `sortText`, which would
--- reorder our two-pass ranking. To keep π's order, pin the comparator for the
--- prompt filetype:
---
---     cmp.setup.filetype("pi-chat-prompt", {
---         sorting = { comparators = { require("cmp.config.compare").sort_text } },
---     })

local Matcher = require("pi.completion")
local Ft = require("pi.filetypes")

---@class pi.CompletionCmpSource
local source = {}

---@type table<string, integer>
local command_kinds = {
    extension = vim.lsp.protocol.CompletionItemKind.Event,
    prompt = vim.lsp.protocol.CompletionItemKind.Snippet,
    skill = vim.lsp.protocol.CompletionItemKind.Module,
}

local file_kind = vim.lsp.protocol.CompletionItemKind.File
local folder_kind = vim.lsp.protocol.CompletionItemKind.Folder
local function_kind = vim.lsp.protocol.CompletionItemKind.Function

--- Max characters of a command description shown in the popup's menu column.
local MENU_DESCRIPTION_CHARS = 44

function source.new()
    return setmetatable({}, { __index = source })
end

function source:is_available()
    return vim.bo.filetype == Ft.prompt
end

--- Include the trigger character in the keyword so `/rev` is replaced whole
--- rather than only the part after the slash.
---@return string
function source:get_keyword_pattern()
    return '[/@][^%s]*'
end

---@return string[]
function source:get_trigger_characters()
    return { "/", "@", "." }
end

--- Collapse to a single line and clip for the popup's menu column.
---@param text string
---@param max integer
---@return string
local function menu_text(text, max)
    local flat = (text:gsub("[%c%s]+", " "))
    flat = flat:gsub("^ *", ""):gsub(" *$", "")
    if vim.fn.strchars(flat) <= max then
        return flat
    end
    return vim.fn.strcharpart(flat, 0, max - 1) .. "…"
end

---@param params cmp.CompleteParams
---@param callback fun(items: lsp.CompletionItem[])
function source:complete(params, callback)
    local keyword = params.keyword or ""
    local trigger = keyword:sub(1, 1)
    local items = {}

    if trigger == "/" then
        -- π only recognises a command on the first line, starting at column 1.
        if params.context.cursor.row ~= 1 or params.offset ~= 0 then
            return callback(items)
        end
        local matches = Matcher.complete_commands(keyword:sub(2), function(cmd, is_fuzzy)
            return { cmd = cmd, fuzzy = is_fuzzy }
        end)
        for rank, match in ipairs(matches) do
            local cmd = match.cmd
            local label = "/" .. cmd.name
            local description = cmd.description or ""
            local docs = { "`" .. label .. "`  ·  " .. cmd.source }
            if description ~= "" then
                docs[#docs + 1] = ""
                docs[#docs + 1] = description
            end
            if cmd.sourceInfo and cmd.sourceInfo.path then
                docs[#docs + 1] = ""
                docs[#docs + 1] = "`" .. cmd.sourceInfo.path .. "`"
            end
            items[#items + 1] = {
                label = label,
                insertText = label,
                filterText = label,
                sortText = ("%04d"):format(rank),
                kind = command_kinds[cmd.source] or function_kind,
                menu = menu_text(description, MENU_DESCRIPTION_CHARS),
                documentation = { kind = "markdown", value = table.concat(docs, "\n") },
                data = { pi = "command", fuzzy = match.fuzzy },
            }
        end
        return callback(items)
    end

    if trigger == "@" then
        local matches = Matcher.complete_files(keyword:sub(2), function(path, kind, is_fuzzy)
            return { path = path, kind = kind, fuzzy = is_fuzzy }
        end)
        for rank, match in ipairs(matches) do
            local text = "@" .. match.path
            items[#items + 1] = {
                label = text,
                insertText = text,
                filterText = text,
                sortText = ("%04d"):format(rank),
                kind = match.kind == "dir" and folder_kind or file_kind,
                menu = match.kind == "dir" and "dir" or "",
                data = { pi = "mention", fuzzy = match.fuzzy },
            }
        end
        return callback(items)
    end

    -- The "." trigger exists so cmp asks us at all; a bare "." is not a mention.
    callback(items)
end

return source
