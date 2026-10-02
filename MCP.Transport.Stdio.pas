unit MCP.Transport.Stdio;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Winapi.Windows,
  Common.Logging;

type
  TMessageReceivedEvent = procedure(const AMessage: string) of object;

  TMCPStdioTransport = class
  private
    FStdinHandle: THandle;
    FStdoutHandle: THandle;
    FRunningFlag: Integer;
    FLock: TCriticalSection;
    FOnMessageReceived: TMessageReceivedEvent;
    FReadThread: TThread;
    FDebugMode: Boolean;
    FMessageCount: Int64;
    FBytesSent: Int64;
    FBytesReceived: Int64;
    FLogContext: ILogContext;
    FLastMessageTime: TDateTime;
    FLastErrorTime: TDateTime;
    FErrorCount: Integer;

    procedure ReadLoop;
    function ReadMessage: string;
    function GetRunning: Boolean;
    procedure HandleStdinClosed;
    procedure LogDebug(const Msg: string; const Args: array of const);
    procedure LogStats;
    procedure UpdateStats;
    procedure LogTiming(const Operation: string; StartTime: UInt64);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Start;
    procedure Stop;
    procedure SendMessage(const AMessage: string);
    function GetStatistics: string;

    property OnMessageReceived: TMessageReceivedEvent read FOnMessageReceived write FOnMessageReceived;
    property Running: Boolean read GetRunning;
    property DebugMode: Boolean read FDebugMode write FDebugMode;
  end;

implementation

type
  TStdioReadThread = class(TThread)
  private
    FTransport: TMCPStdioTransport;
  protected
    procedure Execute; override;
  public
    constructor Create(ATransport: TMCPStdioTransport);
  end;

{ TMCPStdioTransport }

constructor TMCPStdioTransport.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FStdinHandle := GetStdHandle(STD_INPUT_HANDLE);
  FStdoutHandle := GetStdHandle(STD_OUTPUT_HANDLE);
  TInterlocked.Exchange(FRunningFlag, 0);
  FMessageCount := 0;
  FBytesSent := 0;
  FBytesReceived := 0;
  FErrorCount := 0;
  FDebugMode := False;
  FLogContext := Logger.CreateContext('StdioTransport');

  FLogContext.Enter('Create');
  try
    LogDebug('Stdio transport created - stdin: %d, stdout: %d',
      [FStdinHandle, FStdoutHandle]);
  finally
    FLogContext.Exit('Create');
  end;
end;

destructor TMCPStdioTransport.Destroy;
begin
  FLogContext.Enter('Destroy');
  try
    LogStats;
    Stop;
    LogDebug('Stdio transport destroyed - Total messages: %d, Errors: %d, Bytes sent: %d, Bytes received: %d',
      [FMessageCount, FErrorCount, FBytesSent, FBytesReceived]);
  finally
    FLogContext.Exit('Destroy');
    FLock.Free;
    inherited;
  end;
end;

procedure TMCPStdioTransport.LogTiming(const Operation: string; StartTime: UInt64);
var
  ElapsedMs: Integer;
begin
  if FDebugMode then
  begin
    ElapsedMs := (GetTickCount64 - StartTime);
    Logger.Debug('[StdioTransport Timing] %s took %d ms', [Operation, ElapsedMs]);
  end;
end;

procedure TMCPStdioTransport.LogDebug(const Msg: string; const Args: array of const);
begin
  if FDebugMode then
  begin
    if Length(Args) > 0 then
      FLogContext.LogFmt(Msg, Args)
    else
      FLogContext.Log(Msg);
  end;
end;

procedure TMCPStdioTransport.UpdateStats;
begin
  FLastMessageTime := Now;
end;

procedure TMCPStdioTransport.LogStats;
begin
  if not FDebugMode then
    Exit;

  Logger.Info('[StdioTransport Statistics]');
  Logger.Info('  Total messages: %d', [FMessageCount]);
  Logger.Info('  Total errors: %d', [FErrorCount]);
  Logger.Info('  Bytes sent: %d', [FBytesSent]);
  Logger.Info('  Bytes received: %d', [FBytesReceived]);
  if FLastMessageTime > 0 then
    Logger.Info('  Last message: %s', [DateTimeToStr(FLastMessageTime)]);
  if FLastErrorTime > 0 then
	Logger.Info('  Last error: %s', [DateTimeToStr(FLastErrorTime)]);
end;

function TMCPStdioTransport.GetStatistics: string;
begin
  Result := Format('Messages: %d, Errors: %d, Sent: %d bytes, Received: %d bytes',
    [FMessageCount, FErrorCount, FBytesSent, FBytesReceived]);
end;

function TMCPStdioTransport.GetRunning: Boolean;
begin
  Result := TInterlocked.CompareExchange(FRunningFlag, 0, 0) <> 0;
end;

procedure TMCPStdioTransport.Start;
begin
  FLogContext.Enter('Start');
  try
    if GetRunning then
    begin
      LogDebug('Start called but already running', []);
      Exit;
    end;

    Assert(FReadThread = nil, 'FReadThread must be nil when stopped');

    TInterlocked.Exchange(FRunningFlag, 1);
    FReadThread := TStdioReadThread.Create(Self);
    FReadThread.Start;

    Logger.Info('MCP stdio transport started');
    LogDebug('Read thread created and started - Handle: %d', [FReadThread.Handle]);
  finally
    FLogContext.Exit('Start');
  end;
end;

procedure TMCPStdioTransport.Stop;
var
  WaitResult: DWORD;
  StartTime: UInt64;
begin
  FLogContext.Enter('Stop');
  StartTime := GetTickCount64;

  try
    if TInterlocked.Exchange(FRunningFlag, 0) = 0 then
    begin
      LogDebug('Stop called but already stopped', []);
      Exit;
    end;

    LogDebug('Stopping transport, cancelling I/O operations', []);

    // Cancel any pending I/O on stdin
    if FStdinHandle <> INVALID_HANDLE_VALUE then
    begin
      if CancelIo(FStdinHandle) then
        LogDebug('CancelIo succeeded on stdin handle', [])
      else
        LogDebug('CancelIo failed with error: %d', [GetLastError]);
    end;

    if Assigned(FReadThread) then
    begin
      LogDebug('Waiting for read thread to terminate (timeout: 3000ms)', []);
	  FReadThread.Terminate;

      WaitResult := WaitForSingleObject(FReadThread.Handle, 3000);
      case WaitResult of
        WAIT_OBJECT_0:
          LogDebug('Read thread terminated gracefully', []);
        WAIT_TIMEOUT:
          begin
            Logger.Warning('Read thread timeout after 3000ms, forcing termination');
            LogDebug('Read thread timeout, forcing termination', []);
            TerminateThread(FReadThread.Handle, 0);
          end;
        WAIT_FAILED:
          LogDebug('WaitForSingleObject failed with error: %d', [GetLastError]);
      end;

      FreeAndNil(FReadThread);
      LogDebug('Read thread freed', []);
    end;

    LogTiming('Stop', StartTime);
    Logger.Info('MCP stdio transport stopped');
  finally
    FLogContext.Exit('Stop');
  end;
end;

procedure TMCPStdioTransport.HandleStdinClosed;
begin
  FLogContext.Enter('HandleStdinClosed');
  try
    Logger.Info('Stdin closed, shutting down...');
    LogDebug('Stdin closed detected - initiating shutdown sequence', []);

    // Signal to stop running
    if GetRunning then
    begin
      TInterlocked.Exchange(FRunningFlag, 0);
      LogDebug('Running flag cleared', []);

      // Notify via message if someone wants to handle closure
      if Assigned(FOnMessageReceived) then
      begin
        LogDebug('Notifying listeners with empty message (EOF)', []);
        FOnMessageReceived(''); // Empty message signals EOF
      end;
    end;
  finally
    FLogContext.Exit('HandleStdinClosed');
  end;
end;

procedure TMCPStdioTransport.SendMessage(const AMessage: string);
var
  Utf8Message: UTF8String;
  BytesWritten: DWORD;
  NewLine: AnsiString;
  MessageSize: Integer;
  StartTime: UInt64;
begin
  if not GetRunning then
  begin
    LogDebug('SendMessage called but transport not running', []);
    Exit;
  end;

  StartTime := GetTickCount64;
  FLock.Enter;
  try
    Utf8Message := UTF8Encode(AMessage);
    NewLine := #13#10;
    MessageSize := Length(Utf8Message) + Length(NewLine);

    LogDebug('Sending message - size: %d bytes', [MessageSize]);

    // Write content
    if not WriteFile(FStdoutHandle, PAnsiChar(Utf8Message)^, Length(Utf8Message), BytesWritten, nil) then
    begin
      Inc(FErrorCount);
      FLastErrorTime := Now;
      if GetRunning then
        Logger.Error('Failed to write message to stdout - Error: %d', [GetLastError]);
      LogDebug('WriteFile failed for message content - Error: %d', [GetLastError]);
      Exit;
    end;

    // Write newline separator
    if not WriteFile(FStdoutHandle, PAnsiChar(NewLine)^, Length(NewLine), BytesWritten, nil) then
    begin
      Inc(FErrorCount);
      FLastErrorTime := Now;
      if GetRunning then
        Logger.Error('Failed to write newline to stdout - Error: %d', [GetLastError]);
      LogDebug('WriteFile failed for newline - Error: %d', [GetLastError]);
      Exit;
    end;

    FlushFileBuffers(FStdoutHandle);

    // Update statistics
    Inc(FMessageCount);
    FBytesSent := FBytesSent + MessageSize;
    UpdateStats;

    LogTiming('SendMessage', StartTime);
    if FDebugMode then
      Logger.Debug('Sent message (%d bytes): %s', [MessageSize, Copy(AMessage, 1, 200)]);

  finally
    FLock.Leave;
  end;
end;

procedure TMCPStdioTransport.ReadLoop;
var
  Message: string;
  PeekBuffer: array[0..0] of Byte;
  PeekResult: BOOL;
  StdinClosed: Boolean;
  LoopCount: Integer;
  LastActivityTime: UInt64;
begin
  StdinClosed := False;
  LoopCount := 0;
  LastActivityTime := GetTickCount64;

  FLogContext.Enter('ReadLoop');
  LogDebug('ReadLoop started', []);

  try
    while GetRunning and not StdinClosed do
	begin
      Inc(LoopCount);

      try
        // Periodic statistics logging (every 1000 loops)
        if FDebugMode and (LoopCount mod 1000 = 0) then
          LogDebug('ReadLoop iteration %d - Running: %s', [LoopCount, BoolToStr(GetRunning, True)]);

        // First, peek to see if stdin is still open
        PeekResult := PeekNamedPipe(FStdinHandle, @PeekBuffer, 0, nil, nil, nil);
        if not PeekResult then
        begin
          // PeekNamedPipe failed - pipe is broken or closed
          if GetLastError = ERROR_BROKEN_PIPE then
          begin
            LogDebug('Stdin pipe broken detected via PeekNamedPipe', []);
            StdinClosed := True;
            Break;
          end;
        end;

        // Try to read a complete message
        Message := ReadMessage;

        if Message = '' then
        begin
          // Empty message could be EOF or timeout
          // Check if stdin is still valid
          PeekResult := PeekNamedPipe(FStdinHandle, @PeekBuffer, 0, nil, nil, nil);
          if not PeekResult and (GetLastError = ERROR_BROKEN_PIPE) then
          begin
            LogDebug('Stdin closed detected (empty message + broken pipe)', []);
            StdinClosed := True;
            Break;
          end;

          // Log if no activity for 60 seconds
          if GetTickCount64 - LastActivityTime > 60000 then
          begin
            LogDebug('No activity on stdin for 60 seconds', []);
            LastActivityTime := GetTickCount64;
		  end;

          // Small sleep to prevent CPU spin
          if GetRunning then
            Sleep(10);
          Continue;
        end;

        // Reset activity timer
        LastActivityTime := GetTickCount64;

        // Update statistics
        Inc(FMessageCount);
        FBytesReceived := FBytesReceived + Length(Message);
        UpdateStats;

        LogDebug('Received message (%d bytes): %s', [Length(Message), Copy(Message, 1, 200)]);

        if Assigned(FOnMessageReceived) then
		  FOnMessageReceived(Message)
        else
          LogDebug('No message handler assigned', []);

      except
        on E: Exception do
		begin
          Inc(FErrorCount);
          FLastErrorTime := Now;
          if GetRunning then
          begin
            Logger.Error('Error reading message: %s', [E.Message]);
            LogDebug('Exception in ReadLoop: %s - %s', [E.ClassName, E.Message]);
          end;
          Break;
        end;
      end;
    end;

    LogDebug('ReadLoop exiting - StdinClosed: %s, Running: %s',
      [BoolToStr(StdinClosed, True), BoolToStr(GetRunning, True)]);

  finally
    // Stdin closed - initiate shutdown
    if StdinClosed then
      HandleStdinClosed;

    FLogContext.Exit('ReadLoop');
  end;
end;

function TMCPStdioTransport.ReadMessage: string;
var
  Line: AnsiString;
  Ch: AnsiChar;
  BytesRead: DWORD;
  ContentLength: Integer;
  Buffer: TBytes;
  TotalRead: DWORD;
  Utf8Str: UTF8String;
  ReadRes: Boolean;
  StartTime: UInt64;
  HeaderReadTime: UInt64;
begin
  Result := '';
  ContentLength := -1;
  Line := '';
  StartTime := GetTickCount64;
  HeaderReadTime := StartTime;

  LogDebug('ReadMessage started', []);

  // 1. Read headers OR detect raw JSON with timeout
  while GetRunning do
  begin
    // Add timeout to prevent infinite blocking
    if GetTickCount64 - StartTime > 30000 then // 30 second timeout
    begin
      LogDebug('ReadMessage timeout after 30 seconds', []);
      Logger.Debug('ReadMessage timeout after 30 seconds');
      Exit;
    end;

    ReadRes := ReadFile(FStdinHandle, Ch, 1, BytesRead, nil);
    if not ReadRes or (BytesRead = 0) then
    begin
      if GetRunning and (GetLastError <> ERROR_OPERATION_ABORTED) then
      begin
        Logger.Info('Stdin closed or broken pipe during read - Error: %d', [GetLastError]);
        LogDebug('Stdin closed during header read - Error: %d', [GetLastError]);
        TInterlocked.Exchange(FRunningFlag, 0);
      end;
	  Exit;
    end;

    if Ch = #10 then // LF
    begin
      Line := AnsiString(Trim(string(Line)));

      // Empty line signals end of headers if we have a Content-Length
      if Line = '' then
      begin
        if ContentLength >= 0 then
        begin
          LogDebug('Headers complete - Content-Length: %d, parsing time: %d ms',
            [ContentLength, GetTickCount64 - HeaderReadTime]);
          Break; // Proceed to read body
        end;
      end
      // Parse Content-Length header
      else if Pos('Content-Length:', string(Line)) = 1 then
      begin
        Delete(Line, 1, 15);
        ContentLength := StrToIntDef(string(Trim(string(Line))), -1);
        LogDebug('Parsed Content-Length: %d', [ContentLength]);
      end
      // Detect raw JSON (Standard MCP behavior)
      else if (Line <> '') and (Line[1] = '{') then
      begin
        Result := UTF8ToString(UTF8String(Line));
        LogDebug('Detected raw JSON message (no Content-Length): %d bytes', [Length(Result)]);
        Exit;
      end;

      Line := '';
    end
    else if Ch <> #13 then // Ignore CR
      Line := Line + Ch;

    // Safety: don't let a single line grow indefinitely
    if Length(Line) > 1024 * 1024 then
    begin
      Logger.Warning('Header line exceeded 1MB, discarding');
      LogDebug('Header line exceeded 1MB, discarding', []);
      Line := '';
    end;
  end;

  // 2. Read body if we got a Content-Length from headers
  if (ContentLength >= 0) and GetRunning then
  begin
    if ContentLength = 0 then
    begin
      LogDebug('Empty message body (Content-Length: 0)', []);
      Result := '';
      Exit;
    end;

    // Add size limit check
    if ContentLength > 50 * 1024 * 1024 then // 50MB max
    begin
      Logger.Error('Message too large: %d bytes', [ContentLength]);
      LogDebug('Message too large: %d bytes (max: 50MB)', [ContentLength]);
      Exit;
    end;

    SetLength(Buffer, ContentLength);
    TotalRead := 0;
	StartTime := GetTickCount64;

    LogDebug('Reading message body - Expected: %d bytes', [ContentLength]);

    while (TotalRead < DWORD(ContentLength)) and GetRunning do
    begin
      // Add timeout for body read
      if GetTickCount64 - StartTime > 30000 then
      begin
        Logger.Error('Message body read timeout after 30 seconds');
        LogDebug('Message body read timeout - Read %d of %d bytes', [TotalRead, ContentLength]);
        Exit;
      end;

      if not ReadFile(FStdinHandle, Buffer[TotalRead], DWORD(ContentLength) - TotalRead, BytesRead, nil) then
      begin
        if GetLastError <> ERROR_OPERATION_ABORTED then
        begin
          Logger.Error('Failed to read message body - Error: %d', [GetLastError]);
          LogDebug('ReadFile failed for body - Error: %d', [GetLastError]);
        end;
        Exit;
      end;

      if BytesRead = 0 then
      begin
		LogDebug('ReadFile returned 0 bytes - unexpected EOF', []);
        Break;
      end;

      Inc(TotalRead, BytesRead);
      if FDebugMode and (TotalRead mod (1024 * 1024) = 0) then
        LogDebug('Progress: %d%% complete', [(TotalRead * 100) div ContentLength]);
    end;

    if TotalRead = DWORD(ContentLength) then
    begin
      SetLength(Utf8Str, ContentLength);
      Move(Buffer[0], Utf8Str[1], ContentLength);
      Result := UTF8ToString(Utf8Str);
      LogDebug('Message body read complete - %d bytes in %d ms',
        [ContentLength, GetTickCount64 - StartTime]);
    end
    else
    begin
      Logger.Error('Incomplete message body: expected %d bytes, got %d', [ContentLength, TotalRead]);
      LogDebug('Incomplete message body - Expected: %d, Got: %d', [ContentLength, TotalRead]);
    end;
  end;
end;

{ TStdioReadThread }

constructor TStdioReadThread.Create(ATransport: TMCPStdioTransport);
begin
  inherited Create(True);
  FTransport := ATransport;
  FreeOnTerminate := False;
end;

procedure TStdioReadThread.Execute;
begin
  if Assigned(FTransport) then
    FTransport.ReadLoop;
end;

end.
