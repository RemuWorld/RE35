-- Actual host measurement/rendering and fresh admission, not physical pixels.
local H = require('helpers')
local V, P = require('command_tree.view'), require('command_tree.presentation')
local Text = require('command_tree.view.text_layout')
vim.o.columns, vim.o.lines = 120, 44
V.highlights()

local function wrap(text, width, opts)
  local rows, complete = Text.wrap(text, width, V.width, opts)
  for _, row in ipairs(rows) do H.ok(V.width(row) <= width, 'Every wrapped row fits its actual display-cell budget') end
  return rows, complete
end
local rows, complete = wrap('alpha beta gamma', 10)
H.eq({ 'alpha beta', 'gamma' }, rows, 'Whole words move to the next row')
H.eq(true, complete)
H.eq({ 'hello', 'world' }, wrap('hello world', 8), 'A short word is never split to fill a preceding row')
H.eq({ '한글', '설명을', '읽는다' }, wrap('한글 설명을 읽는다', 8), 'Korean spaced units remain whole when they fit a row')
H.eq({ 'first', '', 'second' }, wrap('first\n\nsecond', 10), 'Explicit paragraph and blank-line boundaries remain intact')
H.eq({ '  first', '  second' }, wrap('  first\n  second', 12), 'Explicit line indentation survives when it fits')
H.eq({ 'abcd', 'efgh', 'i' }, wrap('abcdefghi', 4), 'Only a token wider than a whole row uses emergency wrapping')
H.eq({ 'src/', 'main.cpp' }, wrap('src/main.cpp', 8), 'Long paths prefer available separators without inserting characters')
local accent = 'e' .. vim.fn.nr2char(0x301)
H.eq({ accent, accent }, wrap(accent .. accent, 1), 'A combining mark stays attached to its base during emergency wrapping')
local hangul = vim.fn.nr2char(0x1100) .. vim.fn.nr2char(0x1161)
local hangul_width = V.width(hangul)
H.eq({ hangul, hangul }, wrap(hangul .. hangul, hangul_width), 'Decomposed Hangul remains one visible unit')
for _, cluster in ipairs({ '👩‍💻', '👍🏽', '🇰🇷', '✈️' }) do
  local width = V.width(cluster)
  H.eq({ cluster, cluster }, wrap(cluster .. cluster, width), 'Emoji sequence remains whole during emergency wrapping')
end
rows, complete = wrap('한', 1)
H.eq(false, complete, 'An indivisible wide visible unit cannot be claimed complete in one cell')
H.eq({ '…' }, rows, 'Impossible optional text has a bounded visible replacement')
rows, complete = wrap(string.rep('x', 4096), 1, { max_rows = 3, max_chars = 4096 })
H.eq(3, #rows, 'Emergency generation stops at the row budget')
H.eq(false, complete)
rows, complete = wrap(string.rep(accent, 200), 8, { max_rows = 3, max_chars = 16 })
H.eq(false, complete, 'Character bounds include combining marks')
H.ok(#rows <= 3, 'A mark-heavy value remains bounded')

-- The helper itself is independent of editor globals. Host width is injected.
local host = vim
vim = nil
local detached_rows, detached_complete = Text.wrap('portable command words', 10, function(value) return #value end)
vim = host
H.eq({ 'portable', 'command', 'words' }, detached_rows)
H.eq(true, detached_complete)

local function options(density, width, height, scene)
  return P.options({ window = { layout = 'fixed', width = width, max_width = width,
    max_height = height, details = { max_height = 4 }, icons = false }, presentation = {
      version = 1, selected = 'reading', presets = { reading = { extends = density,
        spacing = { horizontal = 0, vertical = 0 }, information = {
          title = false, help = false, status = false, icons = false, details = true } } } } }, {}, scene or 'tree')
end
local function body(part)
  return vim.api.nvim_buf_get_lines(part.buf, 0, -1, false)
end
local function audit(part)
  local config = vim.api.nvim_win_get_config(part.win)
  for _, value in ipairs(body(part)) do H.ok(V.width(value) <= config.width, 'Actual rendered text fits its float') end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(part.buf, -1, 0, -1, { details = true })) do
    H.ok(mark[2] < #body(part) and mark[3] <= #body(part)[mark[2] + 1]
      and mark[4].end_col <= #body(part)[mark[2] + 1], 'Actual highlight spans use valid rendered byte ranges')
  end
end
for _, density in ipairs({ 'full', 'compact', 'minimal' }) do
  local view, opts = {}, options(density, 18, 12)
  local description = 'Whole words remain easy to read. 한글 설명도 이어진다.'
  local data = { path = '\\', items = { { key = 'a', name = 'Run' } }, selected = 1,
    details = { description = description } }
  V.draw(view, data, opts)
  if density ~= 'minimal' then
    H.ok(view.details, 'Description-only data has a details panel')
    H.eq(Text.wrap(description, 18, V.width), view.details.lines, 'Actual detail prose uses the shared layout')
    H.ok(not table.concat(view.details.lines, '\n'):find('registered', 1, true), 'Description-only data invents no command source')
    H.ok(not table.concat(view.details.lines, '\n'):find('current buffer', 1, true), 'Description-only data invents no target')
    audit(view.details)
  end
  audit(view)
  V.close(view)
end

-- A word can fit by itself but cost more rows than character wrapping. Fresh
-- admission and actual required rendering must agree at that exact boundary.
local view = {}
local data = { path = '\\', input = true, review = true, label = 'Review', selected = 1,
  items = { { key = 'a', name = 'Apply' } }, content = { 'alpha beta gamma delta' } }
local opts = options('full', 10, 6, 'review')
local allowed, _, _, plan = V.presentation_review_status(data, opts)
V.draw(view, data, opts)
H.eq(allowed, view.presentation_review_complete, 'Fresh preflight agrees with actual required word wrapping')
H.eq(true, allowed, 'Complete word-wrapped review fits its declared viewport')
local joined = table.concat(body(view), '\n')
H.ok(joined:find('alpha beta\ngamma\ndelta', 1, true), 'Required prose visibly uses word boundaries')
audit(view)
V.close(view)
opts = options('full', 10, 5, 'review')
H.eq(false, V.presentation_review_status(data, opts), 'A shorter viewport refuses the same incomplete required facts')
V.draw(view, data, opts)
H.eq(false, view.presentation_review_complete, 'Actual short review also refuses truncation')
V.close(view)
opts = options('full', 10, 8, 'review')
data.content = { 'first\n\nsecond' }
V.draw(view, data, opts)
H.eq(true, V.presentation_review_status(data, opts), 'Explicit required line breaks participate in fresh row accounting')
H.eq(true, view.presentation_review_complete)
H.ok(table.concat(body(view), '\n'):find('first\n\nsecond', 1, true), 'Required explicit lines remain separate in the actual view')
V.close(view)

local marked = 'a' .. string.rep(vim.fn.nr2char(0x301), 300)
data.content = { marked }
V.draw(view, data, opts)
H.eq(true, V.presentation_review_status(data, opts), 'A bounded combining sequence is admitted by its actual cell width')
H.eq(true, view.presentation_review_complete)
H.ok(table.concat(body(view), '\n'):find(marked, 1, true), 'Required text is not silently clipped by a second character prefix limit')
V.close(view)

data.content = { 'alpha beta gamma delta' }
opts = options('full', 28, 5, 'review')
for _, size in ipairs({ { 120, true }, { 14, false }, { 120, true } }) do
  vim.o.columns = size[1]
  H.eq(size[2], V.presentation_review_status(data, opts), 'Fresh admission recalculates required words after terminal resize')
  V.draw(view, data, opts)
  H.eq(size[2], view.presentation_review_complete, 'Actual resized view agrees with its fresh required-text measurement')
  audit(view)
end
V.close(view)
data = { path = '\\', items = {}, content = { '  code[first] = second;  // original layout' } }
V.draw(view, data, options('full', 52, 8))
H.ok(table.concat(body(view), '\n'):find(data.content[1], 1, true), 'Non-review preformatted output retains its explicit original line')
V.close(view)
data = { path = '\\', input = true, review = true, label = 'Review', selected = 1,
  items = { { key = 'a', name = 'Apply' } }, content = { 'Before: a', 'After: b' },
  error = 'An important inline error needs several complete words' }
opts = options('full', 10, 7, 'review')
opts.details = { enabled = false }
H.eq(false, V.presentation_review_status(data, opts), 'High-priority wrapped feedback participates in fresh required-fact admission')
V.draw(view, data, opts)
H.eq(false, view.presentation_review_complete, 'Feedback cannot silently push reviewed facts out of the actual view')
V.close(view)

-- Typed hint chords are atomic in both right guide and below-panel fallback.
local Panels = require('command_tree.view.panels')
local hints = Panels.help_rows(V, { hints = { { key = '<C-b>', label = 'Toggle the appearance' } } }, 12)
local hint_lines = {}
for _, chunks in ipairs(hints) do
  local row = ''
  for _, chunk in ipairs(chunks) do row = row .. chunk[1] end
  hint_lines[#hint_lines + 1] = row
end
H.eq({ 'Ctrl+b', 'Toggle the', 'appearance' }, hint_lines, 'A chord stays whole while its description wraps by word')
print('Bounded word layout, Unicode units and required-fact admission passed')
