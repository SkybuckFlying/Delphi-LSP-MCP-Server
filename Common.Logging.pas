unit Common.Logging;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.DateUtils,
  System.Generics.Collections;

type
  TLogLevel = (llDebug, llInfo, llWarning, llError);

  // Log context for tracking operations across multiple log entries
  ILogContext = interface
    function GetId: string;
    procedure Log(const AMessage: string);
    procedure LogFmt(const AFormat: string; const AArgs: array of const);
    procedure Enter(const AMethod: string);
    procedure Exit(const AMethod: string);
  end;

  TLogLevelHelper = record helper for TLogLevel
    function ToString: string;
    function ToChar: Char;
  end;

  TLogger = class
  private
    class var FInstance: TLogger;
    class var FLock: TCriticalSection;
    class constructor CreateClass;
    class destructor DestroyClass;
  private
    FLogLevel: TLogLevel;
    FErrWriter: TStreamWriter;
    FErrStream: THandleStream;
    FStartTime: Int64;
    FEnableTimestamps: Boolean;
    FEnableCallStack: Boolean;
    FEnableContextIds: Boolean;
    FContextCounter: Integer;
    FContextLock: TCriticalSection;
    FCurrentContexts: TDictionary<NativeUInt, string>;

    procedure WriteLogLine(const ALine: string);
    function GetTimestamp: string;
    function GetCallStack: string;
    function GetThreadId: string;
    procedure InternalLog(ALevel: TLogLevel; const AMessage: string);
  public
    constructor Create;
    destructor Destroy; override;

    // Core logging methods
    procedure Log(ALevel: TLogLevel; const AMessage: string); overload;
    procedure Log(ALevel: TLogLevel; const AFormat: string; const AArgs: array of const); overload;

	// Convenience methods
    procedure Debug(const AMessage: string); overload;
    procedure Debug(const AFormat: string; const AArgs: array of const); overload;
    procedure Info(const AMessage: string); overload;
    procedure Info(const AFormat: string; const AArgs: array of const); overload;
    procedure Warning(const AMessage: string); overload;
    procedure Warning(const AFormat: string; const AArgs: array of const); overload;
    procedure Error(const AMessage: string); overload;
    procedure Error(const AFormat: string; const AArgs: array of const); overload;

	// Context-aware logging
    function CreateContext(const AName: string = ''): ILogContext;
    procedure EnterContext(const AName: string = '');
    procedure ExitContext;

    // Conditional logging (lazy evaluation - only evaluates if level is enabled)
    procedure DebugIf(ACondition: Boolean; const AMessage: string); overload;
    procedure DebugIf(ACondition: Boolean; const AFormat: string; const AArgs: array of const); overload;

    // Performance logging
    procedure LogTiming(const AOperation: string; AStartTime: UInt64);
    procedure LogDuration(const AOperation: string; AStartTime: TDateTime);

    // Configuration
    property LogLevel: TLogLevel read FLogLevel write FLogLevel;
    property EnableTimestamps: Boolean read FEnableTimestamps write FEnableTimestamps;
    property EnableCallStack: Boolean read FEnableCallStack write FEnableCallStack;
    property EnableContextIds: Boolean read FEnableContextIds write FEnableContextIds;

    class function GetInstance: TLogger; static;
    class procedure ResetInstance; static;
  end;

// Global logging function with optional lazy evaluation
function Logger: TLogger;

// Simplified logging macros
procedure LogDebug(const AMessage: string); overload;
procedure LogDebug(const AFormat: string; const AArgs: array of const); overload;
procedure LogInfo(const AMessage: string); overload;
procedure LogInfo(const AFormat: string; const AArgs: array of const); overload;
procedure LogWarning(const AMessage: string); overload;
procedure LogWarning(const AFormat: string; const AArgs: array of const); overload;
procedure LogError(const AMessage: string); overload;
procedure LogError(const AFormat: string; const AArgs: array of const); overload;

implementation

uses
  Winapi.Windows, System.Diagnostics;

type
  TLogContext = class(TInterfacedObject, ILogContext)
  private
    FId: string;
    FLogger: TLogger;
    FDepth: Integer;
  public
    constructor Create(ALogger: TLogger; const AName: string);
    function GetId: string;
    procedure Log(const AMessage: string);
    procedure LogFmt(const AFormat: string; const AArgs: array of const);
    procedure Enter(const AMethod: string);
    procedure Exit(const AMethod: string);
  end;

{ TLogLevelHelper }

function TLogLevelHelper.ToString: string;
begin
  case Self of
	llDebug:   Result := 'DEBUG';
    llInfo:    Result := 'INFO';
    llWarning: Result := 'WARNING';
    llError:   Result := 'ERROR';
  else
    Result := 'UNKNOWN';
  end;
end;

function TLogLevelHelper.ToChar: Char;
begin
  case Self of
    llDebug:   Result := 'D';
    llInfo:    Result := 'I';
    llWarning: Result := 'W';
    llError:   Result := 'E';
  else
    Result := '?';
  end;
end;

{ TLogContext }

constructor TLogContext.Create(ALogger: TLogger; const AName: string);
begin
  inherited Create;
  FLogger := ALogger;
  FDepth := 0;
  if AName <> '' then
    FId := AName
  else
    FId := 'ctx_' + IntToHex(TInterlocked.Increment(FLogger.FContextCounter), 8);
end;

function TLogContext.GetId: string;
begin
  Result := FId;
end;

procedure TLogContext.Log(const AMessage: string);
begin
  FLogger.Debug('[Context:' + FId + '] ' + StringOfChar(' ', FDepth * 2) + AMessage);
end;

procedure TLogContext.LogFmt(const AFormat: string; const AArgs: array of const);
begin
  Log(Format(AFormat, AArgs));
end;

procedure TLogContext.Enter(const AMethod: string);
begin
  Log('→ ' + AMethod);
  Inc(FDepth);
end;

procedure TLogContext.Exit(const AMethod: string);
begin
  Dec(FDepth);
  Log('← ' + AMethod);
end;

{ TLogger }

class constructor TLogger.CreateClass;
begin
  FLock := TCriticalSection.Create;
end;

class destructor TLogger.DestroyClass;
begin
  FLock.Free;
end;

type
  TUTF8EncodingNoBOM = class(TUTF8Encoding)
  public
    function GetPreamble: TBytes; override;
  end;

function TUTF8EncodingNoBOM.GetPreamble: TBytes;
begin
  SetLength(Result, 0);
end;

constructor TLogger.Create;
var
  StdErrHandle: THandle;
  Utf8NoBom: TUTF8Encoding;
begin
  inherited Create;
  FLogLevel := llInfo;
  FStartTime := TStopwatch.GetTimeStamp;
  FEnableTimestamps := True;
  FEnableCallStack := False;
  FEnableContextIds := False;
  FContextCounter := 0;
  FContextLock := TCriticalSection.Create;
  FCurrentContexts := TDictionary<NativeUInt, string>.Create;

  StdErrHandle := GetStdHandle(STD_ERROR_HANDLE);
  FErrStream := THandleStream.Create(StdErrHandle);

  // Create UTF-8 encoding WITHOUT BOM (False = no BOM)
  // TStreamWriter will take ownership and free the encoding object
  {$IF CompilerVersion >= 36.0}
  Utf8NoBom := TUTF8Encoding.Create(False);
  {$ELSE}
  Utf8NoBom := TUTF8EncodingNoBOM.Create;
  {$ENDIF}
  FErrWriter := TStreamWriter.Create(FErrStream, Utf8NoBom, 4096);

  FErrWriter.AutoFlush := True;
  FErrWriter.NewLine := #10;
end;

destructor TLogger.Destroy;
begin
  FCurrentContexts.Free;
  FContextLock.Free;
  FErrWriter.Free;
  FErrStream.Free;
  inherited;
end;

function TLogger.GetTimestamp: string;
var
  NowUTC: TDateTime;
begin
  if not FEnableTimestamps then
    Exit('');

  NowUTC := Now;
  Result := FormatDateTime('hh:nn:ss.zzz', NowUTC);
end;

function TLogger.GetCallStack: string;
begin
  if not FEnableCallStack then
    Exit('');
  Result := '';
end;

function TLogger.GetThreadId: string;
begin
  Result := IntToHex(GetCurrentThreadId, 4);
end;

procedure TLogger.WriteLogLine(const ALine: string);
begin
  FLock.Enter;
  try
    try
      FErrWriter.WriteLine(ALine);
    except
      // Swallow exceptions to prevent recursive logging
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TLogger.InternalLog(ALevel: TLogLevel; const AMessage: string);
var
  LogLine: string;
  TimeDiff: Int64;
  ElapsedMs: Int64;
  Parts: TStringBuilder;
  ContextId: string;
begin
  Parts := TStringBuilder.Create;
  try
    // Timestamp
    if FEnableTimestamps then
    begin
      TimeDiff := TStopwatch.GetTimeStamp - FStartTime;
      ElapsedMs := TimeDiff div TStopwatch.Frequency div 1000;
      Parts.Append(Format('[%6.3f]', [ElapsedMs / 1000.0]));
    end;

    // Thread ID
    Parts.Append(Format('[%s]', [GetThreadId]));

    // Log level
    Parts.Append(Format('[%s]', [ALevel.ToString]));

    // Context ID (if available)
    if FEnableContextIds then
    begin
      FContextLock.Enter;
      try
        if FCurrentContexts.TryGetValue(NativeUInt(GetCurrentThreadId), ContextId) then
          Parts.Append(Format('[%s]', [ContextId]));
      finally
        FContextLock.Leave;
      end;
    end;

    // Message
	Parts.Append(' ');
    Parts.Append(AMessage);

    LogLine := Parts.ToString;
  finally
    Parts.Free;
  end;

  WriteLogLine(LogLine);
end;

procedure TLogger.Log(ALevel: TLogLevel; const AMessage: string);
begin
  if ALevel < FLogLevel then
    Exit;
  InternalLog(ALevel, AMessage);
end;

procedure TLogger.Log(ALevel: TLogLevel; const AFormat: string; const AArgs: array of const);
begin
  if ALevel < FLogLevel then
	Exit;
  InternalLog(ALevel, Format(AFormat, AArgs));
end;

procedure TLogger.Debug(const AMessage: string);
begin
  Log(llDebug, AMessage);
end;

procedure TLogger.Debug(const AFormat: string; const AArgs: array of const);
begin
  Log(llDebug, AFormat, AArgs);
end;

procedure TLogger.DebugIf(ACondition: Boolean; const AMessage: string);
begin
  if ACondition then
    Log(llDebug, AMessage);
end;

procedure TLogger.DebugIf(ACondition: Boolean; const AFormat: string; const AArgs: array of const);
begin
  if ACondition then
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

procedure TLogger.LogTiming(const AOperation: string; AStartTime: UInt64);
var
  ElapsedMs: Integer;
begin
  ElapsedMs := (GetTickCount64 - AStartTime);
  if ElapsedMs > 1000 then
    Warning('[Timing] %s took %d ms (slow)', [AOperation, ElapsedMs])
  else if ElapsedMs > 100 then
    Info('[Timing] %s took %d ms', [AOperation, ElapsedMs])
  else if FLogLevel <= llDebug then
    Debug('[Timing] %s took %d ms', [AOperation, ElapsedMs]);
end;

procedure TLogger.LogDuration(const AOperation: string; AStartTime: TDateTime);
var
  ElapsedMs: Int64;
begin
  ElapsedMs := MillisecondsBetween(Now, AStartTime);
  if ElapsedMs > 1000 then
    Warning('[Duration] %s took %d ms (slow)', [AOperation, ElapsedMs])
  else if ElapsedMs > 100 then
    Info('[Duration] %s took %d ms', [AOperation, ElapsedMs])
  else if FLogLevel <= llDebug then
    Debug('[Duration] %s took %d ms', [AOperation, ElapsedMs]);
end;

function TLogger.CreateContext(const AName: string): ILogContext;
begin
  Result := TLogContext.Create(Self, AName);
  if FEnableContextIds then
  begin
    FContextLock.Enter;
    try
      FCurrentContexts.AddOrSetValue(NativeUInt(GetCurrentThreadId), Result.GetId);
    finally
      FContextLock.Leave;
    end;
  end;
end;

procedure TLogger.EnterContext(const AName: string);
begin
  CreateContext(AName);
end;

procedure TLogger.ExitContext;
begin
  FContextLock.Enter;
  try
    FCurrentContexts.Remove(NativeUInt(GetCurrentThreadId));
  finally
    FContextLock.Leave;
  end;
end;

class function TLogger.GetInstance: TLogger;
begin
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

{ Global functions }

function Logger: TLogger;
begin
  Result := TLogger.GetInstance;
end;

procedure LogDebug(const AMessage: string);
begin
  Logger.Debug(AMessage);
end;

procedure LogDebug(const AFormat: string; const AArgs: array of const);
begin
  Logger.Debug(AFormat, AArgs);
end;

procedure LogInfo(const AMessage: string);
begin
  Logger.Info(AMessage);
end;

procedure LogInfo(const AFormat: string; const AArgs: array of const);
begin
  Logger.Info(AFormat, AArgs);
end;

procedure LogWarning(const AMessage: string);
begin
  Logger.Warning(AMessage);
end;

procedure LogWarning(const AFormat: string; const AArgs: array of const);
begin
  Logger.Warning(AFormat, AArgs);
end;

procedure LogError(const AMessage: string);
begin
  Logger.Error(AMessage);
end;

procedure LogError(const AFormat: string; const AArgs: array of const);
begin
  Logger.Error(AFormat, AArgs);
end;

end.
