program FilterPluginTableSmoke;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Winapi.Windows,
  AviUtl2FilterTypes in '..\..\Syncroh2\AviUtl\Filter\AviUtl2FilterTypes.pas';

type
  TInitializePlugin = function(Version: DWORD): Byte; cdecl;
  TUninitializePlugin = procedure; cdecl;
  TGetFilterPluginTable = function: PFILTER_PLUGIN_TABLE; cdecl;

procedure Check(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

var
  DllHandle: HMODULE;
  GetTable: TGetFilterPluginTable;
  I: Integer;
  Initialize: TInitializePlugin;
  Item: Pointer;
  ItemType: PWideChar;
  PluginPath: string;
  Table: PFILTER_PLUGIN_TABLE;
  Uninitialize: TUninitializePlugin;
begin
  try
    Check(ParamCount = 1, 'Usage: FilterPluginTableSmoke <plugin.dll>');
    PluginPath := ExpandFileName(ParamStr(1));
    DllHandle := LoadLibrary(PChar(PluginPath));
    Check(DllHandle <> 0, Format('LoadLibrary failed: %d', [GetLastError]));
    try
      Initialize := TInitializePlugin(GetProcAddress(DllHandle,
        'InitializePlugin'));
      Uninitialize := TUninitializePlugin(GetProcAddress(DllHandle,
        'UninitializePlugin'));
      GetTable := TGetFilterPluginTable(GetProcAddress(DllHandle,
        'GetFilterPluginTable'));
      Check(Assigned(Initialize), 'InitializePlugin export is missing.');
      Check(Assigned(Uninitialize), 'UninitializePlugin export is missing.');
      Check(Assigned(GetTable), 'GetFilterPluginTable export is missing.');
      Check(Initialize(0) <> 0, 'InitializePlugin failed.');
      try
        Table := GetTable();
        Check(Assigned(Table), 'Filter table is nil.');
        Check((Table^.Name <> nil) and (Table^.Name^ <> #0),
          'Filter name is empty.');
        Check(Table^.Items <> nil, 'Filter item list is nil.');
        Check(Assigned(Table^.Func_Proc_Video), 'Video callback is nil.');
        for I := 0 to 10 do
        begin
          Item := PPointer(NativeUInt(Table^.Items) +
            NativeUInt(I) * SizeOf(Pointer))^;
          Check(Item <> nil, Format('Filter item %d is nil.', [I]));
          ItemType := PPWideChar(Item)^;
          Check(ItemType <> nil, Format('Filter item %d has no type.', [I]));
        end;
        Item := PPointer(NativeUInt(Table^.Items) +
          NativeUInt(11) * SizeOf(Pointer))^;
        Check(Item = nil, 'Filter item list is not nil-terminated.');
      finally
        Uninitialize();
      end;
    finally
      FreeLibrary(DllHandle);
    end;
    Writeln('Filter plugin table smoke test passed.');
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
