local methods = require("null-ls.methods")

local api = vim.api

local is_windows = vim.loop.os_uname().version:match("Windows")
local path_separator = is_windows and "\\" or "/"

local format_line_ending = {
    ["unix"] = "\n",
    ["dos"] = "\r\n",
    ["mac"] = "\r",
}

local M = {}

--- gets buffer content, attempting to minimize the number of API calls
---@param params table
---@param bufnr number
---@return string content
local resolve_content = function(params, bufnr)
    -- some notifications send full buffer content
    if params.method == methods.lsp.DID_OPEN and params.textDocument and params.textDocument.text then
        return M.split_at_newline(bufnr, params.textDocument.text)
    end
    if
        params.method == methods.lsp.DID_CHANGE
        and params.contentChanges
        and params.contentChanges[1]
        and params.contentChanges[1].text
    then
        return M.split_at_newline(bufnr, params.contentChanges[1].text)
    end

    return M.buf.content(bufnr)
end

--- resolves bufnr from params
---@param params table
---@return number bufnr
local resolve_bufnr = function(params)
    -- if already set, return
    if params.bufnr then
        return params.bufnr
    end

    -- get from uri
    if params.textDocument and params.textDocument.uri then
        return vim.uri_to_bufnr(params.textDocument.uri)
    end

    -- fallback
    return api.nvim_get_current_buf()
end

--- gets the line ending for the given buffer based on fileformat
---@param bufnr number?
---@return string line_ending
M.get_line_ending = function(bufnr)
    return format_line_ending[api.nvim_buf_get_option(bufnr or 0, "fileformat")] or "\n"
end

--- joins text using the line ending for the buffer
---@param bufnr number?
---@param text string
---@return string joined_text, string line_ending
M.join_at_newline = function(bufnr, text)
    local line_ending = M.get_line_ending(bufnr)
    return table.concat(text, line_ending), line_ending
end

--- splits text using the line ending for the buffer
---@param bufnr number?
---@param text string
---@return string split_text, string line_ending
M.split_at_newline = function(bufnr, text)
    local line_ending = M.get_line_ending(bufnr)
    return vim.split(text, line_ending), line_ending
end

--- checks if the current neovim version is above the given version number
---@param ver string version number to check
---@return boolean has_version
M.has_version = function(ver)
    return vim.fn.has("nvim-" .. ver) > 0
end

--- checks if a given command is executable
---@param cmd string? command to check
---@return boolean
M.is_executable = function(cmd)
    return cmd and vim.fn.executable(cmd) == 1 or false
end

---@alias NullLsRange table<"'row'"|"'col'"|"'end_row'"|"'end_col'", number>
---@alias LspRange table<"'start'"|"'end'", table<"'line'"|"'character'", number>>
-- lsp-compatible range is 0-indexed
-- lua-friendly range is 1-indexed
M.range = {
    -- transforms lua-friendly range to a lsp-compatible shape
    ---@param range NullLsRange
    ---@return LspRange
    to_lsp = function(range)
        local lsp_range = {
            ["start"] = {
                line = range.row >= 1 and range.row - 1 or 0,
                character = range.col >= 1 and range.col - 1 or 0,
            },
            ["end"] = {
                line = range.end_row >= 1 and range.end_row - 1 or 0,
                character = range.end_col >= 1 and range.end_col - 1 or 0,
            },
        }
        return lsp_range
    end,
    -- transforms lsp range to a lua-friendly shape
    ---@param lsp_range LspRange
    ---@return NullLsRange
    from_lsp = function(lsp_range)
        local start_range = lsp_range["start"]
        local end_range = lsp_range["end"]
        local range = {
            row = start_range.line >= 0 and start_range.line + 1 or 1,
            col = start_range.character >= 0 and start_range.character + 1 or 1,
            end_row = end_range.line >= 0 and end_range.line + 1 or 1,
            end_col = end_range.character >= 0 and end_range.character + 1 or 1,
        }
        return range
    end,
}

---@class NullLsParams
---@field client_id number null-ls client id
---@field lsp_method string|nil
---@field options table|nil table of options from lsp params
---@field content string buffer content
---@field bufnr number
---@field method string internal null-ls method
---@field row number current row number
---@field col number current column number
---@field bufname string
---@field ft string
---@field range NullLsRange|nil converted LSP range
---@field word_to_complete string|nil
---@field command string|nil set by generator_factory
---@field root string|nil set by generator_factory

---@param original_params table original LSP params
---@param method string internal null-ls method
---@return NullLsParams
M.make_params = function(original_params, method)
    local bufnr = resolve_bufnr(original_params)
    local content = resolve_content(original_params, bufnr)
    local pos = api.nvim_win_get_cursor(0)

    local params = {
        client_id = original_params.client_id,
        lsp_method = original_params.method,
        options = original_params.options,
        content = content,
        method = method,
        row = pos[1],
        col = pos[2],
        bufnr = bufnr,
        bufname = api.nvim_buf_get_name(bufnr),
        ft = api.nvim_buf_get_option(bufnr, "filetype"),
    }

    if original_params.range then
        params.range = M.range.from_lsp(original_params.range)
    end

    if params.lsp_method == methods.lsp.COMPLETION then
        local line = params.content[params.row]
        local line_to_cursor = line:sub(1, pos[2])
        local regex = vim.regex("\\k*$")

        params.word_to_complete = line:sub(regex:match_str(line_to_cursor) + 1, params.col)
    end

    return params
end

---@class ConditionalUtils
---@field has_file fun(patterns: ...): boolean checks if file exists
---@field root_has_file fun(patterns: ...): boolean checks if file exists at root level
---@field root_matches fun(pattern: string): boolean checks if root matches pattern

--- creates a table of conditional utils based on the current root directory
---@return ConditionalUtils
M.make_conditional_utils = function()
    local root = M.get_root()

    return {
        has_file = function(...)
            local patterns = vim.tbl_flatten({ ... })
            for _, name in ipairs(patterns) do
                local full_path = vim.loop.fs_realpath(name)
                if full_path and M.path.exists(full_path) then
                    return true
                end
            end
            return false
        end,
        root_has_file = function(...)
            local patterns = vim.tbl_flatten({ ... })
            for _, name in ipairs(patterns) do
                if M.path.exists(M.path.join(root, name)) then
                    return true
                end
            end
            return false
        end,
        root_matches = function(pattern)
            return root:find(pattern) ~= nil
        end,
    }
end

M.buf = {
    --- returns buffer content as string or table
    ---@param bufnr number|nil
    ---@param to_string boolean
    ---@return string|table content
    content = function(bufnr, to_string)
        bufnr = bufnr or api.nvim_get_current_buf()

        local should_add_eol = api.nvim_buf_get_option(bufnr, "eol") and api.nvim_buf_get_option(bufnr, "fixeol")
        local line_ending = M.get_line_ending(bufnr)

        local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
        if should_add_eol then
            table.insert(lines, "")
        end

        return to_string and table.concat(lines, line_ending) or lines
    end,

    --- runs callback for each loaded buffer
    ---@param cb fun(bufnr: number)
    for_each_bufnr = function(cb)
        for _, bufnr in ipairs(api.nvim_list_bufs()) do
            if api.nvim_buf_is_loaded(bufnr) then
                cb(bufnr)
            end
        end
    end,
}

M.table = {
    --- replaces matching table element(s)
    ---@param tbl table
    ---@param original any
    ---@param replacement any
    ---@return table replaced
    replace = function(tbl, original, replacement)
        local replaced = {}
        for _, v in ipairs(tbl) do
            table.insert(replaced, v == original and replacement or v)
        end
        return replaced
    end,
    --- removes duplicate elements from table
    ---@param t table
    ---@return table new_table
    uniq = function(t)
        local new_table = {}
        local hash = {}
        for _, v in pairs(t) do
            if not hash[v] then
                table.insert(new_table, v)
                hash[v] = true
            end
        end

        return new_table
    end,
}

--- if opt is a function, call it with args; otherwise, return a copy of opt
---@param opt any
---@vararg any args
---@return any
M.handle_function_opt = function(opt, ...)
    if type(opt) == "function" then
        return opt(...)
    end

    return vim.deepcopy(opt)
end

--- gets root using best available method
---@return string root
M.get_root = function()
    local root

    -- prefer getting from client
    local client = require("null-ls.client").get_client()
    if client then
        root = client.config.root_dir
    end

    -- if in named buffer, resolve directly from root_dir
    if not root then
        local fname = api.nvim_buf_get_name(0)
        if fname ~= "" then
            root = require("null-ls.config").get().root_dir(fname)
        end
    end

    -- fall back to cwd
    root = root or vim.loop.cwd()

    return root
end

---@class PathUtils
---@field exists fun(filename: string): boolean
---@field join function(paths: ...): string
M.path = {
    exists = function(filename)
        local stat = vim.loop.fs_stat(filename)
        return stat ~= nil
    end,
    join = function(...)
        return table.concat(vim.tbl_flatten({ ... }), path_separator):gsub(path_separator .. "+", path_separator)
    end,
}

--- creates a callback that returns the first root matching a specified pattern
---@vararg string patterns
---@return fun(startpath: string): string|nil root_dir
M.root_pattern = function(...)
    local patterns = vim.tbl_flatten({ ... })

    return function(start_path)
        for path in vim.fs.parents(start_path) do
            -- escape wildcard characters in the path so that it is not treated like a glob
            path = path:gsub("([%[%]%?%*])", "\\%1")
            for _, pattern in ipairs(patterns) do
                ---@diagnostic disable-next-line: param-type-mismatch
                for _, p in ipairs(vim.fn.glob(M.path.join(path, pattern), true, true)) do
                    if M.path.exists(p) then
                        return path
                    end
                end
            end
        end
    end
end

return M
