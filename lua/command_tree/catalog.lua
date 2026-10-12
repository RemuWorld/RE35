-- Independently written descriptions of Neovim commands; no which-key source.
local M = {}
local groups = {
  g = "Go / actions", z = "View / folds", ["<C-w>"] = "Windows",
  ["'"] = "Marks · line", ["`"] = "Marks · position", ['"'] = "Registers", ["<C-r>"] = "Registers",
}

local normal = {
  g = { g = "First line", e = "Previous word end", E = "Previous WORD end", j = "Display line down",
    k = "Display line up", d = "Local declaration", D = "Global declaration", f = "Open file under cursor",
    F = "Open file at line", i = "Last insert position", v = "Reselect last selection", J = "Join without spaces",
    q = "Format motion", w = "Format and keep position", u = "Lowercase motion", U = "Uppercase motion",
    ["~"] = "Toggle case motion", ["?"] = "ROT13 motion", t = "Next tab", T = "Previous tab",
    [";"] = "Older change", [","] = "Newer change", o = "Go to byte", a = "Character information",
    ["8"] = "UTF-8 bytes", n = "Next search match", N = "Previous search match", ["_"] = "Last nonblank" },
  z = { z = "Center cursor line", t = "Cursor line at top", b = "Cursor line at bottom",
    a = "Toggle fold", A = "Toggle folds recursively", o = "Open fold", O = "Open folds recursively",
    c = "Close fold", C = "Close folds recursively", r = "Reduce fold level", R = "Open all folds",
    m = "Increase folding", M = "Close all folds", f = "Create fold over motion", d = "Delete fold",
    D = "Delete folds recursively", E = "Delete all folds", i = "Toggle folding", x = "Update folds",
    ["="] = "Spelling suggestions", g = "Accept spelling", w = "Mark bad spelling",
    h = "Scroll left", l = "Scroll right", H = "Scroll half screen left", L = "Scroll half screen right" },
  ["<C-w>"] = { h = "Left window", j = "Lower window", k = "Upper window", l = "Right window",
    w = "Next window", W = "Previous window", p = "Previous accessed window", t = "Top-left window",
    b = "Bottom-right window", s = "Split horizontally", v = "Split vertically", n = "New window",
    q = "Quit window", c = "Close window", o = "Only this window", ["="] = "Equalize sizes",
    ["+"] = "Increase height", ["-"] = "Decrease height", [">"] = "Increase width", ["<lt>"] = "Decrease width",
    ["_"] = "Maximize height", ["|"] = "Maximize width", H = "Move window left", J = "Move window bottom",
    K = "Move window top", L = "Move window right", r = "Rotate windows", R = "Rotate backwards",
    x = "Exchange windows", T = "Move to new tab", ["]"] = "Split and jump to tag", f = "Split and open file" },
}

local motions = { w = "Next word", W = "Next WORD", b = "Previous word", B = "Previous WORD",
  e = "Word end", E = "WORD end", h = "Left", j = "Down", k = "Up", l = "Right",
  ["0"] = "Line start", ["^"] = "First nonblank", ["$"] = "Line end", G = "Last line",
  ["{"] = "Previous paragraph", ["}"] = "Next paragraph", ["%"] = "Matching bracket",
  f = "Find character forward", F = "Find character backward", t = "Before character", T = "After character",
  ["/"] = "Search forward", ["?"] = "Search backward", n = "Next match", N = "Previous match" }
local objects = { w = "word", W = "WORD", s = "sentence", p = "paragraph", b = "parentheses",
  B = "braces", ["("] = "parentheses", [")"] = "parentheses", ["["] = "brackets", ["]"] = "brackets",
  ["{"] = "braces", ["}"] = "braces", ["<lt>"] = "angle brackets", [">"] = "angle brackets",
  ['"'] = "double quotes", ["'"] = "single quotes", ["`"] = "backticks", t = "tag" }

function M.populate(add, mode)
  if mode == "n" or mode == "x" or mode == "o" then
    for prefix, items in pairs(normal) do
      local allowed = mode == "x" and prefix == "g" and { q=true, w=true, u=true, U=true, ['~']=true, ['?']=true, J=true }
        or mode == "o" and prefix == "g" and { g=true, e=true, E=true, j=true, k=true, ['_']=true }
      if mode == "n" or allowed or (mode == "x" and prefix == "z") then
        for key, desc in pairs(items) do
          if not allowed or allowed[key] then add(prefix .. key, { name = desc, native = true }) end
        end
      end
    end
    if mode == "o" or mode == "x" then
      for prefix, label in pairs({ i = "Inside", a = "Around" }) do
        add(prefix, { name = label, group = true })
        for key, name in pairs(objects) do add(prefix .. key, { name = label .. " " .. name, native = true }) end
      end
    end
    if mode == "o" then
      for key, desc in pairs(motions) do add(key, { name = desc, native = true }) end
      local op = vim.v.operator
      if op ~= "" then add(op:sub(-1), { name = "Current line", native = true }) end
    end
  end
  for key, name in pairs(groups) do add(key, { name = name, group = true }) end
end

function M.values(add, mode, buf)
  if mode == "n" or mode == "x" or mode == "o" then
    local marks = vim.list_extend(vim.fn.getmarklist(buf), vim.fn.getmarklist())
    for _, mark in ipairs(marks) do
      local key = mark.mark:sub(2)
      if mark.pos[2] > 0 then
        local location = (mark.file and mark.file ~= "" and vim.fn.fnamemodify(mark.file, ":t") .. ":" or "Line ") .. mark.pos[2]
        add("'" .. key, { name = location, native = true })
        add("`" .. key, { name = location .. ":" .. mark.pos[3], native = true })
      end
    end
  end
  local prefix = (mode == "i" or mode == "c") and "<C-r>" or '"'
  if mode == "n" or mode == "x" or mode == "o" or mode == "i" or mode == "c" then
    for key in ('"0123456789abcdefghijklmnopqrstuvwxyz-:.%%#=/+*_'):gmatch(".") do
      local label
      if key == "+" or key == "*" then label = "System clipboard"
      elseif key == "=" then label = "Expression register"
      elseif key == "_" then label = "Black hole"
      else
        local ok, value = pcall(vim.fn.getreg, key)
        label = ok and value:gsub("\n", " ↵ "):gsub("\t", " ") or ""
      end
      if label ~= "" then add(prefix .. key, { name = label, native = true }) end
    end
  end
end

return M
