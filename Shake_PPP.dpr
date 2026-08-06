library Shake_PPP;

{$ALIGN 8}

uses
  Winapi.Windows,
  AviUtl2FilterTypes in 'Source\Lib\AviUtl2FilterTypes.pas',
  Shake_PPP_FilterPlugin in 'Source\Shake_PPP_FilterPlugin.pas';

function InitializePlugin(Version: DWORD): Byte; cdecl;
begin
  Result := InitializeShakePlugin(Version);
end;

procedure UninitializePlugin; cdecl;
begin
  FinalizeShakePlugin;
end;

function GetFilterPluginTable: PFILTER_PLUGIN_TABLE; cdecl;
begin
  Result := GetShakeFilterTable;
end;

exports
  InitializePlugin name 'InitializePlugin',
  UninitializePlugin name 'UninitializePlugin',
  GetFilterPluginTable name 'GetFilterPluginTable';

begin
end.

