unit Shake_PPP_FilterPlugin;

interface

uses
  Winapi.Windows,
  AviUtl2FilterTypes;

function InitializeShakePlugin(Version: DWORD): Byte;
procedure FinalizeShakePlugin;
function GetShakeFilterTable: PFILTER_PLUGIN_TABLE;

implementation

uses
  System.SysUtils,
  System.UITypes,
  Vcl.Dialogs,
  Vcl.Forms,
  Shake_PPP_DebugLog,
  Shake_PPP_LastFrameCapture,
  Shake_PPP_SettingsForm;

function EmptyProcVideo(Video: PFILTER_PROC_VIDEO): Byte; cdecl;
begin
  try
    CaptureLastFrame(Video);
  except
    // AviUtl2の映像コールバック境界へDelphi例外を漏らさない。
  end;
  Result := 1;
end;

procedure SettingsButtonCallback(Edit: PEDIT_SECTION); cdecl;
var
  BackgroundHeight: Integer;
  BackgroundPixels: TBytes;
  BackgroundStatus: string;
  BackgroundWidth: Integer;
  SettingsForm: TFormShakeSettings;
  CopySucceeded: Boolean;
begin
  try
    DebugLog('Settings button clicked.');
    SettingsForm := TFormShakeSettings.Create(nil);
    try
      CopySucceeded := CopyLastFrame(BackgroundPixels, BackgroundWidth,
        BackgroundHeight, BackgroundStatus);
      DebugLog(Format('Settings frame copy: success=%s size=%dx%d status="%s".',
        [BoolToStr(CopySucceeded, True), BackgroundWidth,
         BackgroundHeight, BackgroundStatus]));
      if CopySucceeded then
        SettingsForm.SetBackgroundRgba(BackgroundPixels,
          BackgroundWidth, BackgroundHeight);
      SettingsForm.SetCaptureStatus(BackgroundStatus);
      SettingsForm.ShowModal;
    finally
      SettingsForm.Free;
    end;
  except
    on E: Exception do
      MessageDlg('設定画面を開けませんでした。' + sLineBreak + E.Message,
        mtError, [mbOK], 0);
  end;
end;

var
  SettingsButton: TFILTER_ITEM_BUTTON = (
    ItemType: 'button';
    Name: '設定';
    Callback: SettingsButtonCallback
  );
  DummyItem: TFILTER_ITEM_TRACK;
  PluginItems: array[0..2] of Pointer;
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
  ResetDebugLog;
  DebugLog(Format('InitializePlugin version=%d.', [Version]));
  InitializeLastFrameCapture;
  Result := 1;
end;

procedure FinalizeShakePlugin;
begin
  DebugLog('UninitializePlugin started.');
  FinalizeLastFrameCapture;
end;

function GetShakeFilterTable: PFILTER_PLUGIN_TABLE;
begin
  if Plugin.Items = nil then
  begin
    DummyItem.ItemType := 'track';
    DummyItem.Name := 'ダミー';
    DummyItem.Value := 0.0;
    DummyItem.S := 0.0;
    DummyItem.E := 100.0;
    DummyItem.Step := 1.0;

    PluginItems[0] := @SettingsButton;
    PluginItems[1] := @DummyItem;
    PluginItems[2] := nil;
    Plugin.Items := @PluginItems[0];
  end;
  Result := @Plugin;
end;

end.
