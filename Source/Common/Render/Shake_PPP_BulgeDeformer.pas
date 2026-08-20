unit Shake_PPP_BulgeDeformer;

interface

uses
  Vcl.Graphics,
  Shake_PPP_CurveModel,
  Shake_PPP_StaticDeformer;

type
  TBulgeDeformationMap = class sealed
  private
    FBaseCenterX: Double;
    FBaseCenterY: Double;
    FOuterHalfHeight: Double;
    FOuterHalfWidth: Double;
    FWeightMap: TShakeDeformationMap;
    function GetHeight: Integer;
    function GetWidth: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function Build(Width, Height: Integer; OuterContour,
      CenterContour: TShakeCurve; out ErrorText: string): Boolean;
    function Apply(Source, Destination: TBitmap; Amount, Shape,
      CenterOffsetX, CenterOffsetY, Gravity, GravityDirection, Mass,
      Tension, OpacityResponse, ShadingStrength, LightDirection: Double;
      HighlightStrength: Double;
      out ErrorText: string): Boolean;
    property Height: Integer read GetHeight;
    property Width: Integer read GetWidth;
  end;

  TBulgeDeformer = class sealed
  public
    class function ApplyRgba(WeightMap: TShakeDeformationMap;
      OuterContour, CenterContour: TShakeCurve; Source, Destination: Pointer;
      Amount, Shape, CenterOffsetX, CenterOffsetY, Gravity,
      GravityDirection, Mass, Tension, OpacityResponse, ShadingStrength,
      LightDirection, HighlightStrength: Double;
      out ErrorText: string): Boolean; static;
  end;

implementation

uses
  System.Math,
  System.SysUtils;

type
  TBitmapRows = array of PByte;
  PByteRow = ^TByteRow;
  TByteRow = array[0..268435455] of Byte;
  PRgbaBytes = ^TRgbaBytes;
  TRgbaBytes = array[0..268435455] of Byte;

const
  DISTRIBUTION_LOOKUP_MAX = 2048;

type
  TDistributionLookup = array[0..DISTRIBUTION_LOOKUP_MAX] of Double;

procedure CalculateGeometry(Width, Height: Integer; OuterContour,
  CenterContour: TShakeCurve; out BaseCenterX, BaseCenterY,
  OuterHalfWidth, OuterHalfHeight: Double);
var
  CenterX: Double;
  CenterY: Double;
  I: Integer;
  MaximumX: Double;
  MaximumY: Double;
  MinimumX: Double;
  MinimumY: Double;
begin
  CenterX := 0;
  CenterY := 0;
  for I := 0 to CenterContour.Count - 1 do
  begin
    CenterX := CenterX + CenterContour[I].Position.X;
    CenterY := CenterY + CenterContour[I].Position.Y;
  end;
  BaseCenterX := CenterX / CenterContour.Count * Max(1, Width - 1);
  BaseCenterY := CenterY / CenterContour.Count * Max(1, Height - 1);

  MinimumX := 1;
  MinimumY := 1;
  MaximumX := 0;
  MaximumY := 0;
  for I := 0 to OuterContour.Count - 1 do
  begin
    MinimumX := Min(MinimumX, OuterContour[I].Position.X);
    MinimumY := Min(MinimumY, OuterContour[I].Position.Y);
    MaximumX := Max(MaximumX, OuterContour[I].Position.X);
    MaximumY := Max(MaximumY, OuterContour[I].Position.Y);
  end;
  OuterHalfWidth := (MaximumX - MinimumX) * Max(1, Width - 1) * 0.5;
  OuterHalfHeight := (MaximumY - MinimumY) * Max(1, Height - 1) * 0.5;
end;

procedure BuildDistributionLookup(Shape: Double;
  out Lookup: TDistributionLookup);
var
  Exponent: Double;
  I: Integer;
begin
  Shape := EnsureRange(Shape, 0.0, 1.0);
  // 0% concentrates deformation near the center, 50% keeps the original
  // weight, and 100% spreads deformation toward the fixed outer boundary.
  Exponent := Power(2.0, (0.5 - Shape) * 2.0);
  for I := 0 to DISTRIBUTION_LOOKUP_MAX do
    Lookup[I] := Power(I / DISTRIBUTION_LOOKUP_MAX, Exponent);
end;

function DistributionWeight(const Lookup: TDistributionLookup;
  Weight: Double): Double;
var
  Fraction: Double;
  Index0: Integer;
  Index1: Integer;
  ScaledIndex: Double;
begin
  ScaledIndex := EnsureRange(Weight, 0.0, 1.0) * DISTRIBUTION_LOOKUP_MAX;
  Index0 := Trunc(ScaledIndex);
  Index1 := Min(Index0 + 1, DISTRIBUTION_LOOKUP_MAX);
  Fraction := ScaledIndex - Index0;
  Result := Lookup[Index0] * (1 - Fraction) + Lookup[Index1] * Fraction;
end;

function DistributionSlope(const Lookup: TDistributionLookup;
  Weight: Double): Double;
var
  Index0: Integer;
  Index1: Integer;
  ScaledIndex: Double;
begin
  ScaledIndex := EnsureRange(Weight, 0.0, 1.0) *
    DISTRIBUTION_LOOKUP_MAX;
  Index0 := Trunc(ScaledIndex);
  Index1 := Min(Index0 + 1, DISTRIBUTION_LOOKUP_MAX);
  Result := (Lookup[Index1] - Lookup[Index0]) *
    DISTRIBUTION_LOOKUP_MAX;
end;

procedure CalculateGravityParameters(Gravity, GravityDirection, Mass,
  Tension: Double; out GravityResponse, DirectionX, DirectionY: Double);
begin
  Gravity := EnsureRange(Gravity, 0.0, 1.0);
  Mass := EnsureRange(Mass, 0.0, 1.0);
  Tension := EnsureRange(Tension, 0.0, 1.0);
  // 50% mass and 50% tension preserve the original gravity response.
  // Greater mass increases sag; greater tension resists it.
  GravityResponse := EnsureRange(Gravity * (0.5 + Mass) *
    (1.5 - Tension), 0.0, 2.0);
  DirectionX := Cos(DegToRad(GravityDirection));
  DirectionY := Sin(DegToRad(GravityDirection));
end;

procedure ApplyGravityToSample(X, Y: Integer; CenterX, CenterY,
  OuterHalfWidth, OuterHalfHeight, Amount, GravityResponse, DirectionX,
  DirectionY: Double; var Weight: Double; out SagX, SagY: Double);
var
  Projection: Double;
  SagAmount: Double;
begin
  if SameValue(GravityResponse, 0.0, 0.000001) or
    SameValue(Amount, 1.0, 0.000001) then
  begin
    SagX := 0;
    SagY := 0;
    Exit;
  end;

  Projection := (X - CenterX) / Max(1.0, OuterHalfWidth) * DirectionX +
    (Y - CenterY) / Max(1.0, OuterHalfHeight) * DirectionY;
  Projection := EnsureRange(Projection, -1.0, 1.0);

  // The direction-facing side expands more while the opposite side is held
  // back.  Weight remains zero at the contour, so the boundary stays fixed.
  Weight := EnsureRange(Weight *
    (1 + GravityResponse * Projection * 0.75),
    0.0, 1.0);
  SagAmount := Min(OuterHalfWidth, OuterHalfHeight) * 0.35 *
    GravityResponse * Abs(Amount - 1) * Weight;
  SagX := DirectionX * SagAmount;
  SagY := DirectionY * SagAmount;
end;

procedure CalculateLightParameters(LightDirection: Double;
  out LightX, LightY, LightZ, HalfX, HalfY, HalfZ: Double);
const
  INV_SQRT_2 = 0.7071067811865475;
var
  HalfLength: Double;
begin
  LightX := Cos(DegToRad(LightDirection)) * INV_SQRT_2;
  LightY := Sin(DegToRad(LightDirection)) * INV_SQRT_2;
  LightZ := INV_SQRT_2;
  HalfX := LightX;
  HalfY := LightY;
  HalfZ := LightZ + 1;
  HalfLength := Sqrt(HalfX * HalfX + HalfY * HalfY + HalfZ * HalfZ);
  HalfX := HalfX / HalfLength;
  HalfY := HalfY / HalfLength;
  HalfZ := HalfZ / HalfLength;
end;

procedure LightingAt(WeightMap: TShakeDeformationMap; X, Y: Integer;
  const DistributionLookup: TDistributionLookup;
  UseShapedDistribution: Boolean; CenterX, CenterY, OuterHalfWidth,
  OuterHalfHeight, Amount, GravityResponse, GravityDirectionX,
  GravityDirectionY, CurrentWeight, ShadingStrength, HighlightStrength,
  LightX, LightY, LightZ, HalfX, HalfY, HalfZ: Double;
  out ShadeFactor, HighlightFactor: Double);
var
  GradientX: Double;
  GradientY: Double;
  GravityFactor: Double;
  GravityGradientX: Double;
  GravityGradientY: Double;
  HeightScale: Double;
  NormalLength: Double;
  NormalX: Double;
  NormalY: Double;
  NormalZ: Double;
  Projection: Double;
  RawGradientX: Double;
  RawGradientY: Double;
  RawWeight: Double;
  ShapedWeight: Double;
  ShapeSlope: Double;
  Specular: Double;
begin
  HeightScale := (Amount - 1) * Min(OuterHalfWidth, OuterHalfHeight);
  WeightMap.WeightAndGradientAtScreen(X, Y, RawWeight, RawGradientX,
    RawGradientY);

  if UseShapedDistribution then
  begin
    ShapedWeight := DistributionWeight(DistributionLookup, RawWeight);
    ShapeSlope := DistributionSlope(DistributionLookup, RawWeight);
    GradientX := RawGradientX * ShapeSlope;
    GradientY := RawGradientY * ShapeSlope;
  end
  else
  begin
    ShapedWeight := RawWeight;
    GradientX := RawGradientX;
    GradientY := RawGradientY;
  end;

  if not SameValue(GravityResponse, 0.0, 0.000001) and
    not SameValue(Amount, 1.0, 0.000001) then
  begin
    Projection := (X - CenterX) / Max(1.0, OuterHalfWidth) *
      GravityDirectionX + (Y - CenterY) / Max(1.0, OuterHalfHeight) *
      GravityDirectionY;
    if (Projection > -1.0) and (Projection < 1.0) then
    begin
      GravityGradientX := GravityResponse * 0.75 *
        GravityDirectionX / Max(1.0, OuterHalfWidth);
      GravityGradientY := GravityResponse * 0.75 *
        GravityDirectionY / Max(1.0, OuterHalfHeight);
    end
    else
    begin
      GravityGradientX := 0;
      GravityGradientY := 0;
    end;
    Projection := EnsureRange(Projection, -1.0, 1.0);
    GravityFactor := 1 + GravityResponse * Projection * 0.75;
    if (ShapedWeight * GravityFactor <= 0) or
      (ShapedWeight * GravityFactor >= 1) then
    begin
      GradientX := 0;
      GradientY := 0;
    end
    else
    begin
      GradientX := GradientX * GravityFactor +
        ShapedWeight * GravityGradientX;
      GradientY := GradientY * GravityFactor +
        ShapedWeight * GravityGradientY;
    end;
  end;
  GradientX := GradientX * HeightScale;
  GradientY := GradientY * HeightScale;
  NormalX := -GradientX;
  NormalY := -GradientY;
  NormalZ := 1;
  NormalLength := Sqrt(NormalX * NormalX + NormalY * NormalY + 1);
  NormalX := NormalX / NormalLength;
  NormalY := NormalY / NormalLength;
  NormalZ := NormalZ / NormalLength;
  ShadeFactor := EnsureRange(1 + ShadingStrength * 1.25 *
    (NormalX * LightX + NormalY * LightY + NormalZ * LightZ - LightZ),
    0.25, 1.75);
  Specular := EnsureRange(NormalX * HalfX + NormalY * HalfY +
    NormalZ * HalfZ, 0.0, 1.0);
  Specular := Specular * Specular;
  Specular := Specular * Specular;
  Specular := Specular * Specular;
  Specular := Specular * Specular;
  HighlightFactor := EnsureRange(HighlightStrength * CurrentWeight *
    Min(1.0, Abs(Amount - 1) * 2) * Specular, 0.0, 1.0);
end;

constructor TBulgeDeformationMap.Create;
begin
  inherited Create;
  FWeightMap := TShakeDeformationMap.Create;
end;

destructor TBulgeDeformationMap.Destroy;
begin
  FWeightMap.Free;
  inherited;
end;

procedure TBulgeDeformationMap.Clear;
begin
  FWeightMap.Clear;
  FBaseCenterX := 0;
  FBaseCenterY := 0;
  FOuterHalfWidth := 0;
  FOuterHalfHeight := 0;
end;

function TBulgeDeformationMap.GetHeight: Integer;
begin
  Result := FWeightMap.Height;
end;

function TBulgeDeformationMap.GetWidth: Integer;
begin
  Result := FWeightMap.Width;
end;

function TBulgeDeformationMap.Build(Width, Height: Integer; OuterContour,
  CenterContour: TShakeCurve; out ErrorText: string): Boolean;
begin
  Result := FWeightMap.Build(Width, Height, OuterContour, CenterContour,
    ErrorText);
  if not Result then
    Exit;

  CalculateGeometry(Width, Height, OuterContour, CenterContour,
    FBaseCenterX, FBaseCenterY, FOuterHalfWidth, FOuterHalfHeight);
end;

function TBulgeDeformationMap.Apply(Source, Destination: TBitmap;
  Amount, Shape, CenterOffsetX, CenterOffsetY, Gravity,
  GravityDirection, Mass, Tension, OpacityResponse, ShadingStrength,
  LightDirection, HighlightStrength: Double;
  out ErrorText: string): Boolean;
var
  CenterX: Double;
  CenterY: Double;
  Channel: Integer;
  DestinationRows: TBitmapRows;
  DestinationRow: PByteRow;
  DistributionLookup: TDistributionLookup;
  DirectionX: Double;
  DirectionY: Double;
  FX: Double;
  FY: Double;
  GravityResponse: Double;
  HalfX: Double;
  HalfY: Double;
  HalfZ: Double;
  HighlightFactor: Double;
  LightX: Double;
  LightY: Double;
  LightZ: Double;
  PixelOffset0: Integer;
  PixelOffset1: Integer;
  OpacityFactor: Double;
  Row0: PByteRow;
  Row1: PByteRow;
  SagX: Double;
  SagY: Double;
  Scale: Double;
  ShadeFactor: Double;
  SourceRows: TBitmapRows;
  SourceX: Double;
  SourceY: Double;
  Value: Double;
  Weight: Double;
  UseShapedDistribution: Boolean;
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
    (Source.Width <> FWeightMap.Width) or
    (Source.Height <> FWeightMap.Height) then
  begin
    ErrorText := 'MAP_NOT_READY';
    Exit;
  end;

  Amount := EnsureRange(Amount, 0.0, 2.0);
  Shape := EnsureRange(Shape, 0.0, 1.0);
  OpacityResponse := EnsureRange(OpacityResponse, 0.0, 1.0);
  ShadingStrength := EnsureRange(ShadingStrength, 0.0, 1.0);
  HighlightStrength := EnsureRange(HighlightStrength, 0.0, 1.0);
  UseShapedDistribution := not SameValue(Shape, 0.5, 0.000001);
  if UseShapedDistribution then
    BuildDistributionLookup(Shape, DistributionLookup);
  CenterOffsetX := EnsureRange(CenterOffsetX, -1.0, 1.0);
  CenterOffsetY := EnsureRange(CenterOffsetY, -1.0, 1.0);
  CenterX := EnsureRange(FBaseCenterX + CenterOffsetX * FOuterHalfWidth,
    0.0, Source.Width - 1.0);
  CenterY := EnsureRange(FBaseCenterY + CenterOffsetY * FOuterHalfHeight,
    0.0, Source.Height - 1.0);
  CalculateGravityParameters(Gravity, GravityDirection, Mass, Tension,
    GravityResponse, DirectionX, DirectionY);
  CalculateLightParameters(LightDirection, LightX, LightY, LightZ,
    HalfX, HalfY, HalfZ);

  Source.PixelFormat := pf32bit;
  Destination.PixelFormat := pf32bit;
  Destination.SetSize(Source.Width, Source.Height);
  SetLength(SourceRows, Source.Height);
  SetLength(DestinationRows, Destination.Height);
  for Y := 0 to Source.Height - 1 do
  begin
    SourceRows[Y] := Source.ScanLine[Y];
    DestinationRows[Y] := Destination.ScanLine[Y];
    Move(SourceRows[Y]^, DestinationRows[Y]^, NativeInt(Source.Width) * 4);
  end;

  for Y := FWeightMap.ActiveTop to FWeightMap.ActiveBottom do
  begin
    DestinationRow := PByteRow(DestinationRows[Y]);
    for X := FWeightMap.ActiveLeft to FWeightMap.ActiveRight do
    begin
      Weight := FWeightMap.WeightAtScreen(X, Y);
      if Weight <= 0 then
        Continue;
      if UseShapedDistribution then
        Weight := DistributionWeight(DistributionLookup, Weight);
      ApplyGravityToSample(X, Y, CenterX, CenterY, FOuterHalfWidth,
        FOuterHalfHeight, Amount, GravityResponse, DirectionX, DirectionY,
        Weight, SagX, SagY);
      Scale := Max(0.05, 1 + (Amount - 1) * Weight);
      SourceX := EnsureRange(CenterX + (X - CenterX - SagX) / Scale,
        0.0, Source.Width - 1.0);
      SourceY := EnsureRange(CenterY + (Y - CenterY - SagY) / Scale,
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
      if (ShadingStrength > 0) or (HighlightStrength > 0) then
      begin
        LightingAt(FWeightMap, X, Y,
          DistributionLookup, UseShapedDistribution, CenterX, CenterY,
          FOuterHalfWidth, FOuterHalfHeight, Amount, GravityResponse,
          DirectionX, DirectionY, Weight, ShadingStrength,
          HighlightStrength, LightX, LightY, LightZ, HalfX, HalfY, HalfZ,
          ShadeFactor, HighlightFactor);
        for Channel := 0 to 2 do
        begin
          Value := EnsureRange(DestinationRow[X * 4 + Channel] *
            ShadeFactor, 0.0, 255.0);
          Value := Value + (255 - Value) * HighlightFactor;
          DestinationRow[X * 4 + Channel] :=
            EnsureRange(Round(Value), 0, 255);
        end;
      end;
      if OpacityResponse > 0 then
      begin
        // Approximate local area change by the square of the radial scale.
        // Expansion becomes thinner; contraction becomes optically thicker.
        OpacityFactor := 1 + OpacityResponse *
          (1 / (Scale * Scale) - 1);
        DestinationRow[X * 4 + 3] := EnsureRange(Round(
          DestinationRow[X * 4 + 3] * OpacityFactor), 0, 255);
      end;
    end;
  end;
  Result := True;
end;

class function TBulgeDeformer.ApplyRgba(WeightMap: TShakeDeformationMap;
  OuterContour, CenterContour: TShakeCurve; Source, Destination: Pointer;
  Amount, Shape, CenterOffsetX, CenterOffsetY, Gravity,
  GravityDirection, Mass, Tension, OpacityResponse, ShadingStrength,
  LightDirection, HighlightStrength: Double;
  out ErrorText: string): Boolean;
var
  BaseCenterX: Double;
  BaseCenterY: Double;
  ByteCount: NativeInt;
  CenterX: Double;
  CenterY: Double;
  Channel: Integer;
  DestinationBytes: PRgbaBytes;
  DistributionLookup: TDistributionLookup;
  DirectionX: Double;
  DirectionY: Double;
  FX: Double;
  FY: Double;
  GravityResponse: Double;
  HalfX: Double;
  HalfY: Double;
  HalfZ: Double;
  HighlightFactor: Double;
  LightX: Double;
  LightY: Double;
  LightZ: Double;
  OuterHalfHeight: Double;
  OuterHalfWidth: Double;
  OpacityFactor: Double;
  PixelOffset00: NativeInt;
  PixelOffset01: NativeInt;
  PixelOffset10: NativeInt;
  PixelOffset11: NativeInt;
  SagX: Double;
  SagY: Double;
  Scale: Double;
  ShadeFactor: Double;
  SourceBytes: PRgbaBytes;
  SourceX: Double;
  SourceY: Double;
  Value: Double;
  Weight: Double;
  UseShapedDistribution: Boolean;
  X: Integer;
  X0: Integer;
  X1: Integer;
  Y: Integer;
  Y0: Integer;
  Y1: Integer;
begin
  Result := False;
  ErrorText := '';
  if (WeightMap = nil) or (Source = nil) or (Destination = nil) or
    (WeightMap.Width <= 0) or (WeightMap.Height <= 0) or
    (OuterContour = nil) or (CenterContour = nil) or
    (OuterContour.Count < 3) or (CenterContour.Count < 3) then
  begin
    ErrorText := 'MAP_NOT_READY';
    Exit;
  end;

  CalculateGeometry(WeightMap.Width, WeightMap.Height, OuterContour,
    CenterContour, BaseCenterX, BaseCenterY, OuterHalfWidth,
    OuterHalfHeight);
  Amount := EnsureRange(Amount, 0.0, 2.0);
  Shape := EnsureRange(Shape, 0.0, 1.0);
  OpacityResponse := EnsureRange(OpacityResponse, 0.0, 1.0);
  ShadingStrength := EnsureRange(ShadingStrength, 0.0, 1.0);
  HighlightStrength := EnsureRange(HighlightStrength, 0.0, 1.0);
  UseShapedDistribution := not SameValue(Shape, 0.5, 0.000001);
  if UseShapedDistribution then
    BuildDistributionLookup(Shape, DistributionLookup);
  CenterOffsetX := EnsureRange(CenterOffsetX, -1.0, 1.0);
  CenterOffsetY := EnsureRange(CenterOffsetY, -1.0, 1.0);
  CenterX := EnsureRange(BaseCenterX + CenterOffsetX * OuterHalfWidth,
    0.0, WeightMap.Width - 1.0);
  CenterY := EnsureRange(BaseCenterY + CenterOffsetY * OuterHalfHeight,
    0.0, WeightMap.Height - 1.0);
  CalculateGravityParameters(Gravity, GravityDirection, Mass, Tension,
    GravityResponse, DirectionX, DirectionY);
  CalculateLightParameters(LightDirection, LightX, LightY, LightZ,
    HalfX, HalfY, HalfZ);

  SourceBytes := Source;
  DestinationBytes := Destination;
  ByteCount := NativeInt(WeightMap.Width) * WeightMap.Height * 4;
  Move(SourceBytes^, DestinationBytes^, ByteCount);
  for Y := WeightMap.ActiveTop to WeightMap.ActiveBottom do
    for X := WeightMap.ActiveLeft to WeightMap.ActiveRight do
    begin
      Weight := WeightMap.WeightAtScreen(X, Y);
      if Weight <= 0 then
        Continue;
      if UseShapedDistribution then
        Weight := DistributionWeight(DistributionLookup, Weight);
      ApplyGravityToSample(X, Y, CenterX, CenterY, OuterHalfWidth,
        OuterHalfHeight, Amount, GravityResponse, DirectionX, DirectionY,
        Weight, SagX, SagY);
      Scale := Max(0.05, 1 + (Amount - 1) * Weight);
      SourceX := EnsureRange(CenterX + (X - CenterX - SagX) / Scale,
        0.0, WeightMap.Width - 1.0);
      SourceY := EnsureRange(CenterY + (Y - CenterY - SagY) / Scale,
        0.0, WeightMap.Height - 1.0);
      X0 := Trunc(SourceX);
      Y0 := Trunc(SourceY);
      X1 := Min(X0 + 1, WeightMap.Width - 1);
      Y1 := Min(Y0 + 1, WeightMap.Height - 1);
      FX := SourceX - X0;
      FY := SourceY - Y0;
      PixelOffset00 := (NativeInt(Y0) * WeightMap.Width + X0) * 4;
      PixelOffset01 := (NativeInt(Y0) * WeightMap.Width + X1) * 4;
      PixelOffset10 := (NativeInt(Y1) * WeightMap.Width + X0) * 4;
      PixelOffset11 := (NativeInt(Y1) * WeightMap.Width + X1) * 4;
      for Channel := 0 to 3 do
      begin
        Value := (SourceBytes^[PixelOffset00 + Channel] * (1 - FX) +
          SourceBytes^[PixelOffset01 + Channel] * FX) * (1 - FY) +
          (SourceBytes^[PixelOffset10 + Channel] * (1 - FX) +
          SourceBytes^[PixelOffset11 + Channel] * FX) * FY;
        DestinationBytes^[(NativeInt(Y) * WeightMap.Width + X) * 4 +
          Channel] := EnsureRange(Round(Value), 0, 255);
      end;
      if (ShadingStrength > 0) or (HighlightStrength > 0) then
      begin
        LightingAt(WeightMap, X, Y,
          DistributionLookup, UseShapedDistribution, CenterX, CenterY,
          OuterHalfWidth, OuterHalfHeight, Amount, GravityResponse,
          DirectionX, DirectionY, Weight, ShadingStrength,
          HighlightStrength, LightX, LightY, LightZ, HalfX, HalfY, HalfZ,
          ShadeFactor, HighlightFactor);
        PixelOffset00 := (NativeInt(Y) * WeightMap.Width + X) * 4;
        for Channel := 0 to 2 do
        begin
          Value := EnsureRange(DestinationBytes^[PixelOffset00 + Channel] *
            ShadeFactor, 0.0, 255.0);
          Value := Value + (255 - Value) * HighlightFactor;
          DestinationBytes^[PixelOffset00 + Channel] :=
            EnsureRange(Round(Value), 0, 255);
        end;
      end;
      if OpacityResponse > 0 then
      begin
        OpacityFactor := 1 + OpacityResponse *
          (1 / (Scale * Scale) - 1);
        PixelOffset00 := (NativeInt(Y) * WeightMap.Width + X) * 4 + 3;
        DestinationBytes^[PixelOffset00] := EnsureRange(Round(
          DestinationBytes^[PixelOffset00] * OpacityFactor), 0, 255);
      end;
    end;
  Result := True;
end;

end.
