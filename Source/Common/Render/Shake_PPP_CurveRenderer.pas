unit Shake_PPP_CurveRenderer;

interface

uses
  System.Types,
  Vcl.Graphics,
  Shake_PPP_CurveModel;

type
  TShakeCurveRenderer = class sealed
  strict private
    class procedure ControlPoints(Curve: TShakeCurve; SegmentIndex: Integer;
      out Point0, Control1, Control2, Point3: TPointF); static;
    class procedure FillClosedCurve(Canvas: TCanvas; BufferWidth,
      BufferHeight: Integer; const Destination: TRect; Curve: TShakeCurve;
      CurveKind: TShakeCurveKind; IsActive: Boolean); static;
  public
    class procedure Draw(Canvas: TCanvas; BufferWidth, BufferHeight: Integer;
      const Destination: TRect; Curve: TShakeCurve;
      CurveKind: TShakeCurveKind; IsActive: Boolean;
      SelectedVertex, PPI: Integer); static;
    class function HitTestClosingSegment(const Destination: TRect;
      Curve: TShakeCurve; X, Y, PPI: Integer): Boolean; static;
    class function HitTestSegment(const Destination: TRect;
      Curve: TShakeCurve; X, Y, PPI: Integer): Integer; static;
    class function HitTestVertex(const Destination: TRect; Curve: TShakeCurve;
      X, Y, PPI: Integer): Integer; static;
    class function ToCanvas(const Destination: TRect;
      const Position: TPointF): TPoint; static;
  end;

implementation

uses
  System.Math,
  System.UITypes,
  Winapi.Windows;

class procedure TShakeCurveRenderer.ControlPoints(Curve: TShakeCurve;
  SegmentIndex: Integer; out Point0, Control1, Control2, Point3: TPointF);
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
    else if Curve.Closed then
      PreviousPosition := Curve[Curve.Count - 1].Position
    else
      PreviousPosition := Point0;
    Control1.X := Point0.X + (Point3.X - PreviousPosition.X) / 6;
    Control1.Y := Point0.Y + (Point3.Y - PreviousPosition.Y) / 6;
  end;
  if B.Kind = svkSmooth then
  begin
    if BIndex + 1 < Curve.Count then
      NextPosition := Curve[BIndex + 1].Position
    else if Curve.Closed then
      NextPosition := Curve[0].Position
    else
      NextPosition := Point3;
    Control2.X := Point3.X - (NextPosition.X - Point0.X) / 6;
    Control2.Y := Point3.Y - (NextPosition.Y - Point0.Y) / 6;
  end;
end;

class procedure TShakeCurveRenderer.Draw(Canvas: TCanvas; BufferWidth,
  BufferHeight: Integer; const Destination: TRect; Curve: TShakeCurve;
  CurveKind: TShakeCurveKind; IsActive: Boolean;
  SelectedVertex, PPI: Integer);
var
  BaseColor: TColor;
  Control1: TPointF;
  Control2: TPointF;
  I: Integer;
  Point0: TPointF;
  Point3: TPointF;
  Points: array[0..3] of TPoint;
  SegmentCount: Integer;
  StartRadius: Integer;
  VertexPoint: TPoint;
  VertexRadius: Integer;
  VertexRect: TRect;
begin
  FillClosedCurve(Canvas, BufferWidth, BufferHeight, Destination, Curve,
    CurveKind, IsActive);
  if CurveKind = sckOuterContour then
  begin
    if IsActive then
      BaseColor := RGB(48, 210, 255)
    else
      BaseColor := RGB(35, 165, 195);
  end
  else
  begin
    if IsActive then
      BaseColor := RGB(255, 176, 48)
    else
      BaseColor := RGB(200, 132, 38);
  end;
  Canvas.Pen.Style := psSolid;
  if IsActive then
    Canvas.Pen.Width := Max(2, MulDiv(2, PPI, 96))
  else
    Canvas.Pen.Width := Max(1, MulDiv(2, PPI, 96));
  Canvas.Brush.Style := bsClear;
  SegmentCount := Curve.Count - 1;
  if Curve.Closed and (Curve.Count >= 3) then
    Inc(SegmentCount);
  for I := 0 to SegmentCount - 1 do
  begin
    if Curve.Closed and (I = Curve.Count - 1) then
    begin
      if IsActive then
        Canvas.Pen.Color := RGB(255, 55, 205)
      else
        Canvas.Pen.Color := RGB(190, 50, 150);
      if IsActive then
        Canvas.Pen.Width := Max(2, MulDiv(2, PPI, 96))
      else
        Canvas.Pen.Width := Max(1, MulDiv(2, PPI, 96));
    end
    else
    begin
      Canvas.Pen.Color := BaseColor;
      if IsActive then
        Canvas.Pen.Width := Max(2, MulDiv(2, PPI, 96))
      else
        Canvas.Pen.Width := Max(1, MulDiv(2, PPI, 96));
    end;
    ControlPoints(Curve, I, Point0, Control1, Control2, Point3);
    Points[0] := ToCanvas(Destination, Point0);
    Points[1] := ToCanvas(Destination, Control1);
    Points[2] := ToCanvas(Destination, Control2);
    Points[3] := ToCanvas(Destination, Point3);
    PolyBezier(Canvas.Handle, Points[0], Length(Points));
  end;
  if not IsActive then
    Exit;
  Canvas.Pen.Color := BaseColor;
  Canvas.Pen.Width := Max(1, MulDiv(2, PPI, 96));
  VertexRadius := Max(4, MulDiv(5, PPI, 96));
  StartRadius := Max(7, MulDiv(9, PPI, 96));
  for I := 0 to Curve.Count - 1 do
  begin
    VertexPoint := ToCanvas(Destination, Curve[I].Position);
    if I = 0 then
    begin
      VertexRect := Rect(VertexPoint.X - StartRadius,
        VertexPoint.Y - StartRadius, VertexPoint.X + StartRadius + 1,
        VertexPoint.Y + StartRadius + 1);
      if Curve.Closed then
        Canvas.Brush.Style := bsClear
      else
      begin
        Canvas.Brush.Style := bsSolid;
        Canvas.Brush.Color := RGB(80, 255, 120);
      end;
      if I = SelectedVertex then
        Canvas.Pen.Color := clYellow
      else
        Canvas.Pen.Color := RGB(80, 255, 120);
      Canvas.Rectangle(VertexRect);
      if Curve.Closed then
      begin
        InflateRect(VertexRect, -3, -3);
        Canvas.Brush.Style := bsClear;
        Canvas.Pen.Color := RGB(185, 255, 200);
        Canvas.Rectangle(VertexRect);
      end;
      Continue;
    end;
    VertexRect := Rect(VertexPoint.X - VertexRadius,
      VertexPoint.Y - VertexRadius, VertexPoint.X + VertexRadius + 1,
      VertexPoint.Y + VertexRadius + 1);
    Canvas.Pen.Color := BaseColor;
    if I = SelectedVertex then
      Canvas.Brush.Color := clYellow
    else
      Canvas.Brush.Color := BaseColor;
    Canvas.Brush.Style := bsSolid;
    if Curve[I].Kind = svkCorner then
      Canvas.Polygon([Point(VertexPoint.X, VertexRect.Top),
        Point(VertexRect.Right, VertexPoint.Y),
        Point(VertexPoint.X, VertexRect.Bottom),
        Point(VertexRect.Left, VertexPoint.Y)])
    else
      Canvas.Ellipse(VertexRect);
  end;
  Canvas.Brush.Style := bsClear;
end;

class procedure TShakeCurveRenderer.FillClosedCurve(Canvas: TCanvas;
  BufferWidth, BufferHeight: Integer; const Destination: TRect;
  Curve: TShakeCurve; CurveKind: TShakeCurveKind; IsActive: Boolean);
const
  SAMPLES_PER_SEGMENT = 12;
var
  Blend: BLENDFUNCTION;
  Control1: TPointF;
  Control2: TPointF;
  FillBitmap: Vcl.Graphics.TBitmap;
  I: Integer;
  OneMinusT: Double;
  Point0: TPointF;
  Point3: TPointF;
  Points: TArray<TPoint>;
  Region: HRGN;
  SampleIndex: Integer;
  T: Double;
  X: Double;
  Y: Double;
begin
  if not Curve.Closed or (Curve.Count < 3) then
    Exit;
  SetLength(Points, Curve.Count * SAMPLES_PER_SEGMENT);
  for I := 0 to Curve.Count - 1 do
  begin
    ControlPoints(Curve, I, Point0, Control1, Control2, Point3);
    for SampleIndex := 0 to SAMPLES_PER_SEGMENT - 1 do
    begin
      T := SampleIndex / SAMPLES_PER_SEGMENT;
      OneMinusT := 1 - T;
      X := Sqr(OneMinusT) * OneMinusT * Point0.X +
        3 * Sqr(OneMinusT) * T * Control1.X +
        3 * OneMinusT * Sqr(T) * Control2.X + Sqr(T) * T * Point3.X;
      Y := Sqr(OneMinusT) * OneMinusT * Point0.Y +
        3 * Sqr(OneMinusT) * T * Control1.Y +
        3 * OneMinusT * Sqr(T) * Control2.Y + Sqr(T) * T * Point3.Y;
      Points[I * SAMPLES_PER_SEGMENT + SampleIndex] :=
        ToCanvas(Destination, PointF(X, Y));
    end;
  end;
  Region := CreatePolygonRgn(Points[0], Length(Points), WINDING);
  if Region = 0 then
    Exit;
  FillBitmap := Vcl.Graphics.TBitmap.Create;
  try
    FillBitmap.PixelFormat := pf32bit;
    FillBitmap.SetSize(1, 1);
    if CurveKind = sckOuterContour then
      FillBitmap.Canvas.Pixels[0, 0] := RGB(30, 180, 220)
    else
      FillBitmap.Canvas.Pixels[0, 0] := RGB(230, 135, 25);
    Blend.BlendOp := AC_SRC_OVER;
    Blend.BlendFlags := 0;
    if IsActive then
      Blend.SourceConstantAlpha := 52
    else
      Blend.SourceConstantAlpha := 38;
    Blend.AlphaFormat := 0;
    SelectClipRgn(Canvas.Handle, Region);
    try
      Winapi.Windows.AlphaBlend(Canvas.Handle, 0, 0,
        BufferWidth, BufferHeight, FillBitmap.Canvas.Handle, 0, 0, 1, 1,
        Blend);
    finally
      SelectClipRgn(Canvas.Handle, 0);
    end;
  finally
    FillBitmap.Free;
    DeleteObject(Region);
  end;
end;

class function TShakeCurveRenderer.HitTestClosingSegment(
  const Destination: TRect; Curve: TShakeCurve;
  X, Y, PPI: Integer): Boolean;
const
  SAMPLE_COUNT = 32;
var
  ClosestX: Double;
  ClosestY: Double;
  Control1: TPointF;
  Control2: TPointF;
  CurrentPoint: TPoint;
  DistanceSquared: Double;
  I: Integer;
  LengthSquared: Double;
  OneMinusT: Double;
  Point0: TPointF;
  Point3: TPointF;
  PreviousPoint: TPoint;
  Projection: Double;
  Radius: Integer;
  T: Double;
  VectorX: Double;
  VectorY: Double;
  XValue: Double;
  YValue: Double;
begin
  Result := False;
  if not Curve.Closed or (Curve.Count < 3) then
    Exit;
  ControlPoints(Curve, Curve.Count - 1,
    Point0, Control1, Control2, Point3);
  PreviousPoint := ToCanvas(Destination, Point0);
  Radius := Max(6, MulDiv(8, PPI, 96));
  for I := 1 to SAMPLE_COUNT do
  begin
    T := I / SAMPLE_COUNT;
    OneMinusT := 1 - T;
    XValue := Sqr(OneMinusT) * OneMinusT * Point0.X +
      3 * Sqr(OneMinusT) * T * Control1.X +
      3 * OneMinusT * Sqr(T) * Control2.X + Sqr(T) * T * Point3.X;
    YValue := Sqr(OneMinusT) * OneMinusT * Point0.Y +
      3 * Sqr(OneMinusT) * T * Control1.Y +
      3 * OneMinusT * Sqr(T) * Control2.Y + Sqr(T) * T * Point3.Y;
    CurrentPoint := ToCanvas(Destination, PointF(XValue, YValue));
    VectorX := CurrentPoint.X - PreviousPoint.X;
    VectorY := CurrentPoint.Y - PreviousPoint.Y;
    LengthSquared := VectorX * VectorX + VectorY * VectorY;
    if LengthSquared > 0 then
      Projection := EnsureRange(((X - PreviousPoint.X) * VectorX +
        (Y - PreviousPoint.Y) * VectorY) / LengthSquared, 0.0, 1.0)
    else
      Projection := 0;
    ClosestX := PreviousPoint.X + Projection * VectorX;
    ClosestY := PreviousPoint.Y + Projection * VectorY;
    DistanceSquared := Sqr(X - ClosestX) + Sqr(Y - ClosestY);
    if DistanceSquared <= Radius * Radius then
      Exit(True);
    PreviousPoint := CurrentPoint;
  end;
end;

class function TShakeCurveRenderer.HitTestSegment(const Destination: TRect;
  Curve: TShakeCurve; X, Y, PPI: Integer): Integer;
const
  SAMPLE_COUNT = 32;
var
  ClosestX: Double;
  ClosestY: Double;
  Control1: TPointF;
  Control2: TPointF;
  CurrentPoint: TPoint;
  DistanceSquared: Double;
  I: Integer;
  J: Integer;
  LengthSquared: Double;
  OneMinusT: Double;
  Point0: TPointF;
  Point3: TPointF;
  PreviousPoint: TPoint;
  Projection: Double;
  Radius: Integer;
  SegmentCount: Integer;
  T: Double;
  VectorX: Double;
  VectorY: Double;
  XValue: Double;
  YValue: Double;
begin
  Result := -1;
  if Curve.Count < 2 then
    Exit;
  SegmentCount := Curve.Count - 1;
  if Curve.Closed and (Curve.Count >= 3) then
    Inc(SegmentCount);
  Radius := Max(6, MulDiv(8, PPI, 96));
  for I := 0 to SegmentCount - 1 do
  begin
    ControlPoints(Curve, I, Point0, Control1, Control2, Point3);
    PreviousPoint := ToCanvas(Destination, Point0);
    for J := 1 to SAMPLE_COUNT do
    begin
      T := J / SAMPLE_COUNT;
      OneMinusT := 1 - T;
      XValue := Sqr(OneMinusT) * OneMinusT * Point0.X +
        3 * Sqr(OneMinusT) * T * Control1.X +
        3 * OneMinusT * Sqr(T) * Control2.X + Sqr(T) * T * Point3.X;
      YValue := Sqr(OneMinusT) * OneMinusT * Point0.Y +
        3 * Sqr(OneMinusT) * T * Control1.Y +
        3 * OneMinusT * Sqr(T) * Control2.Y + Sqr(T) * T * Point3.Y;
      CurrentPoint := ToCanvas(Destination, PointF(XValue, YValue));
      VectorX := CurrentPoint.X - PreviousPoint.X;
      VectorY := CurrentPoint.Y - PreviousPoint.Y;
      LengthSquared := VectorX * VectorX + VectorY * VectorY;
      if LengthSquared > 0 then
        Projection := EnsureRange(((X - PreviousPoint.X) * VectorX +
          (Y - PreviousPoint.Y) * VectorY) / LengthSquared, 0.0, 1.0)
      else
        Projection := 0;
      ClosestX := PreviousPoint.X + Projection * VectorX;
      ClosestY := PreviousPoint.Y + Projection * VectorY;
      DistanceSquared := Sqr(X - ClosestX) + Sqr(Y - ClosestY);
      if DistanceSquared <= Radius * Radius then
        Exit(I);
      PreviousPoint := CurrentPoint;
    end;
  end;
end;

class function TShakeCurveRenderer.HitTestVertex(const Destination: TRect;
  Curve: TShakeCurve; X, Y, PPI: Integer): Integer;
var
  DeltaX: Integer;
  DeltaY: Integer;
  I: Integer;
  Radius: Integer;
  VertexPoint: TPoint;
begin
  Result := -1;
  Radius := Max(7, MulDiv(9, PPI, 96));
  for I := Curve.Count - 1 downto 0 do
  begin
    VertexPoint := ToCanvas(Destination, Curve[I].Position);
    DeltaX := X - VertexPoint.X;
    DeltaY := Y - VertexPoint.Y;
    if DeltaX * DeltaX + DeltaY * DeltaY <= Radius * Radius then
      Exit(I);
  end;
end;

class function TShakeCurveRenderer.ToCanvas(const Destination: TRect;
  const Position: TPointF): TPoint;
begin
  Result.X := Destination.Left + Round(Position.X * Destination.Width);
  Result.Y := Destination.Top + Round(Position.Y * Destination.Height);
end;

end.
