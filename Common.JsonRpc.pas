unit Common.JsonRpc;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.SyncObjs;

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
    ServerErrorStart = -32000;
    ServerErrorEnd = -32099;
  end;

  // JSON-RPC 2.0 Message Types
  TJsonRpcMessageType = (jmtRequest, jmtResponse, jmtNotification, jmtInvalid);

  // JSON-RPC 2.0 Error
  TJsonRpcError = class
  private
    FCode: Integer;
    FMessage: string;
    FData: TJSONValue;
  public
    // Takes ownership of a clone of AData. Caller retains ownership of AData.
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
    // Takes ownership of clones of AParams and AId. Caller retains ownership of passed values.
    constructor Create(const AMethod: string; AParams: TJSONValue = nil; AId: TJSONValue = nil);
    destructor Destroy; override;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out AError: string): TJsonRpcRequest;
    
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
    // Takes ownership of clones of AId and AResult. Takes ownership of AError object directly.
    constructor Create(AId: TJSONValue; AResult: TJSONValue = nil; AError: TJsonRpcError = nil);
    destructor Destroy; override;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out AError: string): TJsonRpcResponse;
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
    // Takes ownership of a clone of AParams. Caller retains ownership of passed value.
    constructor Create(const AMethod: string; AParams: TJSONValue = nil);
    destructor Destroy; override;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out AError: string): TJsonRpcNotification;
    
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
    // Returns object + message type + detailed error string. Returns nil + jmtInvalid on error.
    class function ParseMessage(const AJsonText: string; out AMessageType: TJsonRpcMessageType; out AError: string): TObject;
    class function CloneJSONValue(AValue: TJSONValue): TJSONValue;
  end;

implementation

{ TJsonRpcError }

constructor TJsonRpcError.Create(ACode: Integer; const AMessage: string; AData: TJSONValue);
begin
  inherited Create;
  FCode := ACode;
  FMessage := AMessage;
  FData := TJsonRpcHelper.CloneJSONValue(AData); // Clone to avoid dangling pointer/double-free
end;

destructor TJsonRpcError.Destroy;
begin
  FData.Free;
  inherited;
end;

function TJsonRpcError.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('code', TJSONNumber.Create(FCode));
  Result.AddPair('message', FMessage);
  if Assigned(FData) then
    Result.AddPair('data', FData.Clone as TJSONValue);
end;

class function TJsonRpcError.FromJSON(AJson: TJSONObject): TJsonRpcError;
var
  Code: Integer;
  Msg: string;
  Data: TJSONValue;
begin
  if not AJson.TryGetValue<Integer>('code', Code) then
    Code := TJsonRpcErrorCode.InternalError;
  if not AJson.TryGetValue<string>('message', Msg) then
    Msg := 'Unknown error';
  Data := AJson.GetValue('data'); // ctor will clone
  Result := TJsonRpcError.Create(Code, Msg, Data);
end;

{ TJsonRpcRequest }

constructor TJsonRpcRequest.Create(const AMethod: string; AParams: TJSONValue; AId: TJSONValue);
begin
  inherited Create;
  FMethod := AMethod;
  FParams := TJsonRpcHelper.CloneJSONValue(AParams);
  FId := TJsonRpcHelper.CloneJSONValue(AId);
end;

destructor TJsonRpcRequest.Destroy;
begin
  FParams.Free;
  FId.Free;
  inherited;
end;

function TJsonRpcRequest.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('jsonrpc', '2.0');
  Result.AddPair('method', FMethod);
  if Assigned(FParams) then
    Result.AddPair('params', FParams.Clone as TJSONValue);
  if Assigned(FId) then
    Result.AddPair('id', FId.Clone as TJSONValue);
end;

class function TJsonRpcRequest.FromJSON(AJson: TJSONObject; out AError: string): TJsonRpcRequest;
var
  Method: string;
  Params, Id: TJSONValue;
begin
  Result := nil;
  AError := '';
  
  if not AJson.TryGetValue<string>('method', Method) then
  begin
    AError := 'Missing "method" field';
    Exit;
  end;
  
  Params := AJson.GetValue('params');
  Id := AJson.GetValue('id');
  
  try
    Result := TJsonRpcRequest.Create(Method, Params, Id);
  except
    on E: Exception do
      AError := 'Failed to create request: ' + E.Message;
  end;
end;

{ TJsonRpcResponse }

constructor TJsonRpcResponse.Create(AId: TJSONValue; AResult: TJSONValue; AError: TJsonRpcError);
begin
  inherited Create;
  FId := TJsonRpcHelper.CloneJSONValue(AId);
  FResult := TJsonRpcHelper.CloneJSONValue(AResult);
  FError := AError; // Takes ownership of error object directly
end;

destructor TJsonRpcResponse.Destroy;
begin
  FId.Free;
  FResult.Free;
  FError.Free;
  inherited;
end;

function TJsonRpcResponse.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('jsonrpc', '2.0');
  
  if Assigned(FId) then
    Result.AddPair('id', FId.Clone as TJSONValue)
  else
    Result.AddPair('id', TJSONNull.Create);
    
  if Assigned(FError) then
    Result.AddPair('error', FError.ToJSON)
  else
  begin
    if Assigned(FResult) then
      Result.AddPair('result', FResult.Clone as TJSONValue)
    else
      Result.AddPair('result', TJSONNull.Create);
  end;
end;

class function TJsonRpcResponse.FromJSON(AJson: TJSONObject; out AError: string): TJsonRpcResponse;
var
  Id, ResultVal: TJSONValue;
  ErrorVal: TJSONValue;
  ErrorObj: TJsonRpcError;
begin
  Result := nil;
  AError := '';
  ErrorObj := nil;
  
  Id := AJson.GetValue('id');
  ErrorVal := AJson.GetValue('error');
  ResultVal := AJson.GetValue('result');
  
  if Assigned(ErrorVal) and Assigned(ResultVal) then
  begin
    AError := 'Response cannot have both "result" and "error"';
    Exit;
  end;
  
  if not Assigned(ErrorVal) and not Assigned(ResultVal) then
  begin
    AError := 'Response must have either "result" or "error"';
    Exit;
  end;
  
  try
    if Assigned(ErrorVal) and (ErrorVal is TJSONObject) then
      ErrorObj := TJsonRpcError.FromJSON(TJSONObject(ErrorVal));
    Result := TJsonRpcResponse.Create(Id, ResultVal, ErrorObj);
  except
    on E: Exception do
    begin
      ErrorObj.Free;
      AError := 'Failed to create response: ' + E.Message;
    end;
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
  FParams := TJsonRpcHelper.CloneJSONValue(AParams);
end;

destructor TJsonRpcNotification.Destroy;
begin
  FParams.Free;
  inherited;
end;

function TJsonRpcNotification.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('jsonrpc', '2.0');
  Result.AddPair('method', FMethod);
  if Assigned(FParams) then
    Result.AddPair('params', FParams.Clone as TJSONValue);
end;

class function TJsonRpcNotification.FromJSON(AJson: TJSONObject; out AError: string): TJsonRpcNotification;
var
  Method: string;
  Params: TJSONValue;
begin
  Result := nil;
  AError := '';
  
  if not AJson.TryGetValue<string>('method', Method) then
  begin
    AError := 'Missing "method" field';
    Exit;
  end;
  
  Params := AJson.GetValue('params');
  
  try
    Result := TJsonRpcNotification.Create(Method, Params);
  except
    on E: Exception do
      AError := 'Failed to create notification: ' + E.Message;
  end;
end;

{ TJsonRpcHelper }

class function TJsonRpcHelper.GenerateId: Integer;
begin
  Result := TInterlocked.Increment(FNextId);
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
  // TJsonRpcError.Create clones AData, TJsonRpcResponse.Create clones AId
  // So caller can free both AId and AData after this call
  Error := TJsonRpcError.Create(ACode, AMessage, AData);
  Result := TJsonRpcResponse.Create(AId, nil, Error);
end;

class function TJsonRpcHelper.ParseMessage(const AJsonText: string; out AMessageType: TJsonRpcMessageType; out AError: string): TObject;
var
  JsonVal: TJSONValue;
  JsonObj: TJSONObject;
  JsonRpcVer: string;
  HasId, HasMethod, HasResult, HasError: Boolean;
begin
  Result := nil;
  AMessageType := jmtInvalid;
  AError := '';
  
  JsonVal := TJSONObject.ParseJSONValue(AJsonText);
  if not Assigned(JsonVal) then
  begin
    AError := 'Parse error: invalid JSON';
    Exit;
  end;
  
  try
    if not (JsonVal is TJSONObject) then
    begin
      AError := 'Parse error: JSON value is not an object';
      Exit;
    end;
    
    JsonObj := TJSONObject(JsonVal);
    
    if not JsonObj.TryGetValue<string>('jsonrpc', JsonRpcVer) or (JsonRpcVer <> '2.0') then
    begin
      AError := 'Invalid Request: missing or invalid "jsonrpc" field, must be "2.0"';
      Exit;
    end;
    
    HasId := Assigned(JsonObj.GetValue('id'));
    HasMethod := Assigned(JsonObj.GetValue('method'));
    HasResult := Assigned(JsonObj.GetValue('result'));
    HasError := Assigned(JsonObj.GetValue('error'));
    
    try
      if HasMethod and HasId then
      begin
        AMessageType := jmtRequest;
        Result := TJsonRpcRequest.FromJSON(JsonObj, AError);
      end
      else if HasMethod and not HasId then
      begin
        AMessageType := jmtNotification;
        Result := TJsonRpcNotification.FromJSON(JsonObj, AError);
      end
      else if (HasResult or HasError) then
      begin
        AMessageType := jmtResponse;
        Result := TJsonRpcResponse.FromJSON(JsonObj, AError);
      end
      else
      begin
        AError := 'Invalid Request: cannot determine message type';
      end;
    except
      on E: Exception do
        AError := 'Parse error: ' + E.Message;
    end;
    
    if (AError <> '') and Assigned(Result) then
      FreeAndNil(Result);
      
  finally
    JsonVal.Free;
  end;
end;

class function TJsonRpcHelper.CloneJSONValue(AValue: TJSONValue): TJSONValue;
begin
  if not Assigned(AValue) then
    Exit(nil);
  Result := AValue.Clone as TJSONValue;
end;

initialization
  TJsonRpcHelper.FNextId := 0;

end.