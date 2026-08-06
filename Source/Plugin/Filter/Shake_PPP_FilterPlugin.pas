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
  Shake_PPP_RuntimeDeformer,
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

function TryUseObjectPosition(Video: PFILTER_PROC_VIDEO;
  var Settings: TShakeRuntimeSettings; out OutputParamX, OutputParamY,
  RelativeParamX, RelativeParamY: Double): Boolean;
var
  OutputParam: TOBJECT_IMAGE_PARAM;
begin
  Result := False;
  OutputParamX := 0;
  OutputParamY := 0;
  RelativeParamX := 0;
  RelativeParamY := 0;
  if (Video = nil) or not Assigned(Video^.GetOutputImageParam) then
    Exit;

  FillChar(OutputParam, SizeOf(OutputParam), 0);
  if Video^.GetOutputImageParam(nil, 0, @OutputParam,
    SizeOf(OutputParam)) = 0 then
    Exit;

  OutputParamX := OutputParam.X;
  OutputParamY := OutputParam.Y;
  if Video^.Param <> nil then
  begin
    RelativeParamX := Video^.Param^.X;
    RelativeParamY := Video^.Param^.Y;
  end;
  Settings.PositionX := OutputParamX + RelativeParamX;
  Settings.PositionY := OutputParamY + RelativeParamY;
  Result := True;
end;

procedure DebugLogRuntimeInput(Video: PFILTER_PROC_VIDEO;
  const Settings: TShakeRuntimeSettings; ObjectPositionUsed: Boolean;
  OutputParamX, OutputParamY, RelativeParamX, RelativeParamY: Double);
var
  GetOutputFunctionAvailable: Boolean;
  RelativeParamAvailable: Boolean;
  PositionSource: string;
begin
{$IFDEF DEBUG}
  GetOutputFunctionAvailable := (Video <> nil) and
    Assigned(Video^.GetOutputImageParam);
  RelativeParamAvailable := (Video <> nil) and (Video^.Param <> nil);
  if ObjectPositionUsed then
    PositionSource := 'object'
  else
    PositionSource := 'manual-fallback';
  if (Video = nil) or (Video^.Object_ = nil) then
  begin
    DebugLog(Format(
      'Runtime input received: object=nil getOutputFunction=%s getOutputSucceeded=%s relativeParamAvailable=%s timeAxisRaw=%d manualPosition=(%.6f,%.6f) positionSource=%s positionUsed=(%.6f,%.6f).',
      [BoolToStr(GetOutputFunctionAvailable, True),
       BoolToStr(ObjectPositionUsed, True),
       BoolToStr(RelativeParamAvailable, True), TimeAxisEnabledItem.Value,
       PositionXItem.Value, PositionYItem.Value,
       PositionSource,
       Settings.PositionX, Settings.PositionY]));
    Exit;
  end;

  DebugLog(Format(
    'Runtime input received: objectId=%d effectId=%d layer=%d effectLayer=%d objectFlag=%d frame=%d frameRange=%d..%d time=%.6f getOutputFunction=%s getOutputSucceeded=%s relativeParamAvailable=%s timeAxisRaw=%d timeAxisUsed=%s manualPosition=(%.6f,%.6f) positionSource=%s outputPosition=(%.6f,%.6f) relativePosition=(%.6f,%.6f) positionUsed=(%.6f,%.6f).',
    [Video^.Object_^.ID, Video^.Object_^.EffectID,
     Video^.Object_^.Layer, Video^.Object_^.EffectLayer,
     Video^.Object_^.Flag,
     Video^.Object_^.Frame, Video^.Object_^.FrameS, Video^.Object_^.FrameE,
     Video^.Object_^.Time,
     BoolToStr(GetOutputFunctionAvailable, True),
     BoolToStr(ObjectPositionUsed, True),
     BoolToStr(RelativeParamAvailable, True), TimeAxisEnabledItem.Value,
     BoolToStr(Settings.TimeAxisEnabled, True),
     PositionXItem.Value, PositionYItem.Value,
     PositionSource,
     OutputParamX, OutputParamY, RelativeParamX, RelativeParamY,
     Settings.PositionX, Settings.PositionY]));
{$ENDIF}
end;

function EmptyProcVideo(Video: PFILTER_PROC_VIDEO): Byte; cdecl;
var
  CurveDataText: string;
  ObjectPositionUsed: Boolean;
  OutputParamX: Double;
  OutputParamY: Double;
  RelativeParamX: Double;
  RelativeParamY: Double;
  RuntimeSettings: TShakeRuntimeSettings;
begin
  try
    CaptureLastFrame(Video);
    CurveDataText := '';
    if Assigned(CurveDataItem.Value) then
      CurveDataText := string(CurveDataItem.Value);
    RuntimeSettings := CurrentShakeRuntimeSettings;
    ObjectPositionUsed := TryUseObjectPosition(Video, RuntimeSettings,
      OutputParamX, OutputParamY, RelativeParamX, RelativeParamY);
    DebugLogRuntimeInput(Video, RuntimeSettings, ObjectPositionUsed,
      OutputParamX, OutputParamY, RelativeParamX, RelativeParamY);
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
  SettingsButton: TFILTER_ITEM_BUTTON = (
    ItemType: 'button';
    Name: '設定';
    Callback: SettingsButtonCallback
  );
  PluginItems: array[0..12] of Pointer;
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
  if Plugin.Items = nil then
  begin
    PluginItems[0] := @SettingsButton;
    PluginItems[1] := @TimeAxisEnabledItem;
    PluginItems[2] := @PositionXItem;
    PluginItems[3] := @PositionYItem;
    PluginItems[4] := @StrengthItem;
    PluginItems[5] := @DelayItem;
    PluginItems[6] := @SoftnessItem;
    PluginItems[7] := @DurationItem;
    PluginItems[8] := @MaximumDeformationItem;
    PluginItems[9] := @HorizontalInfluenceItem;
    PluginItems[10] := @VerticalInfluenceItem;
    PluginItems[11] := @CurveDataItem;
    PluginItems[12] := nil;
    Plugin.Items := @PluginItems[0];
  end;
  Result := @Plugin;
end;

end.
