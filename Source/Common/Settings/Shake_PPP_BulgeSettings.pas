unit Shake_PPP_BulgeSettings;

// Owns bulge-only parameters. These values intentionally do not affect the
// completed shake simulation until the bulge renderer is implemented.

interface

uses
  AviUtl2FilterTypes;

type
  TBulgeRuntimeSettings = record
    Amount: Double;
    Shape: Double;
    CenterX: Double;
    CenterY: Double;
    Gravity: Double;
    GravityDirection: Double;
    Mass: Double;
    Tension: Double;
    OpacityResponse: Double;
    ShadingStrength: Double;
    LightDirection: Double;
    HighlightStrength: Double;
  end;

var
  BulgeGroup: TFILTER_ITEM_GROUP;
  BulgeAmountItem: TFILTER_ITEM_TRACK;
  BulgeShapeItem: TFILTER_ITEM_TRACK;
  BulgeCenterXItem: TFILTER_ITEM_TRACK;
  BulgeCenterYItem: TFILTER_ITEM_TRACK;
  BulgeGravityItem: TFILTER_ITEM_TRACK;
  BulgeGravityDirectionItem: TFILTER_ITEM_TRACK;
  BulgeMassItem: TFILTER_ITEM_TRACK;
  BulgeTensionItem: TFILTER_ITEM_TRACK;

  BulgeDisplayGroup: TFILTER_ITEM_GROUP;
  BulgeOpacityResponseItem: TFILTER_ITEM_TRACK;
  BulgeShadingStrengthItem: TFILTER_ITEM_TRACK;
  BulgeLightDirectionItem: TFILTER_ITEM_TRACK;
  BulgeHighlightStrengthItem: TFILTER_ITEM_TRACK;

procedure AddBulgeFilterItems;
function CurrentBulgeRuntimeSettings: TBulgeRuntimeSettings;

implementation

uses
  System.Math,
  PluginFilterTable;

procedure AddBulgeFilterItems;
begin
  AddGroup(BulgeGroup, '膨らみ', 1);
  AddTrack(BulgeAmountItem, '膨張量', 100.0, 0.0, 200.0, 1.0);
  AddTrack(BulgeShapeItem, '膨らみ方', 50.0, 0.0, 100.0, 1.0);
  AddTrack(BulgeCenterXItem, '膨張中心X', 0.0, -100.0, 100.0, 1.0);
  AddTrack(BulgeCenterYItem, '膨張中心Y', 0.0, -100.0, 100.0, 1.0);
  AddTrack(BulgeGravityItem, '重力', 0.0, 0.0, 100.0, 1.0);
  AddTrack(BulgeGravityDirectionItem, '重力方向', 90.0, -180.0, 180.0,
    1.0);
  AddTrack(BulgeMassItem, '質量', 50.0, 0.0, 100.0, 1.0);
  AddTrack(BulgeTensionItem, '張力', 50.0, 0.0, 100.0, 1.0);

  AddGroup(BulgeDisplayGroup, '膨らみの表示', 1);
  AddTrack(BulgeOpacityResponseItem, '透明度連動量', 0.0, 0.0, 100.0,
    1.0);
  AddTrack(BulgeShadingStrengthItem, '陰影強度', 0.0, 0.0, 100.0, 1.0);
  AddTrack(BulgeLightDirectionItem, '光源方向', -135.0, -180.0, 180.0,
    1.0);
  AddTrack(BulgeHighlightStrengthItem, 'ハイライト強度', 0.0, 0.0,
    100.0, 1.0);
end;

function CurrentBulgeRuntimeSettings: TBulgeRuntimeSettings;
begin
  Result.Amount := EnsureRange(BulgeAmountItem.Value, 0.0, 200.0) / 100.0;
  Result.Shape := EnsureRange(BulgeShapeItem.Value, 0.0, 100.0) / 100.0;
  Result.CenterX := EnsureRange(BulgeCenterXItem.Value, -100.0, 100.0) /
    100.0;
  Result.CenterY := EnsureRange(BulgeCenterYItem.Value, -100.0, 100.0) /
    100.0;
  Result.Gravity := EnsureRange(BulgeGravityItem.Value, 0.0, 100.0) / 100.0;
  Result.GravityDirection := EnsureRange(BulgeGravityDirectionItem.Value,
    -180.0, 180.0);
  Result.Mass := EnsureRange(BulgeMassItem.Value, 0.0, 100.0) / 100.0;
  Result.Tension := EnsureRange(BulgeTensionItem.Value, 0.0, 100.0) / 100.0;
  Result.OpacityResponse := EnsureRange(BulgeOpacityResponseItem.Value, 0.0,
    100.0) / 100.0;
  Result.ShadingStrength := EnsureRange(BulgeShadingStrengthItem.Value, 0.0,
    100.0) / 100.0;
  Result.LightDirection := EnsureRange(BulgeLightDirectionItem.Value, -180.0,
    180.0);
  Result.HighlightStrength := EnsureRange(BulgeHighlightStrengthItem.Value,
    0.0, 100.0) / 100.0;
end;

end.
