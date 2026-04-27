program TestAllTools;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.JSON,
  System.Classes,
  System.Generics.Collections,
  Winapi.Windows;

const
  READ_TIMEOUT_MS       = 15000;  // 15 seconds for LSP tool calls (retries take time)
  MAX_MESSAGE_SIZE      = 32 * 1024 * 1024;
  MAX_HEADER_LINE_LENGTH = 8192;

  // SourceForAnalysis.dpr lives in the same directory
  SOURCE_FILE = 'SourceForAnalysis.dpr';

type
  TTestResult = record
    Name: string;
    Passed: Boolean;
    Details: string;
    ResponseJson: string;
  end;

  TTestResultArray = array of TTestResult;

var
  StdinWrite, StdoutRead: THandle;
  ProcessHandle: THandle;
  SourceUri: string;
  AllResults: TTestResultArray;
  ResultCount: Integer;

procedure AddResult(const R: TTestResult);
begin
  Inc(ResultCount);
  if ResultCount > Length(AllResults) then
    SetLength(AllResults, ResultCount + 16);
  AllResults[ResultCount - 1] := R;
end;

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
    WriteLn('[FAIL] ', R.Name, ' -- ', R.Details);
end;

procedure SendMessage(const AMessage: string);
var
  Bytes: TBytes;
  Header: AnsiString;
  BytesWritten: DWORD;
begin
  Bytes := TEncoding.UTF8.GetBytes(AMessage);
  Header := AnsiString(Format('Content-Length: %d'#13#10#13#10, [Length(Bytes)]));

  WriteLn('>>> Sending: ', Copy(AMessage, 1, 200));
  if Length(AMessage) > 200 then
    WriteLn('    ... (', Length(AMessage), ' bytes total)');

  if not WriteFile(StdinWrite, Pointer(Header)^, Length(Header), BytesWritten, nil) then
  begin
    WriteLn('ERROR: Failed to write header: ', GetLastError);
    Exit;
  end;

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

  // Read headers or raw JSON
  while True do
  begin
    if (GetTickCount64 - StartTime) > READ_TIMEOUT_MS then
    begin
      WriteLn('ERROR: Header/message timeout after ', READ_TIMEOUT_MS, 'ms');
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
        // Detect raw JSON (server sends raw JSON + CRLF, no Content-Length)
        else if (Line <> '') and (Line[1] = '{') then
        begin
          Raw := UTF8ToString(UTF8String(Line));
          WriteLn('<<< Response (raw JSON): ', Copy(Raw, 1, 200));
          if Length(Raw) > 200 then
            WriteLn('    ... (', Length(Raw), ' bytes total)');
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

  // Read body using Content-Length
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

    if not ReadFile(StdoutRead, Buffer[TotalRead], ContentLength - Integer(TotalRead), BytesRead, nil) then
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
  WriteLn('<<< Response (CL): ', Copy(Raw, 1, 200));
  if Length(Raw) > 200 then
    WriteLn('    ... (', Length(Raw), ' bytes total)');
  Result := True;
end;

function StartServer: Boolean;
var
  SA: TSecurityAttributes;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd: string;
  CmdBuf: array[0..2047] of Char;
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

  Cmd := Format('"DelphiLSPMCPServer.exe" --log-level debug --workspace "%s"', [ExpandFileName('.')]);
  StrPCopy(CmdBuf, Cmd);

  ZeroMemory(@PI, SizeOf(PI));

  if not CreateProcess(nil, CmdBuf, nil, nil, True,
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

function RunTest(const Name, Request: string; ExpectError: Boolean = False): TTestResult;
var
  Raw: string;
  Json: TJSONObject;
  HasError: Boolean;
begin
  Result.Name := Name;
  Result.Passed := False;
  Result.Details := '';
  Result.ResponseJson := '';

  PrintHeader('TEST: ' + Name);
  try
    SendMessage(Request);
    if not ReadMessage(Raw) then
    begin
      Result.Details := 'No response / read error / timeout';
      Exit;
    end;

    Result.ResponseJson := Raw;

    Json := TJSONObject.ParseJSONValue(Raw) as TJSONObject;
    if Json = nil then
    begin
      Result.Details := 'Invalid JSON response';
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
          Result.Details := 'Server error: ' + Json.GetValue('error').ToJSON
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

// Check the content text inside a tool call result
function GetToolResultText(const ResponseJson: string): string;
var
  Json, ResultObj: TJSONObject;
  ContentArr: TJSONArray;
  Item: TJSONObject;
begin
  Result := '';
  Json := TJSONObject.ParseJSONValue(ResponseJson) as TJSONObject;
  if Json = nil then Exit;
  try
    ResultObj := Json.GetValue('result') as TJSONObject;
    if ResultObj = nil then Exit;
    ContentArr := ResultObj.GetValue('content') as TJSONArray;
    if ContentArr = nil then Exit;
    if ContentArr.Count = 0 then Exit;
    Item := ContentArr.Items[0] as TJSONObject;
    if Item = nil then Exit;
    Item.TryGetValue<string>('text', Result);
  finally
    Json.Free;
  end;
end;

function BuildSourceUri: string;
var
  FullPath: string;
  I: Integer;
  C: Char;
begin
  FullPath := ExpandFileName(SOURCE_FILE);
  // Convert backslashes to forward slashes
  FullPath := StringReplace(FullPath, '\', '/', [rfReplaceAll]);

  // Percent-encode spaces and special chars in path
  Result := '';
  for I := 1 to Length(FullPath) do
  begin
    C := FullPath[I];
    if CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~', '/', ':']) then
      Result := Result + C
    else
      Result := Result + '%' + IntToHex(Ord(C), 2);
  end;

  Result := 'file:///' + Result;
end;

function ToolCallRequest(Id: Integer; const ToolName: string; const ArgsJson: string): string;
begin
  Result := Format(
    '{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{"name":"%s","arguments":%s}}',
    [Id, ToolName, ArgsJson]
  );
end;

procedure RunAllTests;
var
  R: TTestResult;
  Text: string;
  ArgsJson: string;
begin
  ResultCount := 0;
  SetLength(AllResults, 32);

  // =========================================================
  // TEST 1: Initialize
  // =========================================================
  R := RunTest('1. MCP Initialize',
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{' +
      '"protocolVersion":"2025-11-25",' +
      '"capabilities":{},' +
      '"clientInfo":{"name":"TestAllTools","version":"1.0"}' +
    '}}');
  AddResult(R);
  PrintResult(R);

  if not R.Passed then
  begin
    WriteLn('FATAL: Initialize failed, cannot continue.');
    Exit;
  end;

  // Check protocolVersion in response
  Text := R.ResponseJson;
  if Pos('"protocolVersion"', Text) = 0 then
    WriteLn('  WARNING: No protocolVersion in response');

  // Give LSP server time to start and index
  WriteLn;
  WriteLn('Waiting 3 seconds for LSP to start and index...');
  Sleep(3000);

  // Send initialized notification (no response expected)
  SendMessage('{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}');
  Sleep(500);

  // =========================================================
  // TEST 2: Tools List
  // =========================================================
  R := RunTest('2. Tools List',
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}');
  AddResult(R);
  PrintResult(R);

  if R.Passed then
  begin
    // Check that we get 5 tools
    if Pos('"delphi_goto_definition"', R.ResponseJson) > 0 then
      WriteLn('  OK: delphi_goto_definition found')
    else
      WriteLn('  WARNING: delphi_goto_definition NOT found');

    if Pos('"delphi_find_references"', R.ResponseJson) > 0 then
      WriteLn('  OK: delphi_find_references found')
    else
      WriteLn('  WARNING: delphi_find_references NOT found');

    if Pos('"delphi_hover"', R.ResponseJson) > 0 then
      WriteLn('  OK: delphi_hover found')
    else
      WriteLn('  WARNING: delphi_hover NOT found');

    if Pos('"delphi_completion"', R.ResponseJson) > 0 then
      WriteLn('  OK: delphi_completion found')
    else
      WriteLn('  WARNING: delphi_completion NOT found');

    if Pos('"delphi_workspace_symbols"', R.ResponseJson) > 0 then
      WriteLn('  OK: delphi_workspace_symbols found')
    else
      WriteLn('  WARNING: delphi_workspace_symbols NOT found');
  end;

  // =========================================================
  // TEST 3: Goto Definition - TFoo.Bar method call
  // SourceForAnalysis.dpr line 27 (0-based 26): "    F.Bar;"
  // "Bar" starts at char 6
  // =========================================================
  WriteLn;
  WriteLn('--- LSP Tool Tests against ', SOURCE_FILE, ' ---');
  WriteLn('Source URI: ', SourceUri);

  ArgsJson := Format('{"uri":"%s","line":26,"character":6}', [SourceUri]);
  R := RunTest('3. Goto Definition (F.Bar call, line 27)',
    ToolCallRequest(10, 'delphi_goto_definition', ArgsJson));
  AddResult(R);
  PrintResult(R);
  Text := GetToolResultText(R.ResponseJson);
  WriteLn('  Tool result text: ', Text);

  // =========================================================
  // TEST 4: Goto Definition - TFoo class on its declaration line
  // SourceForAnalysis.dpr line 13 (0-based 12): "  TFoo = class"
  // "TFoo" starts at char 2
  // =========================================================
  ArgsJson := Format('{"uri":"%s","line":12,"character":3}', [SourceUri]);
  R := RunTest('4. Goto Definition (TFoo declaration, line 13)',
    ToolCallRequest(11, 'delphi_goto_definition', ArgsJson));
  AddResult(R);
  PrintResult(R);
  Text := GetToolResultText(R.ResponseJson);
  WriteLn('  Tool result text: ', Text);

  // =========================================================
  // TEST 5: Goto Definition - WriteLn call
  // SourceForAnalysis.dpr line 19 (0-based 18): "  WriteLn('Hello World');"
  // "WriteLn" starts at char 2
  // =========================================================
  ArgsJson := Format('{"uri":"%s","line":18,"character":4}', [SourceUri]);
  R := RunTest('5. Goto Definition (WriteLn, line 19)',
    ToolCallRequest(12, 'delphi_goto_definition', ArgsJson));
  AddResult(R);
  PrintResult(R);
  Text := GetToolResultText(R.ResponseJson);
  WriteLn('  Tool result text: ', Text);

  // =========================================================
  // TEST 6: Find References - TFoo
  // SourceForAnalysis.dpr line 13 (0-based 12): "  TFoo = class"
  // =========================================================
  ArgsJson := Format('{"uri":"%s","line":12,"character":3,"includeDeclaration":true}', [SourceUri]);
  R := RunTest('6. Find References (TFoo, line 13)',
    ToolCallRequest(13, 'delphi_find_references', ArgsJson));
  AddResult(R);
  PrintResult(R);
  Text := GetToolResultText(R.ResponseJson);
  WriteLn('  Tool result text: ', Text);

  // =========================================================
  // TEST 7: Find References - Bar
  // SourceForAnalysis.dpr line 14 (0-based 13): "    procedure Bar;"
  // "Bar" starts at char 14
  // =========================================================
  ArgsJson := Format('{"uri":"%s","line":13,"character":15}', [SourceUri]);
  R := RunTest('7. Find References (Bar, line 14)',
    ToolCallRequest(14, 'delphi_find_references', ArgsJson));
  AddResult(R);
  PrintResult(R);
  Text := GetToolResultText(R.ResponseJson);
  WriteLn('  Tool result text: ', Text);

  // =========================================================
  // TEST 8: Hover - TFoo class
  // SourceForAnalysis.dpr line 13 (0-based 12)
  // =========================================================
  ArgsJson := Format('{"uri":"%s","line":12,"character":3}', [SourceUri]);
  R := RunTest('8. Hover (TFoo, line 13)',
    ToolCallRequest(15, 'delphi_hover', ArgsJson));
  AddResult(R);
  PrintResult(R);
  Text := GetToolResultText(R.ResponseJson);
  WriteLn('  Tool result text: ', Text);

  // =========================================================
  // TEST 9: Hover - Bar procedure
  // SourceForAnalysis.dpr line 17 (0-based 16): "procedure TFoo.Bar;"
  // "Bar" at char 15
  // =========================================================
  ArgsJson := Format('{"uri":"%s","line":16,"character":15}', [SourceUri]);
  R := RunTest('9. Hover (TFoo.Bar, line 17)',
    ToolCallRequest(16, 'delphi_hover', ArgsJson));
  AddResult(R);
  PrintResult(R);
  Text := GetToolResultText(R.ResponseJson);
  WriteLn('  Tool result text: ', Text);

  // =========================================================
  // TEST 10: Completion - after "F." on line 27
  // Line 27 (0-based 26): "    F.Bar;"
  // Position after "F." = char 6
  // =========================================================
  ArgsJson := Format('{"uri":"%s","line":26,"character":6}', [SourceUri]);
  R := RunTest('10. Completion (after F., line 27)',
    ToolCallRequest(17, 'delphi_completion', ArgsJson));
  AddResult(R);
  PrintResult(R);
  Text := GetToolResultText(R.ResponseJson);
  WriteLn('  Tool result text: ', Copy(Text, 1, 300));

  // =========================================================
  // TEST 11: Completion - after "TFoo." to see methods
  // Line 25 (0-based 24): "  F := TFoo.Create;"
  // Position after "TFoo." = char 14
  // =========================================================
  ArgsJson := Format('{"uri":"%s","line":24,"character":14}', [SourceUri]);
  R := RunTest('11. Completion (after TFoo., line 25)',
    ToolCallRequest(18, 'delphi_completion', ArgsJson));
  AddResult(R);
  PrintResult(R);
  Text := GetToolResultText(R.ResponseJson);
  WriteLn('  Tool result text: ', Copy(Text, 1, 300));

  // =========================================================
  // TEST 12: Workspace Symbols - TFoo
  // =========================================================
  R := RunTest('12. Workspace Symbols (query=TFoo)',
    ToolCallRequest(19, 'delphi_workspace_symbols', '{"query":"TFoo"}'));
  AddResult(R);
  PrintResult(R);
  Text := GetToolResultText(R.ResponseJson);
  WriteLn('  Tool result text: ', Text);

  // =========================================================
  // TEST 13: Workspace Symbols - Bar
  // =========================================================
  R := RunTest('13. Workspace Symbols (query=Bar)',
    ToolCallRequest(20, 'delphi_workspace_symbols', '{"query":"Bar"}'));
  AddResult(R);
  PrintResult(R);
  Text := GetToolResultText(R.ResponseJson);
  WriteLn('  Tool result text: ', Text);

  // =========================================================
  // TEST 14: Workspace Symbols - empty query (should return many)
  // =========================================================
  R := RunTest('14. Workspace Symbols (query="" empty)',
    ToolCallRequest(21, 'delphi_workspace_symbols', '{"query":""}'));
  AddResult(R);
  PrintResult(R);
  Text := GetToolResultText(R.ResponseJson);
  WriteLn('  Tool result text: ', Copy(Text, 1, 200));

  // =========================================================
  // TEST 15: Invalid tool name
  // =========================================================
  R := RunTest('15. Invalid Tool Name',
    ToolCallRequest(22, 'nonexistent_tool', '{}'));
  AddResult(R);
  PrintResult(R);
  Text := GetToolResultText(R.ResponseJson);
  WriteLn('  Tool result text: ', Text);
  // This should return isError=true in the result (not a JSON-RPC error)
  if Pos('"isError":true', R.ResponseJson) > 0 then
    WriteLn('  OK: isError=true in result (correct per MCP spec)')
  else if R.Passed then
    WriteLn('  WARNING: No isError=true found, invalid tool should set isError');

  // =========================================================
  // TEST 16: Resources List
  // =========================================================
  R := RunTest('16. Resources List',
    '{"jsonrpc":"2.0","id":30,"method":"resources/list","params":{}}');
  AddResult(R);
  PrintResult(R);

  // =========================================================
  // TEST 17: Prompts List
  // =========================================================
  R := RunTest('17. Prompts List',
    '{"jsonrpc":"2.0","id":31,"method":"prompts/list","params":{}}');
  AddResult(R);
  PrintResult(R);

  // =========================================================
  // TEST 18: Unknown MCP method (should return MethodNotFound error)
  // =========================================================
  R := RunTest('18. Unknown Method (expect error)',
    '{"jsonrpc":"2.0","id":32,"method":"foo/bar","params":{}}', True);
  AddResult(R);
  PrintResult(R);

  // =========================================================
  // TEST 19: tools/call before re-init (already initialized, should work)
  // Goto definition on SysUtils (line 10, char 2)
  // =========================================================
  ArgsJson := Format('{"uri":"%s","line":9,"character":4}', [SourceUri]);
  R := RunTest('19. Goto Definition (SysUtils, line 10)',
    ToolCallRequest(33, 'delphi_goto_definition', ArgsJson));
  AddResult(R);
  PrintResult(R);
  Text := GetToolResultText(R.ResponseJson);
  WriteLn('  Tool result text: ', Text);

  // =========================================================
  // TEST 20: Shutdown
  // =========================================================
  R := RunTest('20. Shutdown',
    '{"jsonrpc":"2.0","id":99,"method":"shutdown","params":{}}');
  AddResult(R);
  PrintResult(R);
end;

procedure PrintFinalSummary;
var
  I, Passed, Failed: Integer;
begin
  PrintHeader('FINAL SUMMARY');
  Passed := 0;
  Failed := 0;

  for I := 0 to ResultCount - 1 do
  begin
    PrintResult(AllResults[I]);
    if AllResults[I].Passed then
      Inc(Passed)
    else
      Inc(Failed);
  end;

  WriteLn;
  WriteLn(Format('Total: %d | Passed: %d | Failed: %d', [Passed + Failed, Passed, Failed]));

  if Failed = 0 then
    WriteLn('ALL TESTS PASSED!')
  else
    WriteLn('SOME TESTS FAILED!');

  // Detailed analysis of failures
  if Failed > 0 then
  begin
    WriteLn;
    WriteLn('--- FAILURE DETAILS ---');
    for I := 0 to ResultCount - 1 do
    begin
      if not AllResults[I].Passed then
      begin
        WriteLn;
        WriteLn('FAILED: ', AllResults[I].Name);
        WriteLn('  Reason: ', AllResults[I].Details);
        if AllResults[I].ResponseJson <> '' then
          WriteLn('  Response: ', Copy(AllResults[I].ResponseJson, 1, 300));
      end;
    end;
  end;
end;

begin
  SetConsoleOutputCP(CP_UTF8);
  SetConsoleCP(CP_UTF8);

  WriteLn('==============================================');
  WriteLn('  Delphi LSP MCP Server - Comprehensive Test');
  WriteLn('==============================================');
  WriteLn;

  // Build the file URI for SourceForAnalysis.dpr
  SourceUri := BuildSourceUri;
  WriteLn('Source file: ', ExpandFileName(SOURCE_FILE));
  WriteLn('Source URI:  ', SourceUri);
  WriteLn;

  // Check source file exists
  if not FileExists(SOURCE_FILE) then
  begin
    WriteLn('ERROR: Source file not found: ', SOURCE_FILE);
    WriteLn('Make sure SourceForAnalysis.dpr is in the same directory.');
    WriteLn;
    WriteLn('Press ENTER to exit...');
    ReadLn;
    Exit;
  end;

  // Start the MCP server
  WriteLn('Starting MCP server...');
  if not StartServer then
  begin
    WriteLn('ERROR: Could not start server.');
    WriteLn('Make sure DelphiLSPMCPServer.exe is in the same directory.');
    WriteLn;
    WriteLn('Press ENTER to exit...');
    ReadLn;
    Exit;
  end;
  WriteLn('Server started, PID: ', GetProcessId(ProcessHandle));

  // Wait for server to be ready
  Sleep(1000);

  // Run all tests
  RunAllTests;

  // Print summary
  PrintFinalSummary;

  // Cleanup
  Cleanup;

  WriteLn;
  WriteLn('Press ENTER to exit...');
  ReadLn;
end.
