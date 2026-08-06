unit Shake_PPP_StaticDeformer;

interface

uses
  Vcl.Graphics,
  Shake_PPP_CurveModel;

type
  TShakeDeformationMap = class
  private
    FHeight: Integer;
    FLastTimingLog: UInt64;
    FWeights: TArray<Single>;
    FWidth: Integer;
  public
    procedure Clear;
    function Build(Width, Height: Integer; OuterContour,
      CenterContour: TShakeCurve; out ErrorText: string): Boolean;
    function Apply(Source, Destination: TBitmap;
      DisplacementX, DisplacementY: Double;
      out ErrorText: string): Boolean;
    function ApplyRgba(Source, Destination: Pointer;
      DisplacementX, DisplacementY: Double;
      out ErrorText: string): Boolean;
    property Height: Integer read FHeight;
    property Width: Integer read FWidth;
  end;

  TShakeStaticDeformer = class sealed
  public
    class function TryDeform(Source, Destination: TBitmap;
      OuterContour, CenterContour: TShakeCurve;
      DisplacementX, DisplacementY: Double;
      out ErrorText: string): Boolean; static;
  end;

implementation

uses
  System.Math,
  System.SysUtils,
  System.Types,
  Winapi.Windows
{$IFDEF DEBUG}
  , Shake_PPP_DebugLog
{$ENDIF}
  ;

const
  CURVE_SAMPLES_PER_SEGMENT = 12;
  MASK_GRID_SIZE = 4;

type
  TDoubleArray = array of Double;
  TBitmapRows = array of PByte;
  PByteRow = ^TByteRow;
  TByteRow = array[0..268435455] of Byte;

function CubicPoint(const Point0, Control1, Control2, Point3: TPointF;
  T: Double): TPointF;
var
  OneMinusT: Double;
begin
  OneMinusT := 1 - T;
  Result.X := Sqr(OneMinusT) * OneMinusT * Point0.X +
    3 * Sqr(OneMinusT) * T * Control1.X +
    3 * OneMinusT * Sqr(T) * Control2.X + Sqr(T) * T * Point3.X;
  Result.Y := Sqr(OneMinusT) * OneMinusT * Point0.Y +
    3 * Sqr(OneMinusT) * T * Control1.Y +
    3 * OneMinusT * Sqr(T) * Control2.Y + Sqr(T) * T * Point3.Y;
end;

procedure CurveControlPoints(Curve: TShakeCurve; SegmentIndex: Integer;
  out Point0, Control1, Control2, Point3: TPointF);
var
  A: TShakeCurveVertex;
  B: TShakeCurveVertex;
  BIndex: Integer;
  NextPosition: TPointF;
  PreviousPosition: TPointF;
begin
  BIndex := (SegmentIndex + 1) mod Curve.Count;
  A := Curve[SegmentIndex];
  B := Curve[BIndex];
  Point0 := A.Position;
  Point3 := B.Position;
  Control1 := Point0;
  Control2 := Point3;
  if A.Kind = svkSmooth then
  begin
    if SegmentIndex > 0 then
      PreviousPosition := Curve[SegmentIndex - 1].Position
    else
      PreviousPosition := Curve[Curve.Count - 1].Position;
    Control1.X := Point0.X + (Point3.X - PreviousPosition.X) / 6;
    Control1.Y := Point0.Y + (Point3.Y - PreviousPosition.Y) / 6;
  end;
  if B.Kind = svkSmooth then
  begin
    if BIndex + 1 < Curve.Count then
      NextPosition := Curve[BIndex + 1].Position
    else
      NextPosition := Curve[0].Position;
    Control2.X := Point3.X - (NextPosition.X - Point0.X) / 6;
    Control2.Y := Point3.Y - (NextPosition.Y - Point0.Y) / 6;
  end;
end;

function FlattenCurve(Curve: TShakeCurve): TArray<TPointF>;
var
  Control1: TPointF;
  Control2: TPointF;
  I: Integer;
  Point0: TPointF;
  Point3: TPointF;
  SampleIndex: Integer;
begin
  SetLength(Result, Curve.Count * CURVE_SAMPLES_PER_SEGMENT);
  for I := 0 to Curve.Count - 1 do
  begin
    CurveControlPoints(Curve, I, Point0, Control1, Control2, Point3);
    for SampleIndex := 0 to CURVE_SAMPLES_PER_SEGMENT - 1 do
      Result[I * CURVE_SAMPLES_PER_SEGMENT + SampleIndex] := CubicPoint(
        Point0, Control1, Control2, Point3,
        SampleIndex / CURVE_SAMPLES_PER_SEGMENT);
  end;
end;

function PointInPolygon(const Polygon: TArray<TPointF>;
  X, Y: Double): Boolean;
var
  I: Integer;
  J: Integer;
begin
  Result := False;
  J := High(Polygon);
  for I := 0 to High(Polygon) do
  begin
    if ((Polygon[I].Y > Y) <> (Polygon[J].Y > Y)) and
      (X < (Polygon[J].X - Polygon[I].X) * (Y - Polygon[I].Y) /
      (Polygon[J].Y - Polygon[I].Y) + Polygon[I].X) then
      Result := not Result;
    J := I;
  end;
end;

function DistanceToPolygon(const Polygon: TArray<TPointF>;
  X, Y, Aspect: Double): Double;
var
  ClosestX: Double;
  ClosestY: Double;
  DX: Double;
  DY: Double;
  I: Integer;
  J: Integer;
  LengthSquared: Double;
  Projection: Double;
begin
  Result := MaxDouble;
  J := High(Polygon);
  for I := 0 to High(Polygon) do
  begin
    DX := (Polygon[I].X - Polygon[J].X) * Aspect;
    DY := Polygon[I].Y - Polygon[J].Y;
    LengthSquared := DX * DX + DY * DY;
    if LengthSquared > 0 then
      Projection := EnsureRange((((X - Polygon[J].X) * Aspect) * DX +
        (Y - Polygon[J].Y) * DY) / LengthSquared, 0.0, 1.0)
    else
      Projection := 0;
    ClosestX := Polygon[J].X + Projection *
      (Polygon[I].X - Polygon[J].X);
    ClosestY := Polygon[J].Y + Projection *
      (Polygon[I].Y - Polygon[J].Y);
    Result := Min(Result, Sqrt(Sqr((X - ClosestX) * Aspect) +
      Sqr(Y - ClosestY)));
    J := I;
  end;
end;

function MaskValue(const OuterPolygon, CenterPolygon: TArray<TPointF>;
  X, Y, Aspect: Double): Double;
var
  CenterDistance: Double;
  OuterDistance: Double;
begin
  if not PointInPolygon(OuterPolygon, X, Y) then
    Exit(0);
  if PointInPolygon(CenterPolygon, X, Y) then
    Exit(1);
  OuterDistance := DistanceToPolygon(OuterPolygon, X, Y, Aspect);
  CenterDistance := DistanceToPolygon(CenterPolygon, X, Y, Aspect);
  if OuterDistance + CenterDistance <= 1.0E-9 then
    Exit(0);
  Result := OuterDistance / (OuterDistance + CenterDistance);
  // Smoothstep removes a visible change of slope at both boundaries.
  Result := Result * Result * (3 - 2 * Result);
end;

function InterpolatedMask(const Mask: TDoubleArray; GridWidth, GridHeight,
  X, Y: Integer): Double;
var
  FX: Double;
  FY: Double;
  GridX: Double;
  GridY: Double;
  X0: Integer;
  X1: Integer;
  Y0: Integer;
  Y1: Integer;
begin
  GridX := X / MASK_GRID_SIZE;
  GridY := Y / MASK_GRID_SIZE;
  X0 := EnsureRange(Trunc(GridX), 0, GridWidth - 1);
  Y0 := EnsureRange(Trunc(GridY), 0, GridHeight - 1);
  X1 := Min(X0 + 1, GridWidth - 1);
  Y1 := Min(Y0 + 1, GridHeight - 1);
  FX := GridX - X0;
  FY := GridY - Y0;
  Result := (Mask[Y0 * GridWidth + X0] * (1 - FX) +
    Mask[Y0 * GridWidth + X1] * FX) * (1 - FY) +
    (Mask[Y1 * GridWidth + X0] * (1 - FX) +
    Mask[Y1 * GridWidth + X1] * FX) * FY;
end;

procedure TShakeDeformationMap.Clear;
begin
  FWeights := nil;
  FWidth := 0;
  FHeight := 0;
  FLastTimingLog := 0;
end;

function TShakeDeformationMap.Build(Width, Height: Integer;
  OuterContour, CenterContour: TShakeCurve;
  out ErrorText: string): Boolean;
var
  Aspect: Double;
  CenterPolygon: TArray<TPointF>;
  GridHeight: Integer;
  GridWidth: Integer;
  GridX: Integer;
  GridY: Integer;
  Mask: TDoubleArray;
  OuterPolygon: TArray<TPointF>;
{$IFDEF DEBUG}
  StartedAt: UInt64;
{$ENDIF}
  X: Integer;
  Y: Integer;
begin
  Result := False;
  ErrorText := '';
  Clear;
  if (Width <= 0) or (Height <= 0) then
  begin
    ErrorText := 'NO_IMAGE';
    Exit;
  end;
  if (OuterContour = nil) or not OuterContour.Closed or
    (OuterContour.Count < 3) then
  begin
    ErrorText := 'OUTER_NOT_CLOSED';
    Exit;
  end;
  if (CenterContour = nil) or not CenterContour.Closed or
    (CenterContour.Count < 3) then
  begin
    ErrorText := 'CENTER_NOT_CLOSED';
    Exit;
  end;

  OuterPolygon := FlattenCurve(OuterContour);
  CenterPolygon := FlattenCurve(CenterContour);
  Aspect := Width / Height;
  GridWidth := (Width + MASK_GRID_SIZE - 1) div MASK_GRID_SIZE + 1;
  GridHeight := (Height + MASK_GRID_SIZE - 1) div MASK_GRID_SIZE + 1;
  SetLength(Mask, GridWidth * GridHeight);
{$IFDEF DEBUG}
  StartedAt := GetTickCount64;
{$ENDIF}
  for GridY := 0 to GridHeight - 1 do
    for GridX := 0 to GridWidth - 1 do
      Mask[GridY * GridWidth + GridX] := MaskValue(OuterPolygon,
        CenterPolygon, Min(GridX * MASK_GRID_SIZE, Width - 1) /
        Max(1, Width - 1),
        1 - Min(GridY * MASK_GRID_SIZE, Height - 1) /
        Max(1, Height - 1), Aspect);
  FWidth := Width;
  FHeight := Height;
  SetLength(FWeights, FWidth * FHeight);
  for Y := 0 to FHeight - 1 do
    for X := 0 to FWidth - 1 do
      FWeights[Y * FWidth + X] :=
        InterpolatedMask(Mask, GridWidth, GridHeight, X, Y);
{$IFDEF DEBUG}
  Shake_PPP_DebugLog.DebugLog(Format(
    'Deformation map built: size=%dx%d grid=%dx%d elapsed=%dms.',
    [FWidth, FHeight, GridWidth, GridHeight,
     GetTickCount64 - StartedAt]));
{$ENDIF}
  Result := True;
end;

function TShakeDeformationMap.Apply(Source,
  Destination: Vcl.Graphics.TBitmap;
  DisplacementX, DisplacementY: Double;
  out ErrorText: string): Boolean;
var
  Channel: Integer;
  DestinationRows: TBitmapRows;
  DestinationRow: PByteRow;
  FX: Double;
  FY: Double;
  PixelOffset0: Integer;
  PixelOffset1: Integer;
  Row0: PByteRow;
  Row1: PByteRow;
  SourceRows: TBitmapRows;
  SourceX: Double;
  SourceY: Double;
{$IFDEF DEBUG}
  StartedAt: UInt64;
{$ENDIF}
  Value: Double;
  Weight: Double;
  X: Integer;
  X0: Integer;
  X1: Integer;
  Y: Integer;
  Y0: Integer;
  Y1: Integer;
begin
  Result := False;
  ErrorText := '';
  if (Source = nil) or (Destination = nil) or
    (Source.Width <> FWidth) or (Source.Height <> FHeight) or
    (Length(FWeights) <> FWidth * FHeight) then
  begin
    ErrorText := 'MAP_NOT_READY';
    Exit;
  end;
  Source.PixelFormat := pf32bit;
  Destination.PixelFormat := pf32bit;
  Destination.SetSize(Source.Width, Source.Height);
  SetLength(SourceRows, Source.Height);
  SetLength(DestinationRows, Destination.Height);
  for Y := 0 to Source.Height - 1 do
  begin
    SourceRows[Y] := Source.ScanLine[Y];
    DestinationRows[Y] := Destination.ScanLine[Y];
  end;
{$IFDEF DEBUG}
  StartedAt := GetTickCount64;
{$ENDIF}
  for Y := 0 to Source.Height - 1 do
  begin
    DestinationRow := PByteRow(DestinationRows[Y]);
    for X := 0 to Source.Width - 1 do
    begin
      Weight := FWeights[Y * FWidth + X];
      SourceX := EnsureRange(X - DisplacementX * Weight,
        0.0, Source.Width - 1.0);
      // TBitmap scanlines run bottom-to-top, while curve Y and the public
      // displacement use the screen's top-to-bottom coordinate system.
      SourceY := EnsureRange(Y + DisplacementY * Weight,
        0.0, Source.Height - 1.0);
      X0 := Trunc(SourceX);
      Y0 := Trunc(SourceY);
      X1 := Min(X0 + 1, Source.Width - 1);
      Y1 := Min(Y0 + 1, Source.Height - 1);
      FX := SourceX - X0;
      FY := SourceY - Y0;
      Row0 := PByteRow(SourceRows[Y0]);
      Row1 := PByteRow(SourceRows[Y1]);
      PixelOffset0 := X0 * 4;
      PixelOffset1 := X1 * 4;
      for Channel := 0 to 3 do
      begin
        Value := (Row0[PixelOffset0 + Channel] * (1 - FX) +
          Row0[PixelOffset1 + Channel] * FX) * (1 - FY) +
          (Row1[PixelOffset0 + Channel] * (1 - FX) +
          Row1[PixelOffset1 + Channel] * FX) * FY;
        DestinationRow[X * 4 + Channel] :=
          EnsureRange(Round(Value), 0, 255);
      end;
    end;
  end;
{$IFDEF DEBUG}
  if (FLastTimingLog = 0) or
    (GetTickCount64 - FLastTimingLog >= 1000) then
  begin
    FLastTimingLog := GetTickCount64;
    Shake_PPP_DebugLog.DebugLog(Format(
      'Deformation frame applied: size=%dx%d offset=%.1f,%.1f elapsed=%dms.',
      [Source.Width, Source.Height, DisplacementX, DisplacementY,
       FLastTimingLog - StartedAt]));
  end;
{$ENDIF}
  Result := True;
end;

function TShakeDeformationMap.ApplyRgba(Source, Destination: Pointer;
  DisplacementX, DisplacementY: Double;
  out ErrorText: string): Boolean;
type
  PRgbaBytes = ^TRgbaBytes;
  TRgbaBytes = array[0..268435455] of Byte;
var
  Channel: Integer;
  FX: Double;
  FY: Double;
  PixelOffset00: NativeInt;
  PixelOffset01: NativeInt;
  PixelOffset10: NativeInt;
  PixelOffset11: NativeInt;
  SourceBytes: PRgbaBytes;
  DestinationBytes: PRgbaBytes;
  SourceX: Double;
  SourceY: Double;
  Value: Double;
  Weight: Double;
  X: Integer;
  X0: Integer;
  X1: Integer;
  Y: Integer;
  Y0: Integer;
  Y1: Integer;
begin
  Result := False;
  ErrorText := '';
  if (Source = nil) or (Destination = nil) or (FWidth <= 0) or
    (FHeight <= 0) or (Length(FWeights) <> FWidth * FHeight) then
  begin
    ErrorText := 'MAP_NOT_READY';
    Exit;
  end;
  SourceBytes := Source;
  DestinationBytes := Destination;
  for Y := 0 to FHeight - 1 do
    for X := 0 to FWidth - 1 do
    begin
      Weight := FWeights[Y * FWidth + X];
      SourceX := EnsureRange(X - DisplacementX * Weight,
        0.0, FWidth - 1.0);
      SourceY := EnsureRange(Y - DisplacementY * Weight,
        0.0, FHeight - 1.0);
      X0 := Trunc(SourceX);
      Y0 := Trunc(SourceY);
      X1 := Min(X0 + 1, FWidth - 1);
      Y1 := Min(Y0 + 1, FHeight - 1);
      FX := SourceX - X0;
      FY := SourceY - Y0;
      PixelOffset00 := (NativeInt(Y0) * FWidth + X0) * 4;
      PixelOffset01 := (NativeInt(Y0) * FWidth + X1) * 4;
      PixelOffset10 := (NativeInt(Y1) * FWidth + X0) * 4;
      PixelOffset11 := (NativeInt(Y1) * FWidth + X1) * 4;
      for Channel := 0 to 3 do
      begin
        Value := (SourceBytes^[PixelOffset00 + Channel] * (1 - FX) +
          SourceBytes^[PixelOffset01 + Channel] * FX) * (1 - FY) +
          (SourceBytes^[PixelOffset10 + Channel] * (1 - FX) +
          SourceBytes^[PixelOffset11 + Channel] * FX) * FY;
        DestinationBytes^[(NativeInt(Y) * FWidth + X) * 4 + Channel] :=
          EnsureRange(Round(Value), 0, 255);
      end;
    end;
  Result := True;
end;

class function TShakeStaticDeformer.TryDeform(Source,
  Destination: Vcl.Graphics.TBitmap;
  OuterContour, CenterContour: TShakeCurve;
  DisplacementX, DisplacementY: Double; out ErrorText: string): Boolean;
var
  DeformationMap: TShakeDeformationMap;
begin
  Result := False;
  ErrorText := '';
  if (Source = nil) or (Destination = nil) then
  begin
    ErrorText := 'NO_IMAGE';
    Exit;
  end;
  DeformationMap := TShakeDeformationMap.Create;
  try
    if not DeformationMap.Build(Source.Width, Source.Height,
      OuterContour, CenterContour, ErrorText) then
      Exit;
    Result := DeformationMap.Apply(Source, Destination,
      DisplacementX, DisplacementY, ErrorText);
  finally
    DeformationMap.Free;
  end;
end;

end.
