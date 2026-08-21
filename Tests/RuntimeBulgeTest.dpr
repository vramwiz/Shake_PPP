program RuntimeBulgeTest;

{$APPTYPE CONSOLE}

uses
  System.Math,
  System.SysUtils,
  System.Types,
  AviUtl2FilterTypes in '..\Syncroh2\AviUtl\Filter\AviUtl2FilterTypes.pas',
  AviUtl2FilterInfoUtils in '..\Syncroh2\AviUtl\Filter\AviUtl2FilterInfoUtils.pas',
  PluginFilterTable in '..\Syncroh2\Plugin_Filter\PluginFilterTable.pas',
  Shake_PPP_CurveModel in 'Source\Common\Model\Shake_PPP_CurveModel.pas',
  Shake_PPP_CurveData in 'Source\Common\Model\Shake_PPP_CurveData.pas',
  Shake_PPP_DebugLog in 'Source\Common\Diagnostics\Shake_PPP_DebugLog.pas',
  Shake_PPP_FilterSettings in 'Source\Common\Settings\Shake_PPP_FilterSettings.pas',
  Shake_PPP_BulgeSettings in 'Source\Common\Settings\Shake_PPP_BulgeSettings.pas',
  Shake_PPP_StaticDeformer in 'Source\Common\Render\Shake_PPP_StaticDeformer.pas',
  Shake_PPP_BulgeDeformer in 'Source\Common\Render\Shake_PPP_BulgeDeformer.pas',
  Shake_PPP_GpuBulgeDeformer in 'Source\Common\Render\Shake_PPP_GpuBulgeDeformer.pas',
  Shake_PPP_RuntimeDeformer in 'Source\Common\Render\Shake_PPP_RuntimeDeformer.pas';

const
  IMAGE_WIDTH = 128;
  IMAGE_HEIGHT = 96;

var
  InputPixels: TBytes;
  OutputPixels: TBytes;
  SetImageCallCount: Integer;

procedure Require(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

procedure GetImageData(Buffer: PPIXEL_RGBA); cdecl;
begin
  Move(InputPixels[0], Buffer^, Length(InputPixels));
end;

procedure SetImageData(Buffer: PPIXEL_RGBA; Width, Height: Integer); cdecl;
begin
  Require((Width = IMAGE_WIDTH) and (Height = IMAGE_HEIGHT),
    'Runtime output dimensions changed.');
  SetLength(OutputPixels, NativeInt(Width) * Height * 4);
  Move(Buffer^, OutputPixels[0], Length(OutputPixels));
  Inc(SetImageCallCount);
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

procedure FillInput;
var
  Offset: NativeInt;
  X: Integer;
  Y: Integer;
begin
  SetLength(InputPixels, NativeInt(IMAGE_WIDTH) * IMAGE_HEIGHT * 4);
  for Y := 0 to IMAGE_HEIGHT - 1 do
    for X := 0 to IMAGE_WIDTH - 1 do
    begin
      Offset := (NativeInt(Y) * IMAGE_WIDTH + X) * 4;
      InputPixels[Offset] := Byte(X);
      InputPixels[Offset + 1] := Byte(Y);
      InputPixels[Offset + 2] := Byte((X + Y) and $FF);
      InputPixels[Offset + 3] := 255;
    end;
end;

function BytesEqual(const Left, Right: TBytes): Boolean;
begin
  Result := (Length(Left) = Length(Right)) and
    ((Length(Left) = 0) or CompareMem(@Left[0], @Right[0], Length(Left)));
end;

function PixelChannel(const Pixels: TBytes; X, Y, Channel: Integer): Byte;
begin
  Result := Pixels[(NativeInt(Y) * IMAGE_WIDTH + X) * 4 + Channel];
end;

var
  BulgeOnlyPixels: TBytes;
  BulgeSettings: TBulgeRuntimeSettings;
  CurveDataText: string;
  CurveSets: TShakeCurveSets;
  ErrorText: string;
  GravityDownPixels: TBytes;
  HighlightRightPixels: TBytes;
  I: Integer;
  ObjectInfo: TOBJECT_INFO;
  OriginalPixels: TBytes;
  ShadingRightPixels: TBytes;
  StrongGravityResponsePixels: TBytes;
  ShakeSettings: TShakeRuntimeSettings;
  Video: TFILTER_PROC_VIDEO;
begin
  FillInput;
  OriginalPixels := Copy(InputPixels);
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
  begin
    CurveSets[I].OuterContour := TShakeCurve.Create;
    CurveSets[I].CenterContour := TShakeCurve.Create;
  end;
  try
    AddEllipse(CurveSets[0].OuterContour, 0.30, 0.5, 0.20, 0.30);
    AddEllipse(CurveSets[0].CenterContour, 0.30, 0.5, 0.08, 0.12);
    AddEllipse(CurveSets[1].OuterContour, 0.70, 0.5, 0.20, 0.30);
    AddEllipse(CurveSets[1].CenterContour, 0.70, 0.5, 0.08, 0.12);
    Require(TryEncodeCurveSets(CurveSets, CurveDataText, ErrorText),
      ErrorText);

    ObjectInfo := Default(TOBJECT_INFO);
    ObjectInfo.ID := 1;
    ObjectInfo.EffectID := 1001;
    ObjectInfo.Width := IMAGE_WIDTH;
    ObjectInfo.Height := IMAGE_HEIGHT;
    Video := Default(TFILTER_PROC_VIDEO);
    Video.Object_ := @ObjectInfo;
    Video.GetImageData := GetImageData;
    Video.SetImageData := SetImageData;

    ShakeSettings := Default(TShakeRuntimeSettings);
    ShakeSettings.DeformationType := sdtFixedOuter;
    ShakeSettings.MaximumDeformation := 100;
    ShakeSettings.HorizontalInfluence := 1;
    ShakeSettings.VerticalInfluence := 1;
    BulgeSettings := Default(TBulgeRuntimeSettings);
    BulgeSettings.Amount := 1.0;
    BulgeSettings.Shape := 0.5;
    BulgeSettings.Mass := 0.5;
    BulgeSettings.Tension := 0.5;

    InitializeRuntimeDeformer;
    try
      SetImageCallCount := 0;
      ApplyRuntimeDeformation(@Video, CurveDataText, ShakeSettings,
        BulgeSettings);
      Require(SetImageCallCount = 0,
        'Neutral bulge unexpectedly wrote an output frame.');

      BulgeSettings.Amount := 1.5;
      SetImageCallCount := 0;
      ApplyRuntimeDeformation(@Video, CurveDataText, ShakeSettings,
        BulgeSettings);
      Require(SetImageCallCount = 1,
        'Bulge did not run while time-axis calculation was disabled.');
      Require(not BytesEqual(OriginalPixels, OutputPixels),
        'Runtime bulge did not change the image.');
      Require(PixelChannel(OriginalPixels, 47, 48, 0) <>
        PixelChannel(OutputPixels, 47, 48, 0),
        'Curve set 1 did not apply its runtime bulge.');
      Require(PixelChannel(OriginalPixels, 98, 48, 0) <>
        PixelChannel(OutputPixels, 98, 48, 0),
        'Curve set 2 did not apply its runtime bulge.');
      BulgeOnlyPixels := Copy(OutputPixels);

      InputPixels := Copy(OriginalPixels);
      BulgeSettings.OpacityResponse := 1.0;
      ApplyRuntimeDeformation(@Video, CurveDataText, ShakeSettings,
        BulgeSettings);
      Require(PixelChannel(OutputPixels, 38, 48, 3) <
        PixelChannel(BulgeOnlyPixels, 38, 48, 3),
        'Runtime opacity response did not thin the expanded area.');
      Require(PixelChannel(OutputPixels, 2, 2, 3) =
        PixelChannel(OriginalPixels, 2, 2, 3),
        'Runtime opacity response changed a pixel outside the contour.');
      BulgeSettings.OpacityResponse := 0.0;

      InputPixels := Copy(OriginalPixels);
      BulgeSettings.ShadingStrength := 1.0;
      BulgeSettings.LightDirection := 0.0;
      ApplyRuntimeDeformation(@Video, CurveDataText, ShakeSettings,
        BulgeSettings);
      ShadingRightPixels := Copy(OutputPixels);
      Require(not BytesEqual(BulgeOnlyPixels, ShadingRightPixels),
        'Runtime shading did not affect RGB output.');
      Require(PixelChannel(ShadingRightPixels, 38, 48, 3) =
        PixelChannel(BulgeOnlyPixels, 38, 48, 3),
        'Runtime shading unexpectedly changed alpha.');
      InputPixels := Copy(OriginalPixels);
      BulgeSettings.LightDirection := 180.0;
      ApplyRuntimeDeformation(@Video, CurveDataText, ShakeSettings,
        BulgeSettings);
      Require(not BytesEqual(ShadingRightPixels, OutputPixels),
        'Runtime light direction did not affect shading.');
      BulgeSettings.ShadingStrength := 0.0;
      BulgeSettings.LightDirection := -135.0;

      InputPixels := Copy(OriginalPixels);
      BulgeSettings.HighlightStrength := 1.0;
      BulgeSettings.LightDirection := 0.0;
      ApplyRuntimeDeformation(@Video, CurveDataText, ShakeSettings,
        BulgeSettings);
      HighlightRightPixels := Copy(OutputPixels);
      Require(not BytesEqual(BulgeOnlyPixels, HighlightRightPixels),
        'Runtime highlight did not affect RGB output.');
      Require(PixelChannel(HighlightRightPixels, 38, 48, 3) =
        PixelChannel(BulgeOnlyPixels, 38, 48, 3),
        'Runtime highlight unexpectedly changed alpha.');
      InputPixels := Copy(OriginalPixels);
      BulgeSettings.LightDirection := 180.0;
      ApplyRuntimeDeformation(@Video, CurveDataText, ShakeSettings,
        BulgeSettings);
      Require(not BytesEqual(HighlightRightPixels, OutputPixels),
        'Runtime light direction did not move the highlight.');
      BulgeSettings.HighlightStrength := 0.0;
      BulgeSettings.LightDirection := -135.0;

      InputPixels := Copy(OriginalPixels);
      BulgeSettings.Gravity := 1.0;
      BulgeSettings.GravityDirection := 90.0;
      ApplyRuntimeDeformation(@Video, CurveDataText, ShakeSettings,
        BulgeSettings);
      GravityDownPixels := Copy(OutputPixels);
      Require(not BytesEqual(BulgeOnlyPixels, GravityDownPixels),
        'Runtime gravity did not affect the bulge result.');

      InputPixels := Copy(OriginalPixels);
      BulgeSettings.GravityDirection := -90.0;
      ApplyRuntimeDeformation(@Video, CurveDataText, ShakeSettings,
        BulgeSettings);
      Require(not BytesEqual(GravityDownPixels, OutputPixels),
        'Runtime gravity direction did not affect the bulge result.');

      InputPixels := Copy(OriginalPixels);
      BulgeSettings.GravityDirection := 90.0;
      BulgeSettings.Mass := 1.0;
      BulgeSettings.Tension := 0.0;
      ApplyRuntimeDeformation(@Video, CurveDataText, ShakeSettings,
        BulgeSettings);
      StrongGravityResponsePixels := Copy(OutputPixels);
      Require(not BytesEqual(GravityDownPixels, StrongGravityResponsePixels),
        'Runtime mass and tension did not affect the gravity response.');

      BulgeSettings.Gravity := 0.0;
      BulgeSettings.GravityDirection := 90.0;
      BulgeSettings.Mass := 0.5;
      BulgeSettings.Tension := 0.5;

      InputPixels := Copy(OriginalPixels);
      ShakeSettings.TimeAxisEnabled := True;
      ShakeSettings.Strength := 1;
      ShakeSettings.Delay := 0.5;
      ShakeSettings.Softness := 0.5;
      ShakeSettings.Duration := 0.5;
      ObjectInfo.Frame := 0;
      ShakeSettings.PositionX := 0;
      ShakeSettings.PositionY := 0;
      ApplyRuntimeDeformation(@Video, CurveDataText, ShakeSettings,
        BulgeSettings);

      InputPixels := Copy(OriginalPixels);
      ObjectInfo.Frame := 1;
      ShakeSettings.PositionX := 20;
      SetImageCallCount := 0;
      ApplyRuntimeDeformation(@Video, CurveDataText, ShakeSettings,
        BulgeSettings);
      Require(SetImageCallCount = 1,
        'Combined bulge and shake did not write an output frame.');
      Require(not BytesEqual(BulgeOnlyPixels, OutputPixels),
        'Shake was not applied after the runtime bulge.');
    finally
      FinalizeRuntimeDeformer;
    end;
    Writeln('RuntimeBulgeTest: PASS');
  finally
    for I := SHAKE_CURVE_SET_COUNT - 1 downto 0 do
    begin
      CurveSets[I].CenterContour.Free;
      CurveSets[I].OuterContour.Free;
    end;
  end;
end.
