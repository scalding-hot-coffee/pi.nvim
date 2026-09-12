--- Ephemeral visual-selection rewrites powered by a short-lived Pi RPC worker.

local M = {}

local Notify = require("pi.notify")

local ns = vim.api.nvim_create_namespace("pi-quick-edit")
local state = { active = false, job = nil, request = nil }

local function config()
    return require("pi.config").options.quick_edit
end

local function agent_dir()
    local configured = require("pi.config").options.agent_dir
    if configured and configured ~= "" then
        return vim.fn.expand(configured)
    end
    local env = vim.env.PI_CODING_AGENT_DIR
    return env and env ~= "" and vim.fn.expand(env) or ((vim.uv or vim.loop).os_homedir() .. "/.pi/agent")
end

local function read_json(path)
    local file = io.open(path, "r")
    if not file then
        return nil, "Could not read " .. path
    end
    local content = file:read("*a")
    file:close()
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
        return nil, "Could not parse " .. path
    end
    return decoded
end

local function write_json(path, value)
    local tmp = path .. ".nvim.tmp"
    local file = io.open(tmp, "w")
    if not file then
        return false, "Could not write " .. tmp
    end
    file:write(vim.json.encode(value) .. "\n")
    file:close()
    local ok, err = (vim.uv or vim.loop).fs_rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return false, err or ("Could not replace " .. path)
    end
    return true
end

local function profile_path()
    return agent_dir() .. "/profiles.json"
end

local function override_path()
    return agent_dir() .. "/quick-edit.json"
end

local function quick_profile()
    local profiles, err = read_json(profile_path())
    if not profiles then
        return nil, err
    end
    local profile = profiles[config().profile]
    if type(profile) ~= "table" then
        return nil, "Profile '" .. config().profile .. "' not found in " .. profile_path()
    end
    profile = vim.deepcopy(profile)
    local override_file = io.open(override_path(), "r")
    if override_file then
        override_file:close()
        local override, override_err = read_json(override_path())
        if not override then
            return nil, override_err
        end
        if type(override.provider) == "string" then
            profile.provider = override.provider
        end
        if type(override.model) == "string" then
            profile.model = override.model
        end
        if type(override.thinkingLevel) == "string" then
            profile.thinkingLevel = override.thinkingLevel
        end
    end
    if type(profile.provider) ~= "string" or type(profile.model) ~= "string" then
        return nil, "Quick-edit profile must define provider and model"
    end
    return profile
end

local function line_length(buf, row)
    return #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
end

local function selection_mode()
    local mode = vim.fn.visualmode()
    return mode ~= "" and mode or vim.fn.mode()
end

local function clear_marks(request)
    if not request or not vim.api.nvim_buf_is_valid(request.buf) then
        return
    end
    pcall(vim.api.nvim_buf_del_extmark, request.buf, ns, request.start_mark)
    pcall(vim.api.nvim_buf_del_extmark, request.buf, ns, request.end_mark)
end

local function capture_selection(opts)
    local mode = selection_mode()
    if mode == "\22" then
        return nil, "Blockwise selections are not supported"
    end
    local buf = vim.api.nvim_get_current_buf()
    local start_row = math.max(0, (opts.line1 or vim.fn.line("'<")) - 1)
    local end_row = math.max(0, (opts.line2 or vim.fn.line("'>")) - 1)
    local start_col, end_col
    if mode == "V" then
        start_col = 0
        end_col = line_length(buf, end_row)
    else
        start_col = math.max(0, vim.fn.col("'<") - 1)
        end_col = math.max(0, vim.fn.col("'>"))
    end
    if end_row < start_row or (end_row == start_row and end_col < start_col) then
        start_row, end_row = end_row, start_row
        start_col, end_col = end_col, start_col
    end

    local count = vim.api.nvim_buf_line_count(buf)
    if start_row >= count or end_row >= count then
        return nil, "Visual selection is no longer valid"
    end
    start_col = math.min(start_col, line_length(buf, start_row))
    end_col = math.min(end_col, line_length(buf, end_row))

    local selected = table.concat(vim.api.nvim_buf_get_text(buf, start_row, start_col, end_row, end_col, {}), "\n")
    local context_start = math.max(0, start_row - config().context_lines)
    local context_end = math.min(count, end_row + config().context_lines + 1)
    local lines = vim.api.nvim_buf_get_lines(buf, context_start, context_end, false)
    local start_mark = vim.api.nvim_buf_set_extmark(buf, ns, start_row, start_col, { right_gravity = false })
    local end_mark = vim.api.nvim_buf_set_extmark(buf, ns, end_row, end_col, { right_gravity = true })

    return {
        buf = buf,
        path = vim.api.nvim_buf_get_name(buf),
        filetype = vim.bo[buf].filetype,
        start_row = start_row,
        start_col = start_col,
        end_row = end_row,
        end_col = end_col,
        start_mark = start_mark,
        end_mark = end_mark,
        selected = selected,
        context_start = context_start,
        context_lines = lines,
    }
end

local function numbered_context(request)
    local lines = {}
    for index, line in ipairs(request.context_lines) do
        lines[index] = string.format("%5d | %s", request.context_start + index, line)
    end
    return table.concat(lines, "\n")
end

local function initial_prompt(request, instruction)
    return table.concat({
        "Rewrite the selected range in the user's current Neovim buffer.",
        'Return strict JSON only: {"replacement_text":"..."}',
        "No markdown fences, explanations, or tool calls.",
        "Only the selected range will be replaced. Surrounding text is immutable context.",
        "Return only text that should replace the selection, even if broader changes are requested.",
        "",
        "User request:",
        instruction,
        "",
        "Buffer:",
        "- path: " .. (request.path ~= "" and request.path or "[No Name]"),
        "- filetype: " .. (request.filetype ~= "" and request.filetype or "unknown"),
        string.format("- selection: %d:%d-%d:%d", request.start_row + 1, request.start_col + 1, request.end_row + 1, request.end_col + 1),
        "",
        "Selected text:",
        request.selected,
        "",
        "Surrounding immutable context:",
        numbered_context(request),
    }, "\n")
end

local function repair_prompt(raw, error_message)
    return table.concat({
        "Your previous response was invalid.",
        'Return strict JSON only: {"replacement_text":"..."}',
        "No markdown fences or explanations.",
        "Validation error: " .. error_message,
        "Previous output:",
        raw,
    }, "\n")
end

local function parse_replacement(raw)
    local ok, decoded = pcall(vim.json.decode, vim.trim(raw or ""))
    if not ok then
        return nil, "response was not valid JSON"
    end
    if type(decoded) ~= "table" or type(decoded.replacement_text) ~= "string" then
        return nil, "response.replacement_text must be a string"
    end
    return decoded.replacement_text
end

local function current_range(request)
    if not vim.api.nvim_buf_is_valid(request.buf) then
        return nil, "Target buffer is no longer valid"
    end
    local start_mark = vim.api.nvim_buf_get_extmark_by_id(request.buf, ns, request.start_mark, {})
    local end_mark = vim.api.nvim_buf_get_extmark_by_id(request.buf, ns, request.end_mark, {})
    if #start_mark < 2 or #end_mark < 2 then
        return nil, "Original selection is no longer valid"
    end
    return { start_mark[1], start_mark[2], end_mark[1], end_mark[2] }
end

local function apply(request, replacement)
    local range, err = current_range(request)
    if not range then
        return false, err
    end
    local current = table.concat(vim.api.nvim_buf_get_text(request.buf, range[1], range[2], range[3], range[4], {}), "\n")
    if current ~= request.selected then
        return false, "Selection changed while quick edit was running; result was discarded"
    end
    vim.api.nvim_buf_set_text(request.buf, range[1], range[2], range[3], range[4], vim.split(replacement, "\n", { plain = true, trimempty = false }))
    clear_marks(request)
    return true
end

local function finish(message, level)
    if not state.active then
        return
    end
    if state.request then
        clear_marks(state.request)
    end
    state.active = false
    state.job = nil
    state.request = nil
    Notify.dispatch(message, level)
end

local function worker_command()
    local cli = require("pi.cli")
    return {
        cli.bin(),
        "--mode",
        "rpc",
        "--no-session",
        "--no-tools",
        "--no-skills",
        "--no-prompt-templates",
        "--no-context-files",
        "--profile",
        config().profile,
    }
end

local function run_worker(request, instruction, profile)
    local stdout = ""
    local stderr = {}
    local chunks = {}
    local stopping = false
    local attempts = 0
    local pending = nil

    local function stop_worker()
        if state.job then
            stopping = true
            vim.fn.jobstop(state.job)
        end
    end

    local function send_prompt(text)
        attempts = attempts + 1
        chunks = {}
        pending = tostring((vim.uv or vim.loop).hrtime())
        vim.fn.chansend(state.job, vim.json.encode({ id = pending, type = "prompt", message = text }) .. "\n")
    end

    local function handle(line)
        if not state.active or state.request ~= request or line == "" then
            return
        end
        local ok, event = pcall(vim.json.decode, line)
        if not ok then
            return
        end
        if event.type == "message_update" and event.assistantMessageEvent and event.assistantMessageEvent.type == "text_delta" then
            chunks[#chunks + 1] = event.assistantMessageEvent.delta or ""
        elseif event.type == "response" and event.id == pending and not event.success then
            stop_worker()
            finish(event.error or "Quick edit request failed", vim.log.levels.ERROR)
        elseif event.type == "agent_settled" then
            local raw = table.concat(chunks)
            local replacement, err = parse_replacement(raw)
            if replacement then
                local applied, apply_err = apply(request, replacement)
                stop_worker()
                if applied then
                    finish("Quick edit applied", vim.log.levels.INFO)
                else
                    finish(apply_err or "Could not apply quick edit", vim.log.levels.ERROR)
                end
            elseif attempts < config().max_attempts then
                send_prompt(repair_prompt(raw, err or "invalid response"))
            else
                stop_worker()
                finish(err or "Quick edit returned invalid output", vim.log.levels.ERROR)
            end
        end
    end

    local timer = (vim.uv or vim.loop).new_timer()
    local env = vim.tbl_extend("force", vim.fn.environ(), {
        PI_PROFILE_NAME = config().profile,
        PI_PROFILE_MODEL = profile.provider .. "/" .. profile.model,
    })
    if profile.thinkingLevel then
        env.PI_PROFILE_THINKING = profile.thinkingLevel
    end
    state.job = vim.fn.jobstart(worker_command(), {
        cwd = vim.fn.getcwd(),
        env = env,
        stdout_buffered = false,
        stderr_buffered = false,
        on_stdout = function(_, data)
            data[1] = stdout .. data[1]
            stdout = data[#data]
            for index = 1, #data - 1 do
                local line = data[index]
                vim.schedule(function()
                    handle(line)
                end)
            end
        end,
        on_stderr = function(_, data)
            for _, line in ipairs(data or {}) do
                if line ~= "" then
                    stderr[#stderr + 1] = line
                end
            end
        end,
        on_exit = function(_, code)
            vim.schedule(function()
                if timer then
                    timer:stop()
                    timer:close()
                    timer = nil
                end
                if state.active and state.request == request and not stopping and code ~= 0 then
                    finish(table.concat(stderr, "\n") ~= "" and table.concat(stderr, "\n") or ("Quick edit worker exited " .. code), vim.log.levels.ERROR)
                end
            end)
        end,
    })
    if state.job <= 0 then
        timer:close()
        finish("Could not start quick-edit Pi worker", vim.log.levels.ERROR)
        return
    end
    timer:start(config().timeout, 0, function()
        vim.schedule(function()
            if state.active then
                stop_worker()
                finish("Quick edit timed out", vim.log.levels.ERROR)
            end
        end)
    end)
    send_prompt(initial_prompt(request, instruction))
end

function M.run(opts)
    if state.active then
        Notify.warn("Quick edit is already running")
        return
    end
    opts = opts or {}
    if not opts.range or opts.range == 0 then
        Notify.warn("Quick edit requires a visual selection")
        return
    end
    local request, err = capture_selection(opts)
    if not request then
        Notify.error(err or "Could not capture selection")
        return
    end
    state.active = true
    state.request = request
    vim.ui.input({ prompt = config().prompt }, function(instruction)
        if not instruction or vim.trim(instruction) == "" then
            clear_marks(request)
            state.active = false
            state.request = nil
            return
        end
        local profile, profile_err = quick_profile()
        if not profile then
            finish(profile_err or "Could not load quick-edit profile", vim.log.levels.ERROR)
            return
        end
        Notify.info("Quick edit running with " .. profile.provider .. "/" .. profile.model)
        run_worker(request, instruction, profile)
    end)
end

function M.select_model()
    local profile, err = quick_profile()
    if not profile then
        Notify.error(err)
        return
    end

    local cmd = { require("pi.cli").bin(), "--list-models" }
    vim.system(cmd, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                Notify.error(result.stderr and result.stderr ~= "" and result.stderr or "Could not list Pi models")
                return
            end
            local models = {}
            for line in (result.stdout or ""):gmatch("[^\r\n]+") do
                local provider, model = line:match("^(%S+)%s+(%S+)")
                if provider and model and provider ~= "provider" and model:sub(1, 1) ~= "~" then
                    models[#models + 1] = provider .. "/" .. model
                end
            end
            vim.ui.select(models, { prompt = "Quick-edit model" }, function(choice)
                if not choice then
                    return
                end
                local provider, model = choice:match("^([^/]+)/(.+)$")
                local ok, write_err = write_json(override_path(), {
                    provider = provider,
                    model = model,
                    thinkingLevel = profile.thinkingLevel,
                })
                if ok then
                    Notify.info("Quick-edit model: " .. choice)
                else
                    Notify.error(write_err)
                end
            end)
        end)
    end)
end

function M.reset_model()
    local ok, err = os.remove(override_path())
    if not ok and err and not err:match("No such file") then
        Notify.error("Could not reset quick-edit model: " .. err)
        return
    end
    local profile, profile_err = quick_profile()
    if not profile then
        Notify.error(profile_err)
        return
    end
    Notify.info("Quick-edit model reset to " .. profile.provider .. "/" .. profile.model)
end

return M
