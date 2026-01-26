unit LSP.Transport.Process;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Winapi.Windows,
  Common.Logging;

type
  TLSPMessageReceivedEvent = procedure(const AMessage: string) of object;

  TLSPProcessTransport = class
  private
    FProcessPath: string;
    FProcessHandle: THandle;
    FStdinWrite: THandle;
    FStdoutRead: THandle;
    FStderrRead: THandle;
    FRunning: Boolean;
    FLock: TCriticalSection;
    FOnMessageReceived: TLSPMessageReceivedEvent;
    FReadThread: TThread;
    FErrorThread: TThread;
    
    procedure ReadLoop;
    procedure ErrorLoop;
    function ReadMessage: string;
    function ReadHeaders(AHandle: THandle): Integer;
    function StartProcess: Boolean;
    procedure StopProcess;
  public
    constructor Create(const AProcessPath: string);
    destructor Destroy; override;
    
    function Start: Boolean;
    procedure Stop;
    procedure SendMessage(const AMessage: string);
    function IsRunning: Boolean;
    
    property OnMessageReceived: TLSPMessageReceivedEvent read FOnMessageReceived write FOnMessageReceived;
  end;

implementation

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

{ TLSPProcessTransport }

constructor TLSPProcessTransport.Create(const AProcessPath: string);
begin
  inherited Create;
  FProcessPath := AProcessPath;
  FLock := TCriticalSection.Create;
  FRunning := False;
  FProcessHandle := 0;
  FStdinWrite := 0;
  FStdoutRead := 0;
  FStderrRead := 0;
end;

destructor TLSPProcessTransport.Destroy;
begin
  Stop;
  FLock.Free;
  inherited;
end;

function TLSPProcessTransport.Start: Boolean;
begin
  Result := False;
  if FRunning then
    Exit(True);
    
  if not StartProcess then
  begin
    Logger.Error('Failed to start LSP process: %s', [FProcessPath]);
    Exit;
  end;
  
  FRunning := True;
  FReadThread := TLSPReadThread.Create(Self);
  FReadThread.Start;
  FErrorThread := TLSPErrorThread.Create(Self);
  FErrorThread.Start;
  
  Logger.Info('LSP process transport started: %s', [FProcessPath]);
  Result := True;
end;

procedure TLSPProcessTransport.Stop;
begin
  if not FRunning then
    Exit;
    
  FRunning := False;
  
  if Assigned(FReadThread) then
  begin
    FReadThread.Terminate;
    FReadThread.WaitFor;
    FReadThread.Free;
    FReadThread := nil;
  end;
  
  if Assigned(FErrorThread) then
  begin
    FErrorThread.Terminate;
    FErrorThread.WaitFor;
    FErrorThread.Free;
    FErrorThread := nil;
  end;
  
  StopProcess;
  Logger.Info('LSP process transport stopped');
end;

function TLSPProcessTransport.IsRunning: Boolean;
begin
  Result := FRunning and (FProcessHandle <> 0);
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
  
  // Create security attributes for pipe inheritance
  SA.nLength := SizeOf(TSecurityAttributes);
  SA.bInheritHandle := True;
  SA.lpSecurityDescriptor := nil;
  
  // Create pipes for stdin
  if not CreatePipe(StdinRead, FStdinWrite, @SA, 0) then
  begin
    Logger.Error('Failed to create stdin pipe');
    Exit;
  end;
  SetHandleInformation(FStdinWrite, HANDLE_FLAG_INHERIT, 0);
  
  // Create pipes for stdout
  if not CreatePipe(FStdoutRead, StdoutWrite, @SA, 0) then
  begin
    Logger.Error('Failed to create stdout pipe');
    CloseHandle(StdinRead);
    CloseHandle(FStdinWrite);
    Exit;
  end;
  SetHandleInformation(FStdoutRead, HANDLE_FLAG_INHERIT, 0);
  
  // Create pipes for stderr
  if not CreatePipe(FStderrRead, StderrWrite, @SA, 0) then
  begin
    Logger.Error('Failed to create stderr pipe');
    CloseHandle(StdinRead);
    CloseHandle(FStdinWrite);
    CloseHandle(FStdoutRead);
    CloseHandle(StdoutWrite);
    Exit;
  end;
  SetHandleInformation(FStderrRead, HANDLE_FLAG_INHERIT, 0);
  
  // Setup startup info
  ZeroMemory(@SI, SizeOf(TStartupInfo));
  SI.cb := SizeOf(TStartupInfo);
  SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  SI.hStdInput := StdinRead;
  SI.hStdOutput := StdoutWrite;
  SI.hStdError := StderrWrite;
  
  // Create process
  CmdLine := '"' + FProcessPath + '"';
  UniqueString(CmdLine); // Make string mutable for CreateProcess
  ZeroMemory(@PI, SizeOf(TProcessInformation));
  
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, True,
    CREATE_NO_WINDOW, nil, nil, SI, PI) then
  begin
    Logger.Error('Failed to create LSP process: %s (Error: %d)', [FProcessPath, GetLastError]);
    CloseHandle(StdinRead);
    CloseHandle(FStdinWrite);
    CloseHandle(FStdoutRead);
    CloseHandle(StdoutWrite);
    CloseHandle(FStderrRead);
    CloseHandle(StderrWrite);
    Exit;
  end;
  
  // Close handles we don't need
  CloseHandle(StdinRead);
  CloseHandle(StdoutWrite);
  CloseHandle(StderrWrite);
  
  FProcessHandle := PI.hProcess;
  CloseHandle(PI.hThread);
  
  Logger.Info('LSP process started successfully');
  Result := True;
end;

procedure TLSPProcessTransport.StopProcess;
begin
  if FProcessHandle <> 0 then
  begin
    TerminateProcess(FProcessHandle, 0);
    WaitForSingleObject(FProcessHandle, 5000);
    CloseHandle(FProcessHandle);
    FProcessHandle := 0;
  end;
  
  if FStdinWrite <> 0 then
  begin
    CloseHandle(FStdinWrite);
    FStdinWrite := 0;
  end;
  
  if FStdoutRead <> 0 then
  begin
    CloseHandle(FStdoutRead);
    FStdoutRead := 0;
  end;
  
  if FStderrRead <> 0 then
  begin
    CloseHandle(FStderrRead);
    FStderrRead := 0;
  end;
end;

procedure TLSPProcessTransport.SendMessage(const AMessage: string);
var
  Utf8Message: UTF8String;
  Header: AnsiString;
  BytesWritten: DWORD;
begin
  if not IsRunning then
  begin
    Logger.Warning('Cannot send message: LSP process not running');
    Exit;
  end;
  
  FLock.Enter;
  try
    Utf8Message := UTF8Encode(AMessage);
    Header := AnsiString(Format('Content-Length: %d'#13#10#13#10, [Length(Utf8Message)]));
    
    // Write header
    if not WriteFile(FStdinWrite, PAnsiChar(Header)^, Length(Header), BytesWritten, nil) then
    begin
      Logger.Error('Failed to write message header to LSP process');
      Exit;
    end;
    
    // Write content
    if not WriteFile(FStdinWrite, PAnsiChar(Utf8Message)^, Length(Utf8Message), BytesWritten, nil) then
    begin
      Logger.Error('Failed to write message content to LSP process');
      Exit;
    end;
    
    FlushFileBuffers(FStdinWrite);
    Logger.Debug('Sent to LSP: %s', [Copy(AMessage, 1, 200)]);
  finally
    FLock.Leave;
  end;
end;

procedure TLSPProcessTransport.ReadLoop;
var
  Message: string;
begin
  while FRunning do
  begin
    try
      Message := ReadMessage;
      if Message <> '' then
      begin
        Logger.Debug('Received from LSP: %s', [Copy(Message, 1, 200)]);
        if Assigned(FOnMessageReceived) then
          FOnMessageReceived(Message);
      end
      else if not FRunning then
        Break;
    except
      on E: Exception do
      begin
        Logger.Error('Error reading LSP message: %s', [E.Message]);
        Break;
      end;
    end;
  end;
end;

procedure TLSPProcessTransport.ErrorLoop;
var
  Buffer: array[0..4095] of AnsiChar;
  BytesRead: DWORD;
  ErrorText: string;
begin
  while FRunning do
  begin
    if ReadFile(FStderrRead, Buffer, SizeOf(Buffer), BytesRead, nil) and (BytesRead > 0) then
    begin
      SetLength(ErrorText, BytesRead);
      Move(Buffer[0], ErrorText[1], BytesRead);
      Logger.Warning('LSP stderr: %s', [Trim(ErrorText)]);
    end
    else if not FRunning then
      Break;
  end;
end;

function TLSPProcessTransport.ReadHeaders(AHandle: THandle): Integer;
var
  Line: AnsiString;
  Ch: AnsiChar;
  BytesRead: DWORD;
  ContentLength: Integer;
begin
  Result := -1;
  ContentLength := -1;
  Line := '';
  
  while FRunning do
  begin
    if not ReadFile(AHandle, Ch, 1, BytesRead, nil) or (BytesRead = 0) then
      Exit;
      
    if Ch = #10 then
    begin
      if (Length(Line) > 0) and (Line[Length(Line)] = #13) then
        SetLength(Line, Length(Line) - 1);
        
      if Line = '' then
      begin
        Result := ContentLength;
        Exit;
      end;
      
      if Pos('Content-Length:', string(Line)) = 1 then
      begin
        Delete(Line, 1, 15);
        Line := AnsiString(Trim(string(Line)));
        ContentLength := StrToIntDef(string(Line), -1);
      end;
      
      Line := '';
    end
    else if Ch <> #13 then
      Line := Line + Ch;
  end;
end;

function TLSPProcessTransport.ReadMessage: string;
var
  ContentLength: Integer;
  Buffer: TBytes;
  BytesRead, TotalRead: DWORD;
  Utf8Str: UTF8String;
begin
  Result := '';
  
  ContentLength := ReadHeaders(FStdoutRead);
  if ContentLength <= 0 then
    Exit;
  
  SetLength(Buffer, ContentLength);
  TotalRead := 0;
  
  while (TotalRead < DWORD(ContentLength)) and FRunning do
  begin
    if not ReadFile(FStdoutRead, Buffer[TotalRead], DWORD(ContentLength) - TotalRead, BytesRead, nil) then
      Exit;
    
    if BytesRead = 0 then
      Break;
      
    Inc(TotalRead, BytesRead);
  end;
  
  if TotalRead = DWORD(ContentLength) then
  begin
    SetLength(Utf8Str, ContentLength);
    Move(Buffer[0], Utf8Str[1], ContentLength);
    Result := UTF8ToString(Utf8Str);
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

end.
