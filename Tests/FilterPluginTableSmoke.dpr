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
  PFilterItemHeader = ^TFilterItemHeader;
  TFilterItemHeader = record
    ItemType: LPCWSTR;
    Name: LPCWSTR;
  end;

procedure Check(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

function FilterItemAt(Table: PFILTER_PLUGIN_TABLE; Index: Integer): Pointer;
begin
  Result := PPointer(NativeUInt(Table^.Items) +
    NativeUInt(Index) * SizeOf(Pointer))^;
end;

procedure CheckItemName(Table: PFILTER_PLUGIN_TABLE; Index: Integer;
  const ExpectedName: string);
var
  ItemHeader: PFilterItemHeader;
begin
  ItemHeader := PFilterItemHeader(FilterItemAt(Table, Index));
  Check((ItemHeader <> nil) and Assigned(ItemHeader^.Name),
    Format('Filter item %d has no name.', [Index]));
  Check(string(ItemHeader^.Name) = ExpectedName,
    Format('Filter item %d name mismatch.', [Index]));
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
        for I := 0 to 26 do
        begin
          Item := FilterItemAt(Table, I);
          Check(Item <> nil, Format('Filter item %d is nil.', [I]));
          ItemType := PPWideChar(Item)^;
          Check(ItemType <> nil, Format('Filter item %d has no type.', [I]));
        end;
        CheckItemName(Table, 1, '揺れ');
        CheckItemName(Table, 11, '膨らみ');
        CheckItemName(Table, 12, '膨張量');
        CheckItemName(Table, 13, '膨らみ方');
        CheckItemName(Table, 14, '膨張中心X');
        CheckItemName(Table, 15, '膨張中心Y');
        CheckItemName(Table, 16, '重力');
        CheckItemName(Table, 17, '重力方向');
        CheckItemName(Table, 18, '質量');
        CheckItemName(Table, 19, '張力');
        CheckItemName(Table, 20, '膨らみの表示');
        CheckItemName(Table, 21, '透明度連動量');
        CheckItemName(Table, 22, '陰影強度');
        CheckItemName(Table, 23, '光源方向');
        CheckItemName(Table, 24, 'ハイライト強度');
        CheckItemName(Table, 25, '内部データ');
        CheckItemName(Table, 26, '形状データ');
        Item := FilterItemAt(Table, 27);
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
