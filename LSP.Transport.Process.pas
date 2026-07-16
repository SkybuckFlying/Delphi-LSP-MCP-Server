unit LSP.Transport.Process;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs,
  Winapi.Windows, Common.Logging;

type
  TLSPMessageReceivedEvent = procedure(const AMessage: string) of object;
  TLSPErrorEvent = procedure(const AError: string) of object;

  TLSPProcessTransport = class
  private
    FProcessPath: string;
    FProcessHandle: THandle;
    FStdinWrite: THandle;
    FStdoutRead: THandle;
    FStderrRead: THandle;
    FRunning: Integer; // atomic flag
    FLock: TCriticalSection;
    FOnMessageReceived: TLSPMessageReceivedEvent;
    FOnError: TLSPErrorEvent;
    FReadThread: TThread;
    FErrorThread: TThread;
    FMonitorThread: TThread;
    FDebugMode: Boolean;
    FLogContext: ILogContext;

    // Statistics
    FMessagesSent: Integer;
    FMessagesReceived: Integer;
    FBytesSent: Int64;
    FBytesReceived: Int64;
    FErrors: Integer;
    FLastErrorTime: TDateTime;
    FStartTime: TDateTime;

    procedure ReadLoop;
    procedure ErrorLoop;
    procedure MonitorLoop;
    function ReadMessage: string;
    function ReadHeaders(AHandle: THandle; out ContentLength: Integer; out ContentType: string): Boolean;
    function StartProcess: Boolean;
    procedure StopProcess;
    procedure SetRunning(AValue: Boolean);
    function GetRunning: Boolean;
    procedure HandleProcessExit;
    procedure SafeCloseHandle(var AHandle: THandle);
    procedure LogDebug(const Msg: string; const Args: array of const);
    procedure LogStats;
    function GetProcessInfo: string;
  public
    constructor Create(const AProcessPath: string);
    destructor Destroy; override;

    function Start: Boolean;
    procedure Stop;
    function SendMessage(const AMessage: string): Boolean;
    function GetStatistics: string;

	property IsRunning: Boolean read GetRunning;
    property DebugMode: Boolean read FDebugMode write FDebugMode;

    // Called from worker threads; synchronize if touching UI.
    property OnMessageReceived: TLSPMessageReceivedEvent read FOnMessageReceived write FOnMessageReceived;
    property OnError: TLSPErrorEvent read FOnError write FOnError;
  end;

implementation

uses
  System.NetEncoding,
  System.StrUtils;

const
  LSP_PIPE_BUFFER_SIZE = 64 * 1024;
  MAX_MESSAGE_SIZE = 32 * 1024 * 1024; // 32MB
  HEADER_READ_TIMEOUT_MS = 30000; // 30s
  BODY_READ_TIMEOUT_MS = 30000; // 30s
  MAX_HEADER_LINE_LENGTH = 8192; // 8KB;

type
  TLSPReadThread = class(TThread)
  private
    FTransport: TLSPProcessTransport;
  protected
    procedure Execute; override;
  public
    constructor Create(ATransport: TLSPProcessTransport);
  end;

  TLSPErrorThread = class(TThread)
  private
    FTransport: TLSPProcessTransport;
  protected
    procedure Execute; override;
  public
    constructor Create(ATransport: TLSPProcessTransport);
  end;

  TLSPMonitorThread = class(TThread)
  private
	FTransport: TLSPProcessTransport;
  protected
    procedure Execute; override;
  public
    constructor Create(ATransport: TLSPProcessTransport);
  end;

{ TLSPProcessTransport }

constructor TLSPProcessTransport.Create(const AProcessPath: string);
begin
  inherited Create;
  FLogContext := Logger.CreateContext('LSPProcess');
  FLogContext.Enter('Create');

  try
    FProcessPath := AProcessPath;
    FLock := TCriticalSection.Create;
    FProcessHandle := 0;
    FStdinWrite := 0;
    FStdoutRead := 0;
    FStderrRead := 0;
    SetRunning(False);
    FDebugMode := False;
    FMessagesSent := 0;
    FMessagesReceived := 0;
    FBytesSent := 0;
    FBytesReceived := 0;
	FErrors := 0;
    FStartTime := Now;

    LogDebug('LSP Process Transport created for: %s', [AProcessPath]);
  finally
    FLogContext.Exit('Create');
  end;
end;

destructor TLSPProcessTransport.Destroy;
begin
  FLogContext.Enter('Destroy');
  try
    LogStats;
    Stop;
    LogDebug('LSP Process Transport destroyed - Stats: Msgs Sent=%d, Received=%d, Errors=%d',
      [FMessagesSent, FMessagesReceived, FErrors]);
    FLock.Free;
  finally
    FLogContext.Exit('Destroy');
    inherited;
  end;
end;

procedure TLSPProcessTransport.LogDebug(const Msg: string; const Args: array of const);
begin
  if FDebugMode then
  begin
    if Length(Args) > 0 then
      FLogContext.LogFmt(Msg, Args)
    else
      FLogContext.Log(Msg);
  end;
end;

procedure TLSPProcessTransport.LogStats;
begin
  if not FDebugMode then
	Exit;

  Logger.Info('[LSPProcess Statistics]');
  Logger.Info('  Uptime: %s', [FormatDateTime('hh:nn:ss', Now - FStartTime)]);
  Logger.Info('  Messages Sent: %d', [FMessagesSent]);
  Logger.Info('  Messages Received: %d', [FMessagesReceived]);
  Logger.Info('  Bytes Sent: %d', [FBytesSent]);
  Logger.Info('  Bytes Received: %d', [FBytesReceived]);
  Logger.Info('  Errors: %d', [FErrors]);
  if FLastErrorTime > 0 then
    Logger.Info('  Last Error: %s', [DateTimeToStr(FLastErrorTime)]);
end;

function TLSPProcessTransport.GetStatistics: string;
begin
  Result := Format('LSP Process: Msg Sent=%d, Msg Recv=%d, Bytes Sent=%d, Bytes Recv=%d, Errors=%d',
    [FMessagesSent, FMessagesReceived, FBytesSent, FBytesReceived, FErrors]);
end;

function TLSPProcessTransport.GetProcessInfo: string;
begin
  if FProcessHandle <> 0 then
    Result := Format('PID=%d', [GetProcessId(FProcessHandle)])
  else
    Result := 'No process';
end;

procedure TLSPProcessTransport.SetRunning(AValue: Boolean);
begin
  TInterlocked.Exchange(FRunning, Ord(AValue));
  LogDebug('Running flag set to: %s', [BoolToStr(AValue, True)]);
end;

function TLSPProcessTransport.GetRunning: Boolean;
begin
  Result := TInterlocked.CompareExchange(FRunning, 0, 0) <> 0;
end;

procedure TLSPProcessTransport.SafeCloseHandle(var AHandle: THandle);
begin
  if AHandle <> 0 then
  begin
    LogDebug('Closing handle: %d', [AHandle]);
    CloseHandle(AHandle);
    AHandle := 0;
  end;
end;

function TLSPProcessTransport.Start: Boolean;
begin
  FLogContext.Enter('Start');
  Result := True;

  try
    if GetRunning then
    begin
      LogDebug('Start called but already running', []);
      Exit;
    end;

    LogDebug('Starting LSP process: %s', [FProcessPath]);

    if not StartProcess then
    begin
      Logger.Error('Failed to start LSP process: %s', [FProcessPath]);
      LogDebug('StartProcess failed', []);
	  Result := False;
      Exit;
    end;

    SetRunning(True);

    LogDebug('Creating read thread', []);
    FReadThread := TLSPReadThread.Create(Self);
    FReadThread.Start;

    LogDebug('Creating error thread', []);
    FErrorThread := TLSPErrorThread.Create(Self);
    FErrorThread.Start;

    LogDebug('Creating monitor thread', []);
    FMonitorThread := TLSPMonitorThread.Create(Self);
    FMonitorThread.Start;

	Logger.Info('LSP process transport started: %s (%s)', [FProcessPath, GetProcessInfo]);
    LogDebug('All threads created and started', []);

  finally
    FLogContext.Exit('Start');
  end;
end;

procedure TLSPProcessTransport.Stop;
var
  StartTime: UInt64;
  WaitResult: DWORD;
begin
  StartTime := GetTickCount64;
  FLogContext.Enter('Stop');

  try
    if not GetRunning then
    begin
      LogDebug('Stop called but not running', []);
      Exit;
    end;

    LogDebug('Stopping transport', []);
    SetRunning(False);

    // Unblock any blocking ReadFile/WriteFile by closing handles first
    LogDebug('Closing handles to unblock I/O', []);
    SafeCloseHandle(FStdinWrite); // EOF to server
    SafeCloseHandle(FStdoutRead); // unblock ReadLoop
    SafeCloseHandle(FStderrRead); // unblock ErrorLoop

    if Assigned(FReadThread) then
    begin
      LogDebug('Waiting for read thread to terminate', []);
      WaitResult := WaitForSingleObject(FReadThread.Handle, 3000);
      if WaitResult = WAIT_TIMEOUT then
        Logger.Warning('Read thread timeout');
      FreeAndNil(FReadThread);
    end;

    if Assigned(FErrorThread) then
    begin
      LogDebug('Waiting for error thread to terminate', []);
      WaitResult := WaitForSingleObject(FErrorThread.Handle, 3000);
      if WaitResult = WAIT_TIMEOUT then
        Logger.Warning('Error thread timeout');
      FreeAndNil(FErrorThread);
	end;

    if Assigned(FMonitorThread) then
    begin
      LogDebug('Waiting for monitor thread to terminate', []);
      WaitResult := WaitForSingleObject(FMonitorThread.Handle, 3000);
      if WaitResult = WAIT_TIMEOUT then
        Logger.Warning('Monitor thread timeout');
      FreeAndNil(FMonitorThread);
    end;

    StopProcess;
    Logger.Info('LSP process transport stopped in %d ms', [GetTickCount64 - StartTime]);

  finally
    FLogContext.Exit('Stop');
  end;
end;

function TLSPProcessTransport.StartProcess: Boolean;
var
  SA: TSecurityAttributes;
  StdinRead, StdoutWrite, StderrWrite: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: string;
begin
  Result := False;
  StdinRead := 0;
  StdoutWrite := 0;
  StderrWrite := 0;

  LogDebug('Creating pipes for LSP process', []);

  try
    SA.nLength := SizeOf(TSecurityAttributes);
    SA.bInheritHandle := True;
    SA.lpSecurityDescriptor := nil;

    if not CreatePipe(StdinRead, FStdinWrite, @SA, LSP_PIPE_BUFFER_SIZE) then
    begin
      Logger.Error('Failed to create stdin pipe: %d', [GetLastError]);
      LogDebug('CreatePipe stdin failed: %d', [GetLastError]);
      Exit;
    end;
    SetHandleInformation(FStdinWrite, HANDLE_FLAG_INHERIT, 0);
    LogDebug('Stdin pipe created - read: %d, write: %d', [StdinRead, FStdinWrite]);

    if not CreatePipe(FStdoutRead, StdoutWrite, @SA, LSP_PIPE_BUFFER_SIZE) then
    begin
      Logger.Error('Failed to create stdout pipe: %d', [GetLastError]);
      LogDebug('CreatePipe stdout failed: %d', [GetLastError]);
      Exit;
    end;
    SetHandleInformation(FStdoutRead, HANDLE_FLAG_INHERIT, 0);
    LogDebug('Stdout pipe created - read: %d, write: %d', [FStdoutRead, StdoutWrite]);

    if not CreatePipe(FStderrRead, StderrWrite, @SA, LSP_PIPE_BUFFER_SIZE) then
    begin
      Logger.Error('Failed to create stderr pipe: %d', [GetLastError]);
      LogDebug('CreatePipe stderr failed: %d', [GetLastError]);
      Exit;
    end;
    SetHandleInformation(FStderrRead, HANDLE_FLAG_INHERIT, 0);
    LogDebug('Stderr pipe created - read: %d, write: %d', [FStderrRead, StderrWrite]);

	ZeroMemory(@SI, SizeOf(TStartupInfo));
    SI.cb := SizeOf(TStartupInfo);
    SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    SI.wShowWindow := SW_HIDE;
    SI.hStdInput := StdinRead;
    SI.hStdOutput := StdoutWrite;
    SI.hStdError := StderrWrite;

	CmdLine := '"' + FProcessPath + '"';
    UniqueString(CmdLine);
    ZeroMemory(@PI, SizeOf(TProcessInformation));

    LogDebug('Creating LSP process with command line: %s', [CmdLine]);

    if not CreateProcess(
      nil,
      PChar(CmdLine),
      nil,
      nil,
      True,
      CREATE_NO_WINDOW,
      nil,
      nil,
      SI,
      PI) then
    begin
      Logger.Error('Failed to create LSP process: %s (Error: %d)', [FProcessPath, GetLastError]);
      LogDebug('CreateProcess failed: %d', [GetLastError]);
      Exit;
    end;

    FProcessHandle := PI.hProcess;
    CloseHandle(PI.hThread);
    Result := True;

    Logger.Info('LSP process started successfully (PID: %d)', [GetProcessId(FProcessHandle)]);
    LogDebug('Process created - Handle: %d, PID: %d', [FProcessHandle, GetProcessId(FProcessHandle)]);

  finally
    if StdinRead <> 0 then CloseHandle(StdinRead);
    if StdoutWrite <> 0 then CloseHandle(StdoutWrite);
    if StderrWrite <> 0 then CloseHandle(StderrWrite);
    if not Result then
    begin
      SafeCloseHandle(FStdinWrite);
      SafeCloseHandle(FStdoutRead);
      SafeCloseHandle(FStderrRead);
    end;
  end;
end;

procedure TLSPProcessTransport.StopProcess;
begin
  LogDebug('Stopping LSP process', []);

  if FProcessHandle <> 0 then
  begin
    LogDebug('Waiting for process to exit (timeout: 2000ms)', []);
    if WaitForSingleObject(FProcessHandle, 2000) = WAIT_TIMEOUT then
    begin
      Logger.Warning('LSP process did not exit gracefully, terminating');
      LogDebug('Terminating process', []);
      TerminateProcess(FProcessHandle, 1);
    end
    else
      LogDebug('Process exited gracefully', []);

    SafeCloseHandle(FProcessHandle);
  end;

  // Defensive cleanup
  SafeCloseHandle(FStdinWrite);
  SafeCloseHandle(FStdoutRead);
  SafeCloseHandle(FStderrRead);
end;

function TLSPProcessTransport.SendMessage(const AMessage: string): Boolean;
var
  Utf8Bytes: TBytes;
  Header: AnsiString;
  BytesWritten, TotalWritten: DWORD;
  StartTime: UInt64;
begin
  Result := False;

  if not GetRunning then
  begin
    LogDebug('SendMessage called but not running', []);
    Logger.Warning('Cannot send message: LSP process not running');
    Exit;
  end;

  // Check if process already exited
  if (FProcessHandle <> 0) and (WaitForSingleObject(FProcessHandle, 0) = WAIT_OBJECT_0) then
  begin
    LogDebug('Process already exited', []);
    HandleProcessExit;
    Exit;
  end;

  FLock.Enter;
  try
    Utf8Bytes := TEncoding.UTF8.GetBytes(AMessage);
    Header := AnsiString(Format('Content-Length: %d'#13#10#13#10, [Length(Utf8Bytes)]));

    LogDebug('Sending message - Size: %d bytes', [Length(Utf8Bytes)]);

    // Header write
    if not WriteFile(FStdinWrite, PAnsiChar(Header)^, Length(Header), BytesWritten, nil) or
       (BytesWritten <> DWORD(Length(Header))) then
    begin
      Inc(FErrors);
      FLastErrorTime := Now;
      Logger.Error('Failed to write message header: %d', [GetLastError]);
      LogDebug('WriteFile header failed: %d', [GetLastError]);
      HandleProcessExit;
      Exit;
    end;

    // Body write with timeout guard
    TotalWritten := 0;
    StartTime := GetTickCount64;
    while TotalWritten < DWORD(Length(Utf8Bytes)) do
    begin
      if GetTickCount64 - StartTime > BODY_READ_TIMEOUT_MS then
      begin
        Inc(FErrors);
        FLastErrorTime := Now;
        Logger.Error('SendMessage body write timeout');
		LogDebug('Body write timeout after %d ms', [GetTickCount64 - StartTime]);
        HandleProcessExit;
		Exit;
      end;

      if not WriteFile(FStdinWrite, Utf8Bytes[TotalWritten],
                       Length(Utf8Bytes) - TotalWritten, BytesWritten, nil) then
      begin
        Inc(FErrors);
        FLastErrorTime := Now;
        Logger.Error('Failed to write message content: %d', [GetLastError]);
        LogDebug('WriteFile body failed: %d', [GetLastError]);
        HandleProcessExit;
        Exit;
      end;

      if BytesWritten = 0 then
      begin
        Inc(FErrors);
        FLastErrorTime := Now;
        Logger.Error('WriteFile wrote 0 bytes');
        LogDebug('WriteFile returned 0 bytes', []);
        HandleProcessExit;
        Exit;
      end;

      Inc(TotalWritten, BytesWritten);
    end;

    FlushFileBuffers(FStdinWrite);

    Inc(FMessagesSent);
    FBytesSent := FBytesSent + Length(Utf8Bytes);

    if FDebugMode then
      Logger.Debug('Sent to LSP (%d bytes): %s', [Length(Utf8Bytes), Copy(AMessage, 1, 200)]);

    LogDebug('Message sent successfully in %d ms', [GetTickCount64 - StartTime]);
    Result := True;

  finally
    FLock.Leave;
  end;
end;

procedure TLSPProcessTransport.ReadLoop;
var
  Message: string;
  StartTime: UInt64;
  LoopCount: Integer;
begin
  LoopCount := 0;
  FLogContext.Enter('ReadLoop');
  LogDebug('ReadLoop started', []);

  try
    while GetRunning do
    begin
      Inc(LoopCount);

	  try
        Message := ReadMessage;
        if Message <> '' then
        begin
          Inc(FMessagesReceived);
          FBytesReceived := FBytesReceived + Length(Message);

		  if FDebugMode then
            Logger.Debug('Received from LSP (%d bytes): %s', [Length(Message), Copy(Message, 1, 200)]);

          if Assigned(FOnMessageReceived) then
            FOnMessageReceived(Message);
        end
        else if not GetRunning then
          Break;

        // Periodic log for active loops
        if FDebugMode and (LoopCount mod 100 = 0) then
          LogDebug('ReadLoop iteration %d - Running: %s', [LoopCount, BoolToStr(GetRunning, True)]);

      except
        on E: Exception do
        begin
          Inc(FErrors);
          FLastErrorTime := Now;
          Logger.Error('Error reading LSP message: %s', [E.Message]);
          LogDebug('Exception in ReadLoop: %s - %s', [E.ClassName, E.Message]);
          HandleProcessExit;
          Break;
        end;
      end;
    end;

    LogDebug('ReadLoop exiting - Total iterations: %d', [LoopCount]);
  finally
    FLogContext.Exit('ReadLoop');
  end;
end;

procedure TLSPProcessTransport.ErrorLoop;
var
  Buffer: array[0..4095] of Byte;
  BytesRead: DWORD;
  ErrorText: string;
  LastError: DWORD;
  Temp: TBytes;
  LoopCount: Integer;
begin
  LoopCount := 0;
  FLogContext.Enter('ErrorLoop');
  LogDebug('ErrorLoop started', []);

  try
    while GetRunning do
    begin
      Inc(LoopCount);

      if ReadFile(FStderrRead, Buffer, SizeOf(Buffer), BytesRead, nil) then
      begin
        if BytesRead > 0 then
        begin
		  SetLength(Temp, BytesRead);
          Move(Buffer[0], Temp[0], BytesRead);
          ErrorText := TEncoding.UTF8.GetString(Temp);
          Logger.Warning('LSP stderr: %s', [Trim(ErrorText)]);
          LogDebug('Stderr output: %s', [Copy(Trim(ErrorText), 1, 200)]);

          if Assigned(FOnError) then
            FOnError(ErrorText);
        end;
      end
      else
      begin
		LastError := GetLastError;
        if (LastError = ERROR_BROKEN_PIPE) or (LastError = ERROR_OPERATION_ABORTED) then
        begin
          LogDebug('Error pipe broken or aborted', []);
          Break;
        end;
        if not GetRunning then
          Break;
        Sleep(10);
      end;

      if FDebugMode and (LoopCount mod 100 = 0) then
        LogDebug('ErrorLoop iteration %d', [LoopCount]);
    end;

    LogDebug('ErrorLoop exiting - Total iterations: %d', [LoopCount]);
  finally
    FLogContext.Exit('ErrorLoop');
  end;
end;

procedure TLSPProcessTransport.MonitorLoop;
var
  Pid: DWORD;
begin
  FLogContext.Enter('MonitorLoop');
  try
    if FProcessHandle <> 0 then
      Pid := GetProcessId(FProcessHandle)
    else
      Pid := 0;

    LogDebug('MonitorLoop started - Monitoring PID: %d', [Pid]);

    if FProcessHandle <> 0 then
    begin
      WaitForSingleObject(FProcessHandle, INFINITE);
      LogDebug('Process handle signaled - process exited', []);
      if GetRunning then
        HandleProcessExit;
    end;
  finally
    FLogContext.Exit('MonitorLoop');
  end;
end;

function TLSPProcessTransport.ReadHeaders(AHandle: THandle; out ContentLength: Integer; out ContentType: string): Boolean;
var
  Line: AnsiString;
  Ch: AnsiChar;
  BytesRead: DWORD;
  LowerLine: string;
  StartTime: UInt64;
begin
  Result := False;
  ContentLength := -1;
  ContentType := 'application/vscode-jsonrpc; charset=utf-8';
  Line := '';
  StartTime := GetTickCount64;

  LogDebug('Reading headers from handle: %d', [AHandle]);

  while GetRunning do
  begin
    if (FProcessHandle <> 0) and (WaitForSingleObject(FProcessHandle, 0) = WAIT_OBJECT_0) then
    begin
      LogDebug('Process exited during header read', []);
      Exit;
    end;

    if GetTickCount64 - StartTime > HEADER_READ_TIMEOUT_MS then
    begin
	  Logger.Error('Header read timeout after %d ms', [HEADER_READ_TIMEOUT_MS]);
      LogDebug('Header read timeout', []);
      Exit;
    end;

    if not ReadFile(AHandle, Ch, 1, BytesRead, nil) or (BytesRead = 0) then
    begin
      LogDebug('ReadFile failed or EOF during header read', []);
      Exit;
    end;

    if Ch = #10 then
    begin
      if (Length(Line) > 0) and (Line[Length(Line)] = #13) then
        SetLength(Line, Length(Line) - 1);

      if Line = '' then
      begin
        Result := ContentLength >= 0;
        if Result then
          LogDebug('Headers complete - Content-Length: %d, Content-Type: %s',
            [ContentLength, ContentType])
        else
          LogDebug('Headers incomplete - missing Content-Length', []);
        Exit;
      end;

      LowerLine := LowerCase(string(Line));
      if Pos('content-length:', LowerLine) = 1 then
      begin
        Delete(Line, 1, 15);
        ContentLength := StrToIntDef(Trim(string(Line)), -1);
        LogDebug('Parsed Content-Length: %d', [ContentLength]);
      end
      else if Pos('content-type:', LowerLine) = 1 then
      begin
        Delete(Line, 1, 13);
        ContentType := Trim(string(Line));
		LogDebug('Parsed Content-Type: %s', [ContentType]);
      end;

      Line := '';
    end
    else if Ch <> #13 then
    begin
      if Length(Line) >= MAX_HEADER_LINE_LENGTH then
      begin
        Logger.Error('Header line too long: %d bytes', [Length(Line)]);
        LogDebug('Header line exceeded max length', []);
        Exit;
      end;
      Line := Line + Ch;
    end;
  end;
end;

function TLSPProcessTransport.ReadMessage: string;
var
  ContentLength: Integer;
  ContentType: string;
  Buffer: TBytes;
  BytesRead, TotalRead: DWORD;
  StartTime: UInt64;
begin
  Result := '';

  LogDebug('Reading message', []);

  if not ReadHeaders(FStdoutRead, ContentLength, ContentType) then
  begin
    LogDebug('ReadHeaders failed', []);
    Exit;
  end;

  if (ContentLength <= 0) or (ContentLength > MAX_MESSAGE_SIZE) then
  begin
    Logger.Error('Invalid Content-Length: %d (max: %d)', [ContentLength, MAX_MESSAGE_SIZE]);
    LogDebug('Invalid Content-Length: %d', [ContentLength]);
    Exit;
  end;

  LogDebug('Reading body - Size: %d bytes', [ContentLength]);

  SetLength(Buffer, ContentLength);
  TotalRead := 0;
  StartTime := GetTickCount64;

  while (TotalRead < DWORD(ContentLength)) and GetRunning do
  begin
    if GetTickCount64 - StartTime > BODY_READ_TIMEOUT_MS then
    begin
      Logger.Error('Message body read timeout after %d ms (read %d of %d bytes)',
        [BODY_READ_TIMEOUT_MS, TotalRead, ContentLength]);
      LogDebug('Body read timeout - Progress: %d/%d bytes', [TotalRead, ContentLength]);
      Exit;
    end;

    if not ReadFile(FStdoutRead, Buffer[TotalRead], DWORD(ContentLength) - TotalRead, BytesRead, nil) then
	begin
      if GetLastError = ERROR_BROKEN_PIPE then
      begin
        LogDebug('Pipe broken during body read', []);
        HandleProcessExit;
      end
      else
        LogDebug('ReadFile failed during body read: %d', [GetLastError]);
      Exit;
    end;

    if BytesRead = 0 then
    begin
      LogDebug('ReadFile returned 0 bytes during body read', []);
      Break;
    end;

    Inc(TotalRead, BytesRead);

    if FDebugMode and (TotalRead mod (1024 * 1024) = 0) then
      LogDebug('Body read progress: %d/%d bytes (%d%%)',
        [TotalRead, ContentLength, (TotalRead * 100) div ContentLength]);
  end;

  if TotalRead = DWORD(ContentLength) then
  begin
    Result := TEncoding.UTF8.GetString(Buffer);
    LogDebug('Message read complete - %d bytes in %d ms',
      [ContentLength, GetTickCount64 - StartTime]);
  end
  else
  begin
    Inc(FErrors);
	FLastErrorTime := Now;
    Logger.Error('Incomplete message body: expected %d bytes, got %d', [ContentLength, TotalRead]);
    LogDebug('Incomplete body - Expected: %d, Got: %d', [ContentLength, TotalRead]);
  end;
end;

procedure TLSPProcessTransport.HandleProcessExit;
begin
  FLogContext.Enter('HandleProcessExit');
  try
    if GetRunning then
    begin
      Logger.Error('LSP process exited unexpectedly');
      LogDebug('Unexpected process exit detected', []);
      SetRunning(False);
    end;
  finally
    FLogContext.Exit('HandleProcessExit');
  end;
end;

{ TLSPReadThread }

constructor TLSPReadThread.Create(ATransport: TLSPProcessTransport);
begin
  inherited Create(True);
  FTransport := ATransport;
  FreeOnTerminate := False;
end;

procedure TLSPReadThread.Execute;
begin
  if Assigned(FTransport) then
    FTransport.ReadLoop;
end;

{ TLSPErrorThread }

constructor TLSPErrorThread.Create(ATransport: TLSPProcessTransport);
begin
  inherited Create(True);
  FTransport := ATransport;
  FreeOnTerminate := False;
end;

procedure TLSPErrorThread.Execute;
begin
  if Assigned(FTransport) then
    FTransport.ErrorLoop;
end;

{ TLSPMonitorThread }

constructor TLSPMonitorThread.Create(ATransport: TLSPProcessTransport);
begin
  inherited Create(True);
  FTransport := ATransport;
  FreeOnTerminate := False;
end;

procedure TLSPMonitorThread.Execute;
begin
  if Assigned(FTransport) then
    FTransport.MonitorLoop;
end;

end.
