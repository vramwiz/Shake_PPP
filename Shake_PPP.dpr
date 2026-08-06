library Shake_PPP;

{$ALIGN 8}

uses
  Winapi.Windows,
  AviUtl2FilterTypes in 'Source\Lib\AviUtl2FilterTypes.pas',
  Shake_PPP_ToolbarButtons in 'Source\Lib\Shake_PPP_ToolbarButtons.pas',
  Shake_PPP_CurveModel in 'Source\Common\Model\Shake_PPP_CurveModel.pas',
  Shake_PPP_CurveData in 'Source\Common\Model\Shake_PPP_CurveData.pas',
  Shake_PPP_FilterSettings in 'Source\Common\Settings\Shake_PPP_FilterSettings.pas',
  Shake_PPP_CurveRenderer in 'Source\Common\Render\Shake_PPP_CurveRenderer.pas',
  Shake_PPP_StaticDeformer in 'Source\Common\Render\Shake_PPP_StaticDeformer.pas',
  Shake_PPP_DebugLog in 'Source\Common\Diagnostics\Shake_PPP_DebugLog.pas',
  Shake_PPP_LastFrameCapture in 'Source\Common\Render\Shake_PPP_LastFrameCapture.pas',
  Shake_PPP_SettingsForm in 'Source\Plugin\Filter\Shake_PPP_SettingsForm.pas' {FormShakeSettings},
  Shake_PPP_FilterPlugin in 'Source\Plugin\Filter\Shake_PPP_FilterPlugin.pas';

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
