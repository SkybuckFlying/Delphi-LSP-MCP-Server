# Delphi LSP: Expert Guidance

This project is equipped with a Delphi Language Server Protocol (LSP) integration. When working within this workspace, prioritize semantic analysis over text-based searching.

## Tool Hierarchy
1.  **Semantic Discovery:** Use `mcp_delphi-lsp_delphi_workspace_symbols` to locate declarations across the project.
2.  **Navigation:** Use `mcp_delphi-lsp_delphi_goto_definition` to jump to implementations.
3.  **Impact Analysis:** Use `mcp_delphi-lsp_delphi_find_references` before refactoring to identify all call sites.
4.  **Type Inspection:** Use `mcp_delphi-lsp_delphi_hover` to understand method signatures, variable types, and documentation.
5.  **Fallback:** Only use `grep_search` if the LSP is indexing or if searching for non-code text (e.g., strings in `.dfm` or `.rc` files).

## Workflow Best Practices

### 1. The "Surgical" Edit
Before modifying any procedure or function:
*   Call `delphi_hover` on the symbol to confirm the exact signature and parameter types.
*   Call `delphi_find_references` to ensure you understand the dependencies and side effects of your change.

### 2. Handling Indexing Delays
The Delphi LSP indexes the codebase in the background. 
*   If a tool returns "No definition found" or "No symbols found," wait 2-3 seconds and retry once.
*   If it still fails, the symbol might be in a unit not yet in the search path; use `workspace_symbols` with a partial query to locate it.

### 3. Precision Positioning
The LSP is character-sensitive. When using `goto_definition` or `hover`:
*   Ensure the `character` offset is within the bounds of the symbol name.
*   If the exact offset is unknown, use `read_file` on the target line first to verify the column position of the token.

### 4. Unit Dependencies
When adding new functionality:
*   Use `delphi_completion` at the top of the file to see available units for the `uses` clause.
*   Check existing `uses` clauses to ensure you are not introducing circular dependencies.

## Error Recovery
*   **"No completion suggestions":** Often occurs inside a broken code block. Fix syntax errors before requesting completion.
*   **"File not found":** Ensure the `uri` passed to the tool follows the `file:///` scheme and is correctly URL-encoded (especially for spaces).
