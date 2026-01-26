unit Common.JsonRpc;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections;

type
  // JSON-RPC 2.0 Error Codes
  TJsonRpcErrorCode = class
  public const
    ParseError = -32700;
    InvalidRequest = -32600;
    MethodNotFound = -32601;
    InvalidParams = -32602;
    InternalError = -32603;
    // Server error range: -32000 to -32099
    ServerErrorStart = -32099;
    ServerErrorEnd = -32000;
  end;

  // JSON-RPC 2.0 Message Types
  TJsonRpcMessageType = (jmtRequest, jmtResponse, jmtNotification, jmtError);

  // JSON-RPC 2.0 Error
  TJsonRpcError = class
  private
    FCode: Integer;
    FMessage: string;
    FData: TJSONValue;
  public
    constructor Create(ACode: Integer; const AMessage: string; AData: TJSONValue = nil);
    destructor Destroy; override;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TJsonRpcError;
    
    property Code: Integer read FCode write FCode;
    property Message: string read FMessage write FMessage;
    property Data: TJSONValue read FData write FData;
  end;

  // JSON-RPC 2.0 Request
  TJsonRpcRequest = class
  private
    FId: TJSONValue;
    FMethod: string;
    FParams: TJSONValue;
  public
    constructor Create(const AMethod: string; AParams: TJSONValue = nil; AId: TJSONValue = nil);
    destructor Destroy; override;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TJsonRpcRequest;
    
    property Id: TJSONValue read FId write FId;
    property Method: string read FMethod write FMethod;
    property Params: TJSONValue read FParams write FParams;
  end;

  // JSON-RPC 2.0 Response
  TJsonRpcResponse = class
  private
    FId: TJSONValue;
    FResult: TJSONValue;
    FError: TJsonRpcError;
  public
    constructor Create(AId: TJSONValue; AResult: TJSONValue = nil; AError: TJsonRpcError = nil);
    destructor Destroy; override;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TJsonRpcResponse;
    function IsError: Boolean;
    
    property Id: TJSONValue read FId write FId;
    property Result: TJSONValue read FResult write FResult;
    property Error: TJsonRpcError read FError write FError;
  end;

  // JSON-RPC 2.0 Notification
  TJsonRpcNotification = class
  private
    FMethod: string;
    FParams: TJSONValue;
  public
    constructor Create(const AMethod: string; AParams: TJSONValue = nil);
    destructor Destroy; override;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TJsonRpcNotification;
    
    property Method: string read FMethod write FMethod;
    property Params: TJSONValue read FParams write FParams;
  end;

  // Helper class for JSON-RPC operations
  TJsonRpcHelper = class
  private
    class var FNextId: Integer;
  public
    class function GenerateId: Integer;
    class function CreateRequest(const AMethod: string; AParams: TJSONValue = nil): TJsonRpcRequest;
    class function CreateNotification(const AMethod: string; AParams: TJSONValue = nil): TJsonRpcNotification;
    class function CreateSuccessResponse(AId: TJSONValue; AResult: TJSONValue): TJsonRpcResponse;
    class function CreateErrorResponse(AId: TJSONValue; ACode: Integer; const AMessage: string; AData: TJSONValue = nil): TJsonRpcResponse;
    class function ParseMessage(const AJsonText: string; out AMessageType: TJsonRpcMessageType): TObject;
    class function CloneJSONValue(AValue: TJSONValue): TJSONValue;
  end;

implementation

{ TJsonRpcError }

constructor TJsonRpcError.Create(ACode: Integer; const AMessage: string; AData: TJSONValue);
begin
  inherited Create;
  FCode := ACode;
  FMessage := AMessage;
  FData := AData;
end;

destructor TJsonRpcError.Destroy;
begin
  if Assigned(FData) then
    FData.Free;
  inherited;
end;

function TJsonRpcError.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('code', TJSONNumber.Create(FCode));
  Result.AddPair('message', FMessage);
  if Assigned(FData) then
    Result.AddPair('data', TJsonRpcHelper.CloneJSONValue(FData));
end;

class function TJsonRpcError.FromJSON(AJson: TJSONObject): TJsonRpcError;
var
  Code: Integer;
  Msg: string;
  Data: TJSONValue;
begin
  Code := AJson.GetValue<Integer>('code');
  Msg := AJson.GetValue<string>('message');
  Data := AJson.GetValue('data');
  if Assigned(Data) then
    Data := TJsonRpcHelper.CloneJSONValue(Data)
  else
    Data := nil;
  Result := TJsonRpcError.Create(Code, Msg, Data);
end;

{ TJsonRpcRequest }

constructor TJsonRpcRequest.Create(const AMethod: string; AParams: TJSONValue; AId: TJSONValue);
begin
  inherited Create;
  FMethod := AMethod;
  FParams := AParams;
  FId := AId;
end;

destructor TJsonRpcRequest.Destroy;
begin
  if Assigned(FParams) then
    FParams.Free;
  if Assigned(FId) then
    FId.Free;
  inherited;
end;

function TJsonRpcRequest.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('jsonrpc', '2.0');
  Result.AddPair('method', FMethod);
  if Assigned(FParams) then
    Result.AddPair('params', TJsonRpcHelper.CloneJSONValue(FParams));
  if Assigned(FId) then
    Result.AddPair('id', TJsonRpcHelper.CloneJSONValue(FId));
end;

class function TJsonRpcRequest.FromJSON(AJson: TJSONObject): TJsonRpcRequest;
var
  Method: string;
  Params, Id: TJSONValue;
begin
  Method := AJson.GetValue<string>('method');
  Params := AJson.GetValue('params');
  if Assigned(Params) then
    Params := TJsonRpcHelper.CloneJSONValue(Params)
  else
    Params := nil;
  Id := AJson.GetValue('id');
  if Assigned(Id) then
    Id := TJsonRpcHelper.CloneJSONValue(Id)
  else
    Id := nil;
  Result := TJsonRpcRequest.Create(Method, Params, Id);
end;

{ TJsonRpcResponse }

constructor TJsonRpcResponse.Create(AId: TJSONValue; AResult: TJSONValue; AError: TJsonRpcError);
begin
  inherited Create;
  FId := AId;
  FResult := AResult;
  FError := AError;
end;

destructor TJsonRpcResponse.Destroy;
begin
  if Assigned(FId) then
    FId.Free;
  if Assigned(FResult) then
    FResult.Free;
  if Assigned(FError) then
    FError.Free;
  inherited;
end;

function TJsonRpcResponse.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('jsonrpc', '2.0');
  if Assigned(FId) then
    Result.AddPair('id', TJsonRpcHelper.CloneJSONValue(FId))
  else
    Result.AddPair('id', TJSONNull.Create);
    
  if Assigned(FError) then
    Result.AddPair('error', FError.ToJSON)
  else if Assigned(FResult) then
    Result.AddPair('result', TJsonRpcHelper.CloneJSONValue(FResult))
  else
    Result.AddPair('result', TJSONNull.Create);
end;

class function TJsonRpcResponse.FromJSON(AJson: TJSONObject): TJsonRpcResponse;
var
  Id, ResultVal: TJSONValue;
  ErrorVal: TJSONObject;
  Error: TJsonRpcError;
begin
  Id := AJson.GetValue('id');
  if Assigned(Id) then
    Id := TJsonRpcHelper.CloneJSONValue(Id)
  else
    Id := nil;
    
  ErrorVal := AJson.GetValue('error') as TJSONObject;
  if Assigned(ErrorVal) then
  begin
    Error := TJsonRpcError.FromJSON(ErrorVal);
    Result := TJsonRpcResponse.Create(Id, nil, Error);
  end
  else
  begin
    ResultVal := AJson.GetValue('result');
    if Assigned(ResultVal) then
      ResultVal := TJsonRpcHelper.CloneJSONValue(ResultVal)
    else
      ResultVal := nil;
    Result := TJsonRpcResponse.Create(Id, ResultVal, nil);
  end;
end;

function TJsonRpcResponse.IsError: Boolean;
begin
  Result := Assigned(FError);
end;

{ TJsonRpcNotification }

constructor TJsonRpcNotification.Create(const AMethod: string; AParams: TJSONValue);
begin
  inherited Create;
  FMethod := AMethod;
  FParams := AParams;
end;

destructor TJsonRpcNotification.Destroy;
begin
  if Assigned(FParams) then
    FParams.Free;
  inherited;
end;

function TJsonRpcNotification.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('jsonrpc', '2.0');
  Result.AddPair('method', FMethod);
  if Assigned(FParams) then
    Result.AddPair('params', TJsonRpcHelper.CloneJSONValue(FParams));
end;

class function TJsonRpcNotification.FromJSON(AJson: TJSONObject): TJsonRpcNotification;
var
  Method: string;
  Params: TJSONValue;
begin
  Method := AJson.GetValue<string>('method');
  Params := AJson.GetValue('params');
  if Assigned(Params) then
    Params := TJsonRpcHelper.CloneJSONValue(Params)
  else
    Params := nil;
  Result := TJsonRpcNotification.Create(Method, Params);
end;

{ TJsonRpcHelper }

class function TJsonRpcHelper.GenerateId: Integer;
begin
  Inc(FNextId);
  Result := FNextId;
end;

class function TJsonRpcHelper.CreateRequest(const AMethod: string; AParams: TJSONValue): TJsonRpcRequest;
begin
  Result := TJsonRpcRequest.Create(AMethod, AParams, TJSONNumber.Create(GenerateId));
end;

class function TJsonRpcHelper.CreateNotification(const AMethod: string; AParams: TJSONValue): TJsonRpcNotification;
begin
  Result := TJsonRpcNotification.Create(AMethod, AParams);
end;

class function TJsonRpcHelper.CreateSuccessResponse(AId: TJSONValue; AResult: TJSONValue): TJsonRpcResponse;
begin
  Result := TJsonRpcResponse.Create(AId, AResult, nil);
end;

class function TJsonRpcHelper.CreateErrorResponse(AId: TJSONValue; ACode: Integer; const AMessage: string; AData: TJSONValue): TJsonRpcResponse;
var
  Error: TJsonRpcError;
begin
  Error := TJsonRpcError.Create(ACode, AMessage, AData);
  Result := TJsonRpcResponse.Create(AId, nil, Error);
end;

class function TJsonRpcHelper.ParseMessage(const AJsonText: string; out AMessageType: TJsonRpcMessageType): TObject;
var
  JsonObj: TJSONObject;
  HasId, HasMethod, HasResult, HasError: Boolean;
begin
  Result := nil;
  JsonObj := TJSONObject.ParseJSONValue(AJsonText) as TJSONObject;
  if not Assigned(JsonObj) then
    Exit;
    
  try
    HasId := Assigned(JsonObj.GetValue('id'));
    HasMethod := Assigned(JsonObj.GetValue('method'));
    HasResult := Assigned(JsonObj.GetValue('result'));
    HasError := Assigned(JsonObj.GetValue('error'));
    
    if HasMethod and HasId then
    begin
      AMessageType := jmtRequest;
      Result := TJsonRpcRequest.FromJSON(JsonObj);
    end
    else if HasMethod and not HasId then
    begin
      AMessageType := jmtNotification;
      Result := TJsonRpcNotification.FromJSON(JsonObj);
    end
    else if (HasResult or HasError) and HasId then
    begin
      if HasError then
        AMessageType := jmtError
      else
        AMessageType := jmtResponse;
      Result := TJsonRpcResponse.FromJSON(JsonObj);
    end;
  finally
    JsonObj.Free;
  end;
end;

class function TJsonRpcHelper.CloneJSONValue(AValue: TJSONValue): TJSONValue;
var
  JsonText: string;
begin
  if not Assigned(AValue) then
    Exit(nil);
  JsonText := AValue.ToJSON;
  Result := TJSONObject.ParseJSONValue(JsonText);
end;

initialization
  TJsonRpcHelper.FNextId := 0;

end.
