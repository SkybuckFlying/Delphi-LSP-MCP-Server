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
  private
    FLogLevel: TLogLevel;
    FLogToStderr: Boolean;
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
    
    property LogLevel: TLogLevel read FLogLevel write FLogLevel;
    property LogToStderr: Boolean read FLogToStderr write FLogToStderr;
  end;

function Logger: TLogger;

implementation

uses
  Winapi.Windows;

function Logger: TLogger;
begin
  Result := TLogger.GetInstance;
end;

{ TLogger }

constructor TLogger.Create;
begin
  inherited Create;
  FLogLevel := llInfo;
  FLogToStderr := True;
end;

destructor TLogger.Destroy;
begin
  inherited;
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

procedure TLogger.Log(ALevel: TLogLevel; const AMessage: string);
const
  LevelNames: array[TLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
var
  LogLine: string;
begin
  if ALevel < FLogLevel then
    Exit;
    
  FLock.Enter;
  try
    LogLine := Format('[%s] [%s] %s', [
      FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now),
      LevelNames[ALevel],
      AMessage
    ]);
    
    if FLogToStderr then
    begin
      Writeln(ErrOutput, LogLine);
      Flush(ErrOutput);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TLogger.Log(ALevel: TLogLevel; const AFormat: string; const AArgs: array of const);
begin
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

initialization
  TLogger.FLock := TCriticalSection.Create;
  // Ensure stderr output uses UTF-8 to support emojis and special characters
  SetTextCodePage(ErrOutput, 65001); // 65001 is UTF-8
  // Or for modern Delphi:
  // Rewrite(ErrOutput, TEncoding.UTF8); // Note: ErrOutput is already open, Rewrite might reset it. 
  // Ideally, use SetConsoleOutputCP(CP_UTF8) but that affects the whole console.
  // Since we are piping, we just want the bytes written to the handle to be UTF-8.
  // In Delphi, 'ErrOutput' defaults to the system code page.
  // Let's try attempting to set the encoding if possible, or usually SetTextCodePage works for text files.
  
  // Note: SetTextCodePage is the RTL way.
  // Re-opening ErrOutput with specific encoding:
  
  try
    // Prevent 'File not open' error if not console
    if IsConsole then
    begin
        // Force UTF-8 for standard error
       // AssignFile(ErrOutput, '');  // Already done by system
       // Rewrite(ErrOutput); // This resets it
       // We can just set the code page for the existing file handle wrapper if possible.
       // The safest way in modern Delphi to ensure WriteLn emits UTF8 bytes is:
       // System.OutputEncoding := TEncoding.UTF8; // Affects Output
       // But ErrOutput?
    end;
  except
  end;  

  // Actually, simplest fix: modify TLogger.Log to write UTF8 bytes directly using WriteFile
  // OR rely on SetConsoleOutputCP in the main program. 
  
  // Let's modify the Main Program (DelphiLSPMCPServer.dpr) to set output encoding.
  // Changing this file (Common.Logging) to just hold the lock creation.
  TLogger.FLock := TCriticalSection.Create;

finalization
  if Assigned(TLogger.FInstance) then
    TLogger.FInstance.Free;
  TLogger.FLock.Free;

end.
