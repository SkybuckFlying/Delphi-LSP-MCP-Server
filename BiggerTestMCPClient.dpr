program BiggerTestMCPClient;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.JSON,
  System.Classes,
  System.SyncObjs,
  Winapi.Windows;

const
  READ_TIMEOUT_MS       = 8000;
  MAX_MESSAGE_SIZE      = 32 * 1024 * 1024;
  MAX_HEADER_LINE_LENGTH = 8192;

type
  TTestResult = record
    Name: string;
    Passed: Boolean;
    Details: string;
  end;

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
  WriteLn('========================================');
  WriteLn(S);
  WriteLn('========================================');
end;

procedure PrintResult(const R: TTestResult);
begin
  if R.Passed then
    WriteLn('[PASS] ', R.Name)
  else
    WriteLn('[FAIL] ', R.Name, ' - ', R.Details);
end;

procedure SendMessage(const AMessage: string);
var
  Bytes: TBytes;
  Header: AnsiString;
  BytesWritten: DWORD;
begin
  Bytes := TEncoding.UTF8.GetBytes(AMessage);
  Header := AnsiString(Format('Content-Length: %d'#13#10#13#10, [Length(Bytes)]));

  WriteLn('>>> Sending: ', AMessage);

  // Write header
  if not WriteFile(StdinWrite, Pointer(Header)^, Length(Header), BytesWritten, nil) then
  begin
    WriteLn('ERROR: Failed to write header: ', GetLastError);
    Exit;
  end;

  // Write body
  if Length(Bytes) > 0 then
  begin
    if not WriteFile(StdinWrite, Pointer(Bytes)^, Length(Bytes), BytesWritten, nil) then
    begin
      WriteLn('ERROR: Failed to write body: ', GetLastError);
      Exit;
    end;
  end;

  FlushFileBuffers(StdinWrite);
end;

function ReadMessage(out Raw: string): Boolean;
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
  Result := False;
  Raw := '';
  ContentLength := -1;
  Line := '';
  StartTime := GetTickCount64;

  // Headers
  while True do
  begin
    if (GetTickCount64 - StartTime) > READ_TIMEOUT_MS then
    begin
      WriteLn('ERROR: Header timeout');
      Exit(False);
    end;

    if not ReadFile(StdoutRead, Ch, 1, BytesRead, nil) then
    begin
      WriteLn('ERROR: ReadFile header failed: ', GetLastError);
      Exit(False);
    end;

    if BytesRead = 0 then
    begin
      WriteLn('ERROR: EOF while reading header');
      Exit(False);
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
            Exit(False);
          end;
        end
        else if (Line <> '') and (Line[1] = '{') then
        begin
          Raw := UTF8ToString(UTF8String(Line));
          WriteLn('<<< Response (no body): ', Raw);
		  Exit(True);
        end;
      end;

      Line := '';
    end
    else if Ch <> #13 then
    begin
      if Length(Line) >= MAX_HEADER_LINE_LENGTH then
      begin
        WriteLn('ERROR: Header line too long');
        Exit(False);
      end;
      Line := Line + Ch;
    end;
  end;

  // Body
  SetLength(Buffer, ContentLength);
  TotalRead := 0;
  StartTime := GetTickCount64;

  while TotalRead < DWORD(ContentLength) do
  begin
    if (GetTickCount64 - StartTime) > READ_TIMEOUT_MS then
    begin
      WriteLn('ERROR: Body timeout');
      Exit(False);
    end;

    if not ReadFile(StdoutRead, Buffer[TotalRead], ContentLength - TotalRead, BytesRead, nil) then
    begin
      WriteLn('ERROR: ReadFile body failed: ', GetLastError);
      Exit(False);
    end;

    if BytesRead = 0 then
    begin
      WriteLn('ERROR: Pipe closed mid-message');
      Exit(False);
    end;

    Inc(TotalRead, BytesRead);
  end;

  Raw := TEncoding.UTF8.GetString(Buffer);
  WriteLn('<<< Response: ', Raw);
  Result := True;
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
  ProcessHandle := 0;
  StdinWrite := 0;
  StdoutRead := 0;

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

function RunJsonTest(const Name, Request: string; ExpectError: Boolean = False): TTestResult;
var
  Raw: string;
  Json: TJSONObject;
  HasError: Boolean;
begin
  Result.Name := Name;
  Result.Passed := False;
  Result.Details := '';

  PrintHeader(Name);
  try
    SendMessage(Request);
    if not ReadMessage(Raw) then
    begin
      Result.Details := 'No response / read error';
      Exit;
    end;

    Json := TJSONObject.ParseJSONValue(Raw) as TJSONObject;
    if Json = nil then
    begin
      Result.Details := 'Invalid JSON: ' + Raw;
      Exit;
    end;
    try
      HasError := Json.GetValue('error') <> nil;
      if ExpectError then
      begin
        if HasError then
          Result.Passed := True
        else
		  Result.Details := 'Expected error but got success';
      end
      else
      begin
        if HasError then
          Result.Details := 'Server returned error: ' + Json.GetValue('error').ToJSON
        else
          Result.Passed := True;
      end;
    finally
      Json.Free;
    end;
  except
    on E: Exception do
      Result.Details := 'Exception: ' + E.Message;
  end;
end;

function TestInitialize: TTestResult;
begin
  Result := RunJsonTest(
    'Initialize',
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{' +
      '"protocolVersion":"2024-11-05",' +
      '"capabilities":{},' +
      '"clientInfo":{"name":"test-client","version":"1.0"}' +
    '}}',
    False
  );
end;

function TestToolsList: TTestResult;
begin
  Result := RunJsonTest(
    'Tools List',
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}',
    False
  );
end;

function TestToolsCallInvalid: TTestResult;
begin
  Result := RunJsonTest(
	'Tools Call (invalid tool)',
	'{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nonexistent","arguments":{}}}',
	False
  );
end;

function TestResourcesList: TTestResult;
begin
  Result := RunJsonTest(
    'Resources List',
    '{"jsonrpc":"2.0","id":4,"method":"resources/list","params":{}}',
    False
  );
end;

function TestPromptsList: TTestResult;
begin
  Result := RunJsonTest(
    'Prompts List',
    '{"jsonrpc":"2.0","id":5,"method":"prompts/list","params":{}}',
    False
  );
end;

function TestShutdown: TTestResult;
begin
  Result := RunJsonTest(
    'Shutdown',
    '{"jsonrpc":"2.0","id":6,"method":"shutdown","params":{}}',
    False
  );
end;

procedure RunAllTests;
var
  Results: array[0..5] of TTestResult;
  I: Integer;
begin
  Results[0] := TestInitialize;
  Results[1] := TestToolsList;
  Results[2] := TestToolsCallInvalid;
  Results[3] := TestResourcesList;
  Results[4] := TestPromptsList;
  Results[5] := TestShutdown;

  PrintHeader('SUMMARY');
  for I := Low(Results) to High(Results) do
    PrintResult(Results[I]);
end;

procedure MenuLoop;
var
  Choice: string;
  R: TTestResult;
begin
  while True do
  begin
    WriteLn;
    WriteLn('Menu:');
    WriteLn('  1) Initialize');
    WriteLn('  2) Tools List');
    WriteLn('  3) Tools Call (invalid)');
    WriteLn('  4) Resources List');
    WriteLn('  5) Prompts List');
    WriteLn('  6) Shutdown');
    WriteLn('  7) Run ALL tests');
    WriteLn('  Q) Quit');
    Write('Select: ');
    ReadLn(Choice);

    if (Choice = '') then
      Continue;

    case UpCase(Choice[1]) of
      '1': R := TestInitialize;
      '2': R := TestToolsList;
      '3': R := TestToolsCallInvalid;
      '4': R := TestResourcesList;
      '5': R := TestPromptsList;
      '6': R := TestShutdown;
      '7':
        begin
          RunAllTests;
          Continue;
        end;
      'Q':
        Exit;
    else
      WriteLn('Unknown choice.');
      Continue;
    end;

    PrintResult(R);
  end;
end;

begin
  WriteLn('MCP Server Test Client');
  WriteLn('======================');

  if not StartServer then
  begin
    WriteLn('ERROR: Could not start server.');
    WriteLn('Press ENTER to exit...');
    ReadLn;
    Exit;
  end;

  Sleep(800);

  RunAllTests;
  MenuLoop;

  Cleanup;

  WriteLn;
  WriteLn('Press ENTER to exit...');
  ReadLn;
end.

