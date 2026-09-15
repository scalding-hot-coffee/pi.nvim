local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local test_dir = vim.fn.tempname()
vim.fn.mkdir(test_dir, "p")
vim.env.PI_CODING_AGENT_DIR = test_dir
vim.env.PI_QUICK_EDIT_TEST_LOG = test_dir .. "/launch.json"
vim.opt.runtimepath:prepend(root)

vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function()
        vim.fn.delete(test_dir, "rf")
    end,
})

local function equal(actual, expected, message)
    if not vim.deep_equal(actual, expected) then
        error((message or "values differ") .. "\nactual: " .. vim.inspect(actual) .. "\nexpected: " .. vim.inspect(expected))
    end
end

local function wait_for(predicate, message)
    if not vim.wait(4000, predicate, 10) then
        error(message)
    end
end

local function select_chars(buf, start_col, end_col)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, start_col })
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(0, { 1, end_col })
end

local profiles = io.open(test_dir .. "/profiles.json", "w")
profiles:write(vim.json.encode({
    ["quick-edit"] = {
        provider = "openrouter",
        model = "anthropic/claude-haiku-4.5",
        thinkingLevel = "low",
        includeTools = {},
    },
}))
profiles:close()

require("pi").setup({ cli = { bin = root .. "/tests/fake-pi.js" } })

local prompts = { "replace it", "DELAY_TEST" }
vim.ui.input = function(_, callback)
    callback(table.remove(prompts, 1))
end

local buf = vim.api.nvim_create_buf(true, false)
vim.bo[buf].undolevels = -1
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "old text" })
vim.bo[buf].undolevels = 1000
select_chars(buf, 0, 2)
vim.cmd("normal! \27")
vim.cmd("'<,'>PiQuickEdit")
wait_for(function()
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "new text"
end, "quick edit did not replace the selection")
equal(vim.bo[buf].modified, true, "quick edit must leave the buffer unsaved")
vim.cmd("undo")
equal(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "old text", "replacement must be one undo step")

local launch = vim.json.decode(table.concat(vim.fn.readfile(vim.env.PI_QUICK_EDIT_TEST_LOG), "\n"))
equal(launch.profileName, "quick-edit", "worker profile env")
equal(launch.profileModel, "openrouter/anthropic/claude-haiku-4.5", "worker model env")
equal(launch.profileThinking, "low", "worker thinking env")
equal(vim.list_contains(launch.argv, "--no-tools"), true, "worker must have no tools")
equal(vim.list_contains(launch.argv, "--no-session"), true, "worker must be ephemeral")
equal(vim.list_contains(launch.argv, "--profile"), true, "worker must apply quick-edit profile")

-- A concurrent edit inside the tracked selection must make the result stale.
select_chars(buf, 0, 2)
vim.cmd("normal! \27")
vim.cmd("'<,'>PiQuickEdit")
vim.defer_fn(function()
    vim.api.nvim_buf_set_text(buf, 0, 0, 0, 3, { "local" })
end, 20)
wait_for(function()
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "local text"
end, "local edit did not run")
vim.wait(300)
equal(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "local text", "stale quick-edit result must be discarded")

print("quick-edit e2e tests passed")
vim.cmd("qa!")
