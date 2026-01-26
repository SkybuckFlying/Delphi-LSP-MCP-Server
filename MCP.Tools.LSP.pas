unit MCP.Tools.LSP;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections, System.Math,
  MCP.Protocol.Types, LSP.Client, LSP.Protocol.Types, Common.Logging;

type
  TMCPLSPTools = class
  private
    FLSPClient: TLSPClient;
    
    function CreateTextContent(const AText: string): TJSONObject;
    function LocationToText(const ALocation: TLSPLocation): string;
  public
    constructor Create(ALSPClient: TLSPClient);
    
    class function GetToolDefinitions: TArray<TMCPTool>;
    function ExecuteTool(const AToolName: string; AArguments: TJSONObject): TMCPToolCallResult;
    
    // Individual tool implementations
    function ExecuteGotoDefinition(AArguments: TJSONObject): TMCPToolCallResult;
    function ExecuteFindReferences(AArguments: TJSONObject): TMCPToolCallResult;
    function ExecuteHover(AArguments: TJSONObject): TMCPToolCallResult;
    function ExecuteCompletion(AArguments: TJSONObject): TMCPToolCallResult;
    function ExecuteWorkspaceSymbols(AArguments: TJSONObject): TMCPToolCallResult;
  end;

implementation

{ TMCPLSPTools }

constructor TMCPLSPTools.Create(ALSPClient: TLSPClient);
begin
  inherited Create;
  FLSPClient := ALSPClient;
end;

class function TMCPLSPTools.GetToolDefinitions: TArray<TMCPTool>;
var
  Tool: TMCPTool;
  Props: TJSONObject;
begin
  SetLength(Result, 5);
  
  // delphi_goto_definition
  Tool.Name := 'delphi_goto_definition';
  Tool.Description := 'Find the definition of a symbol at a specific position in a Delphi source file';
  Props := TJSONObject.Create;
  Props.AddPair('uri', TJSONObject.Create.AddPair('type', 'string').AddPair('description', 'File URI (e.g., file:///C:/path/to/file.pas)'));
  Props.AddPair('line', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based line number'));
  Props.AddPair('character', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based character offset'));
  Tool.InputSchema.SchemaType := 'object';
  Tool.InputSchema.Properties := Props;
  Tool.InputSchema.Required := ['uri', 'line', 'character'];
  Result[0] := Tool;
  
  // delphi_find_references
  Tool.Name := 'delphi_find_references';
  Tool.Description := 'Find all references to a symbol at a specific position in a Delphi source file';
  Props := TJSONObject.Create;
  Props.AddPair('uri', TJSONObject.Create.AddPair('type', 'string').AddPair('description', 'File URI (e.g., file:///C:/path/to/file.pas)'));
  Props.AddPair('line', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based line number'));
  Props.AddPair('character', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based character offset'));
  Props.AddPair('includeDeclaration', TJSONObject.Create.AddPair('type', 'boolean').AddPair('description', 'Include the declaration in results').AddPair('default', TJSONBool.Create(True)));
  Tool.InputSchema.SchemaType := 'object';
  Tool.InputSchema.Properties := Props;
  Tool.InputSchema.Required := ['uri', 'line', 'character'];
  Result[1] := Tool;
  
  // delphi_hover
  Tool.Name := 'delphi_hover';
  Tool.Description := 'Get hover information (documentation, type info) for a symbol at a specific position';
  Props := TJSONObject.Create;
  Props.AddPair('uri', TJSONObject.Create.AddPair('type', 'string').AddPair('description', 'File URI (e.g., file:///C:/path/to/file.pas)'));
  Props.AddPair('line', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based line number'));
  Props.AddPair('character', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based character offset'));
  Tool.InputSchema.SchemaType := 'object';
  Tool.InputSchema.Properties := Props;
  Tool.InputSchema.Required := ['uri', 'line', 'character'];
  Result[2] := Tool;
  
  // delphi_completion
  Tool.Name := 'delphi_completion';
  Tool.Description := 'Get code completion suggestions at a specific position in a Delphi source file';
  Props := TJSONObject.Create;
  Props.AddPair('uri', TJSONObject.Create.AddPair('type', 'string').AddPair('description', 'File URI (e.g., file:///C:/path/to/file.pas)'));
  Props.AddPair('line', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based line number'));
  Props.AddPair('character', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based character offset'));
  Tool.InputSchema.SchemaType := 'object';
  Tool.InputSchema.Properties := Props;
  Tool.InputSchema.Required := ['uri', 'line', 'character'];
  Result[3] := Tool;
  
  // delphi_workspace_symbols
  Tool.Name := 'delphi_workspace_symbols';
  Tool.Description := 'Search for symbols (classes, functions, procedures, etc.) across the entire workspace';
  Props := TJSONObject.Create;
  Props.AddPair('query', TJSONObject.Create.AddPair('type', 'string').AddPair('description', 'Search query string'));
  Tool.InputSchema.SchemaType := 'object';
  Tool.InputSchema.Properties := Props;
  Tool.InputSchema.Required := ['query'];
  Result[4] := Tool;
end;

function TMCPLSPTools.ExecuteTool(const AToolName: string; AArguments: TJSONObject): TMCPToolCallResult;
begin
  try
    if AToolName = 'delphi_goto_definition' then
      Result := ExecuteGotoDefinition(AArguments)
    else if AToolName = 'delphi_find_references' then
      Result := ExecuteFindReferences(AArguments)
    else if AToolName = 'delphi_hover' then
      Result := ExecuteHover(AArguments)
    else if AToolName = 'delphi_completion' then
      Result := ExecuteCompletion(AArguments)
    else if AToolName = 'delphi_workspace_symbols' then
      Result := ExecuteWorkspaceSymbols(AArguments)
    else
    begin
      Result.IsError := True;
      SetLength(Result.Content, 1);
      Result.Content[0] := CreateTextContent('Unknown tool: ' + AToolName);
    end;
  except
    on E: Exception do
    begin
      Logger.Error('Tool execution error (%s): %s', [AToolName, E.Message]);
      Result.IsError := True;
      SetLength(Result.Content, 1);
      Result.Content[0] := CreateTextContent('Error: ' + E.Message);
    end;
  end;
end;

function TMCPLSPTools.ExecuteGotoDefinition(AArguments: TJSONObject): TMCPToolCallResult;
var
  Uri: string;
  Line, Character: Integer;
  Locations: TArray<TLSPLocation>;
  I: Integer;
  ResultText: string;
begin
  Uri := AArguments.GetValue<string>('uri');
  Line := AArguments.GetValue<Integer>('line');
  Character := AArguments.GetValue<Integer>('character');
  
  Locations := FLSPClient.GetDefinition(Uri, Line, Character);
  
  if Length(Locations) = 0 then
  begin
    ResultText := 'No definition found';
  end
  else if Length(Locations) = 1 then
  begin
    ResultText := 'Definition found at:'#13#10 + LocationToText(Locations[0]);
  end
  else
  begin
    ResultText := Format('Found %d definitions:'#13#10, [Length(Locations)]);
    for I := 0 to High(Locations) do
      ResultText := ResultText + Format('%d. %s'#13#10, [I + 1, LocationToText(Locations[I])]);
  end;
  
  Result.IsError := False;
  SetLength(Result.Content, 1);
  Result.Content[0] := CreateTextContent(ResultText);
end;

function TMCPLSPTools.ExecuteFindReferences(AArguments: TJSONObject): TMCPToolCallResult;
var
  Uri: string;
  Line, Character: Integer;
  IncludeDeclaration: Boolean;
  Locations: TArray<TLSPLocation>;
  I: Integer;
  ResultText: string;
begin
  Uri := AArguments.GetValue<string>('uri');
  Line := AArguments.GetValue<Integer>('line');
  Character := AArguments.GetValue<Integer>('character');
  
  if not AArguments.TryGetValue<Boolean>('includeDeclaration', IncludeDeclaration) then
    IncludeDeclaration := True;
  
  Locations := FLSPClient.GetReferences(Uri, Line, Character, IncludeDeclaration);
  
  if Length(Locations) = 0 then
  begin
    ResultText := 'No references found';
  end
  else
  begin
    ResultText := Format('Found %d reference(s):'#13#10, [Length(Locations)]);
    for I := 0 to High(Locations) do
      ResultText := ResultText + Format('%d. %s'#13#10, [I + 1, LocationToText(Locations[I])]);
  end;
  
  Result.IsError := False;
  SetLength(Result.Content, 1);
  Result.Content[0] := CreateTextContent(ResultText);
end;

function TMCPLSPTools.ExecuteHover(AArguments: TJSONObject): TMCPToolCallResult;
var
  Uri: string;
  Line, Character: Integer;
  Hover: TLSPHover;
  ResultText: string;
begin
  Uri := AArguments.GetValue<string>('uri');
  Line := AArguments.GetValue<Integer>('line');
  Character := AArguments.GetValue<Integer>('character');
  
  if FLSPClient.GetHover(Uri, Line, Character, Hover) then
  begin
    ResultText := Hover.Contents.Value;
    if ResultText = '' then
      ResultText := 'No hover information available';
  end
  else
    ResultText := 'No hover information available';
  
  Result.IsError := False;
  SetLength(Result.Content, 1);
  Result.Content[0] := CreateTextContent(ResultText);
end;

function TMCPLSPTools.ExecuteCompletion(AArguments: TJSONObject): TMCPToolCallResult;
var
  Uri: string;
  Line, Character: Integer;
  Items: TArray<TLSPCompletionItem>;
  I: Integer;
  ResultText: string;
begin
  Uri := AArguments.GetValue<string>('uri');
  Line := AArguments.GetValue<Integer>('line');
  Character := AArguments.GetValue<Integer>('character');
  
  Items := FLSPClient.GetCompletion(Uri, Line, Character);
  
  if Length(Items) = 0 then
  begin
    ResultText := 'No completion suggestions available';
  end
  else
  begin
    ResultText := Format('Found %d completion suggestion(s):'#13#10, [Length(Items)]);
    for I := 0 to Min(High(Items), 49) do // Limit to 50 items
    begin
      ResultText := ResultText + Format('%d. %s', [I + 1, Items[I].Label_]);
      if Items[I].Detail <> '' then
        ResultText := ResultText + ' - ' + Items[I].Detail;
      ResultText := ResultText + #13#10;
    end;
    if Length(Items) > 50 then
      ResultText := ResultText + Format('... and %d more', [Length(Items) - 50]);
  end;
  
  Result.IsError := False;
  SetLength(Result.Content, 1);
  Result.Content[0] := CreateTextContent(ResultText);
end;

function TMCPLSPTools.ExecuteWorkspaceSymbols(AArguments: TJSONObject): TMCPToolCallResult;
var
  Query: string;
  Symbols: TArray<TLSPSymbolInformation>;
  I: Integer;
  ResultText: string;
begin
  Query := AArguments.GetValue<string>('query');
  
  Symbols := FLSPClient.GetWorkspaceSymbols(Query);
  
  if Length(Symbols) = 0 then
  begin
    ResultText := Format('No symbols found matching "%s"', [Query]);
  end
  else
  begin
    ResultText := Format('Found %d symbol(s) matching "%s":'#13#10, [Length(Symbols), Query]);
    for I := 0 to Min(High(Symbols), 49) do // Limit to 50 symbols
    begin
      ResultText := ResultText + Format('%d. %s', [I + 1, Symbols[I].Name]);
      if Symbols[I].ContainerName <> '' then
        ResultText := ResultText + ' (in ' + Symbols[I].ContainerName + ')';
      ResultText := ResultText + #13#10'   ' + LocationToText(Symbols[I].Location) + #13#10;
    end;
    if Length(Symbols) > 50 then
      ResultText := ResultText + Format('... and %d more', [Length(Symbols) - 50]);
  end;
  
  Result.IsError := False;
  SetLength(Result.Content, 1);
  Result.Content[0] := CreateTextContent(ResultText);
end;

function TMCPLSPTools.CreateTextContent(const AText: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'text');
  Result.AddPair('text', AText);
end;

function TMCPLSPTools.LocationToText(const ALocation: TLSPLocation): string;
begin
  Result := Format('%s:%d:%d', [
    ALocation.Uri,
    ALocation.Range.Start.Line + 1,  // Convert to 1-based for display
    ALocation.Range.Start.Character + 1
  ]);
end;

end.
