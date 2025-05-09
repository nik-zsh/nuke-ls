local h = require("null-ls.helpers")
local methods = require("null-ls.methods")

local CODE_ACTION = methods.internal.CODE_ACTION
-- filter diagnostics generated by the cspell built-in
local cspell_diagnostics = function(bufnr, lnum, cursor_col)
    local diagnostics = {}
    for _, diagnostic in ipairs(vim.diagnostic.get(bufnr, { lnum = lnum })) do
        if diagnostic.source == "cspell" and cursor_col >= diagnostic.col and cursor_col < diagnostic.end_col then
            table.insert(diagnostics, diagnostic)
        end
    end
    return diagnostics
end

local CSPELL_CONFIG_FILES = {
    "cspell.json",
    ".cspell.json",
    "cSpell.json",
    ".Sspell.json",
    ".cspell.config.json",
}

-- find the first cspell.json file in the directory tree
local find_cspell_config = function(cwd)
    local cspell_json_file = nil
    for _, file in ipairs(CSPELL_CONFIG_FILES) do
        local path = vim.fn.findfile(file, (cwd or vim.loop.cwd()) .. ";")
        if path ~= "" then
            cspell_json_file = path
            break
        end
    end
    return cspell_json_file
end

-- create a bare minimum cspell.json file
local create_cspell_json = function(cwd, file_name)
    local cspell_json = {
        version = "0.2",
        language = "en",
        words = {},
        flagWords = {},
    }
    local cspell_json_str = vim.json.encode(cspell_json)
    local cspell_json_file_path = require("null-ls.utils").path.join(cwd or vim.loop.cwd(), file_name)
    vim.fn.writefile({ cspell_json_str }, cspell_json_file_path)
    vim.notify("Created a new cspell.json file at " .. cspell_json_file_path, vim.log.levels.INFO)
    return cspell_json_file_path
end

return h.make_builtin({
    name = "cspell",
    meta = {
        url = "https://github.com/streetsidesoftware/cspell",
        description = [[Injects actions to fix typos found by `cspell`.

**This source is not actively developed in this repository.**

An up-to-date version exists as a companion plugin in [cspell.nvim](https://github.com/davidmh/cspell.nvim)
]],
        notes = {
            "This source depends on the `cspell` built-in diagnostics source, so make sure to register it, too.",
        },
        usage = "local sources = { null_ls.builtins.diagnostics.cspell, null_ls.builtins.code_actions.cspell }",
        config = {
            {
                key = "find_json",
                type = "function",
                description = "Customizing the location of cspell config",
                usage = [[
function(cwd)
    return vim.fn.expand(cwd .. "/cspell.json")
end]],
            },
            {
                key = "on_success",
                type = "function",
                description = "Callback after successful execution of code action.",
                usage = [[
function(cspell_config_file, params)
    -- format the cspell config file
    os.execute(
        string.format(
            "cat %s | jq -S '.words |= sort' | tee %s > /dev/null",
            cspell_config_file,
            cspell_config_file
        )
    )
end]],
            },
        },
    },
    method = CODE_ACTION,
    filetypes = {},
    generator = {
        fn = function(params)
            local actions = {}
            local config = params:get_config()
            local find_json = config.find_json or find_cspell_config

            -- create_config_file if nil defaults to true
            local create_config_file = config.create_config_file ~= false

            local create_config_file_name = config.create_config_file_name or "cspell.json"
            if not vim.tbl_contains(CSPELL_CONFIG_FILES, create_config_file_name) then
                vim.notify(
                    "Invalid default file name for cspell json file: "
                    .. create_config_file_name
                    .. '. The name "cspell.json" will be used instead',
                    vim.log.levels.WARN
                )
                create_config_file_name = "cspell.json"
            end

            local diagnostics = cspell_diagnostics(params.bufnr, params.row - 1, params.col)
            if vim.tbl_isempty(diagnostics) then
                return nil
            end
            for _, diagnostic in ipairs(diagnostics) do
                for _, suggestion in ipairs(diagnostic.user_data.suggestions) do
                    table.insert(actions, {
                        title = string.format("Use %s", suggestion),
                        action = function()
                            vim.api.nvim_buf_set_text(
                                diagnostic.bufnr,
                                diagnostic.lnum,
                                diagnostic.col,
                                diagnostic.end_lnum,
                                diagnostic.end_col,
                                { suggestion }
                            )
                        end,
                    })
                end

                -- add word to "words" in cspell.json
                table.insert(actions, {
                    title = "Add to cspell json file",
                    action = function()
                        local word = vim.api.nvim_buf_get_text(
                            diagnostic.bufnr,
                            diagnostic.lnum,
                            diagnostic.col,
                            diagnostic.end_lnum,
                            diagnostic.end_col,
                            {}
                        )[1]

                        local cspell_json_file = find_json(params.cwd)
                            or (create_config_file and create_cspell_json(params.cwd, create_config_file_name))
                            or nil

                        if cspell_json_file == nil or cspell_json_file == "" then
                            vim.notify("\nNo cspell json file found in the directory tree.\n", vim.log.levels.WARN)
                            return
                        end

                        local ok, cspell = pcall(vim.json.decode, table.concat(vim.fn.readfile(cspell_json_file), " "))

                        if not ok then
                            vim.notify("\nCannot parse cspell json file as JSON.\n", vim.log.levels.ERROR)
                            return
                        end

                        if not cspell.words then
                            cspell.words = {}
                        end

                        table.insert(cspell.words, word)

                        vim.fn.writefile({ vim.json.encode(cspell) }, cspell_json_file)

                        -- replace word in buffer to trigger cspell to update diagnostics
                        vim.api.nvim_buf_set_text(
                            diagnostic.bufnr,
                            diagnostic.lnum,
                            diagnostic.col,
                            diagnostic.end_lnum,
                            diagnostic.end_col,
                            { word }
                        )

                        local on_success = config.on_success
                        if on_success then
                            on_success(cspell_json_file, params)
                        end
                    end,
                })
            end
            return actions
        end,
    },
})
