# Delphi LSP MCP Server

A Model Context Protocol (MCP) server that exposes Language Server Protocol (LSP) capabilities to AI assistants and other MCP clients. Supports both Delphi's DelphiLSP and Free Pascal's pasls.

## Project Information

**Author:** Skybuck Flying  
**Contact:** skybuck2000@hotmail.com  
**Version:** 0.05  

**Repository:** https://github.com/SkybuckFlying/Delphi-LSP-MCP-Server  

**Specifications:**  
- MCP Specification (2025-11-25): https://modelcontextprotocol.io/specification/2025-11-25  
- LSP Specification 3.17: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/

## Overview

This server acts as a bridge between:
- **MCP Clients** (like Claude Desktop, Antigravity, Gemini-CLI) - communicate via JSON-RPC 2.0 over stdio
- **LSP Servers** (DelphiLSP.exe or pasls.exe) - Embarcadero's or Free Pascal's Language Server

It allows AI assistants to perform code intelligence operations on Delphi/Pascal source code, including:
- Go to Definition
- Find References
- Hover Information
- Code Completion
- Workspace Symbol Search

## AI Optimization (NEW)

To maximize the effectiveness of this server with AI agents (such as Gemini-CLI or Claude Engineer), a standardized guidance file is available:

### [DelphiLSP.md](./DelphiLSP.md)
This document provides specific instructions for AI agents to prioritize semantic tools (e.g., `hover` and `goto_definition`) over standard text-based searches.

**Recommended Setup:**
Add the following snippet to a `GEMINI.md` file in the Delphi project root to ensure optimal use of the LSP:

```markdown
# Project Context
Refer to [DelphiLSP.md](./DelphiLSP.md) for instructions on using semantic tools for code analysis. This is essential for accurate type checking and navigation.
```

## Requirements

- Delphi 13 (RAD Studio 13.0 or later)
- DelphiLSP.exe (included with RAD Studio) or pasls.exe (Free Pascal Language Server)
- Windows OS

## Building

1. Open `DelphiLSPMCPServer.dpr` in Delphi IDE
2. Build the project (Project → Build)
3. The executable will be created in the project directory

Or use the command line:
```bash
dcc64 DelphiLSPMCPServer.dpr
```

## Usage

### Command Line Options

```bash
DelphiLSPMCPServer [options]

Options:
  --lsp-path <path>      Path to LSP server executable
                         (default: G:\Tools\PascalLanguageServer\git version 26 january 2026\pasls.exe)
  --workspace <path>     Static workspace root directory or file:// URI (Optional)
  --log-level <level>    Log level: debug, info, warning, error (default: info)
  --help                 Show help message
```

### Dynamic Workspace Configuration (v0.05+)

Starting with version 0.05, the server is **environment-aware**. It can dynamically determine the workspace in two ways:
1. **Initialize Sniffing**: The server intercepts the MCP `initialize` request and looks for `rootUri` or `rootPath`. It will automatically target the folder provided by the AI client.
2. **CWD Defaulting**: If no workspace is provided via command line or protocol, it defaults to its own Current Working Directory.

This makes it ideal for use with AI agents that switch between different projects.

### Configuration Examples

#### Antigravity / Gemini-CLI / Agent Settings
To use the server with a dynamic agent, you can leave out the `--workspace` argument so the agent can provide it:

```json
{
  "mcpServers": {
    "delphi-lsp": {
      "command": "C:\\Tools\\DelphiLSPMCPServer.exe",
      "args": [
        "--log-level", "info",
        "--lsp-path", "G:\\Tools\\PascalLanguageServer\\git version 26 january 2026\\pasls.exe"
      ]
    }
  }
}
```

#### Claude Desktop
Add to your Claude Desktop MCP configuration (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "delphi-lsp": {
      "command": "C:\\Tools\\DelphiLSPMCPServer.exe",
      "args": [
        "--workspace", "C:\\MyDelphiProject",
        "--log-level", "info"
      ]
    }
  }
}
```

## Available Tools

### delphi_goto_definition

Find the definition of a symbol at a specific position.

**Parameters:**
- `uri` (string): File URI (e.g., `file:///C:/path/to/file.pas`)
- `line` (integer): Zero-based line number
- `character` (integer): Zero-based character offset

### delphi_find_references

Find all references to a symbol.

**Parameters:**
- `uri` (string): File URI
- `line` (integer): Zero-based line number
- `character` (integer): Zero-based character offset
- `includeDeclaration` (boolean, optional): Include declaration in results (default: true)

### delphi_hover

Get hover information (documentation, type info) for a symbol.

### delphi_completion

Get code completion suggestions at a specific position.

### delphi_workspace_symbols

Search for symbols across the entire workspace.

**Parameters:**
- `query` (string): Search query string


## Architecture

```
┌─────────────────────┐
│  MCP Client         │
│  (AI Assistant)     │
└──────────┬──────────┘
           │ JSON-RPC over stdio
           ▼
┌─────────────────────┐
│  Delphi LSP MCP     │
│  Server (v0.05)     │
│  ┌───────────────┐  │
│  │ MCP Server    │  │
│  │ Component     │  │
│  └───────┬───────┘  │
│          │          │
│  ┌───────▼───────┐  │
│  │ LSP Client    │  │
│  │ Component     │  │
│  └───────┬───────┘  │
└──────────┼──────────┘
           │ LSP JSON-RPC over stdio
           ▼
┌─────────────────────┐
│  DelphiLSP.exe /    │
│  pasls.exe          │
│  (Language Server)  │
└─────────────────────┘
```

## Unit Structure

| Unit | Responsibility |
|------|---------------|
| `Common.JsonRpc` | JSON-RPC 2.0 message types and parsing |
| `Common.Logging` | Thread-safe singleton logger |
| `Common.Utils` | **(NEW in 0.05)** Centralized Path/URI conversion utilities |
| `MCP.Protocol.Types` | MCP protocol type definitions |
| `MCP.Server` | MCP server core: dynamic workspace discovery, tool routing |
| `MCP.Tools.LSP` | Tool implementations bridging MCP to LSP |
| `MCP.Transport.Stdio` | MCP stdio transport with Content-Length headers |
| `LSP.Client` | LSP client: synchronous requests, document sync |
| `LSP.Protocol.Types` | LSP protocol type definitions |
| `LSP.Transport.Process` | LSP process transport: child process management |

## Version History

- **0.01** (26 January 2026) — Initial release
- **0.02** (2 February 2026) — Protocol compliance improvements
- **0.04** (27 April 2026) — Improved unit separation and architecture
  - Added LSP retry logic and auto-document-open
  - Support for both DelphiLSP and pasls
- **0.05** (27 April 2026) — Dynamic Workspace & Stability
  - **Dynamic Workspace Discovery**: Automatically sniffs `rootUri` from initialize request
  - **Environment Stabilization**: Fixed FPC environment variable inheritance
  - **Refactored Utilities**: Centralized URI/Path handling in `Common.Utils`
  - **Auto-Project Search**: Automatically finds `.dpr` or `.lpr` in workspace root
  - **Delphi Mode**: Forces `-Mdelphi` for better syntax parsing in Free Pascal
  - **AI Guidance**: Added `DelphiLSP.md` for standardized AI agent instructions
  - **Expanded Test Suite**: Updated `SourceForAnalysis.dpr` with interfaces, generics, and inheritance tests

## License

This is a demonstration project. Use at your own risk.

- Automatic LSP server restart on crash  
- Improved timeout handling  
- Retry logic for transient failures  

#### Add Configuration Options
- Project file support  
- Search path configuration  
- Compiler settings  

#### Performance Optimization
- Connection pooling  
- Response caching  
- Async operations  


### For Testing

#### Unit Tests
- JSON‑RPC parsing  
- Protocol type serialization  
- Message transport  

#### Integration Tests
- Real Delphi projects  
- Various file types  
- Edge cases
