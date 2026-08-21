unit Shake_PPP_RuntimeDeformer;

// Applies the two saved curve sets to AviUtl2 frames using a damped follower.

interface

uses
  AviUtl2FilterTypes,
  Shake_PPP_BulgeSettings,
  Shake_PPP_FilterSettings;

procedure InitializeRuntimeDeformer;
procedure FinalizeRuntimeDeformer;
procedure ApplyRuntimeDeformation(Video: PFILTER_PROC_VIDEO;
  const CurveDataText: string; const ShakeSettings: TShakeRuntimeSettings;
  const BulgeSettings: TBulgeRuntimeSettings);

implementation

uses
  System.Generics.Collections,
  System.Math,
  System.SysUtils,
  Winapi.Windows,
  AviUtl2FilterInfoUtils,
  Shake_PPP_BulgeDeformer,
  Shake_PPP_CurveData,
  Shake_PPP_CurveModel,
  Shake_PPP_DebugLog,
  Shake_PPP_GpuBulgeDeformer,
  Shake_PPP_StaticDeformer;

const
  MAX_CONTINUOUS_FRAME_GAP = 10;

type
  TShakeObjectState = class
  private
    FCurveDataText: string;
    FCurveSets: TShakeCurveSets;
    FGpuBulge: TGpuBulgeProcessor;
    FLastGpuStatus: string;
    FHeight: Integer;
    FHasFrame: Boolean;
    FLastFrame: Integer;
    FLastMotionLog: UInt64;
    FMapReady: array[0..SHAKE_CURVE_SET_COUNT - 1] of Boolean;
    FMaps: array[0..SHAKE_CURVE_SET_COUNT - 1] of TShakeDeformationMap;
    FOffsetX: Double;
    FOffsetY: Double;
    FPreviousX: Double;
    FPreviousY: Double;
    FVelocityX: Double;
    FVelocityY: Double;
    FWidth: Integer;
    FSource: TBytes;
    FWork: TBytes;
    FOutput: TBytes;
{$IFDEF DEBUG}
    FPerfBufferMilliseconds: Double;
    FPerfBulgeMilliseconds: array[0..SHAKE_CURVE_SET_COUNT - 1] of Double;
    FPerfFrameCount: Integer;
    FPerfGetImageMilliseconds: Double;
    FPerfLastLogTick: UInt64;
    FPerfMaximumTotalMilliseconds: Double;
    FPerfSetImageMilliseconds: Double;
    FPerfShakeMilliseconds: array[0..SHAKE_CURVE_SET_COUNT - 1] of Double;
    FPerfTotalMilliseconds: Double;
    procedure RecordPerformance(Video: PFILTER_PROC_VIDEO;
      BufferMilliseconds, GetImageMilliseconds: Double;
      const BulgeMilliseconds, ShakeMilliseconds: array of Double;
      SetImageMilliseconds, TotalMilliseconds: Double;
      const BulgeSettings: TBulgeRuntimeSettings);
{$ENDIF}
    procedure AdvanceMotion(Frame: Integer;
      const Settings: TShakeRuntimeSettings);
    procedure ApplyDeformation(Video: PFILTER_PROC_VIDEO;
      const CurveDataText: string; Width, Height: Integer;
      DisplacementX, DisplacementY: Double;
      DeformationType: TShakeDeformationType;
      const BulgeSettings: TBulgeRuntimeSettings;
      BulgeEnabled, ShakeEnabled: Boolean);
    function PrepareMaps(Width, Height: Integer;
      const CurveDataText: string): Boolean;
    procedure ResetMotion(Frame: Integer; PositionX, PositionY: Double);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Apply(Video: PFILTER_PROC_VIDEO; const CurveDataText: string;
      const ShakeSettings: TShakeRuntimeSettings;
      const BulgeSettings: TBulgeRuntimeSettings);
  end;

var
  RuntimeInitialized: Boolean;
  RuntimeLock: TRTLCriticalSection;
  RuntimeStates: TObjectDictionary<Int64, TShakeObjectState>;
{$IFDEF DEBUG}
  RuntimePerfCallCount: Integer;
  RuntimePerfLastLogTick: UInt64;
  RuntimePerfLockWaitMilliseconds: Double;
  RuntimePerfMaximumMilliseconds: Double;
  RuntimePerfTotalMilliseconds: Double;
{$ENDIF}

constructor TShakeObjectState.Create;
var
  I: Integer;
begin
  inherited;
  FGpuBulge := TGpuBulgeProcessor.Create;
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
  begin
    FCurveSets[I].OuterContour := TShakeCurve.Create;
    FCurveSets[I].CenterContour := TShakeCurve.Create;
    FMaps[I] := TShakeDeformationMap.Create;
  end;
end;

destructor TShakeObjectState.Destroy;
var
  I: Integer;
begin
  FGpuBulge.Free;
  for I := SHAKE_CURVE_SET_COUNT - 1 downto 0 do
  begin
    FMaps[I].Free;
    FCurveSets[I].CenterContour.Free;
    FCurveSets[I].OuterContour.Free;
  end;
  inherited;
end;

{$IFDEF DEBUG}
procedure TShakeObjectState.RecordPerformance(Video: PFILTER_PROC_VIDEO;
  BufferMilliseconds, GetImageMilliseconds: Double;
  const BulgeMilliseconds, ShakeMilliseconds: array of Double;
  SetImageMilliseconds, TotalMilliseconds: Double;
  const BulgeSettings: TBulgeRuntimeSettings);
var
  CurrentTick: UInt64;
  I: Integer;
begin
  Inc(FPerfFrameCount);
  FPerfBufferMilliseconds := FPerfBufferMilliseconds + BufferMilliseconds;
  FPerfGetImageMilliseconds := FPerfGetImageMilliseconds +
    GetImageMilliseconds;
  for I := 0 to Min(High(BulgeMilliseconds),
    SHAKE_CURVE_SET_COUNT - 1) do
    FPerfBulgeMilliseconds[I] := FPerfBulgeMilliseconds[I] +
      BulgeMilliseconds[I];
  for I := 0 to Min(High(ShakeMilliseconds),
    SHAKE_CURVE_SET_COUNT - 1) do
    FPerfShakeMilliseconds[I] := FPerfShakeMilliseconds[I] +
      ShakeMilliseconds[I];
  FPerfSetImageMilliseconds := FPerfSetImageMilliseconds +
    SetImageMilliseconds;
  FPerfTotalMilliseconds := FPerfTotalMilliseconds + TotalMilliseconds;
  FPerfMaximumTotalMilliseconds := Max(FPerfMaximumTotalMilliseconds,
    TotalMilliseconds);

  CurrentTick := GetTickCount64;
  if FPerfLastLogTick = 0 then
  begin
    FPerfLastLogTick := CurrentTick;
    Exit;
  end;
  if CurrentTick - FPerfLastLogTick < 1000 then
    Exit;

  DebugLog(Format(
    'Runtime performance: objectId=%d effectId=%d frames=%d size=%dx%d avgMs(total=%.3f buffer=%.3f getImage=%.3f bulge1=%.3f bulge2=%.3f shake1=%.3f shake2=%.3f setImage=%.3f) maxTotalMs=%.3f display(opacity=%.2f shading=%.2f highlight=%.2f).',
    [Video^.Object_^.ID, Video^.Object_^.EffectID, FPerfFrameCount,
     FWidth, FHeight, FPerfTotalMilliseconds / FPerfFrameCount,
     FPerfBufferMilliseconds / FPerfFrameCount,
     FPerfGetImageMilliseconds / FPerfFrameCount,
     FPerfBulgeMilliseconds[0] / FPerfFrameCount,
     FPerfBulgeMilliseconds[1] / FPerfFrameCount,
     FPerfShakeMilliseconds[0] / FPerfFrameCount,
     FPerfShakeMilliseconds[1] / FPerfFrameCount,
     FPerfSetImageMilliseconds / FPerfFrameCount,
     FPerfMaximumTotalMilliseconds, BulgeSettings.OpacityResponse,
     BulgeSettings.ShadingStrength, BulgeSettings.HighlightStrength]));
  FPerfFrameCount := 0;
  FPerfBufferMilliseconds := 0;
  FPerfGetImageMilliseconds := 0;
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
  begin
    FPerfBulgeMilliseconds[I] := 0;
    FPerfShakeMilliseconds[I] := 0;
  end;
  FPerfSetImageMilliseconds := 0;
  FPerfTotalMilliseconds := 0;
  FPerfMaximumTotalMilliseconds := 0;
  FPerfLastLogTick := CurrentTick;
end;
{$ENDIF}

procedure TShakeObjectState.ResetMotion(Frame: Integer;
  PositionX, PositionY: Double);
begin
  FHasFrame := True;
  FLastFrame := Frame;
  FPreviousX := PositionX;
  FPreviousY := PositionY;
  FOffsetX := 0;
  FOffsetY := 0;
  FVelocityX := 0;
  FVelocityY := 0;
end;

procedure TShakeObjectState.AdvanceMotion(Frame: Integer;
  const Settings: TShakeRuntimeSettings);
var
  Damping: Double;
  DeltaX: Double;
  DeltaY: Double;
  FrameGap: Integer;
  InputGain: Double;
  Step: Integer;
  StepDeltaX: Double;
  StepDeltaY: Double;
  Spring: Double;
begin
  if not FHasFrame then
  begin
    ResetMotion(Frame, Settings.PositionX, Settings.PositionY);
    Exit;
  end;
  if Frame = FLastFrame then
    Exit;
  if Frame < FLastFrame then
  begin
    DebugLog(Format('Runtime motion reset: frame moved backward from %d to %d.',
      [FLastFrame, Frame]));
    ResetMotion(Frame, Settings.PositionX, Settings.PositionY);
    Exit;
  end;

  FrameGap := Frame - FLastFrame;
  if FrameGap > MAX_CONTINUOUS_FRAME_GAP then
  begin
    DebugLog(Format('Runtime motion reset: frame gap=%d exceeds limit=%d.',
      [FrameGap, MAX_CONTINUOUS_FRAME_GAP]));
    ResetMotion(Frame, Settings.PositionX, Settings.PositionY);
    Exit;
  end;

  DeltaX := Settings.PositionX - FPreviousX;
  DeltaY := Settings.PositionY - FPreviousY;
  StepDeltaX := DeltaX / FrameGap;
  StepDeltaY := DeltaY / FrameGap;
  FPreviousX := Settings.PositionX;
  FPreviousY := Settings.PositionY;
  FLastFrame := Frame;

  InputGain := Settings.Strength * (0.2 + Settings.Delay * 0.8);
  Spring := 0.28 - Settings.Softness * 0.20;
  Damping := 0.62 + Settings.Duration * 0.35;

  // Reconstruct skipped playback frames with linear position interpolation.
  // This preserves spring time and avoids treating normal frame drops as seeks.
  for Step := 1 to FrameGap do
  begin
    // The body moves immediately while the soft part remains behind.
    FOffsetX := FOffsetX - StepDeltaX * InputGain;
    FOffsetY := FOffsetY - StepDeltaY * InputGain;

    // A softer spring returns more slowly. Duration controls energy loss.
    FVelocityX := (FVelocityX - FOffsetX * Spring) * Damping;
    FVelocityY := (FVelocityY - FOffsetY * Spring) * Damping;
    FOffsetX := FOffsetX + FVelocityX;
    FOffsetY := FOffsetY + FVelocityY;
  end;

  if ((Abs(DeltaX) > 0.0001) or (Abs(DeltaY) > 0.0001)) and
    ((FLastMotionLog = 0) or (GetTickCount64 - FLastMotionLog >= 500)) then
  begin
    FLastMotionLog := GetTickCount64;
    DebugLog(Format(
      'Runtime motion: frame=%d gap=%d position=%.1f,%.1f delta=%.1f,%.1f perFrame=%.1f,%.1f offset=%.1f,%.1f.',
      [Frame, FrameGap, Settings.PositionX, Settings.PositionY, DeltaX, DeltaY,
       StepDeltaX, StepDeltaY, FOffsetX, FOffsetY]));
  end;

  if (Abs(FOffsetX) < 0.005) and (Abs(FVelocityX) < 0.005) then
  begin
    FOffsetX := 0;
    FVelocityX := 0;
  end;
  if (Abs(FOffsetY) < 0.005) and (Abs(FVelocityY) < 0.005) then
  begin
    FOffsetY := 0;
    FVelocityY := 0;
  end;
end;

function TShakeObjectState.PrepareMaps(Width, Height: Integer;
  const CurveDataText: string): Boolean;
var
  ErrorText: string;
  I: Integer;
begin
  if (FWidth = Width) and (FHeight = Height) and
    (FCurveDataText = CurveDataText) then
    Exit(FMapReady[0] or FMapReady[1]);

  FWidth := Width;
  FHeight := Height;
  FCurveDataText := CurveDataText;
  FGpuBulge.InvalidateWeights;
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
  begin
    FMaps[I].Clear;
    FMapReady[I] := False;
  end;
  if not TryDecodeCurveSets(CurveDataText, FCurveSets, ErrorText) then
  begin
    DebugLog('Runtime curve data rejected: ' + ErrorText);
    Exit(False);
  end;
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
  begin
    FMapReady[I] := FMaps[I].Build(Width, Height,
      FCurveSets[I].OuterContour, FCurveSets[I].CenterContour, ErrorText);
    if not FMapReady[I] and (ErrorText <> 'OUTER_NOT_CLOSED') then
      DebugLog(Format('Runtime curve set %d rejected: %s.',
        [I + 1, ErrorText]));
  end;
  Result := FMapReady[0] or FMapReady[1];
end;

procedure TShakeObjectState.ApplyDeformation(
  Video: PFILTER_PROC_VIDEO; const CurveDataText: string;
  Width, Height: Integer; DisplacementX, DisplacementY: Double;
  DeformationType: TShakeDeformationType;
  const BulgeSettings: TBulgeRuntimeSettings;
  BulgeEnabled, ShakeEnabled: Boolean);
var
  ByteCount: NativeInt;
  CurrentSource: Pointer;
  ErrorText: string;
  I: Integer;
  NextDestination: Pointer;
  Succeeded: Boolean;
  GpuEligible: Boolean;
{$IFDEF DEBUG}
  BufferMilliseconds: Double;
  BulgeMilliseconds: array[0..SHAKE_CURVE_SET_COUNT - 1] of Double;
  GetImageMilliseconds: Double;
  PerfStageStarted: Int64;
  PerfTotalStarted: Int64;
  SetImageMilliseconds: Double;
  ShakeMilliseconds: array[0..SHAKE_CURVE_SET_COUNT - 1] of Double;
  StageMilliseconds: Double;
  TotalMilliseconds: Double;
{$ENDIF}

  function NextBuffer: Pointer;
  begin
    if CurrentSource = Pointer(@FWork[0]) then
      Result := @FOutput[0]
    else
      Result := @FWork[0];
  end;

begin
  if not PrepareMaps(Width, Height, CurveDataText) then
    Exit;
{$IFDEF DEBUG}
  PerfTotalStarted := DebugTimerStart;
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
  begin
    BulgeMilliseconds[I] := 0;
    ShakeMilliseconds[I] := 0;
  end;
{$ENDIF}
  GpuEligible := BulgeEnabled or ShakeEnabled;
  if GpuEligible then
  begin
    Succeeded := FGpuBulge.ApplyCombined(Video, FCurveSets, FMaps,
      FMapReady, BulgeSettings, BulgeEnabled, ShakeEnabled,
      DeformationType = sdtVariableOuter, DisplacementX, DisplacementY,
      ErrorText);
    if Succeeded then
    begin
      if BulgeEnabled and ShakeEnabled then
      begin
        if FLastGpuStatus <> 'ACTIVE_ALL' then
        begin
          FLastGpuStatus := 'ACTIVE_ALL';
          DebugLog('Runtime GPU bulge + shake path enabled.');
        end;
      end
      else if ShakeEnabled then
      begin
        if FLastGpuStatus <> 'ACTIVE_SHAKE' then
        begin
          FLastGpuStatus := 'ACTIVE_SHAKE';
          DebugLog('Runtime GPU shake path enabled.');
        end;
      end
      else
      begin
        if FLastGpuStatus <> 'ACTIVE' then
        begin
          FLastGpuStatus := 'ACTIVE';
          DebugLog('Runtime GPU bulge path enabled.');
        end;
      end;
      Exit;
    end;
    if not Succeeded and (FLastGpuStatus <> ErrorText) then
    begin
      FLastGpuStatus := ErrorText;
      DebugLog('Runtime GPU bulge fallback: ' + ErrorText + '.');
    end;
  end;
{$IFDEF DEBUG}
  PerfStageStarted := DebugTimerStart;
{$ENDIF}
  ByteCount := NativeInt(Width) * Height * 4;
  SetLength(FSource, ByteCount);
  SetLength(FWork, ByteCount);
  SetLength(FOutput, ByteCount);
{$IFDEF DEBUG}
  BufferMilliseconds := DebugTimerElapsedMilliseconds(PerfStageStarted);
  PerfStageStarted := DebugTimerStart;
{$ENDIF}
  Video^.GetImageData(PPIXEL_RGBA(@FSource[0]));
  CurrentSource := @FSource[0];
{$IFDEF DEBUG}
  GetImageMilliseconds := DebugTimerElapsedMilliseconds(PerfStageStarted);
{$ENDIF}
  if BulgeEnabled then
    for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
      if FMapReady[I] then
      begin
        NextDestination := NextBuffer;
{$IFDEF DEBUG}
        PerfStageStarted := DebugTimerStart;
{$ENDIF}
        Succeeded := TBulgeDeformer.ApplyRgba(FMaps[I],
          FCurveSets[I].OuterContour, FCurveSets[I].CenterContour,
          CurrentSource, NextDestination, BulgeSettings.Amount,
          BulgeSettings.Shape, BulgeSettings.CenterX,
          BulgeSettings.CenterY, BulgeSettings.Gravity,
          BulgeSettings.GravityDirection, BulgeSettings.Mass,
          BulgeSettings.Tension, BulgeSettings.OpacityResponse,
          BulgeSettings.ShadingStrength, BulgeSettings.LightDirection,
          BulgeSettings.HighlightStrength, ErrorText);
        if not Succeeded then
        begin
          DebugLog(Format('Runtime bulge set %d failed: %s.',
            [I + 1, ErrorText]));
          Exit;
        end;
{$IFDEF DEBUG}
        StageMilliseconds := DebugTimerElapsedMilliseconds(PerfStageStarted);
        BulgeMilliseconds[I] := BulgeMilliseconds[I] + StageMilliseconds;
{$ENDIF}
        CurrentSource := NextDestination;
      end;

  if ShakeEnabled then
    for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
      if FMapReady[I] then
      begin
        NextDestination := NextBuffer;
{$IFDEF DEBUG}
        PerfStageStarted := DebugTimerStart;
{$ENDIF}
        case DeformationType of
          sdtFixedOuter:
            Succeeded := FMaps[I].ApplyRgba(CurrentSource, NextDestination,
              DisplacementX, DisplacementY, ErrorText);
          sdtVariableOuter:
            Succeeded := FMaps[I].ApplyVariableOuterRgba(CurrentSource,
              NextDestination, DisplacementX, DisplacementY, ErrorText);
        else
          Succeeded := False;
          ErrorText := 'UNKNOWN_DEFORMATION_TYPE';
        end;
        if not Succeeded then
        begin
          DebugLog(Format('Runtime shake set %d failed: %s.',
            [I + 1, ErrorText]));
          Exit;
        end;
{$IFDEF DEBUG}
        StageMilliseconds := DebugTimerElapsedMilliseconds(PerfStageStarted);
        ShakeMilliseconds[I] := ShakeMilliseconds[I] + StageMilliseconds;
{$ENDIF}
        CurrentSource := NextDestination;
      end;
{$IFDEF DEBUG}
  PerfStageStarted := DebugTimerStart;
{$ENDIF}
  Video^.SetImageData(PPIXEL_RGBA(CurrentSource), Width, Height);
{$IFDEF DEBUG}
  SetImageMilliseconds := DebugTimerElapsedMilliseconds(PerfStageStarted);
  TotalMilliseconds := DebugTimerElapsedMilliseconds(PerfTotalStarted);
  RecordPerformance(Video, BufferMilliseconds, GetImageMilliseconds,
    BulgeMilliseconds, ShakeMilliseconds, SetImageMilliseconds,
    TotalMilliseconds, BulgeSettings);
{$ENDIF}
end;

procedure TShakeObjectState.Apply(Video: PFILTER_PROC_VIDEO;
  const CurveDataText: string; const ShakeSettings: TShakeRuntimeSettings;
  const BulgeSettings: TBulgeRuntimeSettings);
var
  BulgeEnabled: Boolean;
  DisplacementX: Double;
  DisplacementY: Double;
  Frame: Integer;
  Height: Integer;
  ShakeEnabled: Boolean;
  Width: Integer;
begin
  if (Video = nil) or (Video^.Object_ = nil) or
    not Assigned(Video^.GetImageData) or
    not Assigned(Video^.SetImageData) then
    Exit;
  Width := Video^.Object_^.Width;
  Height := Video^.Object_^.Height;
  Frame := AviUtl2GetVideoFrame(Video);
  if (Width <= 0) or (Height <= 0) or
    (NativeInt(Width) > High(NativeInt) div Height div 4) then
    Exit;

  BulgeEnabled := not SameValue(BulgeSettings.Amount, 1.0, 0.0001);
  DisplacementX := 0;
  DisplacementY := 0;
  ShakeEnabled := False;
  if not ShakeSettings.TimeAxisEnabled then
    ResetMotion(Frame, ShakeSettings.PositionX, ShakeSettings.PositionY)
  else
  begin
    AdvanceMotion(Frame, ShakeSettings);
    DisplacementX := EnsureRange(
      FOffsetX * ShakeSettings.HorizontalInfluence,
      -ShakeSettings.MaximumDeformation,
      ShakeSettings.MaximumDeformation);
    DisplacementY := EnsureRange(
      FOffsetY * ShakeSettings.VerticalInfluence,
      -ShakeSettings.MaximumDeformation,
      ShakeSettings.MaximumDeformation);
    ShakeEnabled := not (SameValue(DisplacementX, 0, 0.005) and
      SameValue(DisplacementY, 0, 0.005));
  end;
  if not BulgeEnabled and not ShakeEnabled then
    Exit;

  case ShakeSettings.DeformationType of
    sdtFixedOuter, sdtVariableOuter:
      ApplyDeformation(Video, CurveDataText, Width, Height,
        DisplacementX, DisplacementY, ShakeSettings.DeformationType,
        BulgeSettings, BulgeEnabled, ShakeEnabled);
  end;
end;

procedure InitializeRuntimeDeformer;
begin
  if RuntimeInitialized then
    Exit;
  InitializeCriticalSection(RuntimeLock);
  RuntimeStates := TObjectDictionary<Int64, TShakeObjectState>.Create(
    [doOwnsValues]);
{$IFDEF DEBUG}
  RuntimePerfCallCount := 0;
  RuntimePerfLastLogTick := 0;
  RuntimePerfLockWaitMilliseconds := 0;
  RuntimePerfMaximumMilliseconds := 0;
  RuntimePerfTotalMilliseconds := 0;
{$ENDIF}
  RuntimeInitialized := True;
end;

procedure FinalizeRuntimeDeformer;
begin
  if not RuntimeInitialized then
    Exit;
  EnterCriticalSection(RuntimeLock);
  try
    FreeAndNil(RuntimeStates);
  finally
    LeaveCriticalSection(RuntimeLock);
  end;
  DeleteCriticalSection(RuntimeLock);
  RuntimeInitialized := False;
end;

procedure ApplyRuntimeDeformation(Video: PFILTER_PROC_VIDEO;
  const CurveDataText: string; const ShakeSettings: TShakeRuntimeSettings;
  const BulgeSettings: TBulgeRuntimeSettings);
var
  Key: Int64;
  State: TShakeObjectState;
{$IFDEF DEBUG}
  CurrentTick: UInt64;
  DispatchMilliseconds: Double;
  DispatchStarted: Int64;
  LockWaitMilliseconds: Double;
{$ENDIF}
begin
  if not RuntimeInitialized or (Video = nil) or (Video^.Object_ = nil) then
    Exit;
  Key := Video^.Object_^.EffectID;
  if Key = 0 then
    Key := Video^.Object_^.ID;
{$IFDEF DEBUG}
  DispatchStarted := DebugTimerStart;
{$ENDIF}
  EnterCriticalSection(RuntimeLock);
{$IFDEF DEBUG}
  LockWaitMilliseconds := DebugTimerElapsedMilliseconds(DispatchStarted);
{$ENDIF}
  try
    if not RuntimeStates.TryGetValue(Key, State) then
    begin
      State := TShakeObjectState.Create;
      RuntimeStates.Add(Key, State);
    end;
    State.Apply(Video, CurveDataText, ShakeSettings, BulgeSettings);
  finally
{$IFDEF DEBUG}
    DispatchMilliseconds := DebugTimerElapsedMilliseconds(DispatchStarted);
    Inc(RuntimePerfCallCount);
    RuntimePerfLockWaitMilliseconds := RuntimePerfLockWaitMilliseconds +
      LockWaitMilliseconds;
    RuntimePerfTotalMilliseconds := RuntimePerfTotalMilliseconds +
      DispatchMilliseconds;
    RuntimePerfMaximumMilliseconds := Max(RuntimePerfMaximumMilliseconds,
      DispatchMilliseconds);
    CurrentTick := GetTickCount64;
    if RuntimePerfLastLogTick = 0 then
      RuntimePerfLastLogTick := CurrentTick
    else if CurrentTick - RuntimePerfLastLogTick >= 1000 then
    begin
      DebugLog(Format(
        'Runtime dispatch performance: calls=%d avgMs=%.3f avgLockWaitMs=%.3f maxMs=%.3f objects=%d.',
        [RuntimePerfCallCount,
         RuntimePerfTotalMilliseconds / RuntimePerfCallCount,
         RuntimePerfLockWaitMilliseconds / RuntimePerfCallCount,
         RuntimePerfMaximumMilliseconds, RuntimeStates.Count]));
      RuntimePerfCallCount := 0;
      RuntimePerfLockWaitMilliseconds := 0;
      RuntimePerfTotalMilliseconds := 0;
      RuntimePerfMaximumMilliseconds := 0;
      RuntimePerfLastLogTick := CurrentTick;
    end;
{$ENDIF}
    LeaveCriticalSection(RuntimeLock);
  end;
end;

end.
