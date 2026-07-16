program DelphiLSPMCPServer;

{$APPTYPE CONSOLE}

{$R *.res}

{
  ============================================================================
  Delphi LSP MCP Server - Model Context Protocol Server for Delphi/Pascal LSP
  ============================================================================

  This server implements the Model Context Protocol (MCP) for Delphi/Pascal
  Language Server Protocol (LSP) integration. It allows AI assistants to
  query Delphi code for definitions, references, hover info, completions,
  and workspace symbols.

  ============================================================================
  BASIC USAGE
  ============================================================================
  DelphiLSPMCPServer.exe --workspace "<path-to-your-project>"

  ============================================================================
  FULL DEBUG MODE (Development/Testing)
  ============================================================================
  DelphiLSPMCPServer.exe --debug --log-level debug --workspace "."

  ============================================================================
  COMMAND LINE OPTIONS
  ============================================================================
  --lsp-path <path>   Path to LSP server executable
                      Default (32-bit): G:\Tools\PascalLanguageServer\git version 26 january 2026\pasls.exe
                      Default (64-bit): G:\Tools\PascalLanguageServer\git version 26 january 2026\pasls_x64.exe

  --workspace <path>  Workspace root directory or file:// URI
                      Default: Current directory

  --log-level <level> Log level: debug, info, warning, error
                      Default: info

  --debug             Enable debug mode for all components
                      (Sets log-level to debug and enables component-level debugging)

  --wait              Wait for debugger attachment BEFORE any initialization
                      Use this to debug server startup code (program block,
                      constructor, initialization, etc.)

  --help              Show this help message

  ============================================================================
  EXAMPLES
  ============================================================================

  1. Basic server with default workspace (current directory):
     DelphiLSPMCPServer.exe

  2. Server with specific workspace:
     DelphiLSPMCPServer.exe --workspace "C:\MyDelphiProject"

  3. Full debug mode for testing (recommended for development):
     DelphiLSPMCPServer.exe --debug --workspace "."

  4. Full debug mode with early wait (to debug constructor):
     DelphiLSPMCPServer.exe --debug --workspace "." --wait

  5. Server with custom LSP path:
     DelphiLSPMCPServer.exe --debug --lsp-path "C:\pasls.exe" --workspace "."

  6. Production mode (minimal logging):
     DelphiLSPMCPServer.exe --log-level error --workspace "C:\MyProject"

  ============================================================================
  DEBUGGING WITH TWO DELPHI IDEs (RECOMMENDED METHOD)
  ============================================================================

  This is the MOST POWERFUL way to debug the server. You can debug BOTH
  the test program AND the server simultaneously, each in its own IDE
  with its own debugger.

  WHY TWO IDEs?
  -------------
  - Each Delphi IDE can only debug ONE process at a time
  - Test program needs debugging? Run it from IDE 1
  - Server needs debugging? Attach IDE 2 to the server process
  - Two IDEs = two debuggers = both processes debuggable simultaneously

  ============================================================================
  STEP-BY-STEP INSTRUCTIONS
  ============================================================================

  ┌─────────────────────────────────────────────────────────────────────────┐
  │ IDE 1: TEST PROGRAM (TestAllTools.dpr)                                 │
  ├─────────────────────────────────────────────────────────────────────────┤
  │                                                                         │
  │ 1. Open TestAllTools.dpr in Delphi IDE (Instance #1)                    │
  │                                                                         │
  │ 2. Set breakpoints in test code if needed (optional)                    │
  │                                                                         │
  │ 3. Go to Run -> Parameters                                              │
  │    Enter: --wait                                                        │
  │                                                                         │
  │ 4. Press F9 to run the test program                                     │
  │                                                                         │
  │ 5. The test program will:                                               │
  │    - Launch DelphiLSPMCPServer.exe with --wait flag                     │
  │    - Display: "Server started successfully! PID: 12345"                 │
  │    - Display debugging instructions                                     │
  │    - WAIT for server's ready event                                      │
  │                                                                         │
  └─────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────┐
  │ IDE 2: MCP LSP SERVER (DelphiLSPMCPServer.dpr)                         │
  ├─────────────────────────────────────────────────────────────────────────┤
  │                                                                         │
  │ 1. Open DelphiLSPMCPServer.dpr in a SEPARATE Delphi IDE (Instance #2)   │
  │                                                                         │
  │ 2. Go to Run -> Parameters                                              │
  │                                                                         │
  │    For standard debugging (debug from Server.Run onward):               │
  │    Enter: --debug --workspace "."                                       │
  │                                                                         │
  │    For FULL debugging (debug ENTIRE server including constructor):      │
  │    Enter: --debug --workspace "." --wait                                │
  │                                                                         │
  │ 3. Set breakpoints in server code (see BREAKPOINT LOCATIONS below)      │
  │                                                                         │
  │ 4. Go to Run -> Attach to Process                                       │
  │                                                                         │
  │ 5. Find the process with the PID shown in IDE 1 (12345 in this example) │
  │    - Look for DelphiLSPMCPServer.exe                                    │
  │                                                                         │
  │ 6. Click "Attach"                                                       │
  │                                                                         │
  │ 7. Debugger will break immediately (thread instruction)                 │
  │    This is NORMAL - process was waiting                                 │
  │                                                                         │
  │ 8. Press F9 to let the server continue                                  │
  │                                                                         │
  └─────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────┐
  │ BACK TO IDE 1: TEST PROGRAM                                             │
  ├─────────────────────────────────────────────────────────────────────────┤
  │                                                                         │
  │ 1. The test program automatically detects server's ready event          │
  │                                                                         │
  │ 2. Tests begin automatically - NO manual Enter press needed!            │
  │                                                                         │
  │ 3. When the test calls the server, breakpoints in IDE 2 will hit!       │
  │                                                                         │
  └─────────────────────────────────────────────────────────────────────────┘

  ============================================================================
  SYNCHRONIZATION MECHANISM
  ============================================================================

  The server uses a named Windows Event for synchronization:
  - Event Name: 'Global\DelphiLSPMCPServer_Ready'
  - Server creates event at startup (non-signaled)
  - Server signals event when fully initialized and ready
  - Test program waits for this event before sending messages

  This ensures:
  - No race conditions
  - No manual console input required
  - Perfect synchronization between processes

  ============================================================================
  THE --wait FLAG EXPLAINED
  ============================================================================

  Without --wait: Server starts, initializes, then waits for messages.
                  You can only debug from Server.Run onward.
                  (Constructor and initialization already executed)

  With --wait:    Server displays PID and waits BEFORE any code executes.
                  You can set breakpoints ANYWHERE including:
                  - The very first line of the program
                  - TMCPServer.Create constructor
                  - InitializeLSP function
                  - Any initialization code

                  After attaching debugger and pressing F9, the server
                  continues and will signal the ready event when fully
                  initialized, allowing the test program to proceed.

  Example with --wait:
    DelphiLSPMCPServer.exe --debug --workspace "." --wait

  ============================================================================
  ALTERNATIVE: Single IDE (Server Only Debugging)
  ============================================================================

  If you only need to debug the server (not the test program):

  1. Open DelphiLSPMCPServer.dpr in Delphi IDE
  2. Go to Run -> Parameters
  3. Enter: --debug --workspace "." --wait
  4. Press F9 to run
  5. The server will show PID and wait
  6. Set breakpoints in server code
  7. Press F9 to continue
  8. Run TestAllTools.exe from command line
  9. Breakpoints will hit when tests connect

  Note: In this method, the test program runs freely without a debugger.
        Only the server is under debugger control.

  ============================================================================
  BITNESS CONSIDERATIONS
  ============================================================================

  The server auto-detects its bitness and attempts to use matching LSP:
  - 32-bit server → uses DEFAULT_LSP_PATH_32 (32-bit pasls.exe)
  - 64-bit server → uses DEFAULT_LSP_PATH_64 (64-bit pasls_x64.exe)

  If matching bitness LSP is not found, it falls back to 32-bit with a warning.

  For best results, ensure:
  - LSP server bitness matches the compiled server bitness
  - FPC bitness matches the LSP server (32-bit FPC for 32-bit LSP, etc.)

  ============================================================================
  ENVIRONMENT VARIABLES (for pasls)
  ============================================================================

  The server automatically sets these environment variables:
  - PP         : Path to fpc.exe (auto-detected based on bitness)
  - FPCDIR     : C:\Tools\FPC\3.2.2
  - FPCTARGET  : win32
  - FPCTARGETCPU: i386 or x86_64 (auto-detected)

  ============================================================================
  TROUBLESHOOTING
  ============================================================================

  "Server exits immediately"
  - Check that LSP executable exists at the specified path
  - Verify workspace path exists and is accessible
  - Run with --debug to see detailed error messages

  "LSP operations fail or timeout"
  - Ensure workspace contains Delphi source files (.pas, .dpr, .lpr)
  - Check that FPC environment variables are correctly set
  - Verify LSP server is compatible with your Delphi/FPC version

  "Can't find the PID in Attach to Process list"
  - Make sure the test program has started (IDE 1 should show the PID)
  - Refresh the process list in the Attach dialog
  - Look for DelphiLSPMCPServer.exe, NOT TestAllTools.exe

  "Breakpoints don't hit in server"
  - Ensure debug info is enabled in server project options
  - Verify you attached to the correct process (check PID)
  - Make sure you pressed F9 after attaching to continue execution
  - Check that the test is actually sending requests (look for console output)

  "Test program hangs waiting for server"
  - Check that server created the ready event
  - Look for "Ready event created successfully" in server console
  - Verify event name matches: Global\DelphiLSPMCPServer_Ready

  ============================================================================
  LOG OUTPUT FORMAT
  ============================================================================

  Logs are written to stderr with this format:
  [timestamp][thread_id][LEVEL] message

  Example:
  [ 0.000][1518][INFO] MCP Server created successfully
  [ 0.000][5BF8][DEBUG] ReadLoop started

  The server uses UTF-8 encoding WITHOUT BOM for proper console output.

  ============================================================================
  PROTOCOL
  ============================================================================

  The server communicates via JSON-RPC 2.0 over stdin/stdout.

  Supported MCP methods:
  - initialize           : Server handshake and capability negotiation
  - tools/list           : List available LSP tools
  - tools/call           : Execute an LSP tool (goto definition, references, etc.)
  - resources/list       : List available resources (currently empty)
  - prompts/list         : List available prompts (currently empty)
  - shutdown             : Graceful shutdown request

  LSP Tools Available:
  - delphi_goto_definition
  - delphi_find_references
  - delphi_hover
  - delphi_completion
  - delphi_workspace_symbols
}

{
  ============================================================================
  MCP LSP Server - Breakpoint Opportunities for Debugging
  ============================================================================

  PRIMARY BREAKPOINTS (Most Important)
  ------------------------------------

  1. Entry Point - HandleMessage (MCP.Server.pas)
     -------------------------------------------------
     procedure TMCPServer.HandleMessage(const AMessage: string);
     begin
       // BREAKPOINT HERE - Catches ALL incoming JSON-RPC messages
       // Use this to see what messages arrive from the client
       if AMessage = '' then
       begin
         HandleStdinClosed;
         Exit;
       end;
       ...
     end;
     Purpose: First point of contact for all client communication


  2. Request Handler - HandleRequest (MCP.Server.pas)
     -------------------------------------------------
     procedure TMCPServer.HandleRequest(ARequest: TJsonRpcRequest);
     begin
       // BREAKPOINT HERE - Catches specific method calls
       // Check ARequest.Method to see which method is being called
       Method := ARequest.Method;
       FLogContext.Enter('HandleRequest.' + Method);
       ...
     end;
     Purpose: Route requests to specific handlers (initialize, tools/list, tools/call)


  3. Tool Call Handler - HandleToolsCall (MCP.Server.pas)
     ----------------------------------------------------
     procedure TMCPServer.HandleToolsCall(ARequest: TJsonRpcRequest);
     begin
       // BREAKPOINT HERE - Catches tools/call method
       // Check Params.Name to see which tool is being executed
       FLogContext.Enter('HandleToolsCall');
       ...
     end;
     Purpose: Handle tool execution requests from client


  4. Tool Execution - ExecuteGotoDefinition (MCP.Tools.LSP.pas)
     ----------------------------------------------------------
     function TMCPLSPTools.ExecuteGotoDefinition(AArguments: TJSONObject): TMCPToolCallResult;
     begin
       // BREAKPOINT HERE - Actual tool implementation for goto definition
       // Check Uri, Line, Character parameters
       Result := TMCPToolCallResult.Create;
       Result.IsError := False;
       StartTime := GetTickCount64;
       ...
     end;
     Purpose: Debug specific LSP tool functionality


  5. LSP Client Request - SendRequestSync (LSP.Client.pas)
     ------------------------------------------------------
     function TLSPClient.SendRequestSync(const AMethod: string; AParams: TJSONValue; ATimeout: Cardinal): TJsonRpcResponse;
     begin
       // BREAKPOINT HERE - LSP communication to external LSP server
       // Check AMethod to see which LSP method is being called
       Result := nil;
       StartTime := GetTickCount64;
       RequestIdNum := GetNextRequestId;
       ...
     end;
     Purpose: Debug communication with the underlying LSP server (pasls.exe)


  SECONDARY BREAKPOINTS (For Specific Issues)
  -------------------------------------------

  6. Initialize Handler - HandleInitialize (MCP.Server.pas)
     ------------------------------------------------------
     procedure TMCPServer.HandleInitialize(ARequest: TJsonRpcRequest);
     begin
       // BREAKPOINT HERE - Server handshake
       // Use this to debug startup and capability negotiation
       FLogContext.Enter('HandleInitialize');
       ...
     end;
     Purpose: Debug server initialization and MCP protocol handshake


  7. LSP Definition Request - GetDefinition (LSP.Client.pas)
     -------------------------------------------------------
     function TLSPClient.GetDefinition(const AUri: string; ALine, ACharacter: Integer; out ALocations: TArray<TLSPLocation>): Boolean;
     begin
       // BREAKPOINT HERE - Specific LSP textDocument/definition request
       // Use this to debug goto definition feature
       Result := False;
       SetLength(ALocations, 0);
       StartTime := GetTickCount64;
       ...
     end;
     Purpose: Debug LSP definition requests to the language server

  ============================================================================
  QUICK DEBUGGING SETUP FOR TEST HANG ISSUES
  ============================================================================

  Set breakpoints at locations 1, 2, 3, 4, 5, and 7 above.

  Expected hit order when tests run:
  -------------------------------------------------
  Breakpoint 1: HandleMessage - receives JSON-RPC message
  Breakpoint 2: HandleRequest - identifies method = "tools/call"
  Breakpoint 3: HandleToolsCall - extracts tool name
  Breakpoint 4: ExecuteGotoDefinition - executes the tool
  Breakpoint 7: GetDefinition - calls LSP server
  Breakpoint 5: SendRequestSync - sends LSP request

  DIAGNOSIS:
  ---------
  - If no breakpoint hits: Issue before message parsing (pipe/connection problem)
  - If breakpoint 1 hits but not 2: JSON parsing error
  - If breakpoint 2 hits but not 3: Unknown method routing
  - If breakpoint 3 hits but not 4: Tool name not recognized
  - If breakpoint 4 hits but not 7: Document open or LSP initialization issue
  - If breakpoint 7 hits but not 5: LSP client communication issue
  - If breakpoint 5 hits but no response: LSP server not responding or timeout

  ============================================================================
  HOW TO SET BREAKPOINTS IN DELPHI
  ============================================================================
  1. Open the unit file in Delphi IDE
  2. Navigate to the line indicated above
  3. Click in the left gutter (margin) next to the line number
  4. Or place cursor on the line and press F5
  5. A red dot appears indicating an active breakpoint

  To conditionally break (Delphi 2010+):
  - Right-click the breakpoint red dot
  - Select "Breakpoint Properties"
  - Add condition like: ARequest.Method = 'tools/call'
}

uses
  System.SysUtils,
  System.NetEncoding,
  System.IOUtils,
  System.Classes,
  System.SyncObjs,
  System.DateUtils,
  System.StrUtils,
  Winapi.Windows,
  Common.JsonRpc in 'Common.JsonRpc.pas',
  Common.Logging in 'Common.Logging.pas',
  MCP.Protocol.Types in 'MCP.Protocol.Types.pas',
  LSP.Protocol.Types in 'LSP.Protocol.Types.pas',
  MCP.Transport.Stdio in 'MCP.Transport.Stdio.pas',
  LSP.Transport.Process in 'LSP.Transport.Process.pas',
  LSP.Client in 'LSP.Client.pas',
  MCP.Tools.LSP in 'MCP.Tools.LSP.pas',
  Common.Utils in 'Common.Utils.pas',
  MCP.Server in 'MCP.Server.pas';

const
  // Base paths for different configurations
  FPC_BASE_PATH = 'C:\Tools\FPC\3.2.2';

  // pasls for free pascal compiler and lazarus:
  DEFAULT_LSP_PATH_32 = 'G:\Tools\PascalLanguageServer\git version 26 january 2026\pasls.exe';
  DEFAULT_LSP_PATH_64 = 'G:\Tools\PascalLanguageServer\git version 26 january 2026\pasls_x64.exe';

  // delphilsp for Delphi 13:
  // DEFAULT_LSP_PATH_32 = 'C:\Tools\RAD Studio\37.0\bin\DelphiLSP.exe';
  // DEFAULT_LSP_PATH_64 = 'C:\Tools\RAD Studio\37.0\bin64\DelphiLSP.exe';

  DEFAULT_WORKSPACE = '';
  VERSION = '0.1.0';

  // Named event for synchronization with test program
  SERVER_READY_EVENT_NAME = 'Global\DelphiLSPMCPServer_Ready';

var
  Server: TMCPServer;
  LSPPath: string;
  WorkspaceRoot: string;
  LogLevel: string;
  GlobalShutdownRequested: Boolean = False;
  GlobalShutdownEvent: TEvent;
  StartTime: TDateTime;
  LogContext: ILogContext;
  Is64BitProcess: Boolean;
  WaitForDebugger: Boolean = False;
  ReadyEvent: THandle;

procedure ShowUsage;
begin
  WriteLn(ErrOutput, 'LSP MCP Server v', VERSION);
  WriteLn(ErrOutput, '');
  WriteLn(ErrOutput, 'Usage: DelphiLSPMCPServer [options]');
  WriteLn(ErrOutput, '');
  WriteLn(ErrOutput, 'Options:');
  WriteLn(ErrOutput, ' --lsp-path <path>   Path to LSP server executable (default: auto-detect based on bitness)');
  WriteLn(ErrOutput, ' --workspace <path>  Workspace root directory or file:// URI (default: current directory)');
  WriteLn(ErrOutput, ' --log-level <level> Log level: debug, info, warning, error (default: info)');
  WriteLn(ErrOutput, ' --debug             Enable debug mode for all components');
  WriteLn(ErrOutput, ' --wait              Wait for debugger attachment BEFORE any code executes');
  WriteLn(ErrOutput, ' --help              Show this help message');
  WriteLn(ErrOutput, '');
  WriteLn(ErrOutput, 'The server communicates via JSON-RPC 2.0 over stdin/stdout.');
  WriteLn(ErrOutput, 'Logs are written to stderr.');
  WriteLn(ErrOutput, '');
  WriteLn(ErrOutput, 'For debugging with two Delphi IDEs:');
  WriteLn(ErrOutput, '  1. Run TestAllTools.exe from IDE 1 (with --wait parameter)');
  WriteLn(ErrOutput, '  2. In IDE 2, attach to this process (PID shown by test)');
  WriteLn(ErrOutput, '  3. Set breakpoints and press F9');
  WriteLn(ErrOutput, '  4. Server automatically signals ready, tests begin');
end;

function GetDefaultLSPPath: string;
begin
  if Is64BitProcess then
  begin
    Result := DEFAULT_LSP_PATH_64;
    // If 64-bit version doesn't exist, fall back to 32-bit
    if not FileExists(Result) then
    begin
      Logger.Warning('64-bit LSP not found, falling back to 32-bit: %s', [DEFAULT_LSP_PATH_32]);
      Result := DEFAULT_LSP_PATH_32;
    end;
  end
  else
    Result := DEFAULT_LSP_PATH_32;
end;

procedure SignalServerReady;
begin
  if ReadyEvent <> 0 then
  begin
    SetEvent(ReadyEvent);
    Logger.Info('Server ready event signaled: %s', [SERVER_READY_EVENT_NAME]);
  end;
end;

procedure CleanupEvents;
begin
  if ReadyEvent <> 0 then
  begin
    CloseHandle(ReadyEvent);
    ReadyEvent := 0;
    Logger.Debug('Ready event cleaned up');
  end;
end;

function ParseCommandLine: Boolean;
var
  Param: string;
  I: Integer;
  LocalPath: string;
  DebugModeFlag: Boolean;
begin
  LSPPath := GetDefaultLSPPath;
  WorkspaceRoot := DEFAULT_WORKSPACE;
  LogLevel := 'info';
  DebugModeFlag := False;
  WaitForDebugger := False;

  I := 1;
  while I <= ParamCount do
  begin
    Param := ParamStr(I);

    if (Param = '--help') or (Param = '-h') or (Param = '/?') then
    begin
      ShowUsage;
      Result := False;
      Exit;
    end
    else if Param = '--lsp-path' then
    begin
      Inc(I);
      if I <= ParamCount then
        LSPPath := ParamStr(I)
      else
      begin
        WriteLn(ErrOutput, 'Error: --lsp-path requires a value');
        Result := False;
        Exit;
      end;
    end
    else if Param = '--workspace' then
    begin
      Inc(I);
      if I <= ParamCount then
        WorkspaceRoot := ParamStr(I)
      else
      begin
        WriteLn(ErrOutput, 'Error: --workspace requires a value');
        Result := False;
        Exit;
      end;
    end
    else if Param = '--log-level' then
    begin
      Inc(I);
      if I <= ParamCount then
        LogLevel := LowerCase(ParamStr(I))
      else
      begin
        WriteLn(ErrOutput, 'Error: --log-level requires a value');
        Result := False;
        Exit;
      end;
    end
    else if Param = '--debug' then
    begin
      DebugModeFlag := True;
      LogLevel := 'debug';
	  WriteLn(ErrOutput, 'Debug mode enabled');
    end
    else if Param = '--wait' then
    begin
      WaitForDebugger := True;
      WriteLn(ErrOutput, 'Wait for debugger mode enabled');
    end
    else
    begin
      WriteLn(ErrOutput, 'Error: Unknown parameter: ', Param);
      Result := False;
      Exit;
    end;

    Inc(I);
  end;

  // Normalize workspace to file:// URI
  if WorkspaceRoot = '' then
    WorkspaceRoot := PathToFileUri(TDirectory.GetCurrentDirectory)
  else if not WorkspaceRoot.StartsWith('file://', True) then
    WorkspaceRoot := PathToFileUri(WorkspaceRoot);

  // Best-effort validation for local file:// URIs
  if WorkspaceRoot.StartsWith('file://', True) then
  begin
    LocalPath := FileUriToPath(WorkspaceRoot);
    if (LocalPath <> '') and not DirectoryExists(LocalPath) and not FileExists(LocalPath) then
    begin
      WriteLn(ErrOutput, 'Warning: Workspace path does not exist: ', LocalPath);
      WriteLn(ErrOutput, 'LSP server may fail to initialize.');
    end;
  end;

  Result := DebugModeFlag;
end;

procedure ConfigureLogging;
begin
  if LogLevel = 'debug' then
    Logger.LogLevel := llDebug
  else if LogLevel = 'info' then
    Logger.LogLevel := llInfo
  else if LogLevel = 'warning' then
    Logger.LogLevel := llWarning
  else if LogLevel = 'error' then
    Logger.LogLevel := llError
  else
  begin
    WriteLn(ErrOutput, 'Warning: Invalid log level "', LogLevel, '", using "info"');
    Logger.LogLevel := llInfo;
  end;

  Logger.Info('Logging configured with level: %s', [LogLevel]);
end;

function ConsoleCtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
var
  SignalName: string;
begin
  if GlobalShutdownRequested then
  begin
    Result := True;
    Exit;
  end;

  GlobalShutdownRequested := True;
  Result := True;

  case dwCtrlType of
    CTRL_C_EVENT: SignalName := 'CTRL+C';
    CTRL_BREAK_EVENT: SignalName := 'CTRL+BREAK';
    CTRL_CLOSE_EVENT: SignalName := 'CLOSE';
    CTRL_LOGOFF_EVENT: SignalName := 'LOGOFF';
    CTRL_SHUTDOWN_EVENT: SignalName := 'SHUTDOWN';
  else
    SignalName := 'UNKNOWN';
  end;

  WriteLn(ErrOutput, Format('[%s] Shutdown signal received: %s',
    [FormatDateTime('hh:nn:ss', Now), SignalName]));

  if Assigned(LogContext) then
    LogContext.LogFmt('Console event received: %s', [SignalName]);

  if Assigned(Server) then
  begin
    try
      Server.Stop;
    except
      on E: Exception do
        WriteLn(ErrOutput, 'Error during shutdown: ', E.Message);
    end;
  end;

  if Assigned(GlobalShutdownEvent) then
    GlobalShutdownEvent.SetEvent;
end;

procedure SetupConsoleHandlers;
begin
  GlobalShutdownEvent := TEvent.Create(nil, True, False, '');
  if not SetConsoleCtrlHandler(@ConsoleCtrlHandler, True) then
    Logger.Warning('Failed to set console control handler (Error: %d)', [GetLastError])
  else
    Logger.Info('Console control handler installed');
end;

procedure CleanupConsoleHandlers;
begin
  SetConsoleCtrlHandler(@ConsoleCtrlHandler, False);
  if Assigned(GlobalShutdownEvent) then
  begin
    GlobalShutdownEvent.Free;
    Logger.Info('Console control handler removed');
  end;
end;

procedure SetEnvironmentVariables;
var
  FpcExePath: string;
  TargetCPU: string;
  FpcBinPath: string;
begin
  Logger.Info('Setting up FPC environment variables for pasls...');
  Logger.Info('Process bitness: %s-bit', [IfThen(Is64BitProcess, '64', '32')]);

  if Is64BitProcess then
  begin
    FpcBinPath := FPC_BASE_PATH + '\bin\x86_64-win64';
    FpcExePath := FpcBinPath + '\fpc.exe';
    TargetCPU := 'x86_64';
  end
  else
  begin
    FpcBinPath := FPC_BASE_PATH + '\bin\i386-Win32';
    FpcExePath := FpcBinPath + '\fpc.exe';
    TargetCPU := 'i386';
  end;

  // Check if FPC exists, if not try the other architecture
  if not FileExists(FpcExePath) then
  begin
    Logger.Warning('FPC not found at: %s', [FpcExePath]);
    if Is64BitProcess then
    begin
      // Try 32-bit fallback
      FpcBinPath := FPC_BASE_PATH + '\bin\i386-Win32';
      FpcExePath := FpcBinPath + '\fpc.exe';
      TargetCPU := 'i386';
      Logger.Warning('Falling back to 32-bit FPC');
    end
    else
    begin
      // Try 64-bit fallback
      FpcBinPath := FPC_BASE_PATH + '\bin\x86_64-win64';
      FpcExePath := FpcBinPath + '\fpc.exe';
      TargetCPU := 'x86_64';
      Logger.Warning('Falling back to 64-bit FPC');
    end;
  end;

  SetEnvironmentVariable('PP', PChar(FpcExePath));
  SetEnvironmentVariable('FPCDIR', PChar(FPC_BASE_PATH));
  SetEnvironmentVariable('FPCTARGET', 'win32');
  SetEnvironmentVariable('FPCTARGETCPU', PChar(TargetCPU));

  Logger.Debug('FPC Environment:');
  Logger.Debug('  PP=%s', [GetEnvironmentVariable('PP')]);
  Logger.Debug('  FPCDIR=%s', [GetEnvironmentVariable('FPCDIR')]);
  Logger.Debug('  FPCTARGET=%s', [GetEnvironmentVariable('FPCTARGET')]);
  Logger.Debug('  FPCTARGETCPU=%s', [GetEnvironmentVariable('FPCTARGETCPU')]);
end;

procedure PrintStartupBanner;
begin
  WriteLn(ErrOutput, '');
  WriteLn(ErrOutput, '╔══════════════════════════════════════════════════════════════╗');
  WriteLn(ErrOutput, '║           Delphi LSP MCP Server v', VERSION, '                      ║');
  WriteLn(ErrOutput, '╠══════════════════════════════════════════════════════════════╣');
  WriteLn(ErrOutput, Format('║ Bitness:    %-44s ║', [IfThen(Is64BitProcess, '64-bit', '32-bit')]));
  WriteLn(ErrOutput, Format('║ LSP Path:   %-44s ║', [Copy(LSPPath, 1, 44)]));
  WriteLn(ErrOutput, Format('║ Workspace:  %-44s ║', [Copy(WorkspaceRoot, 1, 44)]));
  WriteLn(ErrOutput, Format('║ Log Level:  %-44s ║', [UpperCase(LogLevel)]));
  WriteLn(ErrOutput, Format('║ PID:        %-44d ║', [GetCurrentProcessId]));
  WriteLn(ErrOutput, '╚══════════════════════════════════════════════════════════════╝');
  WriteLn(ErrOutput, '');
  WriteLn(ErrOutput, 'Ready Event: ', SERVER_READY_EVENT_NAME);
  if WaitForDebugger then
    WriteLn(ErrOutput, 'Mode: Waiting for debugger attachment (--wait)')
  else
    WriteLn(ErrOutput, 'Mode: Normal startup');
  WriteLn(ErrOutput, '');
end;

procedure PrintShutdownBanner;
var
  Uptime: string;
  Hours, Minutes, Seconds: Integer;
  TotalSeconds: Integer;
begin
  TotalSeconds := SecondsBetween(Now, StartTime);
  Hours := TotalSeconds div 3600;
  Minutes := (TotalSeconds mod 3600) div 60;
  Seconds := TotalSeconds mod 60;
  Uptime := Format('%d:%02d:%02d', [Hours, Minutes, Seconds]);

  WriteLn(ErrOutput, '');
  WriteLn(ErrOutput, '╔══════════════════════════════════════════════════════════════╗');
  WriteLn(ErrOutput, '║                    Server Shutting Down                      ║');
  WriteLn(ErrOutput, '╠══════════════════════════════════════════════════════════════╣');
  WriteLn(ErrOutput, Format('║ Uptime:     %-44s ║', [Uptime]));
  WriteLn(ErrOutput, '╚══════════════════════════════════════════════════════════════╝');
  WriteLn(ErrOutput, '');
end;

procedure WaitForDebuggerAttachment;
var
  Waiting: Boolean;
  Elapsed: Integer;
begin
  if not WaitForDebugger then
    Exit;

  WriteLn(ErrOutput, '');
  WriteLn(ErrOutput, '╔══════════════════════════════════════════════════════════════╗');
  WriteLn(ErrOutput, '║                    DEBUGGER ATTACHMENT                       ║');
  WriteLn(ErrOutput, '╠══════════════════════════════════════════════════════════════╣');
  WriteLn(ErrOutput, Format('║ PID: %-60d ║', [GetCurrentProcessId]));
  WriteLn(ErrOutput, '║                                                              ║');
  WriteLn(ErrOutput, '║ Waiting for debugger to attach...                           ║');
  WriteLn(ErrOutput, '║                                                              ║');
  WriteLn(ErrOutput, '║ 1. In Delphi IDE #2: Run -> Attach to Process                ║');
  WriteLn(ErrOutput, '║ 2. Find and select this process (PID above)                 ║');
  WriteLn(ErrOutput, '║ 3. Click Attach                                              ║');
  WriteLn(ErrOutput, '║                                                              ║');
  WriteLn(ErrOutput, '║ Server will continue AUTOMATICALLY when debugger attaches   ║');
  WriteLn(ErrOutput, '║ NO manual Enter press required!                             ║');
  WriteLn(ErrOutput, '╚══════════════════════════════════════════════════════════════╝');
  WriteLn(ErrOutput, '');

  // Wait for debugger to attach (no timeout - wait forever)
  Waiting := True;
  Elapsed := 0;

  while Waiting do
  begin
    if IsDebuggerPresent then
    begin
      WriteLn(ErrOutput, 'Debugger attached! Continuing in 200ms...');
      Waiting := False;
    end
    else
    begin
      // Show heartbeat every 5 seconds
      if Elapsed >= 5000 then
      begin
        WriteLn(ErrOutput, Format('Still waiting for debugger... (%d seconds elapsed)', [Elapsed div 1000]));
        Elapsed := 0;
      end;
      Sleep(100);
      Elapsed := Elapsed + 100;
    end;
  end;

  // Small delay to let debugger settle after attach
  Sleep(200);
  WriteLn(ErrOutput, 'Server initialization continuing...');
end;

procedure RunServer;
var
  DebugModeFlag: Boolean;
begin
  // Check for --wait flag before any initialization
  if ParamCount > 0 then
  begin
    for var I := 1 to ParamCount do
    begin
	  if SameText(ParamStr(I), '--wait') then
	  begin
        WaitForDebugger := True;
        Break;
	  end;
    end;
  end;

  // First wait point - allows debugging of program entry
  WaitForDebuggerAttachment;

  // Create the ready event BEFORE any other initialization
  ReadyEvent := CreateEvent(nil, True, False, SERVER_READY_EVENT_NAME);
  if ReadyEvent = 0 then
    WriteLn(ErrOutput, 'Warning: Failed to create ready event: ', GetLastError)
  else
    WriteLn(ErrOutput, 'Ready event created successfully: ', SERVER_READY_EVENT_NAME);

  StartTime := Now;
  Is64BitProcess := SizeOf(Pointer) = 8;

  LogContext := Logger.CreateContext('Main');
  LogContext.Enter('Main');

  try
    // Force Console to UTF-8 for both input and output
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
    Logger.Debug('Console code pages set to UTF-8');

    // Parse command line - returns debug flag
    DebugModeFlag := ParseCommandLine;
    if not DebugModeFlag then
      Exit;

    // Configure logging
    ConfigureLogging;

	// Log bitness information early
    Logger.Info('Process bitness: %s-bit', [IfThen(Is64BitProcess, '64', '32')]);

    // Set up console signal handlers
	SetupConsoleHandlers;
    Logger.Debug('Console handlers configured');

    // Set FPC environment variables for pasls (with bitness awareness)
    SetEnvironmentVariables;

    // Print startup banner
    PrintStartupBanner;

    Logger.Info('=== LSP MCP Server v%s ===', [VERSION]);
    Logger.Info('Process Bitness: %s-bit', [IfThen(Is64BitProcess, '64', '32')]);
    Logger.Info('LSP Path: %s', [LSPPath]);
    Logger.Info('Workspace: %s', [WorkspaceRoot]);
    Logger.Info('Log Level: %s', [LogLevel]);
    Logger.Info('Process ID: %d', [GetCurrentProcessId]);

    // Verify LSP executable exists and is a file
    if not FileExists(LSPPath) or DirectoryExists(LSPPath) then
    begin
      Logger.Error('LSP server not found or is not a file: %s', [LSPPath]);
      WriteLn(ErrOutput, 'Error: LSP server not found or is not a file: ', LSPPath);
      WriteLn(ErrOutput, 'Use --lsp-path to specify the correct path.');
      WriteLn(ErrOutput, '');
      WriteLn(ErrOutput, 'Press ENTER to exit...');
      ExitCode := 1;
      Exit;
    end;

    // Verify LSP file is executable (just log size, ignore attributes)
    Logger.Debug('LSP file size: %d bytes', [TFile.GetSize(LSPPath)]);

    // Check if LSP bitness matches process bitness (warning only)
    var LspIs64Bit: Boolean;
    try
      var LspStream := TFileStream.Create(LSPPath, fmOpenRead);
      try
		LspStream.Seek($3C, soBeginning);
        var PeOffset: Integer;
        LspStream.Read(PeOffset, SizeOf(PeOffset));
        LspStream.Seek(PeOffset + 4, soBeginning);
        var Machine: Word;
        LspStream.Read(Machine, SizeOf(Machine));
        LspIs64Bit := (Machine = $8664); // IMAGE_FILE_MACHINE_AMD64
      finally
        LspStream.Free;
      end;

      if Is64BitProcess and not LspIs64Bit then
        Logger.Warning('LSP server is 32-bit but process is 64-bit. This may cause issues.')
	  else if not Is64BitProcess and LspIs64Bit then
        Logger.Warning('LSP server is 64-bit but process is 32-bit. This may cause issues.');
    except
      // Ignore errors in bitness detection
    end;

    // Create and run server
    Logger.Debug('Creating MCP Server instance...');
    Server := TMCPServer.Create(LSPPath, WorkspaceRoot);

    // Enable debug mode if --debug flag was used OR log level is debug
    if DebugModeFlag or (LogLevel = 'debug') then
    begin
      Logger.Info('Enabling debug mode for all components');
      Server.DebugMode := True;
    end;

    // Give the server a moment to fully initialize its internal structures
    // This helps ensure it's ready to receive messages
    Sleep(100);

    // Signal that server is ready to receive messages
    // The test program is waiting for this event
    SignalServerReady;
    Logger.Info('Server ready event signaled - test program can now proceed');

    // Small delay to ensure the event signal is processed by the test program
    Sleep(50);

    try
      Logger.Info('Server created, starting main loop...');
      Server.Run;
      Logger.Info('Server main loop exited');
    finally
	  Server.Free;
      Server := nil;
      Logger.Info('Server instance freed');
    end;

    PrintShutdownBanner;

  except
    on E: Exception do
    begin
      Logger.Error('Fatal error: %s', [E.Message]);
      Logger.Error('Exception class: %s', [E.ClassName]);
      WriteLn(ErrOutput, '');
      WriteLn(ErrOutput, '╔══════════════════════════════════════════════════════════════╗');
      WriteLn(ErrOutput, '║                      FATAL ERROR                            ║');
      WriteLn(ErrOutput, '╠══════════════════════════════════════════════════════════════╣');
      WriteLn(ErrOutput, Format('║ %-60s ║', [Copy(E.ClassName, 1, 60)]));
      WriteLn(ErrOutput, Format('║ %-60s ║', [Copy(E.Message, 1, 60)]));
      WriteLn(ErrOutput, '╚══════════════════════════════════════════════════════════════╝');
      WriteLn(ErrOutput, '');
      ExitCode := 1;
	end;
  end;

  CleanupConsoleHandlers;
  CleanupEvents;
  LogContext.Exit('Main');

  WriteLn(ErrOutput, 'Server shutdown complete. Press ENTER to exit...');
  ReadLn;
end;

begin
  RunServer;
end.
