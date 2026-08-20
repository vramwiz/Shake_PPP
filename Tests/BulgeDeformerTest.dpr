program BulgeDeformerTest;

{$APPTYPE CONSOLE}

uses
  System.Math,
  System.SysUtils,
  System.Types,
  Vcl.Graphics,
  Shake_PPP_CurveModel in 'Source\Common\Model\Shake_PPP_CurveModel.pas',
  Shake_PPP_DebugLog in 'Source\Common\Diagnostics\Shake_PPP_DebugLog.pas',
  Shake_PPP_StaticDeformer in 'Source\Common\Render\Shake_PPP_StaticDeformer.pas',
  Shake_PPP_BulgeDeformer in 'Source\Common\Render\Shake_PPP_BulgeDeformer.pas';

procedure Require(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
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

function PixelValue(Bitmap: TBitmap; X, Y, Channel: Integer): Byte;
var
  Row: PByte;
begin
  Row := Bitmap.ScanLine[Y];
  Inc(Row, X * 4 + Channel);
  Result := Row^;
end;

function BitmapsEqual(Left, Right: TBitmap): Boolean;
var
  Y: Integer;
begin
  Result := (Left.Width = Right.Width) and (Left.Height = Right.Height);
  if not Result then
    Exit;
  for Y := 0 to Left.Height - 1 do
    if not CompareMem(Left.ScanLine[Y], Right.ScanLine[Y],
      NativeInt(Left.Width) * 4) then
      Exit(False);
end;

var
  CenterContour: TShakeCurve;
  CenteredResult: TBitmap;
  DeformationMap: TBulgeDeformationMap;
  ErrorText: string;
  FocusedResult: TBitmap;
  GravityDownResult: TBitmap;
  HeavyResult: TBitmap;
  HighTensionResult: TBitmap;
  HighlightLeftResult: TBitmap;
  HighlightRightResult: TBitmap;
  GravityUpResult: TBitmap;
  GravityZeroResult: TBitmap;
  IdentityResult: TBitmap;
  BroadResult: TBitmap;
  OffsetResult: TBitmap;
  OpacityContractResult: TBitmap;
  OpacityExpandResult: TBitmap;
  OuterContour: TShakeCurve;
  Row: PByte;
  ShadingLeftResult: TBitmap;
  ShadingRightResult: TBitmap;
  Source: TBitmap;
  X: Integer;
  Y: Integer;
begin
  Source := TBitmap.Create;
  ShadingLeftResult := TBitmap.Create;
  ShadingRightResult := TBitmap.Create;
  IdentityResult := TBitmap.Create;
  CenteredResult := TBitmap.Create;
  FocusedResult := TBitmap.Create;
  GravityDownResult := TBitmap.Create;
  HeavyResult := TBitmap.Create;
  HighTensionResult := TBitmap.Create;
  HighlightLeftResult := TBitmap.Create;
  HighlightRightResult := TBitmap.Create;
  GravityUpResult := TBitmap.Create;
  GravityZeroResult := TBitmap.Create;
  BroadResult := TBitmap.Create;
  OffsetResult := TBitmap.Create;
  OpacityContractResult := TBitmap.Create;
  OpacityExpandResult := TBitmap.Create;
  DeformationMap := TBulgeDeformationMap.Create;
  OuterContour := TShakeCurve.Create;
  CenterContour := TShakeCurve.Create;
  try
    Source.PixelFormat := pf32bit;
    Source.SetSize(128, 96);
    for Y := 0 to Source.Height - 1 do
    begin
      Row := Source.ScanLine[Y];
      for X := 0 to Source.Width - 1 do
      begin
        Row[0] := Byte(X);
        Row[1] := Byte(Y);
        Row[2] := Byte((X + Y) and $FF);
        Row[3] := 160;
        Inc(Row, 4);
      end;
    end;
    AddEllipse(OuterContour, 0.5, 0.5, 0.42, 0.42);
    AddEllipse(CenterContour, 0.5, 0.5, 0.16, 0.16);
    Require(DeformationMap.Build(Source.Width, Source.Height,
      OuterContour, CenterContour, ErrorText), ErrorText);

    Require(DeformationMap.Apply(Source, IdentityResult, 1.0, 0.5, 0.0,
      0.0, 1.0, 90.0, 1.0, 0.0, 1.0, 0.0, -135.0, 0.0,
      ErrorText), ErrorText);
    Require(BitmapsEqual(Source, IdentityResult),
      'Amount 100% must preserve every pixel.');

    Require(DeformationMap.Apply(Source, CenteredResult, 1.5, 0.5, 0.0,
      0.0, 0.0, 90.0, 0.5, 0.5, 0.0, 0.0, -135.0, 0.0,
      ErrorText), ErrorText);
    Require(PixelValue(Source, 78, 48, 0) <>
      PixelValue(CenteredResult, 78, 48, 0),
      'Expansion did not change an inner pixel.');
    Require(PixelValue(Source, 2, 2, 0) =
      PixelValue(CenteredResult, 2, 2, 0),
      'Expansion changed a pixel outside the outer contour.');

    Require(DeformationMap.Apply(Source, OffsetResult, 1.5, 0.5, 0.5,
      0.0, 0.0, 90.0, 0.5, 0.5, 0.0, 0.0, -135.0, 0.0,
      ErrorText), ErrorText);
    Require(not BitmapsEqual(CenteredResult, OffsetResult),
      'Center offset did not affect the deformation result.');

    Require(DeformationMap.Apply(Source, FocusedResult, 1.5, 0.0, 0.0,
      0.0, 0.0, 90.0, 0.5, 0.5, 0.0, 0.0, -135.0, 0.0,
      ErrorText), ErrorText);
    Require(DeformationMap.Apply(Source, BroadResult, 1.5, 1.0, 0.0,
      0.0, 0.0, 90.0, 0.5, 0.5, 0.0, 0.0, -135.0, 0.0,
      ErrorText), ErrorText);
    Require(PixelValue(BroadResult, 95, 48, 0) <
      PixelValue(FocusedResult, 95, 48, 0),
      'Bulge shape did not broaden deformation toward the outer contour.');

    Require(DeformationMap.Apply(Source, GravityZeroResult, 1.5, 0.5,
      0.0, 0.0, 0.0, -45.0, 1.0, 0.0, 0.0, 0.0, -135.0, 0.0,
      ErrorText), ErrorText);
    Require(BitmapsEqual(CenteredResult, GravityZeroResult),
      'Gravity 0% must preserve the standard bulge result.');
    Require(DeformationMap.Apply(Source, GravityDownResult, 1.5, 0.5,
      0.0, 0.0, 1.0, 90.0, 0.5, 0.5, 0.0, 0.0, -135.0, 0.0,
      ErrorText), ErrorText);
    Require(DeformationMap.Apply(Source, GravityUpResult, 1.5, 0.5,
      0.0, 0.0, 1.0, -90.0, 0.5, 0.5, 0.0, 0.0, -135.0, 0.0,
      ErrorText), ErrorText);
    Require(not BitmapsEqual(CenteredResult, GravityDownResult),
      'Gravity strength did not affect the deformation result.');
    Require(not BitmapsEqual(GravityDownResult, GravityUpResult),
      'Gravity direction did not affect the deformation result.');

    Require(DeformationMap.Apply(Source, HeavyResult, 1.5, 0.5,
      0.0, 0.0, 0.6, 90.0, 1.0, 0.5, 0.0, 0.0, -135.0, 0.0,
      ErrorText), ErrorText);
    Require(DeformationMap.Apply(Source, HighTensionResult, 1.5, 0.5,
      0.0, 0.0, 0.6, 90.0, 1.0, 1.0, 0.0, 0.0, -135.0, 0.0,
      ErrorText), ErrorText);
    Require(not BitmapsEqual(HeavyResult, HighTensionResult),
      'Tension did not resist the mass-driven gravity response.');
    Require(not BitmapsEqual(GravityDownResult, HeavyResult),
      'Mass did not affect the gravity response.');

    Require(DeformationMap.Apply(Source, OpacityExpandResult, 1.5, 0.5,
      0.0, 0.0, 0.0, 90.0, 0.5, 0.5, 1.0, 0.0, -135.0, 0.0,
      ErrorText), ErrorText);
    Require(PixelValue(OpacityExpandResult, 64, 48, 3) <
      PixelValue(CenteredResult, 64, 48, 3),
      'Expanded area did not become thinner.');
    Require(PixelValue(OpacityExpandResult, 2, 2, 3) =
      PixelValue(Source, 2, 2, 3),
      'Opacity response changed a pixel outside the outer contour.');
    Require(DeformationMap.Apply(Source, OpacityContractResult, 0.75, 0.5,
      0.0, 0.0, 0.0, 90.0, 0.5, 0.5, 1.0, 0.0, -135.0, 0.0,
      ErrorText), ErrorText);
    Require(PixelValue(OpacityContractResult, 64, 48, 3) >
      PixelValue(Source, 64, 48, 3),
      'Contracted area did not become optically thicker.');

    Require(DeformationMap.Apply(Source, ShadingRightResult, 1.5, 0.5,
      0.0, 0.0, 0.0, 90.0, 0.5, 0.5, 0.0, 1.0, 0.0, 0.0,
      ErrorText), ErrorText);
    Require(DeformationMap.Apply(Source, ShadingLeftResult, 1.5, 0.5,
      0.0, 0.0, 0.0, 90.0, 0.5, 0.5, 0.0, 1.0, 180.0, 0.0,
      ErrorText), ErrorText);
    Require(not BitmapsEqual(ShadingRightResult, ShadingLeftResult),
      'Light direction did not affect pseudo-height shading.');
    Require(PixelValue(ShadingRightResult, 64, 48, 3) =
      PixelValue(CenteredResult, 64, 48, 3),
      'Shading unexpectedly changed alpha.');
    Require(PixelValue(ShadingRightResult, 2, 2, 0) =
      PixelValue(Source, 2, 2, 0),
      'Shading changed a pixel outside the outer contour.');

    Require(DeformationMap.Apply(Source, HighlightRightResult, 1.5, 0.5,
      0.0, 0.0, 0.0, 90.0, 0.5, 0.5, 0.0, 0.0, 0.0, 1.0,
      ErrorText), ErrorText);
    Require(DeformationMap.Apply(Source, HighlightLeftResult, 1.5, 0.5,
      0.0, 0.0, 0.0, 90.0, 0.5, 0.5, 0.0, 0.0, 180.0, 1.0,
      ErrorText), ErrorText);
    Require(not BitmapsEqual(CenteredResult, HighlightRightResult),
      'Highlight strength did not affect RGB output.');
    Require(not BitmapsEqual(HighlightRightResult, HighlightLeftResult),
      'Light direction did not move the highlight.');
    Require(PixelValue(HighlightRightResult, 64, 48, 3) =
      PixelValue(CenteredResult, 64, 48, 3),
      'Highlight unexpectedly changed alpha.');
    Require(PixelValue(HighlightRightResult, 2, 2, 0) =
      PixelValue(Source, 2, 2, 0),
      'Highlight changed a pixel outside the outer contour.');
    Writeln('BulgeDeformerTest: PASS');
  finally
    CenterContour.Free;
    OuterContour.Free;
    DeformationMap.Free;
    HighlightRightResult.Free;
    HighlightLeftResult.Free;
    ShadingRightResult.Free;
    ShadingLeftResult.Free;
    OpacityExpandResult.Free;
    OpacityContractResult.Free;
    HighTensionResult.Free;
    HeavyResult.Free;
    GravityZeroResult.Free;
    GravityUpResult.Free;
    GravityDownResult.Free;
    OffsetResult.Free;
    BroadResult.Free;
    FocusedResult.Free;
    CenteredResult.Free;
    IdentityResult.Free;
    Source.Free;
  end;
end.
