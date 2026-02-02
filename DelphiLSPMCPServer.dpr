program DelphiLSPMCPServer;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  Winapi.Windows,
  Common.JsonRpc in 'Common.JsonRpc.pas',
  Common.Logging in 'Common.Logging.pas',
  MCP.Protocol.Types in 'MCP.Protocol.Types.pas',
  LSP.Protocol.Types in 'LSP.Protocol.Types.pas',
  MCP.Transport.Stdio in 'MCP.Transport.Stdio.pas',
  LSP.Transport.Process in 'LSP.Transport.Process.pas',
  LSP.Client in 'LSP.Client.pas',
  MCP.Tools.LSP in 'MCP.Tools.LSP.pas',
  MCP.Server in 'MCP.Server.pas';

const
  // delphilsp for Delphi 13
  DEFAULT_LSP_PATH = 'C:\Tools\RAD Studio\37.0\bin64\DelphiLSP.exe';

  // pasls for free pascal compiler and lazarus:
//  DEFAULT_LSP_PATH = 'G:\Tools\PascalLanguageServer\git version 26 january 2026\pasls.exe';

  DEFAULT_WORKSPACE = '';

var
  Server: TMCPServer;
  LSPPath: string;
  WorkspaceRoot: string;
  LogLevel: string;
  I: Integer;

procedure ShowUsage;
begin
  WriteLn(ErrOutput, 'Delphi LSP MCP Server v0.2.0');
  WriteLn(ErrOutput, '');
  WriteLn(ErrOutput, 'Usage: DelphiLSPMCPServer [options]');
  WriteLn(ErrOutput, '');
  WriteLn(ErrOutput, 'Options:');
  WriteLn(ErrOutput, '  --lsp-path <path>      Path to DelphiLSP.exe (default: ', DEFAULT_LSP_PATH, ')');
  WriteLn(ErrOutput, '  --workspace <path>     Workspace root directory (default: current directory)');
  WriteLn(ErrOutput, '  --log-level <level>    Log level: debug, info, warning, error (default: info)');
  WriteLn(ErrOutput, '  --help                 Show this help message');
  WriteLn(ErrOutput, '');
  WriteLn(ErrOutput, 'The server communicates via JSON-RPC 2.0 over stdin/stdout.');
  WriteLn(ErrOutput, 'Logs are written to stderr.');
end;

function ParseCommandLine: Boolean;
var
  Param: string;
begin
  Result := True;
  LSPPath := DEFAULT_LSP_PATH;
  WorkspaceRoot := DEFAULT_WORKSPACE;
  LogLevel := 'info';
  
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
    else
    begin
      WriteLn(ErrOutput, 'Error: Unknown parameter: ', Param);
      Result := False;
      Exit;
    end;
    
    Inc(I);
  end;
  
  // Set default workspace to current directory if not specified
  if WorkspaceRoot = '' then
    WorkspaceRoot := 'file:///' + StringReplace(GetCurrentDir, '\', '/', [rfReplaceAll]);
  
  // Ensure workspace has file:// scheme
  if not WorkspaceRoot.StartsWith('file://') then
    WorkspaceRoot := 'file:///' + StringReplace(WorkspaceRoot, '\', '/', [rfReplaceAll]);
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
end;

begin
  try
    // Force Console Output to UTF-8 to handle special characters (e.g. from pasls)
    SetConsoleOutputCP(CP_UTF8);
    
    // Parse command line
    if not ParseCommandLine then
      Exit;
    
    // Configure logging
    ConfigureLogging;
    
    Logger.Info('=== Delphi LSP MCP Server v0.2.0 ===');
    Logger.Info('LSP Path: %s', [LSPPath]);
    Logger.Info('Workspace: %s', [WorkspaceRoot]);
    Logger.Info('Log Level: %s', [LogLevel]);
    
    // Verify LSP executable exists
    if not FileExists(LSPPath) then
    begin
      Logger.Error('DelphiLSP.exe not found at: %s', [LSPPath]);
      WriteLn(ErrOutput, 'Error: DelphiLSP.exe not found at: ', LSPPath);
      WriteLn(ErrOutput, 'Use --lsp-path to specify the correct path.');
      ExitCode := 1;
      Exit;
    end;
    
    // Create and run server
    Server := TMCPServer.Create(LSPPath, WorkspaceRoot);
    try
      Server.Run;
    finally
      Server.Free;
    end;
    
  except
    on E: Exception do
    begin
      Logger.Error('Fatal error: %s', [E.Message]);
      WriteLn(ErrOutput, 'Fatal error: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
