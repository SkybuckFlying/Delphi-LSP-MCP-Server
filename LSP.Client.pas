unit LSP.Client;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections, System.SyncObjs,
  Winapi.Windows,
  Common.JsonRpc, Common.Logging, LSP.Protocol.Types, LSP.Transport.Process;

type
  TLSPResponseCallback = reference to procedure(AResponse: TJsonRpcResponse);

  TLSPClient = class
  private
    FTransport: TLSPProcessTransport;
    FInitialized: Boolean;
    FPendingRequests: TDictionary<Integer, TLSPResponseCallback>;
    FLock: TCriticalSection;
    FServerCapabilities: TJSONObject;
    
    procedure HandleMessage(const AMessage: string);
    procedure HandleResponse(AResponse: TJsonRpcResponse);
    procedure HandleNotification(ANotification: TJsonRpcNotification);
    function SendRequest(const AMethod: string; AParams: TJSONValue): Integer;
    procedure SendNotification(const AMethod: string; AParams: TJSONValue);
  public
    constructor Create(const ALSPPath: string);
    destructor Destroy; override;
    
    function Initialize(const ARootUri: string; AInitializationOptions: TJSONObject = nil): Boolean;
    procedure Shutdown;
    
    // Synchronous LSP operations
    function GetDefinition(const AUri: string; ALine, ACharacter: Integer): TArray<TLSPLocation>;
    function GetReferences(const AUri: string; ALine, ACharacter: Integer; AIncludeDeclaration: Boolean): TArray<TLSPLocation>;
    function GetHover(const AUri: string; ALine, ACharacter: Integer; out AHover: TLSPHover): Boolean;
    function GetCompletion(const AUri: string; ALine, ACharacter: Integer): TArray<TLSPCompletionItem>;
    function GetWorkspaceSymbols(const AQuery: string): TArray<TLSPSymbolInformation>;
    
    // Document synchronization
    procedure DidOpenTextDocument(const AUri, ALanguageId, AText: string; AVersion: Integer = 1);
    procedure DidCloseTextDocument(const AUri: string);
    
    property Initialized: Boolean read FInitialized;
    property ServerCapabilities: TJSONObject read FServerCapabilities;
  end;

implementation

{ TLSPClient }

constructor TLSPClient.Create(const ALSPPath: string);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FPendingRequests := TDictionary<Integer, TLSPResponseCallback>.Create;
  FTransport := TLSPProcessTransport.Create(ALSPPath);
  FTransport.OnMessageReceived := HandleMessage;
  FInitialized := False;
  FServerCapabilities := nil;
end;

destructor TLSPClient.Destroy;
begin
  Shutdown;
  FTransport.Free;
  FPendingRequests.Free;
  FLock.Free;
  if Assigned(FServerCapabilities) then
    FServerCapabilities.Free;
  inherited;
end;

function TLSPClient.Initialize(const ARootUri: string; AInitializationOptions: TJSONObject = nil): Boolean;
var
  Params: TLSPInitializeParams;
  ParamsJson: TJSONObject;
  RequestId: Integer;
  Event: TEvent;
  InitResult: TLSPInitializeResult;
  Success: Boolean;
begin
  Result := False;
  Success := False;
  
  if not FTransport.Start then
  begin
    Logger.Error('Failed to start LSP transport');
    Exit;
  end;
  
  // Prepare initialize params
  Params.ProcessId := GetCurrentProcessId;
  Params.RootUri := ARootUri;
  Params.Capabilities := TJSONObject.Create;
  
  if Assigned(AInitializationOptions) then
    Params.InitializationOptions := AInitializationOptions.Clone as TJSONObject
  else
    Params.InitializationOptions := nil;
    
  ParamsJson := Params.ToJSON;
  
  Event := TEvent.Create(nil, True, False, '');
  try
    // Send initialize request
    FLock.Enter;
    try
      RequestId := SendRequest('initialize', ParamsJson);
      FPendingRequests.Add(RequestId, 
        procedure(AResponse: TJsonRpcResponse)
        begin
          if not AResponse.IsError then
          begin
            try
              InitResult := TLSPInitializeResult.FromJSON(AResponse.Result as TJSONObject);
              FServerCapabilities := InitResult.Capabilities;
              Success := True;
              Logger.Info('LSP initialized successfully');
            except
              on E: Exception do
                Logger.Error('Failed to parse initialize result: %s', [E.Message]);
            end;
          end
          else
            Logger.Error('LSP initialize failed: %s', [AResponse.Error.Message]);
          Event.SetEvent;
        end);
    finally
      FLock.Leave;
    end;
    
    // Wait for response (timeout 30 seconds)
    if Event.WaitFor(30000) = wrSignaled then
    begin
      if Success then
      begin
        // Send initialized notification
        SendNotification('initialized', TJSONObject.Create);
        FInitialized := True;
        Result := True;
      end;
    end
    else
      Logger.Error('LSP initialize timeout');
  finally
    Event.Free;
  end;
end;

procedure TLSPClient.Shutdown;
begin
  if FInitialized then
  begin
    SendRequest('shutdown', nil);
    SendNotification('exit', nil);
    FInitialized := False;
  end;
  FTransport.Stop;
end;

function TLSPClient.SendRequest(const AMethod: string; AParams: TJSONValue): Integer;
var
  Request: TJsonRpcRequest;
  RequestJson: TJSONObject;
begin
  Request := TJsonRpcHelper.CreateRequest(AMethod, AParams);
  try
    Result := (Request.Id as TJSONNumber).AsInt;
    RequestJson := Request.ToJSON;
    try
      FTransport.SendMessage(RequestJson.ToJSON);
    finally
      RequestJson.Free;
    end;
  finally
    Request.Free;
  end;
end;

procedure TLSPClient.SendNotification(const AMethod: string; AParams: TJSONValue);
var
  Notification: TJsonRpcNotification;
  NotificationJson: TJSONObject;
begin
  Notification := TJsonRpcHelper.CreateNotification(AMethod, AParams);
  try
    NotificationJson := Notification.ToJSON;
    try
      FTransport.SendMessage(NotificationJson.ToJSON);
    finally
      NotificationJson.Free;
    end;
  finally
    Notification.Free;
  end;
end;

procedure TLSPClient.HandleMessage(const AMessage: string);
var
  MessageType: TJsonRpcMessageType;
  MessageObj: TObject;
begin
  MessageObj := TJsonRpcHelper.ParseMessage(AMessage, MessageType);
  if not Assigned(MessageObj) then
    Exit;
    
  try
    case MessageType of
      jmtResponse, jmtError:
        HandleResponse(MessageObj as TJsonRpcResponse);
      jmtNotification:
        HandleNotification(MessageObj as TJsonRpcNotification);
    end;
  finally
    MessageObj.Free;
  end;
end;

procedure TLSPClient.HandleResponse(AResponse: TJsonRpcResponse);
var
  RequestId: Integer;
  Callback: TLSPResponseCallback;
begin
  if not Assigned(AResponse.Id) then
    Exit;
    
  RequestId := (AResponse.Id as TJSONNumber).AsInt;
  
  FLock.Enter;
  try
    if FPendingRequests.TryGetValue(RequestId, Callback) then
    begin
      FPendingRequests.Remove(RequestId);
      if Assigned(Callback) then
        Callback(AResponse);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TLSPClient.HandleNotification(ANotification: TJsonRpcNotification);
begin
  // Handle server notifications (e.g., diagnostics, log messages)
  Logger.Debug('LSP notification: %s', [ANotification.Method]);
end;

function TLSPClient.GetDefinition(const AUri: string; ALine, ACharacter: Integer): TArray<TLSPLocation>;
var
  Params: TLSPDefinitionParams;
  ParamsJson: TJSONObject;
  RequestId: Integer;
  Event: TEvent;
  Locations: TArray<TLSPLocation>;
begin
  SetLength(Result, 0);
  
  if not FInitialized then
    Exit;
    
  Params.TextDocument.Uri := AUri;
  Params.Position.Line := ALine;
  Params.Position.Character := ACharacter;
  ParamsJson := Params.ToJSON;
  
  Event := TEvent.Create(nil, True, False, '');
  try
    FLock.Enter;
    try
      RequestId := SendRequest('textDocument/definition', ParamsJson);
      FPendingRequests.Add(RequestId,
        procedure(AResponse: TJsonRpcResponse)
        var
          ResultArray: TJSONArray;
          I: Integer;
        begin
          if not AResponse.IsError and Assigned(AResponse.Result) then
          begin
            if AResponse.Result is TJSONArray then
            begin
              ResultArray := AResponse.Result as TJSONArray;
              SetLength(Locations, ResultArray.Count);
              for I := 0 to ResultArray.Count - 1 do
                Locations[I] := TLSPLocation.FromJSON(ResultArray.Items[I] as TJSONObject);
            end
            else if AResponse.Result is TJSONObject then
            begin
              SetLength(Locations, 1);
              Locations[0] := TLSPLocation.FromJSON(AResponse.Result as TJSONObject);
            end;
          end;
          Event.SetEvent;
        end);
    finally
      FLock.Leave;
    end;
    
    if Event.WaitFor(10000) = wrSignaled then
      Result := Locations;
  finally
    Event.Free;
  end;
end;

function TLSPClient.GetReferences(const AUri: string; ALine, ACharacter: Integer; AIncludeDeclaration: Boolean): TArray<TLSPLocation>;
var
  Params: TLSPReferenceParams;
  ParamsJson: TJSONObject;
  RequestId: Integer;
  Event: TEvent;
  Locations: TArray<TLSPLocation>;
begin
  SetLength(Result, 0);
  
  if not FInitialized then
    Exit;
    
  Params.TextDocument.Uri := AUri;
  Params.Position.Line := ALine;
  Params.Position.Character := ACharacter;
  Params.Context.IncludeDeclaration := AIncludeDeclaration;
  ParamsJson := Params.ToJSON;
  
  Event := TEvent.Create(nil, True, False, '');
  try
    FLock.Enter;
    try
      RequestId := SendRequest('textDocument/references', ParamsJson);
      FPendingRequests.Add(RequestId,
        procedure(AResponse: TJsonRpcResponse)
        var
          ResultArray: TJSONArray;
          I: Integer;
        begin
          if not AResponse.IsError and Assigned(AResponse.Result) and (AResponse.Result is TJSONArray) then
          begin
            ResultArray := AResponse.Result as TJSONArray;
            SetLength(Locations, ResultArray.Count);
            for I := 0 to ResultArray.Count - 1 do
              Locations[I] := TLSPLocation.FromJSON(ResultArray.Items[I] as TJSONObject);
          end;
          Event.SetEvent;
        end);
    finally
      FLock.Leave;
    end;
    
    if Event.WaitFor(10000) = wrSignaled then
      Result := Locations;
  finally
    Event.Free;
  end;
end;

function TLSPClient.GetHover(const AUri: string; ALine, ACharacter: Integer; out AHover: TLSPHover): Boolean;
var
  Params: TLSPHoverParams;
  ParamsJson: TJSONObject;
  RequestId: Integer;
  Event: TEvent;
  HoverResult: TLSPHover;
  Success: Boolean;
begin
  Result := False;
  Success := False;
  
  if not FInitialized then
    Exit;
    
  Params.TextDocument.Uri := AUri;
  Params.Position.Line := ALine;
  Params.Position.Character := ACharacter;
  ParamsJson := Params.ToJSON;
  
  Event := TEvent.Create(nil, True, False, '');
  try
    FLock.Enter;
    try
      RequestId := SendRequest('textDocument/hover', ParamsJson);
      FPendingRequests.Add(RequestId,
        procedure(AResponse: TJsonRpcResponse)
        begin
          if not AResponse.IsError and Assigned(AResponse.Result) and (AResponse.Result is TJSONObject) then
          begin
            HoverResult := TLSPHover.FromJSON(AResponse.Result as TJSONObject);
            Success := True;
          end;
          Event.SetEvent;
        end);
    finally
      FLock.Leave;
    end;
    
    if Event.WaitFor(10000) = wrSignaled then
    begin
      if Success then
      begin
        AHover := HoverResult;
        Result := True;
      end;
    end;
  finally
    Event.Free;
  end;
end;

function TLSPClient.GetCompletion(const AUri: string; ALine, ACharacter: Integer): TArray<TLSPCompletionItem>;
var
  Params: TLSPCompletionParams;
  ParamsJson: TJSONObject;
  RequestId: Integer;
  Event: TEvent;
  Items: TArray<TLSPCompletionItem>;
begin
  SetLength(Result, 0);
  
  if not FInitialized then
    Exit;
    
  Params.TextDocument.Uri := AUri;
  Params.Position.Line := ALine;
  Params.Position.Character := ACharacter;
  Params.HasContext := False;
  ParamsJson := Params.ToJSON;
  
  Event := TEvent.Create(nil, True, False, '');
  try
    FLock.Enter;
    try
      RequestId := SendRequest('textDocument/completion', ParamsJson);
      FPendingRequests.Add(RequestId,
        procedure(AResponse: TJsonRpcResponse)
        var
          ResultArray: TJSONArray;
          ResultObj: TJSONObject;
          I: Integer;
        begin
          if not AResponse.IsError and Assigned(AResponse.Result) then
          begin
            if AResponse.Result is TJSONArray then
            begin
              ResultArray := AResponse.Result as TJSONArray;
              SetLength(Items, ResultArray.Count);
              for I := 0 to ResultArray.Count - 1 do
                Items[I] := TLSPCompletionItem.FromJSON(ResultArray.Items[I] as TJSONObject);
            end
            else if AResponse.Result is TJSONObject then
            begin
              ResultObj := AResponse.Result as TJSONObject;
              if Assigned(ResultObj.GetValue('items')) then
              begin
                ResultArray := ResultObj.GetValue('items') as TJSONArray;
                SetLength(Items, ResultArray.Count);
                for I := 0 to ResultArray.Count - 1 do
                  Items[I] := TLSPCompletionItem.FromJSON(ResultArray.Items[I] as TJSONObject);
              end;
            end;
          end;
          Event.SetEvent;
        end);
    finally
      FLock.Leave;
    end;
    
    if Event.WaitFor(10000) = wrSignaled then
      Result := Items;
  finally
    Event.Free;
  end;
end;

function TLSPClient.GetWorkspaceSymbols(const AQuery: string): TArray<TLSPSymbolInformation>;
var
  Params: TLSPWorkspaceSymbolParams;
  ParamsJson: TJSONObject;
  RequestId: Integer;
  Event: TEvent;
  Symbols: TArray<TLSPSymbolInformation>;
begin
  SetLength(Result, 0);
  
  if not FInitialized then
    Exit;
    
  Params.Query := AQuery;
  ParamsJson := Params.ToJSON;
  
  Event := TEvent.Create(nil, True, False, '');
  try
    FLock.Enter;
    try
      RequestId := SendRequest('workspace/symbol', ParamsJson);
      FPendingRequests.Add(RequestId,
        procedure(AResponse: TJsonRpcResponse)
        var
          ResultArray: TJSONArray;
          I: Integer;
        begin
          if not AResponse.IsError and Assigned(AResponse.Result) and (AResponse.Result is TJSONArray) then
          begin
            ResultArray := AResponse.Result as TJSONArray;
            SetLength(Symbols, ResultArray.Count);
            for I := 0 to ResultArray.Count - 1 do
              Symbols[I] := TLSPSymbolInformation.FromJSON(ResultArray.Items[I] as TJSONObject);
          end;
          Event.SetEvent;
        end);
    finally
      FLock.Leave;
    end;
    
    if Event.WaitFor(10000) = wrSignaled then
      Result := Symbols;
  finally
    Event.Free;
  end;
end;

procedure TLSPClient.DidOpenTextDocument(const AUri, ALanguageId, AText: string; AVersion: Integer);
var
  Params: TLSPDidOpenTextDocumentParams;
  ParamsJson: TJSONObject;
begin
  if not FInitialized then
    Exit;
    
  Params.TextDocument.Uri := AUri;
  Params.TextDocument.LanguageId := ALanguageId;
  Params.TextDocument.Version := AVersion;
  Params.TextDocument.Text := AText;
  ParamsJson := Params.ToJSON;
  
  SendNotification('textDocument/didOpen', ParamsJson);
end;

procedure TLSPClient.DidCloseTextDocument(const AUri: string);
var
  Params: TLSPDidCloseTextDocumentParams;
  ParamsJson: TJSONObject;
begin
  if not FInitialized then
    Exit;
    
  Params.TextDocument.Uri := AUri;
  ParamsJson := Params.ToJSON;
  
  SendNotification('textDocument/didClose', ParamsJson);
end;

end.
