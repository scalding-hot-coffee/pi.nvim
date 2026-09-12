local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(root)
require("pi").setup()

local function equal(actual, expected, message)
    if not vim.deep_equal(actual, expected) then
        error((message or "values differ") .. "\nactual: " .. vim.inspect(actual) .. "\nexpected: " .. vim.inspect(expected))
    end
end

local quick = require("pi.quick_edit")
local profile = require("pi.config").options.quick_edit
equal(profile.profile, "quick-edit", "quick-edit profile default")
equal(profile.context_lines, 20, "quick-edit context default")

for _, command in ipairs({ "PiQuickEdit", "PiQuickEditModel", "PiQuickEditModelReset" }) do
    equal(vim.fn.exists(":" .. command), 2, command .. " must be registered")
end

equal(type(quick.run), "function", "quick edit API")
equal(type(quick.select_model), "function", "quick edit model API")
equal(type(quick.reset_model), "function", "quick edit reset API")

print("quick-edit smoke tests passed")
vim.cmd("qa!")
