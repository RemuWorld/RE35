local Lsp = require("command_tree.adapters.lsp")
local M = {}

function M.register(registry, integration)
  for _, entry in ipairs({
    { "d", "definition", "Go to definition", "textDocument/definition", "Definitions" },
    { "D", "declaration", "Go to declaration", "textDocument/declaration", "Declarations" },
    { "t", "type_definition", "Go to type definition", "textDocument/typeDefinition", "Type definitions" },
    { "i", "implementation", "Go to implementation", "textDocument/implementation", "Implementations" },
    { "R", "references", "Find references", "textDocument/references", "References" },
    { "o", "document_symbols", "Document symbols", "textDocument/documentSymbol", nil, Lsp.document_symbols },
    { "h", "hover", "Hover documentation", "textDocument/hover", nil, Lsp.hover },
  }) do
    registry:register({ id = "code." .. entry[2], name = entry[3], provider = "lsp", type = "picker", async = true,
      stable_target = true, available = Lsp.available(entry[4], false, integration),
      run = entry[6] or Lsp.navigation(entry[4], entry[5]), path = { "c", entry[1] },
    })
  end
end

return M
