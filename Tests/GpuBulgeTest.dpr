program GpuBulgeTest;

{$APPTYPE CONSOLE}

uses
  System.Math,
  System.SysUtils,
  System.Types,
  Winapi.D3D11,
  Winapi.D3DCommon,
  Winapi.DxgiFormat,
  AviUtl2FilterTypes in '..\Syncroh2\AviUtl\Filter\AviUtl2FilterTypes.pas',
  PluginFilterTable in '..\Syncroh2\Plugin_Filter\PluginFilterTable.pas',
  Shake_PPP_CurveModel in 'Source\Common\Model\Shake_PPP_CurveModel.pas',
  Shake_PPP_CurveData in 'Source\Common\Model\Shake_PPP_CurveData.pas',
  Shake_PPP_DebugLog in 'Source\Common\Diagnostics\Shake_PPP_DebugLog.pas',
  Shake_PPP_StaticDeformer in 'Source\Common\Render\Shake_PPP_StaticDeformer.pas',
  Shake_PPP_BulgeSettings in 'Source\Common\Settings\Shake_PPP_BulgeSettings.pas',
  Shake_PPP_BulgeDeformer in 'Source\Common\Render\Shake_PPP_BulgeDeformer.pas',
  Shake_PPP_GpuBulgeDeformer in 'Source\Common\Render\Shake_PPP_GpuBulgeDeformer.pas';

const
  IMAGE_WIDTH = 128;
  IMAGE_HEIGHT = 96;

var
  CapturedOutput: TBytes;
  InputTexture: ID3D11Texture2D;
  OutputTexture: ID3D11Texture2D;

procedure Require(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

function GetInputTexture: PID3D11Texture2D; cdecl;
begin
  Result := Pointer(InputTexture);
end;

function GetFramebufferTexture: PID3D11Texture2D; cdecl;
begin
  Result := Pointer(OutputTexture);
end;

procedure SetOutputData(Buffer: PPIXEL_RGBA; Width, Height: Integer); cdecl;
begin
  SetLength(CapturedOutput, Width * Height * 4);
  if Length(CapturedOutput) > 0 then
    Move(Buffer^, CapturedOutput[0], Length(CapturedOutput));
end;

procedure AddEllipse(Curve: TShakeCurve; CenterX, CenterY,
  RadiusX, RadiusY: Single);
const
  POINT_COUNT = 12;
var
  Angle: Double;
  I: Integer;
begin
  for I := 0 to POINT_COUNT - 1 do
  begin
    Angle := I * 2 * Pi / POINT_COUNT;
    Curve.AddVertex(PointF(CenterX + Cos(Angle) * RadiusX,
      CenterY + Sin(Angle) * RadiusY), svkSmooth);
  end;
  Curve.Closed := True;
end;

var
  Context: ID3D11DeviceContext;
  CombinedDifference: Integer;
  CpuOutput: TBytes;
  CurveSets: TShakeCurveSets;
  Desc: TD3D11_TEXTURE2D_DESC;
  Device: ID3D11Device;
  DirectBytes: TBytes;
  DisplayDifference: Integer;
  ErrorText: string;
  FeatureLevel: D3D_FEATURE_LEVEL;
  FixedShakeDifference: Integer;
  Gpu: TGpuBulgeProcessor;
  GpuBytes: TBytes;
  I: Integer;
  InitialData: TD3D11_SUBRESOURCE_DATA;
  MapReady: array[0..SHAKE_CURVE_SET_COUNT - 1] of Boolean;
  Maps: array[0..SHAKE_CURVE_SET_COUNT - 1] of TShakeDeformationMap;
  MaximumDifference: Integer;
  Offset: NativeInt;
  OutputPixels: Pointer;
  Settings: TBulgeRuntimeSettings;
  SourceBytes: TBytes;
  Video: TFILTER_PROC_VIDEO;
  VariableShakeDifference: Integer;
  X: Integer;
  Y: Integer;
begin
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
  begin
    CurveSets[I].OuterContour := TShakeCurve.Create;
    CurveSets[I].CenterContour := TShakeCurve.Create;
    Maps[I] := TShakeDeformationMap.Create;
  end;
  Gpu := TGpuBulgeProcessor.Create;
  try
    AddEllipse(CurveSets[0].OuterContour, 0.5, 0.5, 0.42, 0.40);
    AddEllipse(CurveSets[0].CenterContour, 0.5, 0.5, 0.16, 0.14);
    MapReady[0] := Maps[0].Build(IMAGE_WIDTH, IMAGE_HEIGHT,
      CurveSets[0].OuterContour, CurveSets[0].CenterContour, ErrorText);
    Require(MapReady[0], ErrorText);
    MapReady[1] := False;

    SetLength(SourceBytes, IMAGE_WIDTH * IMAGE_HEIGHT * 4);
    for Y := 0 to IMAGE_HEIGHT - 1 do
      for X := 0 to IMAGE_WIDTH - 1 do
      begin
        Offset := (NativeInt(Y) * IMAGE_WIDTH + X) * 4;
        SourceBytes[Offset] := X;
        SourceBytes[Offset + 1] := Y;
        SourceBytes[Offset + 2] := (X + Y) and $FF;
        SourceBytes[Offset + 3] := 255;
      end;

    Require(D3D11CreateDevice(nil, D3D_DRIVER_TYPE_WARP, 0, 0, nil, 0,
      D3D11_SDK_VERSION, Device, FeatureLevel, Context) >= 0,
      'Could not create the D3D11 WARP device.');
    FillChar(Desc, SizeOf(Desc), 0);
    Desc.Width := IMAGE_WIDTH;
    Desc.Height := IMAGE_HEIGHT;
    Desc.MipLevels := 1;
    Desc.ArraySize := 1;
    Desc.Format := DXGI_FORMAT_R8G8B8A8_UNORM;
    Desc.SampleDesc.Count := 1;
    Desc.Usage := D3D11_USAGE_DEFAULT;
    Desc.BindFlags := D3D11_BIND_SHADER_RESOURCE;
    FillChar(InitialData, SizeOf(InitialData), 0);
    InitialData.pSysMem := @SourceBytes[0];
    InitialData.SysMemPitch := IMAGE_WIDTH * 4;
    Require(Device.CreateTexture2D(Desc, @InitialData, InputTexture) >= 0,
      'Could not create the GPU input texture.');
    Desc.BindFlags := 0;
    Require(Device.CreateTexture2D(Desc, nil, OutputTexture) >= 0,
      'Could not create the GPU framebuffer texture.');

    Video := Default(TFILTER_PROC_VIDEO);
    Video.GetImageTexture2D := GetInputTexture;
    Video.GetFramebufferTexture2D := GetFramebufferTexture;
    Video.SetImageData := SetOutputData;
    Settings := Default(TBulgeRuntimeSettings);
    Settings.Amount := 1.67;
    Settings.Shape := 1.0;
    Settings.CenterX := 0.04;
    Settings.CenterY := -0.27;
    Settings.Gravity := 0.26;
    Settings.GravityDirection := 117.0;
    Settings.Mass := 0.63;
    Settings.Tension := 0.60;
    Require(Gpu.Apply(@Video, CurveSets, Maps, MapReady, Settings,
      ErrorText), ErrorText);

    GpuBytes := Copy(CapturedOutput);
    Require(Length(GpuBytes) = Length(SourceBytes),
      'SetImageData did not receive the GPU result.');
    Require(Gpu.ApplyToBuffer(@Video, CurveSets, Maps, MapReady, Settings,
      OutputPixels, ErrorText), ErrorText);
    Require(OutputPixels <> nil, 'ApplyToBuffer returned no pixels.');
    SetLength(DirectBytes, Length(SourceBytes));
    Move(OutputPixels^, DirectBytes[0], Length(DirectBytes));
    Require(CompareMem(@DirectBytes[0], @GpuBytes[0], Length(GpuBytes)),
      'ApplyToBuffer differs from the SetImageData output.');

    SetLength(CpuOutput, Length(SourceBytes));
    Require(TBulgeDeformer.ApplyRgba(Maps[0],
      CurveSets[0].OuterContour, CurveSets[0].CenterContour,
      @SourceBytes[0], @CpuOutput[0], Settings.Amount, Settings.Shape,
      Settings.CenterX, Settings.CenterY, Settings.Gravity,
      Settings.GravityDirection, Settings.Mass, Settings.Tension, 0, 0,
      0, 0, ErrorText), ErrorText);
    MaximumDifference := 0;
    for I := 0 to Length(CpuOutput) - 1 do
      MaximumDifference := Max(MaximumDifference,
        Abs(Integer(CpuOutput[I]) - Integer(GpuBytes[I])));
    Require(MaximumDifference <= 2, Format(
      'GPU output differs from CPU output by %d.', [MaximumDifference]));

    Settings.OpacityResponse := 0.65;
    Settings.ShadingStrength := 0.45;
    Settings.LightDirection := 35.0;
    Settings.HighlightStrength := 0.70;
    Require(Gpu.Apply(@Video, CurveSets, Maps, MapReady, Settings,
      ErrorText), ErrorText);
    GpuBytes := Copy(CapturedOutput);
    Require(TBulgeDeformer.ApplyRgba(Maps[0],
      CurveSets[0].OuterContour, CurveSets[0].CenterContour,
      @SourceBytes[0], @CpuOutput[0], Settings.Amount, Settings.Shape,
      Settings.CenterX, Settings.CenterY, Settings.Gravity,
      Settings.GravityDirection, Settings.Mass, Settings.Tension,
      Settings.OpacityResponse, Settings.ShadingStrength,
      Settings.LightDirection, Settings.HighlightStrength, ErrorText),
      ErrorText);
    DisplayDifference := 0;
    for I := 0 to Length(CpuOutput) - 1 do
      DisplayDifference := Max(DisplayDifference,
        Abs(Integer(CpuOutput[I]) - Integer(GpuBytes[I])));
    Require(DisplayDifference <= 3, Format(
      'GPU display correction differs from CPU output by %d.',
      [DisplayDifference]));

    Settings.OpacityResponse := 0;
    Settings.ShadingStrength := 0;
    Settings.HighlightStrength := 0;

    Require(Gpu.ApplyCombined(@Video, CurveSets, Maps, MapReady, Settings,
      False, True, False, 12.75, -8.5, ErrorText), ErrorText);
    GpuBytes := Copy(CapturedOutput);
    Require(Maps[0].ApplyRgba(@SourceBytes[0], @CpuOutput[0],
      12.75, -8.5, ErrorText), ErrorText);
    FixedShakeDifference := 0;
    for I := 0 to Length(CpuOutput) - 1 do
      FixedShakeDifference := Max(FixedShakeDifference,
        Abs(Integer(CpuOutput[I]) - Integer(GpuBytes[I])));
    Require(FixedShakeDifference <= 2, Format(
      'GPU fixed shake differs from CPU output by %d.',
      [FixedShakeDifference]));

    Require(Gpu.ApplyCombined(@Video, CurveSets, Maps, MapReady, Settings,
      False, True, True, 12.75, -8.5, ErrorText), ErrorText);
    GpuBytes := Copy(CapturedOutput);
    Require(Maps[0].ApplyVariableOuterRgba(@SourceBytes[0], @CpuOutput[0],
      12.75, -8.5, ErrorText), ErrorText);
    VariableShakeDifference := 0;
    for I := 0 to Length(CpuOutput) - 1 do
      VariableShakeDifference := Max(VariableShakeDifference,
        Abs(Integer(CpuOutput[I]) - Integer(GpuBytes[I])));
    Require(VariableShakeDifference <= 2, Format(
      'GPU variable shake differs from CPU output by %d.',
      [VariableShakeDifference]));

    Settings.OpacityResponse := 0.65;
    Settings.ShadingStrength := 0.45;
    Settings.LightDirection := 35.0;
    Settings.HighlightStrength := 0.70;
    Require(Gpu.ApplyCombined(@Video, CurveSets, Maps, MapReady, Settings,
      True, True, False, 12.75, -8.5, ErrorText), ErrorText);
    GpuBytes := Copy(CapturedOutput);
    Require(TBulgeDeformer.ApplyRgba(Maps[0],
      CurveSets[0].OuterContour, CurveSets[0].CenterContour,
      @SourceBytes[0], @CpuOutput[0], Settings.Amount, Settings.Shape,
      Settings.CenterX, Settings.CenterY, Settings.Gravity,
      Settings.GravityDirection, Settings.Mass, Settings.Tension,
      Settings.OpacityResponse, Settings.ShadingStrength,
      Settings.LightDirection, Settings.HighlightStrength, ErrorText),
      ErrorText);
    Require(Maps[0].ApplyRgba(@CpuOutput[0], @DirectBytes[0],
      12.75, -8.5, ErrorText), ErrorText);
    CombinedDifference := 0;
    for I := 0 to Length(DirectBytes) - 1 do
      CombinedDifference := Max(CombinedDifference,
        Abs(Integer(DirectBytes[I]) - Integer(GpuBytes[I])));
    Require(CombinedDifference <= 3, Format(
      'GPU combined deformation differs from CPU output by %d.',
      [CombinedDifference]));

    Writeln(Format(
      'GpuBulgeTest: PASS bulge=%d display=%d fixedShake=%d variableShake=%d combined=%d',
      [MaximumDifference, DisplayDifference, FixedShakeDifference,
       VariableShakeDifference, CombinedDifference]));
  finally
    Gpu.Free;
    for I := SHAKE_CURVE_SET_COUNT - 1 downto 0 do
    begin
      Maps[I].Free;
      CurveSets[I].CenterContour.Free;
      CurveSets[I].OuterContour.Free;
    end;
  end;
end.
