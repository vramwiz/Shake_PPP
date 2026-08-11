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
  AviUtl2FilterInfoUtils,
  Vcl.Dialogs,
  Vcl.Forms,
  Shake_PPP_DebugLog,
  Shake_PPP_FilterSettings,
  Shake_PPP_LastFrameCapture,
  Shake_PPP_RuntimeDeformer,
  Shake_PPP_SettingsForm,
  PluginFilterTable;

const
  FILTER_EFFECT_NAME = '胸揺れ';
  CURVE_DATA_ITEM_NAME = '形状データ';

var
  CurveDataItem: TFILTER_ITEM_STRING;
{$IFDEF DEBUG}
  LastRuntimeInputLogTick: UInt64;
{$ENDIF}

procedure DebugLogRuntimeInput(Video: PFILTER_PROC_VIDEO;
  const Settings: TShakeRuntimeSettings; ObjectPositionUsed: Boolean;
  const Position: TAviUtl2ObjectPosition);
{$IFDEF DEBUG}
var
  CurrentTick: UInt64;
  GetOutputFunctionAvailable: Boolean;
  RelativeParamAvailable: Boolean;
  PositionSource: string;
{$ENDIF}
begin
{$IFDEF DEBUG}
  CurrentTick := GetTickCount64;
  if (LastRuntimeInputLogTick <> 0) and
    (CurrentTick - LastRuntimeInputLogTick < 1000) then
    Exit;
  LastRuntimeInputLogTick := CurrentTick;
  GetOutputFunctionAvailable := (Video <> nil) and
    Assigned(Video^.GetOutputImageParam);
  RelativeParamAvailable := (Video <> nil) and (Video^.Param <> nil);
  if ObjectPositionUsed then
    PositionSource := 'object'
  else
    PositionSource := 'unavailable';
  if (Video = nil) or (Video^.Object_ = nil) then
  begin
    DebugLog(Format(
      'Runtime input received: object=nil getOutputFunction=%s getOutputSucceeded=%s relativeParamAvailable=%s timeAxisRaw=%d positionSource=%s positionUsed=(%.6f,%.6f).',
      [BoolToStr(GetOutputFunctionAvailable, True),
       BoolToStr(ObjectPositionUsed, True),
       BoolToStr(RelativeParamAvailable, True), TimeAxisEnabledItem.Value,
       PositionSource,
       Settings.PositionX, Settings.PositionY]));
    Exit;
  end;

  DebugLog(Format(
    'Runtime input received: objectId=%d effectId=%d layer=%d effectLayer=%d objectFlag=%d frame=%d frameRange=%d..%d time=%.6f getOutputFunction=%s getOutputSucceeded=%s relativeParamAvailable=%s timeAxisRaw=%d timeAxisUsed=%s positionSource=%s outputPosition=(%.6f,%.6f) relativePosition=(%.6f,%.6f) positionUsed=(%.6f,%.6f).',
    [Video^.Object_^.ID, Video^.Object_^.EffectID,
     Video^.Object_^.Layer, Video^.Object_^.EffectLayer,
     Video^.Object_^.Flag,
     Video^.Object_^.Frame, Video^.Object_^.FrameS, Video^.Object_^.FrameE,
     Video^.Object_^.Time,
     BoolToStr(GetOutputFunctionAvailable, True),
     BoolToStr(ObjectPositionUsed, True),
     BoolToStr(RelativeParamAvailable, True), TimeAxisEnabledItem.Value,
     BoolToStr(Settings.TimeAxisEnabled, True),
     PositionSource,
     Position.OutputX, Position.OutputY,
     Position.RelativeX, Position.RelativeY,
     Settings.PositionX, Settings.PositionY]));
{$ENDIF}
end;

function EmptyProcVideo(Video: PFILTER_PROC_VIDEO): Byte; cdecl;
var
  CurveDataText: string;
  ObjectPositionUsed: Boolean;
  Position: TAviUtl2ObjectPosition;
  RuntimeSettings: TShakeRuntimeSettings;
begin
  try
    CaptureLastFrame(Video);
    CurveDataText := '';
    if Assigned(CurveDataItem.Value) then
      CurveDataText := string(CurveDataItem.Value);
    RuntimeSettings := CurrentShakeRuntimeSettings;
    ObjectPositionUsed := AviUtl2TryGetObjectPosition(Video, Position);
    if ObjectPositionUsed then
    begin
      RuntimeSettings.PositionX := Position.X;
      RuntimeSettings.PositionY := Position.Y;
    end;
    DebugLogRuntimeInput(Video, RuntimeSettings, ObjectPositionUsed,
      Position);
    ApplyRuntimeDeformation(Video, CurveDataText, RuntimeSettings);
  except
    on E: Exception do
      DebugLog('Video callback failed: ' + E.ClassName + ': ' + E.Message);
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
  SettingsButton: TFILTER_ITEM_BUTTON;

function InitializeShakePlugin(Version: DWORD): Byte;
begin
  ResetDebugLog;
{$IFDEF DEBUG}
  LastRuntimeInputLogTick := 0;
{$ENDIF}
  DebugLog(Format('InitializePlugin version=%d.', [Version]));
  InitializeLastFrameCapture;
  InitializeRuntimeDeformer;
  Result := 1;
end;

procedure FinalizeShakePlugin;
begin
  DebugLog('UninitializePlugin started.');
  FinalizeRuntimeDeformer;
  FinalizeLastFrameCapture;
end;

function GetShakeFilterTable: PFILTER_PLUGIN_TABLE;
begin
  if GTable.Name = nil then
  begin
    AddButton(SettingsButton, '設定', SettingsButtonCallback);
    AddShakeFilterItems;
    AddString(CurveDataItem, CURVE_DATA_ITEM_NAME, '');
    SetupPluginTable(FILTER_FLAG_VIDEO or FILTER_FLAG_FILTER,
      FILTER_EFFECT_NAME, 'SYNC', '胸揺れフタープラグイン',
      EmptyProcVideo, nil);
  end;
  Result := @GTable;
end;

end.
