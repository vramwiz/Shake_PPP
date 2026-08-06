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
  Shake_PPP_FilterSettings,
  Shake_PPP_LastFrameCapture,
  Shake_PPP_SettingsForm;

const
  FILTER_EFFECT_NAME = '胸揺れ';
  CURVE_DATA_ITEM_NAME = '形状データ';

var
  CurveDataItem: TFILTER_ITEM_STRING = (
    ItemType: 'string';
    Name: '形状データ';
    Value: ''
  );

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
  CurrentDataText: string;
  CurveDataError: string;
  SettingsForm: TFormShakeSettings;
  CopySucceeded: Boolean;
  FocusObject: OBJECT_HANDLE;
  SelectedDataText: string;
  Utf8DataText: UTF8String;
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
      CurrentDataText := '';
      if Assigned(CurveDataItem.Value) then
        CurrentDataText := string(CurveDataItem.Value);
      if not SettingsForm.TryLoadCurveDataText(CurrentDataText,
        CurveDataError) then
        MessageDlg('保存済みの曲線データを読み込めませんでした。' +
          sLineBreak + CurveDataError, mtWarning, [mbOK], 0);
      SettingsForm.ShowModal;
      if not SettingsForm.TrySaveCurveDataText(SelectedDataText,
        CurveDataError) then
      begin
        MessageDlg('曲線データを保存できませんでした。' + sLineBreak +
          CurveDataError, mtError, [mbOK], 0);
        Exit;
      end;
      if SelectedDataText = CurrentDataText then
        Exit;
      FocusObject := nil;
      if (Edit <> nil) and Assigned(Edit^.GetFocusObject) then
        FocusObject := Edit^.GetFocusObject();
      if (Edit = nil) or not Assigned(Edit^.SetObjectItemValue) or
        (FocusObject = nil) then
      begin
        MessageDlg('曲線データの保存対象を取得できませんでした。',
          mtError, [mbOK], 0);
        Exit;
      end;
      Utf8DataText := UTF8String(SelectedDataText);
      if not Edit^.SetObjectItemValue(FocusObject, FILTER_EFFECT_NAME,
        CURVE_DATA_ITEM_NAME, PAnsiChar(Utf8DataText)) then
      begin
        MessageDlg('曲線データを形状データ項目へ反映できませんでした。',
          mtError, [mbOK], 0);
        Exit;
      end;
      DebugLog(Format('Curve data saved: chars=%d.',
        [Length(SelectedDataText)]));
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
  PluginItems: array[0..10] of Pointer;
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
    PluginItems[0] := @SettingsButton;
    PluginItems[1] := @TimeAxisEnabledItem;
    PluginItems[2] := @StrengthItem;
    PluginItems[3] := @DelayItem;
    PluginItems[4] := @SoftnessItem;
    PluginItems[5] := @DurationItem;
    PluginItems[6] := @MaximumDeformationItem;
    PluginItems[7] := @HorizontalInfluenceItem;
    PluginItems[8] := @VerticalInfluenceItem;
    PluginItems[9] := @CurveDataItem;
    PluginItems[10] := nil;
    Plugin.Items := @PluginItems[0];
  end;
  Result := @Plugin;
end;

end.
