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
  public
    constructor Create(const AProcessPath: string);
    destructor Destroy; override;

    function Start: Boolean;
    procedure Stop;
    function SendMessage(const AMessage: string): Boolean;
    property IsRunning: Boolean read GetRunning;

    // Called from worker threads; synchronize if touching UI.
    property OnMessageReceived: TLSPMessageReceivedEvent read FOnMessageReceived write FOnMessageReceived;
    property OnError: TLSPErrorEvent read FOnError write FOnError;
  end;

implementation

uses
  System.NetEncoding;

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
  FProcessPath := AProcessPath;
  FLock := TCriticalSection.Create;
  FProcessHandle := 0;
  FStdinWrite := 0;
  FStdoutRead := 0;
  FStderrRead := 0;
  SetRunning(False);
end;

destructor TLSPProcessTransport.Destroy;
begin
  Stop;
  FLock.Free;
  inherited;
end;

procedure TLSPProcessTransport.SetRunning(AValue: Boolean);
begin
  TInterlocked.Exchange(FRunning, Ord(AValue));
end;

function TLSPProcessTransport.GetRunning: Boolean;
begin
  Result := TInterlocked.CompareExchange(FRunning, 0, 0) <> 0;
end;

procedure TLSPProcessTransport.SafeCloseHandle(var AHandle: THandle);
begin
  if AHandle <> 0 then
  begin
    CloseHandle(AHandle);
    AHandle := 0;
  end;
end;

function TLSPProcessTransport.Start: Boolean;
begin
  Result := True;
  if GetRunning then
    Exit;

  if not StartProcess then
  begin
    Logger.Error('Failed to start LSP process: %s', [FProcessPath]);
    Result := False;
    Exit;
  end;

  SetRunning(True);
  FReadThread := TLSPReadThread.Create(Self);
  FReadThread.Start;
  FErrorThread := TLSPErrorThread.Create(Self);
  FErrorThread.Start;
  FMonitorThread := TLSPMonitorThread.Create(Self);
  FMonitorThread.Start;

  Logger.Info('LSP process transport started: %s', [FProcessPath]);
end;

procedure TLSPProcessTransport.Stop;
begin
  if not GetRunning then
    Exit;

  SetRunning(False);

  // Unblock any blocking ReadFile/WriteFile by closing handles first
  SafeCloseHandle(FStdinWrite); // EOF to server
  SafeCloseHandle(FStdoutRead); // unblock ReadLoop
  SafeCloseHandle(FStderrRead); // unblock ErrorLoop

  if Assigned(FReadThread) then
  begin
    FReadThread.WaitFor;
    FreeAndNil(FReadThread);
  end;

  if Assigned(FErrorThread) then
  begin
    FErrorThread.WaitFor;
    FreeAndNil(FErrorThread);
  end;

  if Assigned(FMonitorThread) then
  begin
    FMonitorThread.WaitFor;
    FreeAndNil(FMonitorThread);
  end;

  StopProcess;
  Logger.Info('LSP process transport stopped');
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

  try
    SA.nLength := SizeOf(TSecurityAttributes);
	SA.bInheritHandle := True;
    SA.lpSecurityDescriptor := nil;

    if not CreatePipe(StdinRead, FStdinWrite, @SA, LSP_PIPE_BUFFER_SIZE) then
    begin
      Logger.Error('Failed to create stdin pipe: %d', [GetLastError]);
      Exit;
    end;
    SetHandleInformation(FStdinWrite, HANDLE_FLAG_INHERIT, 0);

    if not CreatePipe(FStdoutRead, StdoutWrite, @SA, LSP_PIPE_BUFFER_SIZE) then
    begin
      Logger.Error('Failed to create stdout pipe: %d', [GetLastError]);
      Exit;
    end;
    SetHandleInformation(FStdoutRead, HANDLE_FLAG_INHERIT, 0);

    if not CreatePipe(FStderrRead, StderrWrite, @SA, LSP_PIPE_BUFFER_SIZE) then
    begin
      Logger.Error('Failed to create stderr pipe: %d', [GetLastError]);
      Exit;
    end;
    SetHandleInformation(FStderrRead, HANDLE_FLAG_INHERIT, 0);

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

    // FIX: 8th parameter must be lpCurrentDirectory (nil), not SI
    if not CreateProcess(
      nil,
      PChar(CmdLine),
      nil,
      nil,
      True,
      CREATE_NO_WINDOW,
      nil,
      nil,   // lpCurrentDirectory
      SI,
      PI) then
    begin
      Logger.Error('Failed to create LSP process: %s (Error: %d)', [FProcessPath, GetLastError]);
      Exit;
    end;

    FProcessHandle := PI.hProcess;
    CloseHandle(PI.hThread);
    Result := True;
    Logger.Info('LSP process started successfully');
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
  if FProcessHandle <> 0 then
  begin
    // stdin already closed in Stop; give server time to exit
    if WaitForSingleObject(FProcessHandle, 2000) = WAIT_TIMEOUT then
      TerminateProcess(FProcessHandle, 1);
    SafeCloseHandle(FProcessHandle);
  end;

  // Defensive cleanup (already closed in Stop, but safe)
  SafeCloseHandle(FStdinWrite);
  SafeCloseHandle(FStdoutRead);
  SafeCloseHandle(FStderrRead);
end;

function TLSPProcessTransport.SendMessage(const AMessage: string): Boolean;
var
  Utf8Bytes: TBytes;
  Header: AnsiString;
  BytesWritten, TotalWritten: DWORD;
  StartTime: UInt64; // FIX: Use UInt64 to avoid W1073
begin
  Result := False;
  if not GetRunning then
  begin
    Logger.Warning('Cannot send message: LSP process not running');
    Exit;
  end;

  // Check if process already exited
  if (FProcessHandle <> 0) and (WaitForSingleObject(FProcessHandle, 0) = WAIT_OBJECT_0) then
  begin
    HandleProcessExit;
    Exit;
  end;

  FLock.Enter;
  try
    Utf8Bytes := TEncoding.UTF8.GetBytes(AMessage);
    Header := AnsiString(Format('Content-Length: %d'#13#10#13#10, [Length(Utf8Bytes)]));

    // Header write
    if not WriteFile(FStdinWrite, PAnsiChar(Header)^, Length(Header), BytesWritten, nil) or
       (BytesWritten <> DWORD(Length(Header))) then
    begin
      Logger.Error('Failed to write message header: %d', [GetLastError]);
      HandleProcessExit;
      Exit;
    end;

    // Body write with timeout guard
    TotalWritten := 0;
    StartTime := GetTickCount64; // FIX: Use GetTickCount64
    while TotalWritten < DWORD(Length(Utf8Bytes)) do
    begin
      if GetTickCount64 - StartTime > BODY_READ_TIMEOUT_MS then
      begin
        Logger.Error('SendMessage body write timeout');
        HandleProcessExit;
        Exit;
      end;

      if not WriteFile(FStdinWrite, Utf8Bytes[TotalWritten],
                       Length(Utf8Bytes) - TotalWritten, BytesWritten, nil) then
      begin
        Logger.Error('Failed to write message content: %d', [GetLastError]);
        HandleProcessExit;
        Exit;
      end;

      if BytesWritten = 0 then
      begin
        Logger.Error('WriteFile wrote 0 bytes');
        HandleProcessExit;
        Exit;
      end;

      Inc(TotalWritten, BytesWritten);
    end;

    FlushFileBuffers(FStdinWrite);
    Logger.Debug('Sent to LSP: %s', [Copy(AMessage, 1, 200)]);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TLSPProcessTransport.ReadLoop;
var
  Message: string;
begin
  while GetRunning do
  begin
    try
      Message := ReadMessage;
      if Message <> '' then
      begin
        Logger.Debug('Received from LSP: %s', [Copy(Message, 1, 200)]);
        if Assigned(FOnMessageReceived) then
          FOnMessageReceived(Message);
      end
      else if not GetRunning then
        Break;
    except
      on E: Exception do
      begin
        Logger.Error('Error reading LSP message: %s', [E.Message]);
        HandleProcessExit;
        Break;
      end;
    end;
  end;
end;

procedure TLSPProcessTransport.ErrorLoop;
var
  Buffer: array[0..4095] of Byte;
  BytesRead: DWORD;
  ErrorText: string;
  LastError: DWORD;
  Temp: TBytes;
begin
  while GetRunning do
  begin
    if ReadFile(FStderrRead, Buffer, SizeOf(Buffer), BytesRead, nil) then
    begin
	  if BytesRead > 0 then
      begin
        // FIX: Convert static array to TBytes, then use GetString
        SetLength(Temp, BytesRead);
        Move(Buffer[0], Temp[0], BytesRead);
        ErrorText := TEncoding.UTF8.GetString(Temp);
        Logger.Warning('LSP stderr: %s', [Trim(ErrorText)]);
        if Assigned(FOnError) then
          FOnError(ErrorText);
      end;
    end
    else
    begin
      LastError := GetLastError;
      if (LastError = ERROR_BROKEN_PIPE) or (LastError = ERROR_OPERATION_ABORTED) then
        Break;
      if not GetRunning then
        Break;
      Sleep(10);
    end;
  end;
end;

procedure TLSPProcessTransport.MonitorLoop;
begin
  if FProcessHandle <> 0 then
  begin
    WaitForSingleObject(FProcessHandle, INFINITE);
    if GetRunning then
      HandleProcessExit;
  end;
end;

function TLSPProcessTransport.ReadHeaders(AHandle: THandle; out ContentLength: Integer; out ContentType: string): Boolean;
var
  Line: AnsiString;
  Ch: AnsiChar;
  BytesRead: DWORD;
  LowerLine: string;
  StartTime: UInt64; // FIX: Use UInt64
begin
  Result := False;
  ContentLength := -1;
  ContentType := 'application/vscode-jsonrpc; charset=utf-8';
  Line := '';
  StartTime := GetTickCount64; // FIX: Use GetTickCount64

  while GetRunning do
  begin
    if (FProcessHandle <> 0) and (WaitForSingleObject(FProcessHandle, 0) = WAIT_OBJECT_0) then
      Exit;

    if GetTickCount64 - StartTime > HEADER_READ_TIMEOUT_MS then
    begin
      Logger.Error('Header read timeout');
      Exit;
    end;

    if not ReadFile(AHandle, Ch, 1, BytesRead, nil) or (BytesRead = 0) then
      Exit;

    if Ch = #10 then
    begin
      if (Length(Line) > 0) and (Line[Length(Line)] = #13) then
        SetLength(Line, Length(Line) - 1);

	  if Line = '' then
      begin
        Result := ContentLength >= 0;
        Exit;
      end;

      LowerLine := LowerCase(string(Line));
      if Pos('content-length:', LowerLine) = 1 then
      begin
        Delete(Line, 1, 15);
        ContentLength := StrToIntDef(Trim(string(Line)), -1);
      end
      else if Pos('content-type:', LowerLine) = 1 then
      begin
        Delete(Line, 1, 13);
        ContentType := Trim(string(Line));
      end;

      Line := '';
    end
    else if Ch <> #13 then
    begin
      if Length(Line) >= MAX_HEADER_LINE_LENGTH then
      begin
        Logger.Error('Header line too long');
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
  StartTime: UInt64; // FIX: Use UInt64
begin
  Result := '';

  if not ReadHeaders(FStdoutRead, ContentLength, ContentType) then
    Exit;

  if (ContentLength <= 0) or (ContentLength > MAX_MESSAGE_SIZE) then
  begin
    Logger.Error('Invalid Content-Length: %d', [ContentLength]);
    Exit;
  end;

  SetLength(Buffer, ContentLength);
  TotalRead := 0;
  StartTime := GetTickCount64; // FIX: Use GetTickCount64

  while (TotalRead < DWORD(ContentLength)) and GetRunning do
  begin
    if GetTickCount64 - StartTime > BODY_READ_TIMEOUT_MS then
    begin
      Logger.Error('Message body read timeout');
      Exit;
    end;

    if not ReadFile(FStdoutRead, Buffer[TotalRead], DWORD(ContentLength) - TotalRead, BytesRead, nil) then
    begin
      if GetLastError = ERROR_BROKEN_PIPE then
		HandleProcessExit;
      Exit;
    end;

    if BytesRead = 0 then
      Break;

    Inc(TotalRead, BytesRead);
  end;

  if TotalRead = DWORD(ContentLength) then
    Result := TEncoding.UTF8.GetString(Buffer); // FIX: Correct overload
end;

procedure TLSPProcessTransport.HandleProcessExit;
begin
  if GetRunning then
  begin
    SetRunning(False);
    Logger.Error('LSP process exited unexpectedly');
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
  FTransport.MonitorLoop;
end;

end.

