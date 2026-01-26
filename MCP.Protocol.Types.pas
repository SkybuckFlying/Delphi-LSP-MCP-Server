unit MCP.Protocol.Types;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections;

type
  // MCP Protocol Version
  TMCPProtocolVersion = string;

const
  MCP_PROTOCOL_VERSION = '2024-11-05';

type
  // MCP Client Information
  TMCPClientInfo = record
    Name: string;
    Version: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TMCPClientInfo; static;
  end;

  // MCP Server Information
  TMCPServerInfo = record
    Name: string;
    Version: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TMCPServerInfo; static;
  end;

  // MCP Capabilities
  TMCPCapabilities = record
    Tools: Boolean;
    Resources: Boolean;
    Prompts: Boolean;
    Sampling: Boolean;
    Roots: Boolean;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TMCPCapabilities; static;
    class function Default: TMCPCapabilities; static;
  end;

  // MCP Initialize Request Parameters
  TMCPInitializeParams = record
    ProtocolVersion: TMCPProtocolVersion;
    Capabilities: TMCPCapabilities;
    ClientInfo: TMCPClientInfo;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TMCPInitializeParams; static;
  end;

  // MCP Initialize Result
  TMCPInitializeResult = record
    ProtocolVersion: TMCPProtocolVersion;
    Capabilities: TMCPCapabilities;
    ServerInfo: TMCPServerInfo;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TMCPInitializeResult; static;
  end;

  // MCP Tool Input Schema (JSON Schema)
  TMCPToolInputSchema = record
    SchemaType: string; // "object"
    Properties: TJSONObject;
    Required: TArray<string>;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TMCPToolInputSchema; static;
  end;

  // MCP Tool Definition
  TMCPTool = record
    Name: string;
    Description: string;
    InputSchema: TMCPToolInputSchema;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TMCPTool; static;
  end;

  // MCP Tool Call Request Parameters
  TMCPToolCallParams = record
    Name: string;
    Arguments: TJSONObject;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TMCPToolCallParams; static;
  end;

  // MCP Tool Call Result
  TMCPToolCallResult = record
    Content: TArray<TJSONObject>; // Array of content items
    IsError: Boolean;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TMCPToolCallResult; static;
  end;

  // MCP Resource
  TMCPResource = record
    Uri: string;
    Name: string;
    Description: string;
    MimeType: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TMCPResource; static;
  end;

implementation

{ TMCPClientInfo }

function TMCPClientInfo.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', Name);
  Result.AddPair('version', Version);
end;

class function TMCPClientInfo.FromJSON(AJson: TJSONObject): TMCPClientInfo;
begin
  Result.Name := AJson.GetValue<string>('name');
  Result.Version := AJson.GetValue<string>('version');
end;

{ TMCPServerInfo }

function TMCPServerInfo.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', Name);
  Result.AddPair('version', Version);
end;

class function TMCPServerInfo.FromJSON(AJson: TJSONObject): TMCPServerInfo;
begin
  Result.Name := AJson.GetValue<string>('name');
  Result.Version := AJson.GetValue<string>('version');
end;

{ TMCPCapabilities }

function TMCPCapabilities.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  if Tools then
    Result.AddPair('tools', TJSONObject.Create);
  if Resources then
    Result.AddPair('resources', TJSONObject.Create);
  if Prompts then
    Result.AddPair('prompts', TJSONObject.Create);
  if Sampling then
    Result.AddPair('sampling', TJSONObject.Create);
  if Roots then
    Result.AddPair('roots', TJSONObject.Create);
end;

class function TMCPCapabilities.FromJSON(AJson: TJSONObject): TMCPCapabilities;
begin
  Result.Tools := Assigned(AJson.GetValue('tools'));
  Result.Resources := Assigned(AJson.GetValue('resources'));
  Result.Prompts := Assigned(AJson.GetValue('prompts'));
  Result.Sampling := Assigned(AJson.GetValue('sampling'));
  Result.Roots := Assigned(AJson.GetValue('roots'));
end;

class function TMCPCapabilities.Default: TMCPCapabilities;
begin
  Result.Tools := True;
  Result.Resources := False;
  Result.Prompts := False;
  Result.Sampling := False;
  Result.Roots := False;
end;

{ TMCPInitializeParams }

function TMCPInitializeParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('protocolVersion', ProtocolVersion);
  Result.AddPair('capabilities', Capabilities.ToJSON);
  Result.AddPair('clientInfo', ClientInfo.ToJSON);
end;

class function TMCPInitializeParams.FromJSON(AJson: TJSONObject): TMCPInitializeParams;
begin
  Result.ProtocolVersion := AJson.GetValue<string>('protocolVersion');
  Result.Capabilities := TMCPCapabilities.FromJSON(AJson.GetValue('capabilities') as TJSONObject);
  Result.ClientInfo := TMCPClientInfo.FromJSON(AJson.GetValue('clientInfo') as TJSONObject);
end;

{ TMCPInitializeResult }

function TMCPInitializeResult.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('protocolVersion', ProtocolVersion);
  Result.AddPair('capabilities', Capabilities.ToJSON);
  Result.AddPair('serverInfo', ServerInfo.ToJSON);
end;

class function TMCPInitializeResult.FromJSON(AJson: TJSONObject): TMCPInitializeResult;
begin
  Result.ProtocolVersion := AJson.GetValue<string>('protocolVersion');
  Result.Capabilities := TMCPCapabilities.FromJSON(AJson.GetValue('capabilities') as TJSONObject);
  Result.ServerInfo := TMCPServerInfo.FromJSON(AJson.GetValue('serverInfo') as TJSONObject);
end;

{ TMCPToolInputSchema }

function TMCPToolInputSchema.ToJSON: TJSONObject;
var
  RequiredArray: TJSONArray;
  I: Integer;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', SchemaType);
  if Assigned(Properties) then
    Result.AddPair('properties', Properties.Clone as TJSONObject);
  if Length(Required) > 0 then
  begin
    RequiredArray := TJSONArray.Create;
    for I := 0 to High(Required) do
      RequiredArray.Add(Required[I]);
    Result.AddPair('required', RequiredArray);
  end;
end;

class function TMCPToolInputSchema.FromJSON(AJson: TJSONObject): TMCPToolInputSchema;
var
  RequiredArray: TJSONArray;
  I: Integer;
begin
  Result.SchemaType := AJson.GetValue<string>('type');
  Result.Properties := AJson.GetValue('properties') as TJSONObject;
  if Assigned(Result.Properties) then
    Result.Properties := Result.Properties.Clone as TJSONObject;
  RequiredArray := AJson.GetValue('required') as TJSONArray;
  if Assigned(RequiredArray) then
  begin
    SetLength(Result.Required, RequiredArray.Count);
    for I := 0 to RequiredArray.Count - 1 do
      Result.Required[I] := RequiredArray.Items[I].Value;
  end;
end;

{ TMCPTool }

function TMCPTool.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', Name);
  Result.AddPair('description', Description);
  Result.AddPair('inputSchema', InputSchema.ToJSON);
end;

class function TMCPTool.FromJSON(AJson: TJSONObject): TMCPTool;
begin
  Result.Name := AJson.GetValue<string>('name');
  Result.Description := AJson.GetValue<string>('description');
  Result.InputSchema := TMCPToolInputSchema.FromJSON(AJson.GetValue('inputSchema') as TJSONObject);
end;

{ TMCPToolCallParams }

function TMCPToolCallParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', Name);
  if Assigned(Arguments) then
    Result.AddPair('arguments', Arguments.Clone as TJSONObject);
end;

class function TMCPToolCallParams.FromJSON(AJson: TJSONObject): TMCPToolCallParams;
begin
  Result.Name := AJson.GetValue<string>('name');
  Result.Arguments := AJson.GetValue('arguments') as TJSONObject;
  if Assigned(Result.Arguments) then
    Result.Arguments := Result.Arguments.Clone as TJSONObject;
end;

{ TMCPToolCallResult }

function TMCPToolCallResult.ToJSON: TJSONObject;
var
  ContentArray: TJSONArray;
  I: Integer;
begin
  Result := TJSONObject.Create;
  ContentArray := TJSONArray.Create;
  for I := 0 to High(Content) do
    ContentArray.Add(Content[I].Clone as TJSONObject);
  Result.AddPair('content', ContentArray);
  Result.AddPair('isError', TJSONBool.Create(IsError));
end;

class function TMCPToolCallResult.FromJSON(AJson: TJSONObject): TMCPToolCallResult;
var
  ContentArray: TJSONArray;
  I: Integer;
begin
  ContentArray := AJson.GetValue('content') as TJSONArray;
  if Assigned(ContentArray) then
  begin
    SetLength(Result.Content, ContentArray.Count);
    for I := 0 to ContentArray.Count - 1 do
      Result.Content[I] := ContentArray.Items[I].Clone as TJSONObject;
  end;
  Result.IsError := AJson.GetValue<Boolean>('isError');
end;

{ TMCPResource }

function TMCPResource.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('uri', Uri);
  Result.AddPair('name', Name);
  if Description <> '' then
    Result.AddPair('description', Description);
  if MimeType <> '' then
    Result.AddPair('mimeType', MimeType);
end;

class function TMCPResource.FromJSON(AJson: TJSONObject): TMCPResource;
begin
  Result.Uri := AJson.GetValue<string>('uri');
  Result.Name := AJson.GetValue<string>('name');
  if AJson.TryGetValue<string>('description', Result.Description) then;
  if AJson.TryGetValue<string>('mimeType', Result.MimeType) then;
end;

end.
