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
    FRunning: Boolean;
    FLock: TCriticalSection;
    FOnMessageReceived: TMessageReceivedEvent;
    FReadThread: TThread;
    
    procedure ReadLoop;
    function ReadMessage: string;
  public
    constructor Create;
    destructor Destroy; override;
    
    procedure Start;
    procedure Stop;
    procedure SendMessage(const AMessage: string);
    
    property OnMessageReceived: TMessageReceivedEvent read FOnMessageReceived write FOnMessageReceived;
    property Running: Boolean read FRunning;
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
  FRunning := False;
end;

destructor TMCPStdioTransport.Destroy;
begin
  Stop;
  FLock.Free;
  inherited;
end;

procedure TMCPStdioTransport.Start;
begin
  if FRunning then
    Exit;
    
  FRunning := True;
  FReadThread := TStdioReadThread.Create(Self);
  FReadThread.Start;
  Logger.Info('MCP stdio transport started');
end;

procedure TMCPStdioTransport.Stop;
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
  Logger.Info('MCP stdio transport stopped');
end;

procedure TMCPStdioTransport.SendMessage(const AMessage: string);
var
  Utf8Message: UTF8String;
  BytesWritten: DWORD;
  NewLine: AnsiString;
begin
  FLock.Enter;
  try
    Utf8Message := UTF8Encode(AMessage);
    // Use strict CRLF as per JSON-RPC/MCP specification, regardless of platform
    NewLine := #13#10;
    
    // Write content
    if not WriteFile(FStdoutHandle, PAnsiChar(Utf8Message)^, Length(Utf8Message), BytesWritten, nil) then
    begin
      Logger.Error('Failed to write message to stdout');
      Exit;
    end;
    
    // Write newline separator (standard for line-delimited JSON-RPC in MCP)
    WriteFile(FStdoutHandle, PAnsiChar(NewLine)^, Length(NewLine), BytesWritten, nil);
    
    FlushFileBuffers(FStdoutHandle);
    Logger.Debug('Sent message: %s', [Copy(AMessage, 1, 200)]);
  finally
    FLock.Leave;
  end;
end;

procedure TMCPStdioTransport.ReadLoop;
var
  Message: string;
begin
  while FRunning do
  begin
    try
      Message := ReadMessage;
      if Message <> '' then
      begin
        Logger.Debug('Received message: %s', [Copy(Message, 1, 200)]);
        if Assigned(FOnMessageReceived) then
          FOnMessageReceived(Message);
      end;
    except
      on E: Exception do
      begin
        if FRunning then
          Logger.Error('Error reading message: %s', [E.Message]);
        Break;
      end;
    end;
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
begin
  Result := '';
  ContentLength := -1;
  Line := '';
  
  // 1. Read headers OR detect raw JSON
  while FRunning do
  begin
    ReadRes := ReadFile(FStdinHandle, Ch, 1, BytesRead, nil);
    if not ReadRes or (BytesRead = 0) then
    begin
      if FRunning then
      begin
        Logger.Info('Stdin closed or broken pipe');
        FRunning := False;
      end;
      Exit;
    end;
      
    if Ch = #10 then // LF
    begin
      Line := AnsiString(Trim(string(Line)));
      
      // Empty line signals end of headers if we have a Content-Length
      if Line = '' then
      begin
        if ContentLength > 0 then
          Break; // Proceed to read body
      end
      // Parse Content-Length header
      else if Pos('Content-Length:', string(Line)) = 1 then
      begin
        Delete(Line, 1, 15);
        ContentLength := StrToIntDef(string(Trim(string(Line))), -1);
      end
      // Detect raw JSON (Standard MCP behavior)
      else if (Line <> '') and (Line[1] = '{') then
      begin
        Result := UTF8ToString(UTF8String(Line));
        Exit;
      end;
      
      Line := '';
    end
    else if Ch <> #13 then // Ignore CR
      Line := Line + Ch;
      
    // Safety: don't let a single line grow indefinitely
    if Length(Line) > 1024 * 1024 then
      Line := '';
  end;
  
  // 2. Read body if we got a Content-Length from headers
  if (ContentLength > 0) and FRunning then
  begin
    SetLength(Buffer, ContentLength);
    TotalRead := 0;
    
    while (TotalRead < DWORD(ContentLength)) and FRunning do
    begin
      if not ReadFile(FStdinHandle, Buffer[TotalRead], DWORD(ContentLength) - TotalRead, BytesRead, nil) then
      begin
        Logger.Error('Failed to read message body');
        Exit;
      end;
      
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
  FTransport.ReadLoop;
end;

end.
