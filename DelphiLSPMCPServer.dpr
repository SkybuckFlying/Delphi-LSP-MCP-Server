program DelphiLSPMCPServer;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.NetEncoding,
  System.IOUtils,
  System.Classes,
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
  // pasls for free pascal compiler and lazarus:
  DEFAULT_LSP_PATH = 'G:\Tools\PascalLanguageServer\git version 26 january 2026\pasls.exe';
  // delphilsp for Delphi 13:
  // DEFAULT_LSP_PATH = 'C:\Tools\RAD Studio\37.0\bin64\DelphiLSP.exe';

  DEFAULT_WORKSPACE = '';

var
  Server: TMCPServer;
  LSPPath: string;
  WorkspaceRoot: string;
  LogLevel: string;



procedure ShowUsage;
begin
  WriteLn(ErrOutput, 'LSP MCP Server v0.05');
  WriteLn(ErrOutput, '');
  WriteLn(ErrOutput, 'Usage: DelphiLSPMCPServer [options]');
  WriteLn(ErrOutput, '');
  WriteLn(ErrOutput, 'Options:');
  WriteLn(ErrOutput, ' --lsp-path <path>   Path to LSP server executable (default: ', DEFAULT_LSP_PATH, ')');
  WriteLn(ErrOutput, ' --workspace <path>  Workspace root directory or file:// URI (default: current directory)');
  WriteLn(ErrOutput, ' --log-level <level> Log level: debug, info, warning, error (default: info)');
  WriteLn(ErrOutput, ' --help              Show this help message');
  WriteLn(ErrOutput, '');
  WriteLn(ErrOutput, 'The server communicates via JSON-RPC 2.0 over stdin/stdout.');
  WriteLn(ErrOutput, 'Logs are written to stderr.');
end;

function ParseCommandLine: Boolean;
var
  Param: string;
  I: Integer;
  LocalPath: string;
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
    // Force Console to UTF-8 for both input and output
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);

    // Set FPC environment variables for pasls
    SetEnvironmentVariable('PP', 'C:\Tools\FPC\3.2.2\bin\i386-Win32\fpc.exe');
    SetEnvironmentVariable('FPCDIR', 'C:\Tools\FPC\3.2.2');
    SetEnvironmentVariable('FPCTARGET', 'win32');
    SetEnvironmentVariable('FPCTARGETCPU', 'i386');

    // Parse command line
    if not ParseCommandLine then
      Exit;

    // Configure logging
    ConfigureLogging;

	Logger.Info('=== LSP MCP Server v0.04 ===');
    Logger.Info('LSP Path: %s', [LSPPath]);
    Logger.Info('Workspace: %s', [WorkspaceRoot]);
    Logger.Info('Log Level: %s', [LogLevel]);

    // Verify LSP executable exists and is a file
    if not FileExists(LSPPath) or DirectoryExists(LSPPath) then
    begin
      Logger.Error('LSP server not found or is not a file: %s', [LSPPath]);
      WriteLn(ErrOutput, 'Error: LSP server not found or is not a file: ', LSPPath);
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

