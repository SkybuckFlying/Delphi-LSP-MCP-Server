# Delphi LSP MCP Server

A Model Context Protocol (MCP) server that exposes Language Server Protocol (LSP) capabilities to AI assistants and other MCP clients. Supports both Delphi's DelphiLSP and Free Pascal's pasls.

## Project Information

**Author:** Skybuck Flying  
**Contact:** skybuck2000@hotmail.com  
**Version:** 0.04  

**Repository:** https://github.com/SkybuckFlying/Delphi-LSP-MCP-Server  

**Specifications:**  
- MCP Specification (2025-11-25): https://modelcontextprotocol.io/specification/2025-11-25  
- LSP Specification 3.17: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/


## Overview

This server acts as a bridge between:
- **MCP Clients** (like Claude Desktop, AI assistants) - communicate via JSON-RPC 2.0 over stdio
- **LSP Servers** (DelphiLSP.exe or pasls.exe) - Embarcadero's or Free Pascal's Language Server

It allows AI assistants to perform code intelligence operations on Delphi/Pascal source code, including:
- Go to Definition
- Find References
- Hover Information
- Code Completion
- Workspace Symbol Search

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
msbuild DelphiLSPMCPServer.dpr /p:Config=Release
```

## Usage

### Command Line Options

```bash
DelphiLSPMCPServer [options]

Options:
  --lsp-path <path>      Path to LSP server executable
                         (default: G:\Tools\PascalLanguageServer\git version 26 january 2026\pasls.exe)
  --workspace <path>     Workspace root directory or file:// URI (default: current directory)
  --log-level <level>    Log level: debug, info, warning, error (default: info)
  --help                 Show help message
```

### Running Standalone

```bash
DelphiLSPMCPServer --workspace "C:\MyDelphiProject" --log-level debug
```

The server will:
1. Start the LSP server (DelphiLSP.exe or pasls.exe) as a child process
2. Initialize the LSP connection
3. Listen for MCP requests on stdin
4. Send MCP responses to stdout
5. Write logs to stderr

### Integration with Claude Desktop

Add to your Claude Desktop MCP configuration (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "delphi-lsp": {
      "command": "K:\\Delphi\\Tests\\test Skybuck's LSP MCP server\\version 0.04\\DelphiLSPMCPServer.exe",
      "args": [
        "--workspace",
        "C:\\MyDelphiProject",
        "--log-level",
        "info",
        "--lsp-path",
        "C:\\Tools\\RAD Studio\\37.0\\bin64\\DelphiLSP.exe"
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
- `line` (integer): Zero-based line number (NOTE: Delphi IDE displays line numbers starting at 1, so subtract 1 from the IDE line number)
- `character` (integer): Zero-based character offset

**Example:**
```json
{
  "uri": "file:///C:/MyProject/Unit1.pas",
  "line": 10,
  "character": 15
}
```

### delphi_find_references

Find all references to a symbol.

**Parameters:**
- `uri` (string): File URI
- `line` (integer): Zero-based line number (0-based)
- `character` (integer): Zero-based character offset
- `includeDeclaration` (boolean, optional): Include declaration in results (default: true)

### delphi_hover

Get hover information (documentation, type info) for a symbol.

**Parameters:**
- `uri` (string): File URI
- `line` (integer): Zero-based line number (0-based)
- `character` (integer): Zero-based character offset

### delphi_completion

Get code completion suggestions at a specific position.

**Parameters:**
- `uri` (string): File URI
- `line` (integer): Zero-based line number (0-based)
- `character` (integer): Zero-based character offset

### delphi_workspace_symbols

Search for symbols across the entire workspace.

**Parameters:**
- `query` (string): Search query string

**Example:**
```json
{
  "query": "TForm"
}
```

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
│  Server             │
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

The project is organized into well-separated units with clear responsibilities:

| Unit | Responsibility |
|------|---------------|
| `Common.JsonRpc` | JSON-RPC 2.0 message types (Request, Response, Notification, Error), parsing, and helper functions |
| `Common.Logging` | Thread-safe singleton logger writing to stderr with monotonic timestamps |
| `MCP.Protocol.Types` | MCP protocol type definitions (capabilities, tools, content items, initialize params/result) |
| `MCP.Server` | MCP server core: message dispatch, initialize handshake, tool routing |
| `MCP.Tools.LSP` | Tool implementations bridging MCP tool calls to LSP requests, with retry logic |
| `MCP.Transport.Stdio` | MCP stdio transport: reading/writing JSON-RPC messages over stdin/stdout with Content-Length headers |
| `LSP.Client` | LSP client: synchronous request/response, pending request tracking, document sync |
| `LSP.Protocol.Types` | LSP protocol type definitions (Position, Range, Location, Hover, Completion, etc.) |
| `LSP.Transport.Process` | LSP process transport: child process management, pipe I/O, process monitoring |

## Protocol Details

### MCP Protocol

- Version: 2025-11-25
- Transport: stdio with Content-Length headers
- Message Format: JSON-RPC 2.0

### LSP Protocol

- Version: 3.17
- Transport: stdio with Content-Length headers
- Message Format: JSON-RPC 2.0

## Logging

Logs are written to stderr with the following format:
```
[elapsed_seconds] [LEVEL] Message
```

Log levels:
- **DEBUG**: Detailed protocol messages
- **INFO**: General information (default)
- **WARNING**: Warning messages
- **ERROR**: Error messages

## Troubleshooting

### LSP server not found

Ensure the path to the LSP server executable is correct. Use `--lsp-path` to specify the location:
```bash
DelphiLSPMCPServer --lsp-path "C:\Program Files\Embarcadero\Studio\37.0\bin64\DelphiLSP.exe"
```

### LSP initialization fails

Check stderr logs for details. Common issues:
- Invalid workspace path
- LSP server crashes on startup
- Insufficient permissions

### No results from tools

Ensure:
1. The workspace path is correct
2. The file URI uses the correct format (`file:///C:/path/to/file.pas`)
3. Line and character positions are zero-based
4. The file is part of a valid Delphi project
5. The LSP server may still be indexing — the tool retry logic will attempt up to 3 retries automatically

## License

This is a demonstration project. Use at your own risk.

## Version History

- **0.01** (26 January 2026) — Initial release
- **0.02** (2 February 2026) — Protocol compliance improvements
- **0.03** (2 February 2026) — Skipped
- **0.04** (27 April 2026) — Improved unit separation and architecture
  - Thread safety improvements: atomic flags via `TInterlocked` for running/initialized state
  - Added LSP retry logic with configurable delays (100ms, 300ms, 600ms)
  - Auto document open: tools automatically call `textDocument/didOpen` before LSP requests
  - Robust file URI handling: proper encoding, UNC path support, `file://localhost/` support
  - Monotonic timestamps in logger (elapsed seconds since start)
  - Process monitor thread for detecting unexpected LSP server exits
  - Added `resources/list` and `prompts/list` handlers (returning empty arrays)
  - Proper LSP `Content-Length` + `Content-Type` header parsing
  - Support for both DelphiLSP and pasls (Free Pascal Language Server)

## Future Direction

### For Production Use

#### Add More LSP Features
- Document symbols  
- Code actions  
- Formatting  
- Rename  

#### Enhance Error Handling
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
