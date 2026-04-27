unit Common.Utils;

interface

uses
  System.SysUtils, System.NetEncoding, System.IOUtils;

function PathToFileUri(const APath: string): string;
function FileUriToPath(const AUri: string): string;

implementation

function PathToFileUri(const APath: string): string;
var
  S: string;
begin
  S := ExpandFileName(APath);
  S := StringReplace(S, '\', '/', [rfReplaceAll]);
  Result := 'file:///' + TNetEncoding.URL.Encode(S).Replace('%2F', '/').Replace('%3A', ':');
end;

function FileUriToPath(const AUri: string): string;
var
  S, Host, PathPart: string;
  SlashPos: Integer;
begin
  Result := '';
  if not AUri.StartsWith('file://', True) then
    Exit;

  S := AUri.Substring(7);
  SlashPos := Pos('/', S);
  if SlashPos = 0 then
  begin
    Host := '';
    PathPart := S;
  end
  else
  begin
    Host := Copy(S, 1, SlashPos - 1);
    PathPart := Copy(S, SlashPos + 1);
  end;

  if SameText(Host, 'localhost') or (Host = '') then
  begin
    Result := TNetEncoding.URL.Decode(PathPart);
    if (Result <> '') and (Result[1] = '/') then
      Delete(Result, 1, 1);
    Result := StringReplace(Result, '/', '\', [rfReplaceAll]);
  end
  else
  begin
    Result := '\\' + Host + '\' + StringReplace(TNetEncoding.URL.Decode(PathPart), '/', '\', [rfReplaceAll]);
  end;
end;

end.
