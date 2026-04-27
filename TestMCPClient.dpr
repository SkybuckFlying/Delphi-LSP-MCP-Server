program TestMCPClient;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.JSON,
  System.Classes,
  System.SyncObjs,
  Winapi.Windows;

const
  READ_TIMEOUT_MS = 5000;
  MAX_MESSAGE_SIZE = 32 * 1024 * 1024;
  MAX_HEADER_LINE_LENGTH = 8192;

var
  StdinWrite, StdoutRead: THandle;
  ProcessHandle: THandle;

procedure SafeCloseHandle(var AHandle: THandle);
begin
  if AHandle <> 0 then
  begin
    CloseHandle(AHandle);
    AHandle := 0;
  end;
end;

procedure PrintHeader(const S: string);
begin
  WriteLn;
  WriteLn('==============================');
  WriteLn(S);
  WriteLn('==============================');
end;

procedure PrintResult(const TestName: string; Success: Boolean);
begin
  if Success then
    WriteLn('[PASS] ', TestName)
  else
    WriteLn('[FAIL] ', TestName);
end;

procedure SendMessage(const AMessage: string);
var
  Bytes: TBytes;
  Header: AnsiString;
  BytesWritten: DWORD;
begin
  Bytes := TEncoding.UTF8.GetBytes(AMessage);
  Header := AnsiString(Format('Content-Length: %d'#13#10#13#10, [Length(Bytes)]));

  WriteLn('Sending: ', AMessage);

  if not WriteFile(StdinWrite, PAnsiChar(Header)^, Length(Header), BytesWritten, nil) then
  begin
    WriteLn('ERROR: Failed to write header: ', GetLastError);
    Exit;
  end;

  if BytesWritten <> DWORD(Length(Header)) then
	WriteLn('WARNING: Partial header write');

  if Length(Bytes) > 0 then
  begin
    if not WriteFile(StdinWrite, Bytes[0], Length(Bytes), BytesWritten, nil) then
    begin
      WriteLn('ERROR: Failed to write body: ', GetLastError);
      Exit;
    end;

    if BytesWritten <> DWORD(Length(Bytes)) then
      WriteLn('WARNING: Partial body write');
  end;

  FlushFileBuffers(StdinWrite);
end;

function ReadMessage: string;
var
  Line: AnsiString;
  Ch: AnsiChar;
  BytesRead: DWORD;
  ContentLength: Integer;
  Buffer: TBytes;
  TotalRead: DWORD;
  StartTime: UInt64;
  LowerLine: string;
begin
  Result := '';
  ContentLength := -1;
  Line := '';
  StartTime := GetTickCount64;

  // Read headers
  while True do
  begin
    if (GetTickCount64 - StartTime) > READ_TIMEOUT_MS then
    begin
      WriteLn('ERROR: Header timeout');
      Exit('');
    end;

    if not ReadFile(StdoutRead, Ch, 1, BytesRead, nil) then
    begin
      WriteLn('ERROR: ReadFile header failed: ', GetLastError);
      Exit('');
    end;

    if BytesRead = 0 then
    begin
      WriteLn('ERROR: EOF while reading header');
      Exit('');
    end;

    if Ch = #10 then
    begin
      Line := AnsiString(Trim(string(Line)));

      if Line = '' then
      begin
        if ContentLength > 0 then
          Break;
	  end
      else
      begin
        LowerLine := LowerCase(string(Line));
        if Pos('content-length:', LowerLine) = 1 then
        begin
          Delete(Line, 1, 15);
          ContentLength := StrToIntDef(Trim(string(Line)), -1);
          if (ContentLength <= 0) or (ContentLength > MAX_MESSAGE_SIZE) then
          begin
            WriteLn('ERROR: Invalid Content-Length: ', ContentLength);
            Exit('');
          end;
        end
        else if (Line <> '') and (Line[1] = '{') then
        begin
          Result := UTF8ToString(UTF8String(Line));
          Exit;
        end;
      end;

      Line := '';
    end
    else if Ch <> #13 then
    begin
      if Length(Line) >= MAX_HEADER_LINE_LENGTH then
      begin
        WriteLn('ERROR: Header line too long');
        Exit('');
      end;
      Line := Line + Ch;
    end;
  end;

  // Read body
  SetLength(Buffer, ContentLength);
  TotalRead := 0;
  StartTime := GetTickCount64;

  while TotalRead < DWORD(ContentLength) do
  begin
    if (GetTickCount64 - StartTime) > READ_TIMEOUT_MS then
    begin
      WriteLn('ERROR: Body timeout');
      Exit('');
	end;

	if not ReadFile(StdoutRead, Buffer[TotalRead], ContentLength - TotalRead, BytesRead, nil) then
	begin
	  WriteLn('ERROR: ReadFile body failed: ', GetLastError);
	  Exit('');
	end;

	if BytesRead = 0 then
	begin
	  WriteLn('ERROR: Pipe closed mid-message');
	  Exit('');
	end;

	Inc(TotalRead, BytesRead);
  end;

  Result := TEncoding.UTF8.GetString(Buffer);
end;

function StartServer: Boolean;
var
  SA: TSecurityAttributes;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd: array[0..1023] of Char;
  StdinRead, StdoutWrite: THandle;
  StdErr: THandle;
begin
  Result := False;

  ZeroMemory(@SA, SizeOf(SA));
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;

  if not CreatePipe(StdinRead, StdinWrite, @SA, 0) then
  begin
    WriteLn('ERROR: CreatePipe stdin failed: ', GetLastError);
    Exit(False);
  end;
  SetHandleInformation(StdinWrite, HANDLE_FLAG_INHERIT, 0);

  if not CreatePipe(StdoutRead, StdoutWrite, @SA, 0) then
  begin
    WriteLn('ERROR: CreatePipe stdout failed: ', GetLastError);
    SafeCloseHandle(StdinRead);
    SafeCloseHandle(StdinWrite);
    Exit(False);
  end;
  SetHandleInformation(StdoutRead, HANDLE_FLAG_INHERIT, 0);

  ZeroMemory(@SI, SizeOf(SI));
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES;

  SI.hStdInput := StdinRead;
  SI.hStdOutput := StdoutWrite;

  StdErr := GetStdHandle(STD_ERROR_HANDLE);
  if StdErr = INVALID_HANDLE_VALUE then
    StdErr := 0;
  SI.hStdError := StdErr;

  StrPCopy(Cmd, '"DelphiLSPMCPServer.exe" --log-level debug');

  ZeroMemory(@PI, SizeOf(PI));

  if not CreateProcess(nil, Cmd, nil, nil, True,
    CREATE_NO_WINDOW, nil, nil, SI, PI) then
  begin
    WriteLn('ERROR: CreateProcess failed: ', GetLastError);
    SafeCloseHandle(StdinRead);
    SafeCloseHandle(StdinWrite);
    SafeCloseHandle(StdoutRead);
    SafeCloseHandle(StdoutWrite);
    Exit(False);
  end;

  SafeCloseHandle(StdinRead);
  SafeCloseHandle(StdoutWrite);
  SafeCloseHandle(PI.hThread);
  ProcessHandle := PI.hProcess;

  Result := True;
end;

function RunTest(const Name, Request: string): Boolean;
var
  Response: string;
begin
  PrintHeader(Name);
  Result := False;

  try
    SendMessage(Request);
    Response := ReadMessage;

    WriteLn('Response: ', Response);

    if Response = '' then
      Exit(False);

    if Pos('"error"', Response) > 0 then
      Exit(False);

    Result := True;
  except
    on E: Exception do
    begin
      WriteLn('EXCEPTION: ', E.Message);
      Result := False;
    end;
  end;
end;

procedure Cleanup;
begin
  if ProcessHandle <> 0 then
  begin
    TerminateProcess(ProcessHandle, 0);
    SafeCloseHandle(ProcessHandle);
  end;

  SafeCloseHandle(StdinWrite);
  SafeCloseHandle(StdoutRead);
end;

var
  OkInit, OkTools: Boolean;

begin
  WriteLn('MCP Server Test Client');
  WriteLn('======================');

  if not StartServer then
  begin
    WriteLn('ERROR: Could not start server.');
    ReadLn;
    Exit;
  end;

  Sleep(800);

  OkInit := RunTest('Initialize',
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0"}}}');

  OkTools := RunTest('Tools List',
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}');

  PrintHeader('SUMMARY');
  PrintResult('Initialize', OkInit);
  PrintResult('Tools List', OkTools);

  WriteLn;
  WriteLn('Press ENTER to exit...');
  ReadLn;

  Cleanup;
end.

