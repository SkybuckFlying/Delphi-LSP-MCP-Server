program TestMCPClient;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.JSON,
  Winapi.Windows;

var
  StdinRead, StdoutWrite: THandle;
  StdinWrite, StdoutRead: THandle;
  ProcessHandle: THandle;

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
  
  WriteLn('Sent: ', Copy(AMessage, 1, 100), '...');
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
  
  // Read until we find Content-Length OR a JSON object
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
          Break; // End of headers
      end
      else if Pos('Content-Length:', string(Line)) = 1 then
      begin
        Delete(Line, 1, 15);
        ContentLength := StrToIntDef(string(Trim(string(Line))), -1);
      end
      else if (Line <> '') and (Line[1] = '{') then
      begin
        // Raw JSON detected
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
  
  if not CreatePipe(StdinRead, StdinWrite, @SA, 0) then
    Exit;
  SetHandleInformation(StdinWrite, HANDLE_FLAG_INHERIT, 0);
  
  if not CreatePipe(StdoutRead, StdoutWrite, @SA, 0) then
  begin
    CloseHandle(StdinRead);
    CloseHandle(StdinWrite);
    Exit;
  end;
  SetHandleInformation(StdoutRead, HANDLE_FLAG_INHERIT, 0);
  
  ZeroMemory(@SI, SizeOf(TStartupInfo));
  SI.cb := SizeOf(TStartupInfo);
  SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  SI.hStdInput := StdinRead;
  SI.hStdOutput := StdoutWrite;
  SI.hStdError := GetStdHandle(STD_ERROR_HANDLE);
  
  CmdLine := 'K:\Delphi\Tests\test Skybuck''s LSP MCP server\version 0.01\DelphiLSPMCPServer.exe --log-level debug';
  UniqueString(CmdLine); // Make string mutable for CreateProcess
  ZeroMemory(@PI, SizeOf(TProcessInformation));
  
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, True,
    CREATE_NO_WINDOW, nil, nil, SI, PI) then
  begin
    CloseHandle(StdinRead);
    CloseHandle(StdinWrite);
    CloseHandle(StdoutRead);
    CloseHandle(StdoutWrite);
    Exit;
  end;
  
  CloseHandle(StdinRead);
  CloseHandle(StdoutWrite);
  CloseHandle(PI.hThread);
  ProcessHandle := PI.hProcess;
  
  Result := True;
end;

procedure TestInitialize;
var
  Request, Response: string;
begin
  WriteLn('=== Test: Initialize ===');
  Request := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{' +
    '"protocolVersion":"2024-11-05",' +
    '"capabilities":{},' +
    '"clientInfo":{"name":"test-client","version":"1.0"}' +
    '}}';
  SendMessage(Request);
  Response := ReadMessage;
  WriteLn('Received: ', Response);
  WriteLn;
end;

procedure TestToolsList;
var
  Request, Response: string;
begin
  WriteLn('=== Test: Tools List ===');
  Request := '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}';
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
end;

begin
  try
    WriteLn('MCP Server Test Client');
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
    
    Sleep(1000); // Give server time to initialize
    
    TestInitialize;
    Sleep(500);
    
    TestToolsList;
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
