program TestLSPFunctionality;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.JSON,
  Winapi.Windows;

var
  StdinRead, StdoutWrite: THandle;
  StdinWrite, StdoutRead: THandle;
  StderrRead, StderrWrite: THandle;
  ProcessHandle: THandle;
  LogThreadHandle: THandle;
  LogThreadId: DWORD;

type
  TLogReader = class
  public
    class procedure ReadLog(Payload: Pointer); static;
  end;

class procedure TLogReader.ReadLog(Payload: Pointer);
var
  Buffer: array[0..4095] of Byte; // Use Byte to correctly visualize it's raw data
  BytesRead, BytesWritten: DWORD;
  ConsoleOutput: THandle;
begin
  ConsoleOutput := GetStdHandle(STD_OUTPUT_HANDLE);
  while ReadFile(StderrRead, Buffer, SizeOf(Buffer), BytesRead, nil) do
  begin
    if BytesRead > 0 then
    begin
      WriteFile(ConsoleOutput, Buffer, BytesRead, BytesWritten, nil);
      // FlushFileBuffers(ConsoleOutput); // Not strictly necessary for console
    end;
  end;
end;

procedure SendMessage(const AMessage: string);
var
  Utf8Message: UTF8String;
  Header: AnsiString;
  BytesWritten: DWORD;
begin
  Utf8Message := UTF8Encode(AMessage);
  Header := AnsiString(Format('Content-Length: %d'#13#10#13#10, [Length(Utf8Message)]));
  
  WriteFile(StdinWrite, PAnsiChar(Header)^, Length(Header), BytesWritten, nil);
  WriteFile(StdinWrite, PAnsiChar(Utf8Message)^, Length(Utf8Message), BytesWritten, nil);
  FlushFileBuffers(StdinWrite);
  
  WriteLn('Sent: ', Copy(AMessage, 1, 150), '...');
end;


function ReadMessage: string;
var
  Line: AnsiString;
  Ch: AnsiChar;
  BytesRead: DWORD;
  ContentLength: Integer;
  Buffer: TBytes;
  TotalRead: DWORD;
  Utf8Str: UTF8String;
  ReadRes: Boolean;
begin
  Result := '';
  ContentLength := -1;
  Line := '';
  
  while True do
  begin
    ReadRes := ReadFile(StdoutRead, Ch, 1, BytesRead, nil);
    if not ReadRes or (BytesRead = 0) then Exit;
    
    if Ch = #10 then
    begin
      Line := AnsiString(Trim(string(Line)));
      if Line = '' then
      begin
        if ContentLength > 0 then
          Break;
      end
      else if Pos('Content-Length:', string(Line)) = 1 then
      begin
        Delete(Line, 1, 15);
        ContentLength := StrToIntDef(string(Trim(string(Line))), -1);
      end
      else if (Line <> '') and (Line[1] = '{') then
      begin
        Result := UTF8ToString(UTF8String(Line));
        Exit;
      end;
      Line := '';
    end
    else if Ch <> #13 then
      Line := Line + Ch;
  end;
  
  if ContentLength > 0 then
  begin
    SetLength(Buffer, ContentLength);
    TotalRead := 0;
    while TotalRead < DWORD(ContentLength) do
    begin
      if not ReadFile(StdoutRead, Buffer[TotalRead], ContentLength - TotalRead, BytesRead, nil) then
        Exit;
      if BytesRead = 0 then Break;
      Inc(TotalRead, BytesRead);
    end;
    
    if TotalRead = DWORD(ContentLength) then
    begin
      SetLength(Utf8Str, ContentLength);
      Move(Buffer[0], Utf8Str[1], ContentLength);
      Result := UTF8ToString(Utf8Str);
    end;
  end;
end;

function StartServer: Boolean;
var
  SA: TSecurityAttributes;
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: string;
begin
  Result := False;
  
  SA.nLength := SizeOf(TSecurityAttributes);
  SA.bInheritHandle := True;
  SA.lpSecurityDescriptor := nil;
  
  if not CreatePipe(StdinRead, StdinWrite, @SA, 0) then Exit;
  SetHandleInformation(StdinWrite, HANDLE_FLAG_INHERIT, 0);
  
  if not CreatePipe(StdoutRead, StdoutWrite, @SA, 0) then
  begin
    CloseHandle(StdinRead);
    CloseHandle(StdinWrite);
    Exit;
  end;
  SetHandleInformation(StdoutRead, HANDLE_FLAG_INHERIT, 0);
  
  if not CreatePipe(StderrRead, StderrWrite, @SA, 0) then
  begin
    CloseHandle(StdinRead);
    CloseHandle(StdinWrite);
    CloseHandle(StdoutRead);
    CloseHandle(StdoutWrite);
    Exit;
  end;
  SetHandleInformation(StderrRead, HANDLE_FLAG_INHERIT, 0); // Read handle shouldn't be inherited? Wait, we read it. Write handle inherited.
  SetHandleInformation(StderrRead, HANDLE_FLAG_INHERIT, 0); // Ensure Read end is NOT inherited
  SetHandleInformation(StderrWrite, HANDLE_FLAG_INHERIT, 1); // Ensure Write end IS inherited

  ZeroMemory(@SI, SizeOf(TStartupInfo));
  SI.cb := SizeOf(TStartupInfo);
  SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  SI.hStdInput := StdinRead;
  SI.hStdOutput := StdoutWrite;
  SI.hStdError := StderrWrite;
  
  CmdLine := 'DelphiLSPMCPServer.exe --log-level debug';
  UniqueString(CmdLine);
  ZeroMemory(@PI, SizeOf(TProcessInformation));
  
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, True,
    CREATE_NO_WINDOW, nil, nil, SI, PI) then
  begin
    CloseHandle(StdinRead); CloseHandle(StdinWrite);
    CloseHandle(StdoutRead); CloseHandle(StdoutWrite);
    CloseHandle(StderrRead); CloseHandle(StderrWrite);
    Exit;
  end;
  
  CloseHandle(StdinRead);
  CloseHandle(StdoutWrite);
  CloseHandle(StderrWrite); // Close write end in parent
  
  CloseHandle(PI.hThread);
  ProcessHandle := PI.hProcess;
  
  // Start log reader thread
  LogThreadHandle := CreateThread(nil, 0, @TLogReader.ReadLog, nil, 0, LogThreadId);
  
  Result := True;
end;

procedure TestInitialize;
var
  Request, Response: string;
begin
  WriteLn('=== Test: Initialize ===');
  Request := Format('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{' +
    '"protocolVersion":"2024-11-05",' +
    '"rootUri":"file:///%s",' +
    '"capabilities":{},' +
    '"clientInfo":{"name":"test-client","version":"1.0"}' +
    '}}', [StringReplace(ExtractFilePath(ParamStr(0)), '\', '/', [rfReplaceAll])]);
  SendMessage(Request);
  Response := ReadMessage;
  WriteLn('Received: ', Response);
  WriteLn;
end;

procedure TestGoToDefinition;
var
  Request, Response: string;
  FilePath: string;
begin
  WriteLn('=== Test: Go To Definition ===');
  FilePath := ExtractFilePath(ParamStr(0)) + 'SourceForAnalysis.dpr';
  FilePath := StringReplace(FilePath, '\', '/', [rfReplaceAll]);
  
  // Looking for definition of 'Bar' at the call site (Line 23, Char 6)
  // Note: Line 23 is index 22 in 0-based LSP
  
  Request := Format('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{' +
    '"name":"delphi_goto_definition",' +
    '"arguments":{' +
    '"uri":"file:///%s",' +
    '"line":22,' +
    '"character":6' +
    '}}}', [FilePath]);
    
  SendMessage(Request);
  Response := ReadMessage;
  WriteLn('Received: ', Response);
  WriteLn;
end;

procedure TestHover;
var
  Request, Response: string;
  FilePath: string;
begin
  WriteLn('=== Test: Hover ===');
  FilePath := ExtractFilePath(ParamStr(0)) + 'SourceForAnalysis.dpr';
  FilePath := StringReplace(FilePath, '\', '/', [rfReplaceAll]);
  
  // Hover over 'Bar' at the call site (Line 23, Char 6)
  
  Request := Format('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{' +
    '"name":"delphi_hover",' +
    '"arguments":{' +
    '"uri":"file:///%s",' +
    '"line":22,' +
    '"character":6' +
    '}}}', [FilePath]);
    
  SendMessage(Request);
  Response := ReadMessage;
  WriteLn('Received: ', Response);
  WriteLn;
end;

procedure Cleanup;
begin
  if ProcessHandle <> 0 then
  begin
    TerminateProcess(ProcessHandle, 0);
    CloseHandle(ProcessHandle);
  end;
  if StdinWrite <> 0 then
    CloseHandle(StdinWrite);
  if StdoutRead <> 0 then
    CloseHandle(StdoutRead);
  if StderrRead <> 0 then
    CloseHandle(StderrRead);
  if LogThreadHandle <> 0 then
  begin
    TerminateThread(LogThreadHandle, 0);
    CloseHandle(LogThreadHandle);
  end;
end;

begin
  try
    SetConsoleOutputCP(CP_UTF8); // Force console to UTF-8 to display server logs correctly
    WriteLn('MCP Functionality Test');
    WriteLn('======================');
    WriteLn;
    
    if not StartServer then
    begin
      WriteLn('ERROR: Failed to start server');
      ExitCode := 1;
      Exit;
    end;
    
    WriteLn('Server started successfully');
    WriteLn;
    
    Sleep(2000); // Wait for pasls to fully load
    
    TestInitialize;
    Sleep(500);
    
    TestGoToDefinition;
    Sleep(500);
    
    TestHover;
    Sleep(500);
    
    WriteLn('Tests completed');
    
  except
    on E: Exception do
    begin
      WriteLn('ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
  
  Cleanup;
end.
