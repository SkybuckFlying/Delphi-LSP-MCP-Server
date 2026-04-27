unit MCP.Protocol.Types;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections;

type
  TMCPProtocolVersion = string;

const
  MCP_PROTOCOL_VERSION = '2024-11-05';

type
  TMCPClientInfo = record
    Name: string;
    Version: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPClientInfo; static;
  end;

  TMCPServerInfo = record
    Name: string;
    Version: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPServerInfo; static;
  end;

  TMCPToolsCapability = record
    ListChanged: Boolean;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TMCPToolsCapability; static;
  end;

  TMCPCapabilities = record
    Tools: TMCPToolsCapability;
    HasTools: Boolean;
    Resources: TMCPToolsCapability;
    HasResources: Boolean;
    Prompts: TMCPToolsCapability;
    HasPrompts: Boolean;
    Roots: TMCPToolsCapability;
    HasRoots: Boolean;
    HasSampling: Boolean; // FIX: Was Boolean, spec says object
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TMCPCapabilities; static;
  end;

  TMCPInitializeParams = record
    ProtocolVersion: TMCPProtocolVersion;
    Capabilities: TMCPCapabilities;
    ClientInfo: TMCPClientInfo;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPInitializeParams; static;
  end;

  TMCPInitializeResult = record
    ProtocolVersion: TMCPProtocolVersion;
    Capabilities: TMCPCapabilities;
    ServerInfo: TMCPServerInfo;
    Instructions: string;
    HasInstructions: Boolean;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPInitializeResult; static;
  end;

  TMCPToolInputSchema = class
  public
    SchemaType: string;
    Properties: TJSONObject; // Owned
    Required: TArray<string>;
    constructor Create;
    destructor Destroy; override;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPToolInputSchema; static;
  end;

  TMCPTool = class
  public
    Name: string;
    Description: string;
    InputSchema: TMCPToolInputSchema; // Owned, optional
    constructor Create;
    destructor Destroy; override;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPTool; static;
  end;

  TMCPToolCallParams = class
  public
    Name: string;
    Arguments: TJSONObject; // Owned
    constructor Create;
    destructor Destroy; override;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPToolCallParams; static;
  end;

  TMCPContentItem = class
  public
    ContentType: string; // "text", "image", "resource"
    Text: string;
    Data: string; // base64 for image
    MimeType: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPContentItem; static;
  end;

  TMCPToolCallResult = class
  public
    Content: TObjectList<TMCPContentItem>; // Owned
    IsError: Boolean;
    constructor Create;
    destructor Destroy; override;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPToolCallResult; static;
  end;

implementation

{ TMCPClientInfo }

function TMCPClientInfo.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', Name);
  Result.AddPair('version', Version);
end;

class function TMCPClientInfo.FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPClientInfo;
begin
  Result.Name := '';
  Result.Version := '';
  IsValid := False;
  if not Assigned(AJson) then
    Exit;
  IsValid :=
    AJson.TryGetValue<string>('name', Result.Name) and
    AJson.TryGetValue<string>('version', Result.Version);
end;

{ TMCPServerInfo }

function TMCPServerInfo.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', Name);
  Result.AddPair('version', Version);
end;

class function TMCPServerInfo.FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPServerInfo;
begin
  Result.Name := '';
  Result.Version := '';
  IsValid := False;
  if not Assigned(AJson) then
    Exit;
  IsValid :=
    AJson.TryGetValue<string>('name', Result.Name) and
    AJson.TryGetValue<string>('version', Result.Version);
end;

{ TMCPToolsCapability }

function TMCPToolsCapability.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  if ListChanged then
    Result.AddPair('listChanged', TJSONBool.Create(True));
end;

class function TMCPToolsCapability.FromJSON(AJson: TJSONObject): TMCPToolsCapability;
begin
  Result.ListChanged := False;
  if Assigned(AJson) then
    AJson.TryGetValue<Boolean>('listChanged', Result.ListChanged);
end;

{ TMCPCapabilities }

function TMCPCapabilities.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  if HasTools then
    Result.AddPair('tools', Tools.ToJSON);
  if HasResources then
    Result.AddPair('resources', Resources.ToJSON);
  if HasPrompts then
    Result.AddPair('prompts', Prompts.ToJSON);
  if HasRoots then
    Result.AddPair('roots', Roots.ToJSON);
  if HasSampling then
    Result.AddPair('sampling', TJSONObject.Create); // FIX: Empty object per spec
end;

class function TMCPCapabilities.FromJSON(AJson: TJSONObject): TMCPCapabilities;
var
  Val: TJSONValue;
begin
  Result.HasTools := False;
  Result.HasResources := False;
  Result.HasPrompts := False;
  Result.HasRoots := False;
  Result.HasSampling := False;
  if not Assigned(AJson) then
    Exit;

  Val := AJson.GetValue('tools');
  if Val is TJSONObject then
  begin
    Result.Tools := TMCPToolsCapability.FromJSON(TJSONObject(Val));
    Result.HasTools := True;
  end;

  Val := AJson.GetValue('resources');
  if Val is TJSONObject then
  begin
    Result.Resources := TMCPToolsCapability.FromJSON(TJSONObject(Val));
    Result.HasResources := True;
  end;

  Val := AJson.GetValue('prompts');
  if Val is TJSONObject then
  begin
    Result.Prompts := TMCPToolsCapability.FromJSON(TJSONObject(Val));
    Result.HasPrompts := True;
  end;

  Val := AJson.GetValue('roots');
  if Val is TJSONObject then
  begin
    Result.Roots := TMCPToolsCapability.FromJSON(TJSONObject(Val));
    Result.HasRoots := True;
  end;

  Result.HasSampling := Assigned(AJson.GetValue('sampling')); // FIX: Check existence
end;

{ TMCPInitializeParams }

function TMCPInitializeParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('protocolVersion', ProtocolVersion);
  Result.AddPair('capabilities', Capabilities.ToJSON);
  Result.AddPair('clientInfo', ClientInfo.ToJSON);
end;

class function TMCPInitializeParams.FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPInitializeParams;
var
  Val: TJSONValue;
  OkClient: Boolean;
begin
  IsValid := False;
  if not Assigned(AJson) then
    Exit;

  IsValid := AJson.TryGetValue<string>('protocolVersion', Result.ProtocolVersion);
  if not IsValid then
    Exit;

  Val := AJson.GetValue('capabilities');
  if Val is TJSONObject then
    Result.Capabilities := TMCPCapabilities.FromJSON(TJSONObject(Val))
  else
    Exit;

  Val := AJson.GetValue('clientInfo');
  if Val is TJSONObject then
    Result.ClientInfo := TMCPClientInfo.FromJSON(TJSONObject(Val), OkClient)
  else
    Exit;

  IsValid := OkClient;
end;

{ TMCPInitializeResult }

function TMCPInitializeResult.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('protocolVersion', ProtocolVersion);
  Result.AddPair('capabilities', Capabilities.ToJSON);
  Result.AddPair('serverInfo', ServerInfo.ToJSON);
  if HasInstructions then
    Result.AddPair('instructions', Instructions);
end;

class function TMCPInitializeResult.FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPInitializeResult;
var
  Val: TJSONValue;
  OkServer: Boolean;
begin
  IsValid := False;
  Result.HasInstructions := False;
  if not Assigned(AJson) then
    Exit;

  IsValid := AJson.TryGetValue<string>('protocolVersion', Result.ProtocolVersion);
  if not IsValid then
    Exit;

  Val := AJson.GetValue('capabilities');
  if Val is TJSONObject then
    Result.Capabilities := TMCPCapabilities.FromJSON(TJSONObject(Val))
  else
    Exit;

  Val := AJson.GetValue('serverInfo');
  if Val is TJSONObject then
    Result.ServerInfo := TMCPServerInfo.FromJSON(TJSONObject(Val), OkServer)
  else
    Exit;

  IsValid := OkServer;
  Result.HasInstructions := AJson.TryGetValue<string>('instructions', Result.Instructions);
end;

{ TMCPToolInputSchema }

constructor TMCPToolInputSchema.Create;
begin
  inherited;
  Properties := nil;
end;

destructor TMCPToolInputSchema.Destroy;
begin
  Properties.Free;
  inherited;
end;

function TMCPToolInputSchema.ToJSON: TJSONObject;
var
  Arr: TJSONArray;
  I: Integer;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', SchemaType);
  if Assigned(Properties) then
    Result.AddPair('properties', Properties.Clone as TJSONObject);
  if Length(Required) > 0 then
  begin
    Arr := TJSONArray.Create;
    for I := 0 to High(Required) do
      Arr.Add(Required[I]);
    Result.AddPair('required', Arr);
  end;
end;

class function TMCPToolInputSchema.FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPToolInputSchema;
var
  Arr: TJSONArray;
  I: Integer;
  Val: TJSONValue;
begin
  Result := TMCPToolInputSchema.Create;
  IsValid := False;
  if not Assigned(AJson) then
  begin
    FreeAndNil(Result);
    Exit;
  end;

  IsValid := AJson.TryGetValue<string>('type', Result.SchemaType);
  if not IsValid then
  begin
    FreeAndNil(Result);
    Exit;
  end;

  Val := AJson.GetValue('properties');
  if Val is TJSONObject then
    Result.Properties := TJSONObject(Val).Clone as TJSONObject;

  Arr := AJson.GetValue('required') as TJSONArray;
  if Assigned(Arr) then
  begin
    SetLength(Result.Required, Arr.Count);
    for I := 0 to Arr.Count - 1 do
      Result.Required[I] := Arr.Items[I].Value;
  end;
end;

{ TMCPTool }

constructor TMCPTool.Create;
begin
  inherited;
  InputSchema := nil;
end;

destructor TMCPTool.Destroy;
begin
  InputSchema.Free;
  inherited;
end;

function TMCPTool.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', Name);
  Result.AddPair('description', Description);
  if Assigned(InputSchema) then // FIX: inputSchema optional
    Result.AddPair('inputSchema', InputSchema.ToJSON);
end;

class function TMCPTool.FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPTool;
var
  Val: TJSONValue;
  OkSchema: Boolean;
begin
  Result := TMCPTool.Create;
  IsValid := False;
  if not Assigned(AJson) then
  begin
    FreeAndNil(Result);
    Exit;
  end;

  IsValid :=
    AJson.TryGetValue<string>('name', Result.Name) and
    AJson.TryGetValue<string>('description', Result.Description);
  if not IsValid then
  begin
    FreeAndNil(Result);
    Exit;
  end;

  Val := AJson.GetValue('inputSchema');
  if Val is TJSONObject then
  begin
    Result.InputSchema := TMCPToolInputSchema.FromJSON(TJSONObject(Val), OkSchema);
    IsValid := OkSchema;
    if not IsValid then
    begin
      FreeAndNil(Result);
      Exit;
    end;
  end
  else
    IsValid := True; // FIX: inputSchema is optional per MCP spec
end;

{ TMCPToolCallParams }

constructor TMCPToolCallParams.Create;
begin
  inherited;
  Arguments := nil;
end;

destructor TMCPToolCallParams.Destroy;
begin
  Arguments.Free;
  inherited;
end;

function TMCPToolCallParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', Name);
  if Assigned(Arguments) then
    Result.AddPair('arguments', Arguments.Clone as TJSONObject);
end;

class function TMCPToolCallParams.FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPToolCallParams;
var
  Val: TJSONValue;
begin
  Result := TMCPToolCallParams.Create;
  IsValid := False;
  if not Assigned(AJson) then
  begin
    FreeAndNil(Result);
    Exit;
  end;

  IsValid := AJson.TryGetValue<string>('name', Result.Name);
  if not IsValid then
  begin
    FreeAndNil(Result);
    Exit;
  end;

  Val := AJson.GetValue('arguments');
  if Val is TJSONObject then
    Result.Arguments := TJSONObject(Val).Clone as TJSONObject;
end;

{ TMCPContentItem }

function TMCPContentItem.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', ContentType);
  if ContentType = 'text' then
    Result.AddPair('text', Text)
  else if ContentType = 'image' then
  begin
    Result.AddPair('data', Data);
    Result.AddPair('mimeType', MimeType);
  end
  else if ContentType = 'resource' then
  begin
    // Spec extension point: resource content
  end;
end;

class function TMCPContentItem.FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPContentItem;
begin
  Result := TMCPContentItem.Create;
  IsValid := False;
  if not Assigned(AJson) then
  begin
    FreeAndNil(Result);
    Exit;
  end;

  IsValid := AJson.TryGetValue<string>('type', Result.ContentType);
  if not IsValid then
  begin
    FreeAndNil(Result);
    Exit;
  end;

  if Result.ContentType = 'text' then
    AJson.TryGetValue<string>('text', Result.Text)
  else if Result.ContentType = 'image' then
  begin
    AJson.TryGetValue<string>('data', Result.Data);
    AJson.TryGetValue<string>('mimeType', Result.MimeType);
  end
  else if Result.ContentType = 'resource' then
  begin
    // Spec extension point
  end;
end;

{ TMCPToolCallResult }

constructor TMCPToolCallResult.Create;
begin
  inherited;
  Content := TObjectList<TMCPContentItem>.Create(True);
  IsError := False;
end;

destructor TMCPToolCallResult.Destroy;
begin
  Content.Free;
  inherited;
end;

function TMCPToolCallResult.ToJSON: TJSONObject;
var
  Arr: TJSONArray;
  I: Integer;
begin
  Result := TJSONObject.Create;
  Arr := TJSONArray.Create;
  for I := 0 to Content.Count - 1 do
    Arr.Add(Content[I].ToJSON);
  Result.AddPair('content', Arr);
  if IsError then
    Result.AddPair('isError', TJSONBool.Create(True));
end;

class function TMCPToolCallResult.FromJSON(AJson: TJSONObject; out IsValid: Boolean): TMCPToolCallResult;
var
  Arr: TJSONArray;
  I: Integer;
  Item: TMCPContentItem;
  OkItem: Boolean;
begin
  Result := TMCPToolCallResult.Create;
  IsValid := False;
  if not Assigned(AJson) then
  begin
    FreeAndNil(Result);
    Exit;
  end;

  Arr := AJson.GetValue('content') as TJSONArray;
  if not Assigned(Arr) then
  begin
    FreeAndNil(Result);
    Exit;
  end;

  for I := 0 to Arr.Count - 1 do
  begin
    if Arr.Items[I] is TJSONObject then
    begin
      Item := TMCPContentItem.FromJSON(TJSONObject(Arr.Items[I]), OkItem);
      if OkItem then
        Result.Content.Add(Item)
      else
        Item.Free;
    end;
  end;

  Result.IsError := False;
  AJson.TryGetValue<Boolean>('isError', Result.IsError);
  IsValid := True;
end;

end.