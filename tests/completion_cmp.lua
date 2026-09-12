local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(root)

-- Stub the project file cache before pi.completion captures the module.
package.loaded["pi.cache.files"] = {
    list = function()
        return { "lua/pi/init.lua", "lua/pi/ui/chat/init.lua", "README.md", "lua/pi/ui/" }
    end,
    is_pi_prompt_buf = function()
        return true
    end,
    exists = function()
        return false
    end,
    invalidate = function()
    end,
}

local Source = require("pi.completion.cmp")
local CommandsCache = require("pi.cache.commands")

local Kind = vim.lsp.protocol.CompletionItemKind
local source = Source.new()

local function equal(actual, expected, message)
    if not vim.deep_equal(actual, expected) then
        error((message or "values differ") .. "\nactual: " .. vim.inspect(actual) .. "\nexpected: " .. vim.inspect(expected))
    end
end

local function ok(condition, message)
    if not condition then
        error(message)
    end
end

CommandsCache.set({
    { name = "review", description = "Review the current diff", source = "prompt" },
    { name = "skill:commit", description = "Write a commit message", source = "skill" },
    {
        name = "plannotator-plan-mode",
        description = "Toggle plan mode. The agent writes a markdown plan file anywhere in the working directory and submits its path",
        source = "extension",
        sourceInfo = { path = "/home/me/.pi/agent/extensions/plan/index.ts", source = "package" },
    },
})

---Build a cmp-shaped params table for a prompt line.
---@param keyword string the matched keyword (trigger char included)
---@param opts? { offset?: integer, row?: integer }
local function params(keyword, opts)
    opts = opts or {}
    local line = keyword
    return {
        keyword = keyword,
        offset = opts.offset or 0,
        context = {
            cursor = { row = opts.row or 1, col = #line },
            cursor_before_line = line,
            cursor_line = line,
            bufnr = vim.api.nvim_get_current_buf(),
        },
    }
end

local function collect(keyword, opts)
    local out = nil
    source:complete(params(keyword, opts), function(items)
        out = items
    end)
    return out or {}
end

-- Availability is scoped to the prompt filetype only.
vim.bo.filetype = ""
equal(source:is_available(), false, "source must stay off outside the pi prompt")
vim.bo.filetype = "pi-chat-prompt"
equal(source:is_available(), true, "source must be on in the pi prompt")

equal(source:get_keyword_pattern(), '[/@][^%s]*', "keyword pattern keeps the trigger char")
equal(source:get_trigger_characters(), { "/", "@", "." }, "trigger characters")

-- Bare "/" lists every command in pi's own order (extension, prompt, skill).
local all = collect("/")
equal(#all, 3, "all commands listed")
equal(all[1].label, "/review", "first label")
equal(all[1].insertText, "/review", "insert text carries the slash")
equal(all[1].filterText, "/review", "filter text carries the slash")
equal(all[1].kind, Kind.Snippet, "prompt template kind")
equal(all[2].label, "/skill:commit", "skills keep their skill: prefix")
equal(all[2].kind, Kind.Module, "skill kind")
equal(all[3].kind, Kind.Event, "extension command kind")
ok(all[1].sortText < all[2].sortText and all[2].sortText < all[3].sortText, "rank survives via sortText")
equal(all[1].menu, "Review the current diff", "short descriptions pass through untouched")
ok(vim.fn.strchars(all[3].menu) <= 44, "menu text respects the width cap")
ok(all[3].menu:sub(-3) == "…", "clipped menu text ends with a real ellipsis (3 bytes)")
equal(type(all[1].documentation), "table", "documentation attached")
ok(all[1].documentation.value:find("Review the current diff", 1, true), "docs carry the full description")
ok(all[3].documentation.value:find("plan/index.ts", 1, true), "docs carry the source path")
equal(all[1].data.pi, "command", "entries are tagged as commands")

-- Prefix matches rank ahead of fuzzy ones, like the TUI.
local prefix = collect("/pl")
equal(#prefix, 1, "one prefix match")
equal(prefix[1].label, "/plannotator-plan-mode", "prefix match")
equal(prefix[1].data.fuzzy, false, "prefix match is not fuzzy")

local fuzzy = collect("/rm")
equal(#fuzzy, 1, "one fuzzy match")
equal(fuzzy[1].label, "/plannotator-plan-mode", "subsequence match found")
equal(fuzzy[1].data.fuzzy, true, "ranked as fuzzy")

-- Skill short names are matchable, mirroring the TUI.
local skill = collect("/com")
equal(#skill, 1, "skill matched by short name")
equal(skill[1].label, "/skill:commit", "skill label")

-- π only treats the first line, column 1 as a command.
equal(#collect("/rev", { row = 2 }), 0, "no command completion off the first line")
equal(#collect("review", { offset = 0 }), 0, "nothing without a trigger char")
equal(#collect("/rev", { offset = 3 }), 0, "commands must start at column 1")

-- @-mentions collapse one directory segment at a time, like the TUI.
local mentions = collect("@lua")
ok(#mentions >= 1, "mention candidates returned")
equal(mentions[1].label, "@lua/", "first candidate collapses to the next segment")
equal(mentions[1].insertText, "@lua/", "mention insert text keeps the @ and trailing slash")
equal(mentions[1].kind, Kind.Folder, "directory kind")
equal(mentions[1].data.pi, "mention", "entries are tagged as mentions")

local nested = collect("@lua/")
local found = false
for _, item in ipairs(nested) do
    if item.label == "@lua/pi/" then
        found = true
    end
end
ok(found, "typing the slash drills into the next segment")

local plain = collect("@README")
equal(plain[1].label, "@README.md", "files complete to their name")
equal(plain[1].kind, Kind.File, "file kind")

local files = collect("@init")
ok(#files >= 1, "fuzzy file matches returned")
equal(files[1].data.fuzzy, true, "non-prefix file match ranks as fuzzy")

equal(#collect("."), 0, "bare dot is not a mention")

-- Public API needed so accepting a slash command can submit like the TUI.
equal(type(require("pi").submit), "function", "pi.submit is exposed")

print("cmp completion source tests passed")
vim.cmd("qa!")
