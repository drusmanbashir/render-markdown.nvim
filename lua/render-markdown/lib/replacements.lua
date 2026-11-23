local compat = require('render-markdown.lib.compat')

local M = {}

---Highlight groups other namespaces paint across the whole of a row, lowest
---priority first. A replaced row is concealed, so its virtual lines must
---carry these or highlights such as a diff or review line background vanish.
---@param buf integer
---@param ns integer
---@param row integer
---@return string[]
local function line_highlights(buf, ns, row)
    if not compat.has_10 then
        return {}
    end
    local extmarks = vim.api.nvim_buf_get_extmarks(
        buf,
        -1,
        { row, 0 },
        { row, -1 },
        { details = true, overlap = true }
    )
    local found = {} ---@type { priority: integer, groups: string[] }[]
    for _, extmark in ipairs(extmarks) do
        local start_row, start_col = extmark[2], extmark[3]
        local details = extmark[4] or {}
        local group = nil ---@type string|string[]|nil
        if details.ns_id ~= ns then
            if details.line_hl_group then
                group = details.line_hl_group
            elseif details.hl_group and details.hl_eol then
                local from = start_row < row or start_col == 0
                local to = (details.end_row or start_row) > row
                if from and to then
                    group = details.hl_group
                end
            end
        end
        if group then
            found[#found + 1] = {
                priority = details.priority or 0,
                groups = type(group) == 'table' and group or { group },
            }
        end
    end
    table.sort(found, function(a, b)
        return a.priority < b.priority
    end)
    local result = {} ---@type string[]
    for _, item in ipairs(found) do
        vim.list_extend(result, item.groups)
    end
    return result
end

---Stack groups over each chunk, last so they win as they do on the real row.
---@param lines render.md.mark.Line[]
---@param groups string[]
---@return render.md.mark.Line[]
local function stack(lines, groups)
    if #groups == 0 then
        return lines
    end
    local result = {} ---@type render.md.mark.Line[]
    for _, line in ipairs(lines) do
        local chunks = {} ---@type render.md.mark.Line
        for _, chunk in ipairs(line) do
            local hl = chunk[2]
            local stacked = {} ---@type string[]
            if type(hl) == 'table' then
                vim.list_extend(stacked, hl)
            elseif hl and hl ~= '' then
                stacked[#stacked + 1] = hl
            end
            vim.list_extend(stacked, groups)
            chunks[#chunks + 1] = { chunk[1], stacked }
        end
        result[#result + 1] = chunks
    end
    return result
end

---Virtual lines on concealed rows are hidden by Neovim.
---Move them above the next visible row while grouping.
---@param buf integer
---@param ns integer
---@param visible render.md.Mark[]
---@param line_count integer
---@return render.md.Mark[]
function M.resolve(buf, ns, visible, line_count)
    local marks = {} ---@type render.md.Mark[]
    for _, mark in ipairs(visible) do
        if mark.replace then
            marks[#marks + 1] = mark
        end
    end
    table.sort(marks, function(a, b)
        return a.start_row < b.start_row
    end)
    if #marks == 0 then
        return {}
    end

    local hidden = {} ---@type table<integer, true>
    for _, mark in ipairs(visible) do
        if mark.opts.conceal_lines then
            local end_row = mark.opts.end_row or mark.start_row
            if end_row > mark.start_row and mark.opts.end_col == 0 then
                end_row = end_row - 1
            end
            for row = mark.start_row, end_row do
                hidden[row] = true
            end
        end
    end

    local groups = {} ---@type render.md.Mark[]
    for _, mark in ipairs(marks) do
        local row = mark.start_row + 1
        while row < line_count and hidden[row] do
            row = row + 1
        end
        local group = groups[#groups]
        if not group or group.start_row ~= row then
            group = {
                conceal = true,
                start_row = row,
                start_col = 0,
                opts = {
                    virt_lines = {},
                    virt_lines_above = true,
                    strict = false,
                },
            }
            groups[#groups + 1] = group
        end
        local highlights = line_highlights(buf, ns, mark.start_row)
        vim.list_extend(group.opts.virt_lines, stack(mark.replace, highlights))
    end
    return groups
end

return M
