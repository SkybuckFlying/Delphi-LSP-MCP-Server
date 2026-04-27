unit Common.Logging;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs;

type
  TLogLevel = (llDebug, llInfo, llWarning, llError);

  TLogger = class
  private
    class var FInstance: TLogger;
    class var FLock: TCriticalSection;
    class constructor CreateClass;
    class destructor DestroyClass;
  private
    FLogLevel: TLogLevel;
    FErrWriter: TStreamWriter;
    FErrStream: THandleStream; // Keep separate so we control lifetime
    FStartTime: UInt64; // For monotonic timestamps
    procedure WriteLogLine(const ALine: string);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Log(ALevel: TLogLevel; const AMessage: string); overload;
    procedure Log(ALevel: TLogLevel; const AFormat: string; const AArgs: array of const); overload;
    procedure Debug(const AMessage: string); overload;
    procedure Debug(const AFormat: string; const AArgs: array of const); overload;
    procedure Info(const AMessage: string); overload;
    procedure Info(const AFormat: string; const AArgs: array of const); overload;
    procedure Warning(const AMessage: string); overload;
    procedure Warning(const AFormat: string; const AArgs: array of const); overload;
    procedure Error(const AMessage: string); overload;
    procedure Error(const AFormat: string; const AArgs: array of const); overload;

    class function GetInstance: TLogger; static;
    class procedure ResetInstance; // for tests

    property LogLevel: TLogLevel read FLogLevel write FLogLevel;
  end;

function Logger: TLogger;

implementation

uses
  Winapi.Windows, System.DateUtils, System.Diagnostics;

function Logger: TLogger;
begin
  Result := TLogger.GetInstance;
end;

{ TLogger }

class constructor TLogger.CreateClass;
begin
  // Class constructor runs before any code in this unit executes,
  // including initialization section. This guarantees FLock exists.
  FLock := TCriticalSection.Create;
end;

class destructor TLogger.DestroyClass;
begin
  FLock.Free;
end;

constructor TLogger.Create;
var
  StdErrHandle: THandle;
begin
  inherited Create;
  FLogLevel := llInfo;
  FStartTime := TStopwatch.GetTimeStamp;

  StdErrHandle := GetStdHandle(STD_ERROR_HANDLE);
  // Don't let TStreamWriter close stderr. We don't own the OS handle.
  FErrStream := THandleStream.Create(StdErrHandle);
  FErrWriter := TStreamWriter.Create(FErrStream, TEncoding.UTF8, 4096);
  // AutoFlush=True is safer for MCP: if we crash, last line isn't lost.
  // Cost is 1 syscall per log. Acceptable for LSP servers.
  FErrWriter.AutoFlush := True;
  FErrWriter.NewLine := #10; // LF only per JSON-RPC spec
end;

destructor TLogger.Destroy;
begin
  // Free writer first, then stream. Stream won't close the handle.
  FErrWriter.Free;
  FErrStream.Free;
  inherited;
end;

class function TLogger.GetInstance: TLogger;
begin
  // FLock guaranteed non-nil due to class constructor
  if not Assigned(FInstance) then
  begin
    FLock.Enter;
    try
      if not Assigned(FInstance) then
        FInstance := TLogger.Create;
    finally
      FLock.Leave;
    end;
  end;
  Result := FInstance;
end;

class procedure TLogger.ResetInstance;
begin
  FLock.Enter;
  try
    FreeAndNil(FInstance);
  finally
    FLock.Leave;
  end;
end;

procedure TLogger.WriteLogLine(const ALine: string);
begin
  FLock.Enter;
  try
    try
      FErrWriter.WriteLine(ALine);
    except
      // Swallow ALL exceptions to prevent recursive logging death spirals.
      // If stderr is broken, we can't log about it anyway.
      on E: Exception do;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TLogger.Log(ALevel: TLogLevel; const AMessage: string);
const
  LevelNames: array[TLogLevel] of string = ('DEBUG', 'INFO', 'WARNING', 'ERROR');
var
  LogLine: string;
  ElapsedMs: Int64;
begin
  if ALevel < FLogLevel then
    Exit;

  // Monotonic timestamp: milliseconds since logger start
  // This never goes backwards and sorts correctly
  ElapsedMs := (TStopwatch.GetTimeStamp - FStartTime) div TStopwatch.Frequency div 1000;

  LogLine := Format('[%6.3f] [%s] %s', [
    ElapsedMs / 1000.0,
    LevelNames[ALevel],
    AMessage
  ]);

  WriteLogLine(LogLine);
end;

procedure TLogger.Log(ALevel: TLogLevel; const AFormat: string; const AArgs: array of const);
begin
  if ALevel < FLogLevel then
    Exit; // Check BEFORE formatting to avoid cost
  Log(ALevel, Format(AFormat, AArgs));
end;

procedure TLogger.Debug(const AMessage: string);
begin
  Log(llDebug, AMessage);
end;

procedure TLogger.Debug(const AFormat: string; const AArgs: array of const);
begin
  Log(llDebug, AFormat, AArgs);
end;

procedure TLogger.Info(const AMessage: string);
begin
  Log(llInfo, AMessage);
end;

procedure TLogger.Info(const AFormat: string; const AArgs: array of const);
begin
  Log(llInfo, AFormat, AArgs);
end;

procedure TLogger.Warning(const AMessage: string);
begin
  Log(llWarning, AMessage);
end;

procedure TLogger.Warning(const AFormat: string; const AArgs: array of const);
begin
  Log(llWarning, AFormat, AArgs);
end;

procedure TLogger.Error(const AMessage: string);
begin
  Log(llError, AMessage);
end;

procedure TLogger.Error(const AFormat: string; const AArgs: array of const);
begin
  Log(llError, AFormat, AArgs);
end;

end.