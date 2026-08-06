program CurveDataRoundTrip;

{$APPTYPE CONSOLE}

uses
  System.Math,
  System.SysUtils,
  System.Types,
  Shake_PPP_CurveModel in 'Source\Common\Model\Shake_PPP_CurveModel.pas',
  Shake_PPP_CurveData in 'Source\Common\Model\Shake_PPP_CurveData.pas';

procedure Require(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

var
  Center: TShakeCurve;
  DecodedCenter: TShakeCurve;
  DecodedOuter: TShakeCurve;
  DecodedSets: TShakeCurveSets;
  ErrorText: string;
  I: Integer;
  OldText: string;
  Outer: TShakeCurve;
  Sets: TShakeCurveSets;
  Text: string;
begin
  Outer := TShakeCurve.Create;
  Center := TShakeCurve.Create;
  DecodedOuter := TShakeCurve.Create;
  DecodedCenter := TShakeCurve.Create;
  Sets[0].OuterContour := Outer;
  Sets[0].CenterContour := Center;
  Sets[1].OuterContour := TShakeCurve.Create;
  Sets[1].CenterContour := TShakeCurve.Create;
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
  begin
    DecodedSets[I].OuterContour := TShakeCurve.Create;
    DecodedSets[I].CenterContour := TShakeCurve.Create;
  end;
  try
    Outer.AddVertex(PointF(0.1, 0.2), svkSmooth);
    Outer.AddVertex(PointF(0.8, 0.25), svkCorner);
    Outer.AddVertex(PointF(0.55, 0.9), svkSmooth);
    Outer.Closed := True;
    Center.AddVertex(PointF(0.3, 0.4), svkCorner);
    Center.AddVertex(PointF(0.6, 0.7), svkSmooth);

    Require(TryEncodeCurveData(Outer, Center, Text, ErrorText), ErrorText);
    OldText := Text;
    Require(Pos(#10, Text) = 0, 'Serialized data must stay on one line.');
    Require(TryDecodeCurveData(Text, DecodedOuter, DecodedCenter,
      ErrorText), ErrorText);
    Require(DecodedOuter.Closed, 'Outer closed state was not restored.');
    Require(DecodedOuter.Count = 3, 'Outer vertex count changed.');
    Require(DecodedCenter.Count = 2, 'Center vertex count changed.');
    Require(DecodedOuter[1].Kind = svkCorner, 'Vertex kind changed.');
    Require(SameValue(DecodedOuter[2].Position.Y, 0.9, 0.000001),
      'Coordinate changed.');

    Sets[1].OuterContour.AddVertex(PointF(0.2, 0.3), svkCorner);
    Sets[1].CenterContour.AddVertex(PointF(0.7, 0.6), svkSmooth);
    Require(TryEncodeCurveSets(Sets, Text, ErrorText), ErrorText);
    Require(Text.StartsWith('SPP2|'), 'Two-set format prefix is invalid.');
    Require(TryDecodeCurveSets(Text, DecodedSets, ErrorText), ErrorText);
    Require(DecodedSets[0].OuterContour.Count = 3,
      'Set 1 outer curve changed.');
    Require(DecodedSets[1].OuterContour.Count = 1,
      'Set 2 outer curve changed.');
    Require(DecodedSets[1].CenterContour[0].Kind = svkSmooth,
      'Set 2 center vertex kind changed.');
    Require(TryDecodeCurveSets(OldText, DecodedSets, ErrorText), ErrorText);
    Require((DecodedSets[0].OuterContour.Count = 3) and
      (DecodedSets[1].OuterContour.Count = 0),
      'SPP1 compatibility conversion failed.');

    Require(not TryDecodeCurveData('SPP1|O,1;bad|C,0',
      DecodedOuter, DecodedCenter, ErrorText),
      'Malformed data was accepted.');
    Require(DecodedOuter.Count = 3,
      'Malformed data modified the current curve.');
    Require(TryDecodeCurveData('', DecodedOuter, DecodedCenter,
      ErrorText), ErrorText);
    Require((DecodedOuter.Count = 0) and (DecodedCenter.Count = 0),
      'Empty data did not clear the curves.');
    Writeln('CurveDataRoundTrip: PASS');
  finally
    for I := SHAKE_CURVE_SET_COUNT - 1 downto 0 do
    begin
      DecodedSets[I].CenterContour.Free;
      DecodedSets[I].OuterContour.Free;
    end;
    Sets[1].CenterContour.Free;
    Sets[1].OuterContour.Free;
    DecodedCenter.Free;
    DecodedOuter.Free;
    Center.Free;
    Outer.Free;
  end;
end.
