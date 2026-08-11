unit Shake_PPP_FilterSettings;

// Owns the AviUtl2 items used by the future motion and deformation stages.

interface

uses
  AviUtl2FilterTypes;

type
  TShakeDeformationType = (
    sdtFixedOuter = 0,
    sdtVariableOuter = 1
  );

  TShakeRuntimeSettings = record
    DeformationType: TShakeDeformationType;
    TimeAxisEnabled: Boolean;
    PositionX: Double;
    PositionY: Double;
    Strength: Double;
    Delay: Double;
    Softness: Double;
    Duration: Double;
    MaximumDeformation: Double;
    HorizontalInfluence: Double;
    VerticalInfluence: Double;
  end;

var
  DeformationTypeList: array[0..2] of TFILTER_ITEM_SELECT_ITEM = (
    (Name: '外周固定'; Value: Ord(sdtFixedOuter)),
    (Name: '外周可変'; Value: Ord(sdtVariableOuter)),
    (Name: nil; Value: 0)
  );
  DeformationTypeItem: TFILTER_ITEM_SELECT = (
    ItemType: 'select';
    Name: '変形タイプ';
    Value: Ord(sdtFixedOuter);
    List: @DeformationTypeList[0]
  );
  TimeAxisEnabledItem: TFILTER_ITEM_CHECK = (
    ItemType: 'check';
    Name: '時間軸計算';
    Value: 1
  );
  StrengthItem: TFILTER_ITEM_TRACK = (
    ItemType: 'track';
    Name: '揺れの強さ';
    Value: 50.0;
    S: 0.0;
    E: 100.0;
    Step: 1.0
  );
  DelayItem: TFILTER_ITEM_TRACK = (
    ItemType: 'track';
    Name: '動きの遅れ';
    Value: 50.0;
    S: 0.0;
    E: 100.0;
    Step: 1.0
  );
  SoftnessItem: TFILTER_ITEM_TRACK = (
    ItemType: 'track';
    Name: 'やわらかさ';
    Value: 50.0;
    S: 0.0;
    E: 100.0;
    Step: 1.0
  );
  DurationItem: TFILTER_ITEM_TRACK = (
    ItemType: 'track';
    Name: '揺れの長さ';
    Value: 50.0;
    S: 0.0;
    E: 100.0;
    Step: 1.0
  );
  MaximumDeformationItem: TFILTER_ITEM_TRACK = (
    ItemType: 'track';
    Name: '最大変形量';
    Value: 50.0;
    S: 0.0;
    E: 100.0;
    Step: 1.0
  );
  HorizontalInfluenceItem: TFILTER_ITEM_TRACK = (
    ItemType: 'track';
    Name: '横方向';
    Value: 50.0;
    S: 0.0;
    E: 100.0;
    Step: 1.0
  );
  VerticalInfluenceItem: TFILTER_ITEM_TRACK = (
    ItemType: 'track';
    Name: '縦方向';
    Value: 50.0;
    S: 0.0;
    E: 100.0;
    Step: 1.0
  );

function CurrentShakeRuntimeSettings: TShakeRuntimeSettings;

implementation

uses
  System.Math;

function Percent(Value, Minimum, Maximum: Double): Double;
begin
  Result := EnsureRange(Value, Minimum, Maximum) / 100.0;
end;

function CurrentShakeRuntimeSettings: TShakeRuntimeSettings;
begin
  Result.DeformationType := TShakeDeformationType(EnsureRange(
    DeformationTypeItem.Value, Ord(Low(TShakeDeformationType)),
    Ord(High(TShakeDeformationType))));
  Result.TimeAxisEnabled := TimeAxisEnabledItem.Value <> 0;
  Result.PositionX := 0;
  Result.PositionY := 0;
  Result.Strength := Percent(StrengthItem.Value, 0, 100);
  Result.Delay := Percent(DelayItem.Value, 0, 100);
  Result.Softness := Percent(SoftnessItem.Value, 0, 100);
  Result.Duration := Percent(DurationItem.Value, 0, 100);
  Result.MaximumDeformation := EnsureRange(MaximumDeformationItem.Value,
    0.0, 100.0);
  Result.HorizontalInfluence := Percent(HorizontalInfluenceItem.Value,
    0, 100);
  Result.VerticalInfluence := Percent(VerticalInfluenceItem.Value,
    0, 100);
end;

end.
