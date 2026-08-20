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
  ShakeGroup: TFILTER_ITEM_GROUP;
  DeformationTypeList: array[0..2] of TFILTER_ITEM_SELECT_ITEM;
  DeformationTypeItem: TFILTER_ITEM_SELECT;
  TimeAxisEnabledItem: TFILTER_ITEM_CHECK;
  StrengthItem: TFILTER_ITEM_TRACK;
  DelayItem: TFILTER_ITEM_TRACK;
  SoftnessItem: TFILTER_ITEM_TRACK;
  DurationItem: TFILTER_ITEM_TRACK;
  MaximumDeformationItem: TFILTER_ITEM_TRACK;
  HorizontalInfluenceItem: TFILTER_ITEM_TRACK;
  VerticalInfluenceItem: TFILTER_ITEM_TRACK;

procedure AddShakeFilterItems;
function CurrentShakeRuntimeSettings: TShakeRuntimeSettings;

implementation

uses
  System.Math,
  PluginFilterTable;

procedure AddShakeFilterItems;
begin
  AddGroup(ShakeGroup, '揺れ', 1);
  ClearSelectList;
  AddSelectList(DeformationTypeList, '外周固定', Ord(sdtFixedOuter));
  AddSelectList(DeformationTypeList, '外周可変', Ord(sdtVariableOuter));
  AddSelect(DeformationTypeItem, '変形タイプ', Ord(sdtFixedOuter),
    @DeformationTypeList[0]);
  AddCheck(TimeAxisEnabledItem, '時間軸計算', 1);
  AddTrack(StrengthItem, '揺れの強さ', 50.0, 0.0, 100.0, 1.0);
  AddTrack(DelayItem, '動きの遅れ', 50.0, 0.0, 100.0, 1.0);
  AddTrack(SoftnessItem, 'やわらかさ', 50.0, 0.0, 100.0, 1.0);
  AddTrack(DurationItem, '揺れの長さ', 50.0, 0.0, 100.0, 1.0);
  AddTrack(MaximumDeformationItem, '最大変形量', 50.0, 0.0, 100.0, 1.0);
  AddTrack(HorizontalInfluenceItem, '横方向', 50.0, 0.0, 100.0, 1.0);
  AddTrack(VerticalInfluenceItem, '縦方向', 50.0, 0.0, 100.0, 1.0);
end;

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
