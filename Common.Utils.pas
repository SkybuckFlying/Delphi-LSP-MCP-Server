unit Common.Utils;

interface

uses
  System.SysUtils, System.NetEncoding, System.IOUtils, Common.Logging;

type
  TPathConversionResult = record
    Success: Boolean;
    OriginalPath: string;
    ConvertedPath: string;
    ErrorMessage: string;
  end;

  TPathUtils = class
  private
    class var FDebugMode: Boolean;
    class var FLogContext: ILogContext;
    class procedure LogDebug(const Msg: string; const Args: array of const); static;
  public
    class procedure Initialize; static;
    class function PathToFileUri(const APath: string): string;
    class function FileUriToPath(const AUri: string): string;
    class function PathToFileUriEx(const APath: string; out ConvResult: TPathConversionResult): Boolean; static;
    class function FileUriToPathEx(const AUri: string; out ConvResult: TPathConversionResult): Boolean; static;
    class function NormalizePath(const APath: string): string; static;
    class function IsFileUri(const AUri: string): Boolean; static;
    class property DebugMode: Boolean read FDebugMode write FDebugMode;
  end;

// Legacy function wrappers for backward compatibility
function PathToFileUri(const APath: string): string;
function FileUriToPath(const AUri: string): string;

implementation

var
  LegacyDebugMode: Boolean = False;

procedure SetLegacyDebugMode(Value: Boolean);
begin
  LegacyDebugMode := Value;
  TPathUtils.DebugMode := Value;
end;

{ TPathUtils }

class procedure TPathUtils.Initialize;
begin
  FDebugMode := False;
  FLogContext := Logger.CreateContext('PathUtils');
end;

class procedure TPathUtils.LogDebug(const Msg: string; const Args: array of const);
begin
  if FDebugMode then
  begin
    if Length(Args) > 0 then
      FLogContext.LogFmt(Msg, Args)
    else
      FLogContext.Log(Msg);
  end;
end;

class function TPathUtils.PathToFileUri(const APath: string): string;
var
  ConvResult: TPathConversionResult;
begin
  if PathToFileUriEx(APath, ConvResult) then
    Result := ConvResult.ConvertedPath
  else
    Result := '';
end;

class function TPathUtils.PathToFileUriEx(const APath: string; out ConvResult: TPathConversionResult): Boolean;
var
  ExpandedPath: string;
  EncodedPath: string;
  OriginalPath: string;
begin
  Result := False;
  ConvResult.Success := False;
  ConvResult.OriginalPath := APath;
  ConvResult.ConvertedPath := '';
  ConvResult.ErrorMessage := '';

  FLogContext.Enter('PathToFileUriEx');
  try
    LogDebug('Converting path to file URI: %s', [APath]);

    // Validate input
    if APath = '' then
    begin
      ConvResult.ErrorMessage := 'Input path is empty';
      LogDebug('Error: %s', [ConvResult.ErrorMessage]);
      Exit;
    end;

    // Store original for debugging
    OriginalPath := APath;

    // Expand to full path
    try
      ExpandedPath := ExpandFileName(APath);
      LogDebug('Expanded path: %s', [ExpandedPath]);
    except
      on E: Exception do
      begin
        ConvResult.ErrorMessage := Format('Failed to expand path: %s', [E.Message]);
        LogDebug('Error: %s', [ConvResult.ErrorMessage]);
        Exit;
      end;
	end;

    // Convert backslashes to forward slashes
    ExpandedPath := StringReplace(ExpandedPath, '\', '/', [rfReplaceAll]);
    LogDebug('Normalized slashes: %s', [ExpandedPath]);

    // URL encode the path
    try
      EncodedPath := TNetEncoding.URL.Encode(ExpandedPath);
      LogDebug('URL encoded: %s', [EncodedPath]);

      // Clean up encoding (don't encode forward slashes and colons)
      EncodedPath := StringReplace(EncodedPath, '%2F', '/', [rfReplaceAll]);
      EncodedPath := StringReplace(EncodedPath, '%3A', ':', [rfReplaceAll]);
      LogDebug('Cleaned encoding: %s', [EncodedPath]);
    except
      on E: Exception do
      begin
        ConvResult.ErrorMessage := Format('Failed to encode path: %s', [E.Message]);
        LogDebug('Error: %s', [ConvResult.ErrorMessage]);
        Exit;
      end;
    end;

    // Add file:/// prefix
    ConvResult.ConvertedPath := 'file:///' + EncodedPath;
    ConvResult.Success := True;

    LogDebug('Successfully converted: %s -> %s', [OriginalPath, ConvResult.ConvertedPath]);
    Result := True;

  finally
    FLogContext.Exit('PathToFileUriEx');
  end;
end;

class function TPathUtils.FileUriToPath(const AUri: string): string;
var
  ConvResult: TPathConversionResult;
begin
  if FileUriToPathEx(AUri, ConvResult) then
    Result := ConvResult.ConvertedPath
  else
    Result := '';
end;

class function TPathUtils.FileUriToPathEx(const AUri: string; out ConvResult: TPathConversionResult): Boolean;
var
  S, Host, PathPart: string;
  SlashPos: Integer;
  DecodedPath: string;
begin
  Result := False;
  ConvResult.Success := False;
  ConvResult.OriginalPath := AUri;
  ConvResult.ConvertedPath := '';
  ConvResult.ErrorMessage := '';

  FLogContext.Enter('FileUriToPathEx');
  try
    LogDebug('Converting file URI to path: %s', [AUri]);

    // Validate input
    if AUri = '' then
    begin
      ConvResult.ErrorMessage := 'Input URI is empty';
      LogDebug('Error: %s', [ConvResult.ErrorMessage]);
	  Exit;
    end;

    // Check if it's a file URI
    if not AUri.StartsWith('file://', True) then
    begin
      ConvResult.ErrorMessage := Format('Not a file URI: %s', [AUri]);
      LogDebug('Error: %s', [ConvResult.ErrorMessage]);
      Exit;
    end;

    // Remove file:// prefix
    S := AUri.Substring(7);
    LogDebug('URI without prefix: %s', [S]);

    // Parse host and path
    SlashPos := Pos('/', S);
    if SlashPos = 0 then
    begin
      Host := '';
      PathPart := S;
      LogDebug('No host detected, path only: %s', [PathPart]);
    end
    else
    begin
      Host := Copy(S, 1, SlashPos - 1);
      PathPart := Copy(S, SlashPos + 1);
      LogDebug('Host: "%s", Path: "%s"', [Host, PathPart]);
    end;

    // Decode the path
    try
      DecodedPath := TNetEncoding.URL.Decode(PathPart);
      LogDebug('Decoded path: %s', [DecodedPath]);
    except
      on E: Exception do
      begin
        ConvResult.ErrorMessage := Format('Failed to decode path: %s', [E.Message]);
        LogDebug('Error: %s', [ConvResult.ErrorMessage]);
        Exit;
      end;
    end;

    // Handle different host types
    if SameText(Host, 'localhost') or (Host = '') then
    begin
      // Local file
      ConvResult.ConvertedPath := DecodedPath;

      // Remove leading slash if present (Windows paths)
      if (ConvResult.ConvertedPath <> '') and (ConvResult.ConvertedPath[1] = '/') then
        Delete(ConvResult.ConvertedPath, 1, 1);

      // Convert forward slashes to backslashes for Windows
      ConvResult.ConvertedPath := StringReplace(ConvResult.ConvertedPath, '/', '\', [rfReplaceAll]);

      LogDebug('Local path: %s', [ConvResult.ConvertedPath]);
    end
    else
    begin
      // UNC path
      ConvResult.ConvertedPath := '\\' + Host + '\' + StringReplace(DecodedPath, '/', '\', [rfReplaceAll]);
      LogDebug('UNC path: %s', [ConvResult.ConvertedPath]);
    end;

    // Validate the resulting path exists (warning only, not error)
	if not FileExists(ConvResult.ConvertedPath) and not DirectoryExists(ConvResult.ConvertedPath) then
    begin
      LogDebug('Warning: Converted path does not exist: %s', [ConvResult.ConvertedPath]);
      // Not an error - the path might be valid but not yet exist
    end;

    ConvResult.Success := True;
    LogDebug('Successfully converted: %s -> %s', [AUri, ConvResult.ConvertedPath]);
    Result := True;

  finally
    FLogContext.Exit('FileUriToPathEx');
  end;
end;

class function TPathUtils.NormalizePath(const APath: string): string;
begin
  Result := APath;

  if APath = '' then
    Exit;

  LogDebug('Normalizing path: %s', [APath]);

  try
    // Expand to full path
    Result := ExpandFileName(APath);

    // Normalize directory separators
    Result := StringReplace(Result, '/', '\', [rfReplaceAll]);

    LogDebug('Normalized path: %s -> %s', [APath, Result]);
  except
    on E: Exception do
    begin
      LogDebug('Failed to normalize path: %s', [E.Message]);
      // Return original on error
    end;
  end;
end;

class function TPathUtils.IsFileUri(const AUri: string): Boolean;
begin
  Result := AUri.StartsWith('file://', True);
  LogDebug('IsFileUri(%s) = %s', [AUri, BoolToStr(Result, True)]);
end;

{ Legacy functions }

function PathToFileUri(const APath: string): string;
begin
  Result := TPathUtils.PathToFileUri(APath);
end;

function FileUriToPath(const AUri: string): string;
begin
  Result := TPathUtils.FileUriToPath(AUri);
end;

initialization
  // Initialize with debug mode off by default
  TPathUtils.Initialize;
  TPathUtils.DebugMode := False;

finalization
  // Cleanup if needed
end.
