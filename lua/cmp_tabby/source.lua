local cmp = require('cmp')
local api = vim.api
local fn = vim.fn
local conf = require('cmp_tabby.config')

local function dump(...)
  local objects = vim.tbl_map(vim.inspect, { ... })
  print(unpack(objects))
end

local Source = {
  id = nil,
  job = nil,
}
local last_instance = nil

function Source.new()
  last_instance = setmetatable({}, { __index = Source })
  return last_instance
end

function Source.is_available(self)
  return true
end

function Source.get_debug_name()
  return 'tabby'
end

function Source._do_complete(self, ctx, callback)
  local max_lines = conf:get('max_lines')

  local cursor = ctx.context.cursor
  local cursor_line_idx = cursor.line

  local cur_line = ctx.context.cursor_line
  local cur_line_prev = string.sub(cur_line, 1, cursor.col - 1)
  local cur_line_post = string.sub(cur_line, cursor.col, -1)

  local prev_line_idx = math.max(cursor.line - max_lines / 2, 0)
  local post_line_idx = cursor.line + max_lines / 2
  local prev_lines = api.nvim_buf_get_lines(0, prev_line_idx, cursor_line_idx, false)
  local post_lines = api.nvim_buf_get_lines(0, cursor_line_idx + 1, post_line_idx + 1, false)

  local prev_text = table.concat(prev_lines, '\n') .. '\n' .. cur_line_prev
  local post_text = cur_line_post .. '\n' .. table.concat(post_lines, '\n')

  local req = {
    -- prompt = prev_text,
    language = vim.bo.filetype,
    segments = {
      prefix = prev_text,
      suffix = post_text,
    },
  }
  -- local res = curl.post(conf:get('host') .. '/v1/engines/codegen/completions', {
  --   body = vim.fn.json_encode(req),
  --   headers = {
  --     content_type = 'application/json',
  --   },
  -- })

  -- dump(req)

  self.job = fn.jobstart({
    'curl',
    '-s',
    '-H',
    'Content-type: application/json',
    '-H',
    'Accept: application/json',
    '-X',
    'POST',
    '-d',
    vim.json.encode(req),
    conf:get('host') .. '/v1/completions',
  }, {
    on_stdout = function(_, c, _)
      local items = {}
      for _, res in ipairs(c) do
        if res ~= nil and res ~= '' and res ~= 'null' then
          local data = (vim.json.decode(res) or {})
          for _, result in ipairs(data.choices) do
            local newText = result.text:gsub('<|endoftext|>', '')

            if newText:find('.*\n.*') then
              -- this is a multi line completion.
              -- remove leading newlines
              newText = newText:gsub('^\n', '')
            end

            local range = {
              start = { line = cursor.line, character = cursor.col },
              ['end'] = { line = cursor.line, character = cursor.col },
            }

            local item = {
              label = newText,
              -- removing filterText, as it interacts badly with multiline
              -- filterText = newText,
              data = {
                id = data.id,
                choice = result.index,
              },
              textEdit = {
                newText = newText,
                insert = range, -- May be better to exclude the trailing part of old_suffix since it's 'replaced'?
                replace = range,
              },
              sortText = newText,
              dup = 0,
              cmp = {
                kind_text = 'tabby',
              },
              documentation = {
                kind = cmp.lsp.MarkupKind.Markdown,
                value = '```' .. (vim.filetype.match({ buf = 0 }) or '') .. '\n' .. cur_line_prev .. newText .. '\n```',
              },
            }
            if result.text:find('.*\n.*') then
              item['data']['multiline'] = true
            end
            table.insert(items, item)
          end
        end
      end
      if next(items) ~= nil then
        if self.id == ctx.context.id then
          callback({
            items = items,
            isIncomplete = conf:get('run_on_every_keystroke'),
          })
        end
      end
    end,
  })
end

--- execute
function Source.execute(self, item, callback)
  -- dump(item)
  local req = {
    type = 'select',
    completion_id = item.data.id,
    choice_index = item.data.choice,
  }
  -- dump(vim.json.encode(req))
  fn.jobstart({
    'curl',
    '-s',
    '-H',
    'Content-type: application/json',
    '-H',
    'Accept: application/json',
    '-X',
    'POST',
    '-d',
    vim.json.encode(req),
    conf:get('host') .. '/v1/events',
  }, {
    on_stdout = function(_, c, _)
      -- dump(c)
    end,
  })
  callback(item)
end

--- complete
function Source.complete(self, ctx, callback)
  self.id = ctx.context.id
  if self.job ~= nil then
    fn.jobstop(self.job)
    self.job = nil
  end
  self:_do_complete(ctx, callback)
end

return Source
