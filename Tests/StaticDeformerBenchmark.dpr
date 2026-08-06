program StaticDeformerBenchmark;

{$APPTYPE CONSOLE}

uses
  System.Math,
  System.SysUtils,
  System.Types,
  Winapi.Windows,
  Vcl.Graphics,
  Shake_PPP_CurveModel in 'Source\Common\Model\Shake_PPP_CurveModel.pas',
  Shake_PPP_DebugLog in 'Source\Common\Diagnostics\Shake_PPP_DebugLog.pas',
  Shake_PPP_StaticDeformer in 'Source\Common\Render\Shake_PPP_StaticDeformer.pas';

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
  CenterContour: TShakeCurve;
  DeformationMap: TShakeDeformationMap;
  Destination: TBitmap;
  Elapsed: UInt64;
  ErrorText: string;
  OuterContour: TShakeCurve;
  Row: PByte;
  Source: TBitmap;
  StartedAt: UInt64;
  X: Integer;
  Y: Integer;
begin
  Source := TBitmap.Create;
  Destination := TBitmap.Create;
  DeformationMap := TShakeDeformationMap.Create;
  OuterContour := TShakeCurve.Create;
  CenterContour := TShakeCurve.Create;
  try
    Source.PixelFormat := pf32bit;
    Source.SetSize(1024, 1024);
    for Y := 0 to Source.Height - 1 do
    begin
      Row := Source.ScanLine[Y];
      for X := 0 to Source.Width - 1 do
      begin
        Row[0] := Byte(X and $FF);
        Row[1] := Byte(Y and $FF);
        Row[2] := Byte((X + Y) and $FF);
        Row[3] := 255;
        Inc(Row, 4);
      end;
    end;
    AddEllipse(OuterContour, 0.5, 0.5, 0.42, 0.42);
    AddEllipse(CenterContour, 0.5, 0.5, 0.18, 0.18);
    StartedAt := GetTickCount64;
    if not DeformationMap.Build(Source.Width, Source.Height,
      OuterContour, CenterContour, ErrorText) then
      raise Exception.Create(ErrorText);
    Elapsed := GetTickCount64 - StartedAt;
    Writeln(Format('1024x1024 map build: %d ms', [Elapsed]));
    StartedAt := GetTickCount64;
    for X := 0 to 29 do
      if not DeformationMap.Apply(Source, Destination,
        Sin(X / 5) * 61.4, Cos(X / 7) * 35.8, ErrorText) then
        raise Exception.Create(ErrorText);
    Elapsed := GetTickCount64 - StartedAt;
    Writeln(Format('30 frames: %d ms, average: %.1f ms',
      [Elapsed, Elapsed / 30.0]));
  finally
    CenterContour.Free;
    OuterContour.Free;
    Destination.Free;
    DeformationMap.Free;
    Source.Free;
  end;
end.
