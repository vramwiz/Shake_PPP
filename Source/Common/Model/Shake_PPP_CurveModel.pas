unit Shake_PPP_CurveModel;

interface

uses
  System.Generics.Collections,
  System.Types;

type
  TShakeCurveKind = (sckOuterContour, sckCenterContour);
  TShakeVertexKind = (svkCorner, svkSmooth);

  TShakeCurveVertex = record
    Position: TPointF;
    Kind: TShakeVertexKind;
  end;

  TShakeCurve = class
  private
    FClosed: Boolean;
    FVertices: TList<TShakeCurveVertex>;
    function GetCount: Integer;
    function GetVertex(Index: Integer): TShakeCurveVertex;
  public
    constructor Create;
    destructor Destroy; override;
    function AddVertex(const Position: TPointF;
      Kind: TShakeVertexKind): Integer;
    function InsertVertex(Index: Integer; const Position: TPointF;
      Kind: TShakeVertexKind): Integer;
    procedure Assign(Source: TShakeCurve);
    procedure Clear;
    procedure DeleteVertex(Index: Integer);
    procedure SetVertexKind(Index: Integer; Kind: TShakeVertexKind);
    procedure SetVertexPosition(Index: Integer; const Position: TPointF);
    property Closed: Boolean read FClosed write FClosed;
    property Count: Integer read GetCount;
    property Vertices[Index: Integer]: TShakeCurveVertex read GetVertex; default;
  end;

const
  SHAKE_CURVE_SET_COUNT = 2;

type
  TShakeCurveSet = record
    OuterContour: TShakeCurve;
    CenterContour: TShakeCurve;
  end;
  TShakeCurveSets = array[0..SHAKE_CURVE_SET_COUNT - 1] of TShakeCurveSet;

implementation

uses
  System.Math;

constructor TShakeCurve.Create;
begin
  inherited Create;
  FVertices := TList<TShakeCurveVertex>.Create;
end;

destructor TShakeCurve.Destroy;
begin
  FVertices.Free;
  inherited;
end;

function TShakeCurve.AddVertex(const Position: TPointF;
  Kind: TShakeVertexKind): Integer;
var
  Vertex: TShakeCurveVertex;
begin
  Vertex.Position := Position;
  Vertex.Kind := Kind;
  Result := FVertices.Add(Vertex);
end;

function TShakeCurve.InsertVertex(Index: Integer; const Position: TPointF;
  Kind: TShakeVertexKind): Integer;
var
  Vertex: TShakeCurveVertex;
begin
  Result := EnsureRange(Index, 0, FVertices.Count);
  Vertex.Position := Position;
  Vertex.Kind := Kind;
  FVertices.Insert(Result, Vertex);
end;

procedure TShakeCurve.Assign(Source: TShakeCurve);
var
  I: Integer;
begin
  if Source = Self then
    Exit;
  Clear;
  if Source = nil then
    Exit;
  for I := 0 to Source.Count - 1 do
    FVertices.Add(Source[I]);
  FClosed := Source.Closed;
end;

procedure TShakeCurve.Clear;
begin
  FVertices.Clear;
  FClosed := False;
end;

procedure TShakeCurve.DeleteVertex(Index: Integer);
begin
  if (Index < 0) or (Index >= FVertices.Count) then
    Exit;
  FVertices.Delete(Index);
  if FVertices.Count < 3 then
    FClosed := False;
end;

function TShakeCurve.GetCount: Integer;
begin
  Result := FVertices.Count;
end;

function TShakeCurve.GetVertex(Index: Integer): TShakeCurveVertex;
begin
  Result := FVertices[Index];
end;

procedure TShakeCurve.SetVertexPosition(Index: Integer;
  const Position: TPointF);
var
  Vertex: TShakeCurveVertex;
begin
  if (Index < 0) or (Index >= FVertices.Count) then
    Exit;
  Vertex := FVertices[Index];
  Vertex.Position := Position;
  FVertices[Index] := Vertex;
end;

procedure TShakeCurve.SetVertexKind(Index: Integer; Kind: TShakeVertexKind);
var
  Vertex: TShakeCurveVertex;
begin
  if (Index < 0) or (Index >= FVertices.Count) then
    Exit;
  Vertex := FVertices[Index];
  Vertex.Kind := Kind;
  FVertices[Index] := Vertex;
end;

end.
