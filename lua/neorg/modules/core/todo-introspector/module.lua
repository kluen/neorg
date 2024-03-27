local neorg = require("neorg")
local modules = neorg.modules

local module = modules.create("core.todo-introspector")

-- TODO: When searching recursive children also account for generic_list nodes

module.private = {
    namespace = vim.api.nvim_create_namespace("neorg/todo-introspector"),

    --- List of active buffers
    buffers = {},
}

-- NOTE(vhyrro): This module serves as a temporary proof of concept.
-- We will want to add a plethora of customizability options after the base behaviour is implemented.
module.config.public = {}

module.setup = function()
    return {
        success = true,
        requires = { "core.integrations.treesitter" },
    }
end

module.load = function()
    vim.api.nvim_create_autocmd("Filetype", {
        pattern = "norg",
        desc = "Attaches the TODO introspector to any Norg buffer.",
        callback = function(ev)
            local buf = ev.buf

            if module.private.buffers[buf] then
                return
            end

            module.private.buffers[buf] = true
            module.public.attach_introspector(buf)
        end,
    })
end

--- Attaches the introspector to a given Norg buffer.
--- Errors if the target buffer is not a Norg buffer.
---@param buffer number #The buffer ID to attach to.
function module.public.attach_introspector(buffer)
    if not vim.api.nvim_buf_is_valid(buffer) or vim.bo[buffer].filetype ~= "norg" then
        error(string.format("Could not attach to buffer %d, buffer is not a norg file!", buffer))
    end

    vim.api.nvim_buf_attach(buffer, false, {
        on_lines = vim.schedule_wrap(function(_, buf, _, first)
            ---@type TSNode?
            local node = module.required["core.integrations.treesitter"].get_first_node_on_line(buf, first)

            local parent = node

            while parent do
                local child = parent:named_child(1)

                if child and child:type() == "detached_modifier_extension" then
                    module.public.perform_introspection(buffer, parent)
                    -- NOTE: do not break here as we want the introspection to propagate all the way up the syntax tree
                end

                parent = parent:parent()
            end
        end),

        on_detach = function()
            module.private.buffers[buffer] = nil
        end,
    })
end

--- Aggregates TODO item counts from children.
---@param node TSNode
---@return { undone: number, pending: number, done: number, cancelled: number, recurring: number, on_hold: number, urgent: number, uncertain: number }
---@return number total
function module.public.calculate_items(node)
    local counts = {
        undone = 0,
        pending = 0,
        done = 0,
        cancelled = 0,
        recurring = 0,
        on_hold = 0,
        urgent = 0,
        uncertain = 0,
    }

    local total = 0

    -- Go through all the children of the current todo item node and count the amount of "done" children
    for child in node:iter_children() do
        if child:named_child(1) and child:named_child(1):type() == "detached_modifier_extension" then
            for status in child:named_child(1):iter_children() do
                if status:type():match("^todo_item_") then
                    local type = status:type():match("^todo_item_(.+)$")

                    counts[type] = counts[type] + 1

                    if type == "cancelled" then
                        break
                    end

                    total = total + 1
                end
            end
        end
    end

    return counts, total
end

--- Displays the amount of done items in the form of an extmark.
---@param buffer number
---@param node TSNode
function module.public.perform_introspection(buffer, node)
    local counts, total = module.public.calculate_items(node)

    local line, col = node:start()

    local unique_id = assert(tonumber(tostring(buffer) .. tostring(node:symbol()) .. tostring(line)))

    if total == 0 then
        vim.api.nvim_buf_del_extmark(buffer, module.private.namespace, unique_id)
        return
    end

    -- TODO: Make configurable, make colours customizable, don't display [x/total]
    -- as the total also includes things like uncertain tasks.
    vim.api.nvim_buf_set_extmark(buffer, module.private.namespace, line, col, {
        id = unique_id,
        virt_text = { { string.format("[%d/%d]", counts.done, total), "Normal" } },
    })
end

return module
