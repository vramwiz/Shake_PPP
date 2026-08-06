unit Shake_PPP_FilterPlugin;

interface

uses
  Winapi.Windows,
  AviUtl2FilterTypes;

function InitializeShakePlugin(Version: DWORD): Byte;
procedure FinalizeShakePlugin;
function GetShakeFilterTable: PFILTER_PLUGIN_TABLE;

implementation

function EmptyProcVideo(Video: PFILTER_PROC_VIDEO): Byte; cdecl;
begin
  // This empty filter intentionally leaves the video unchanged.
  Result := 1;
end;

var
  Plugin: TFILTER_PLUGIN_TABLE = (
    Flag: FILTER_FLAG_VIDEO or FILTER_FLAG_FILTER;
    Name: '胸揺れ';
    Label_: 'SYNC';
    Information: '胸揺れフィルタープラグイン';
    Items: nil;
    Func_Proc_Video: EmptyProcVideo;
    Func_Proc_Audio: nil
  );

function InitializeShakePlugin(Version: DWORD): Byte;
begin
  Result := 1;
end;

procedure FinalizeShakePlugin;
begin
end;

function GetShakeFilterTable: PFILTER_PLUGIN_TABLE;
begin
  Result := @Plugin;
end;

end.

