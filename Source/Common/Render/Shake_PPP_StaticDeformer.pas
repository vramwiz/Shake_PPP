unit Shake_PPP_StaticDeformer;

interface

uses
  Vcl.Graphics,
  Shake_PPP_CurveModel;

type
  TShakeDeformationMap = class
  private
    FActiveBottom: Integer;
    FActiveLeft: Integer;
    FActiveRight: Integer;
    FActiveTop: Integer;
    FHeight: Integer;
    FLastTimingLog: UInt64;
    FWeights: TArray<Single>;
    FWidth: Integer;
  public
    procedure Clear;
    function Build(Width, Height: Integer; OuterContour,
      CenterContour: TShakeCurve; out ErrorText: string): Boolean;
    procedure CopyScreenWeightsToSingles(out Buffer: TArray<Single>);
    function Apply(Source, Destination: TBitmap;
      DisplacementX, DisplacementY: Double;
      out ErrorText: string): Boolean;
    function ApplyRgba(Source, Destination: Pointer;
      DisplacementX, DisplacementY: Double;
      out ErrorText: string): Boolean;
    function ApplyVariableOuterRgba(Source, Destination: Pointer;
      DisplacementX, DisplacementY: Double;
      out ErrorText: string): Boolean;
    function WeightAtScreen(X, Y: Integer): Double;
    procedure WeightAndGradientAtScreen(X, Y: Integer; out Weight,
      GradientX, GradientY: Double);
    property ActiveBottom: Integer read FActiveBottom;
    property ActiveLeft: Integer read FActiveLeft;
    property ActiveRight: Integer read FActiveRight;
    property ActiveTop: Integer read FActiveTop;
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
  VARIABLE_OUTER_MOTION_RATIO = 0.35;

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

{$IFDEF DEBUG}
procedure DebugLogCurveCoordinates(const CurveName: string;
  Curve: TShakeCurve; const Polygon: TArray<TPointF>;
  Width, Height: Integer);
var
  I: Integer;
  MaximumX: Double;
  MaximumY: Double;
  MinimumX: Double;
  MinimumY: Double;
  Vertex: TShakeCurveVertex;
begin
  for I := 0 to Curve.Count - 1 do
  begin
    Vertex := Curve[I];
    Shake_PPP_DebugLog.DebugLog(Format(
      'Deformation curve vertex: curve=%s index=%d normalized=(%.8f,%.8f) image=(%.3f,%.3f).',
      [CurveName, I, Vertex.Position.X, Vertex.Position.Y,
       Vertex.Position.X * Max(1, Width - 1),
       Vertex.Position.Y * Max(1, Height - 1)]));
  end;

  MinimumX := MaxDouble;
  MinimumY := MaxDouble;
  MaximumX := -MaxDouble;
  MaximumY := -MaxDouble;
  for I := 0 to High(Polygon) do
  begin
    MinimumX := Min(MinimumX, Polygon[I].X);
    MinimumY := Min(MinimumY, Polygon[I].Y);
    MaximumX := Max(MaximumX, Polygon[I].X);
    MaximumY := Max(MaximumY, Polygon[I].Y);
  end;
  Shake_PPP_DebugLog.DebugLog(Format(
    'Deformation curve bounds: curve=%s normalized=(%.8f,%.8f)-(%.8f,%.8f) image=(%.3f,%.3f)-(%.3f,%.3f).',
    [CurveName, MinimumX, MinimumY, MaximumX, MaximumY,
     MinimumX * Max(1, Width - 1), MinimumY * Max(1, Height - 1),
     MaximumX * Max(1, Width - 1), MaximumY * Max(1, Height - 1)]));
end;
{$ENDIF}

procedure TShakeDeformationMap.Clear;
begin
  FWeights := nil;
  FWidth := 0;
  FHeight := 0;
  FActiveLeft := 0;
  FActiveTop := 0;
  FActiveRight := -1;
  FActiveBottom := -1;
  FLastTimingLog := 0;
end;

function TShakeDeformationMap.WeightAtScreen(X, Y: Integer): Double;
begin
  if (X < 0) or (X >= FWidth) or (Y < 0) or (Y >= FHeight) or
    (Length(FWeights) <> FWidth * FHeight) then
    Exit(0);
  Result := FWeights[(FHeight - 1 - Y) * FWidth + X];
end;

procedure TShakeDeformationMap.WeightAndGradientAtScreen(X, Y: Integer;
  out Weight, GradientX, GradientY: Double);
var
  BottomWeight: Double;
  Index: NativeInt;
  LeftWeight: Double;
  RightWeight: Double;
  TopWeight: Double;
  WeightY: Integer;
begin
  if (X < 0) or (X >= FWidth) or (Y < 0) or (Y >= FHeight) or
    (Length(FWeights) <> FWidth * FHeight) then
  begin
    Weight := 0;
    GradientX := 0;
    GradientY := 0;
    Exit;
  end;

  WeightY := FHeight - 1 - Y;
  Index := NativeInt(WeightY) * FWidth + X;
  Weight := FWeights[Index];
  if X > 0 then
    LeftWeight := FWeights[Index - 1]
  else
    LeftWeight := 0;
  if X < FWidth - 1 then
    RightWeight := FWeights[Index + 1]
  else
    RightWeight := 0;
  // Internal rows use a bottom origin; public gradients use screen Y.
  if WeightY < FHeight - 1 then
    TopWeight := FWeights[Index + FWidth]
  else
    TopWeight := 0;
  if WeightY > 0 then
    BottomWeight := FWeights[Index - FWidth]
  else
    BottomWeight := 0;
  GradientX := (RightWeight - LeftWeight) * 0.5;
  GradientY := (BottomWeight - TopWeight) * 0.5;
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
  NormalizedX: Double;
  NormalizedY: Double;
  OuterPolygon: TArray<TPointF>;
  AffectedBottom: Integer;
  AffectedLeft: Integer;
  AffectedRight: Integer;
  AffectedTop: Integer;
  ScreenY: Integer;
{$IFDEF DEBUG}
  AffectedCount: NativeInt;
  StartedAt: UInt64;
{$ENDIF}
  X: Integer;
  Y: Integer;
  Weight: Double;
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
  AffectedLeft := Width;
  AffectedTop := Height;
  AffectedRight := -1;
  AffectedBottom := -1;
{$IFDEF DEBUG}
  StartedAt := GetTickCount64;
  DebugLogCurveCoordinates('outer', OuterContour, OuterPolygon,
    Width, Height);
  DebugLogCurveCoordinates('center', CenterContour, CenterPolygon,
    Width, Height);
  AffectedCount := 0;
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
    begin
      Weight := InterpolatedMask(Mask, GridWidth, GridHeight, X, Y);
      if Weight > 0 then
      begin
        NormalizedX := X / Max(1, FWidth - 1);
        NormalizedY := 1 - Y / Max(1, FHeight - 1);
        if not PointInPolygon(OuterPolygon, NormalizedX, NormalizedY) then
          Weight := 0;
      end;
      FWeights[Y * FWidth + X] := Weight;
      if Weight > 0 then
      begin
        ScreenY := FHeight - 1 - Y;
        AffectedLeft := Min(AffectedLeft, X);
        AffectedTop := Min(AffectedTop, ScreenY);
        AffectedRight := Max(AffectedRight, X);
        AffectedBottom := Max(AffectedBottom, ScreenY);
{$IFDEF DEBUG}
        Inc(AffectedCount);
{$ENDIF}
      end;
    end;
  FActiveLeft := AffectedLeft;
  FActiveTop := AffectedTop;
  FActiveRight := AffectedRight;
  FActiveBottom := AffectedBottom;
{$IFDEF DEBUG}
  if AffectedCount > 0 then
    Shake_PPP_DebugLog.DebugLog(Format(
      'Deformation affected bounds: image=(%d,%d)-(%d,%d) pixels=%d coordinateSpace=image-dpi-independent.',
      [AffectedLeft, AffectedTop, AffectedRight, AffectedBottom,
       AffectedCount]))
  else
    Shake_PPP_DebugLog.DebugLog(
      'Deformation affected bounds: empty coordinateSpace=image-dpi-independent.');
  Shake_PPP_DebugLog.DebugLog(Format(
    'Deformation map built: size=%dx%d grid=%dx%d elapsed=%dms.',
    [FWidth, FHeight, GridWidth, GridHeight,
     GetTickCount64 - StartedAt]));
{$ENDIF}
  Result := True;
end;

procedure TShakeDeformationMap.CopyScreenWeightsToSingles(
  out Buffer: TArray<Single>);
var
  DestinationIndex: NativeInt;
  SourceIndex: NativeInt;
  X: Integer;
  Y: Integer;
begin
  if (FWidth <= 0) or (FHeight <= 0) or
    (Length(FWeights) <> FWidth * FHeight) then
  begin
    Buffer := nil;
    Exit;
  end;
  SetLength(Buffer, NativeInt(FWidth) * FHeight);
  for Y := 0 to FHeight - 1 do
  begin
    SourceIndex := NativeInt(FHeight - 1 - Y) * FWidth;
    DestinationIndex := NativeInt(Y) * FWidth;
    for X := 0 to FWidth - 1 do
      Buffer[DestinationIndex + X] := FWeights[SourceIndex + X];
  end;
end;

function TShakeDeformationMap.Apply(Source,
  Destination: Vcl.Graphics.TBitmap;
  DisplacementX, DisplacementY: Double;
  out ErrorText: string): Boolean;
var
  BlendWeight: Double;
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
  WeightY: Integer;
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
{$IFDEF DEBUG}
  StartedAt := GetTickCount64;
{$ENDIF}
  for Y := 0 to Source.Height - 1 do
  begin
    SourceRows[Y] := Source.ScanLine[Y];
    DestinationRows[Y] := Destination.ScanLine[Y];
    Move(SourceRows[Y]^, DestinationRows[Y]^, NativeInt(Source.Width) * 4);
  end;
  for Y := FActiveTop to FActiveBottom do
  begin
    DestinationRow := PByteRow(DestinationRows[Y]);
    // Use the same top-origin curve coordinate space as the AviUtl2 output.
    WeightY := FHeight - 1 - Y;
    for X := FActiveLeft to FActiveRight do
    begin
      Weight := FWeights[WeightY * FWidth + X];
      BlendWeight := Weight * Weight;
      SourceX := EnsureRange(X - DisplacementX * Weight,
        0.0, Source.Width - 1.0);
      SourceY := EnsureRange(Y - DisplacementY * Weight,
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
        Value := PByteRow(SourceRows[Y])^[X * 4 + Channel] *
          (1 - BlendWeight) + Value * BlendWeight;
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
  BlendWeight: Double;
  Channel: Integer;
  FX: Double;
  FY: Double;
  PixelOffset00: NativeInt;
  PixelOffset01: NativeInt;
  PixelOffset10: NativeInt;
  PixelOffset11: NativeInt;
  SourceBytes: PRgbaBytes;
  DestinationBytes: PRgbaBytes;
  ByteCount: NativeInt;
  SourceX: Double;
  SourceY: Double;
  Value: Double;
  Weight: Double;
  WeightY: Integer;
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
  ByteCount := NativeInt(FWidth) * FHeight * 4;
  Move(SourceBytes^, DestinationBytes^, ByteCount);
  for Y := FActiveTop to FActiveBottom do
  begin
    // AviUtl2 RGBA rows are top-to-bottom, while FWeights follows the
    // bottom-to-top TBitmap scanline order used by the settings preview.
    WeightY := FHeight - 1 - Y;
    for X := FActiveLeft to FActiveRight do
    begin
      Weight := FWeights[WeightY * FWidth + X];
      BlendWeight := Weight * Weight;
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
        Value := SourceBytes^[(NativeInt(Y) * FWidth + X) * 4 + Channel] *
          (1 - BlendWeight) + Value * BlendWeight;
        DestinationBytes^[(NativeInt(Y) * FWidth + X) * 4 + Channel] :=
          EnsureRange(Round(Value), 0, 255);
      end;
    end;
  end;
  Result := True;
end;

function TShakeDeformationMap.ApplyVariableOuterRgba(Source,
  Destination: Pointer; DisplacementX, DisplacementY: Double;
  out ErrorText: string): Boolean;
type
  PRgbaBytes = ^TRgbaBytes;
  TRgbaBytes = array[0..268435455] of Byte;
var
  AffectedBottom: Integer;
  AffectedLeft: Integer;
  AffectedRight: Integer;
  AffectedTop: Integer;
  BaseX: Double;
  BaseY: Double;
  ByteCount: NativeInt;
  Channel: Integer;
  Coverage: Double;
  DestinationBytes: PRgbaBytes;
  DestinationOffset: NativeInt;
  FX: Double;
  FY: Double;
  InnerMotionRatio: Double;
  PixelOffset00: NativeInt;
  PixelOffset01: NativeInt;
  PixelOffset10: NativeInt;
  PixelOffset11: NativeInt;
  SampleX: Double;
  SampleY: Double;
  ShiftX: Double;
  ShiftY: Double;
  SourceBytes: PRgbaBytes;
  Value: Double;
  Weight: Double;
  WeightX0: Integer;
  WeightX1: Integer;
  WeightY0: Integer;
  WeightY1: Integer;
  X: Integer;
  X0: Integer;
  X1: Integer;
  Y: Integer;
  Y0: Integer;
  Y1: Integer;

  function MapWeight(ScreenX, ScreenY: Integer): Double;
  begin
    if (ScreenX < 0) or (ScreenX >= FWidth) or
      (ScreenY < 0) or (ScreenY >= FHeight) then
      Exit(0);
    Result := FWeights[(FHeight - 1 - ScreenY) * FWidth + ScreenX];
  end;

  function SampleMap(MapX, MapY: Double; CoverageOnly: Boolean): Double;
  var
    W00: Double;
    W01: Double;
    W10: Double;
    W11: Double;
  begin
    if (MapX < 0) or (MapX > FWidth - 1) or
      (MapY < 0) or (MapY > FHeight - 1) then
      Exit(0);
    WeightX0 := Trunc(MapX);
    WeightY0 := Trunc(MapY);
    WeightX1 := Min(WeightX0 + 1, FWidth - 1);
    WeightY1 := Min(WeightY0 + 1, FHeight - 1);
    FX := MapX - WeightX0;
    FY := MapY - WeightY0;
    W00 := MapWeight(WeightX0, WeightY0);
    W01 := MapWeight(WeightX1, WeightY0);
    W10 := MapWeight(WeightX0, WeightY1);
    W11 := MapWeight(WeightX1, WeightY1);
    if CoverageOnly then
    begin
      W00 := Ord(W00 > 0);
      W01 := Ord(W01 > 0);
      W10 := Ord(W10 > 0);
      W11 := Ord(W11 > 0);
    end;
    Result := (W00 * (1 - FX) + W01 * FX) * (1 - FY) +
      (W10 * (1 - FX) + W11 * FX) * FY;
  end;

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
  ByteCount := NativeInt(FWidth) * FHeight * 4;
  Move(SourceBytes^, DestinationBytes^, ByteCount);
  if (FActiveRight < FActiveLeft) or (FActiveBottom < FActiveTop) then
  begin
    Result := True;
    Exit;
  end;

  ShiftX := DisplacementX * VARIABLE_OUTER_MOTION_RATIO;
  ShiftY := DisplacementY * VARIABLE_OUTER_MOTION_RATIO;
  InnerMotionRatio := 1 - VARIABLE_OUTER_MOTION_RATIO;
  AffectedLeft := EnsureRange(FActiveLeft + Floor(Min(0.0, ShiftX)),
    0, FWidth - 1);
  AffectedTop := EnsureRange(FActiveTop + Floor(Min(0.0, ShiftY)),
    0, FHeight - 1);
  AffectedRight := EnsureRange(FActiveRight + Ceil(Max(0.0, ShiftX)),
    0, FWidth - 1);
  AffectedBottom := EnsureRange(FActiveBottom + Ceil(Max(0.0, ShiftY)),
    0, FHeight - 1);

  // Evaluate the mask in a coordinate system translated by the outer-edge
  // motion. The remaining displacement grows smoothly toward the center.
  for Y := AffectedTop to AffectedBottom do
    for X := AffectedLeft to AffectedRight do
    begin
      BaseX := X - ShiftX;
      BaseY := Y - ShiftY;
      Weight := SampleMap(BaseX, BaseY, False);
      Coverage := Max(SampleMap(X, Y, True),
        SampleMap(BaseX, BaseY, True));
      if Coverage <= 0 then
        Continue;

      SampleX := EnsureRange(BaseX - DisplacementX *
        InnerMotionRatio * Weight, 0.0, FWidth - 1.0);
      SampleY := EnsureRange(BaseY - DisplacementY *
        InnerMotionRatio * Weight, 0.0, FHeight - 1.0);
      X0 := Trunc(SampleX);
      Y0 := Trunc(SampleY);
      X1 := Min(X0 + 1, FWidth - 1);
      Y1 := Min(Y0 + 1, FHeight - 1);
      FX := SampleX - X0;
      FY := SampleY - Y0;
      PixelOffset00 := (NativeInt(Y0) * FWidth + X0) * 4;
      PixelOffset01 := (NativeInt(Y0) * FWidth + X1) * 4;
      PixelOffset10 := (NativeInt(Y1) * FWidth + X0) * 4;
      PixelOffset11 := (NativeInt(Y1) * FWidth + X1) * 4;
      DestinationOffset := (NativeInt(Y) * FWidth + X) * 4;
      for Channel := 0 to 3 do
      begin
        Value := (SourceBytes^[PixelOffset00 + Channel] * (1 - FX) +
          SourceBytes^[PixelOffset01 + Channel] * FX) * (1 - FY) +
          (SourceBytes^[PixelOffset10 + Channel] * (1 - FX) +
          SourceBytes^[PixelOffset11 + Channel] * FX) * FY;
        Value := SourceBytes^[DestinationOffset + Channel] * (1 - Coverage) +
          Value * Coverage;
        DestinationBytes^[DestinationOffset + Channel] :=
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
