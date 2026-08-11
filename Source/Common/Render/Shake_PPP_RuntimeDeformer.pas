unit Shake_PPP_RuntimeDeformer;

// Applies the two saved curve sets to AviUtl2 frames using a damped follower.

interface

uses
  AviUtl2FilterTypes,
  Shake_PPP_FilterSettings;

procedure InitializeRuntimeDeformer;
procedure FinalizeRuntimeDeformer;
procedure ApplyRuntimeDeformation(Video: PFILTER_PROC_VIDEO;
  const CurveDataText: string; const Settings: TShakeRuntimeSettings);

implementation

uses
  System.Generics.Collections,
  System.Math,
  System.SysUtils,
  Winapi.Windows,
  Shake_PPP_CurveData,
  Shake_PPP_CurveModel,
  Shake_PPP_DebugLog,
  Shake_PPP_StaticDeformer;

const
  MAX_CONTINUOUS_FRAME_GAP = 10;

type
  TShakeObjectState = class
  private
    FCurveDataText: string;
    FCurveSets: TShakeCurveSets;
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
    FPerfDeformMilliseconds: array[0..SHAKE_CURVE_SET_COUNT - 1] of Double;
    FPerfFrameCount: Integer;
    FPerfGetImageMilliseconds: Double;
    FPerfLastLogTick: UInt64;
    FPerfMaximumTotalMilliseconds: Double;
    FPerfSetImageMilliseconds: Double;
    FPerfTotalMilliseconds: Double;
    procedure RecordPerformance(Video: PFILTER_PROC_VIDEO;
      BufferMilliseconds, GetImageMilliseconds: Double;
      const DeformMilliseconds: array of Double;
      SetImageMilliseconds, TotalMilliseconds: Double);
{$ENDIF}
    procedure AdvanceMotion(Frame: Integer;
      const Settings: TShakeRuntimeSettings);
    procedure ApplyDeformation(Video: PFILTER_PROC_VIDEO;
      const CurveDataText: string; Width, Height: Integer;
      DisplacementX, DisplacementY: Double;
      DeformationType: TShakeDeformationType);
    function PrepareMaps(Width, Height: Integer;
      const CurveDataText: string): Boolean;
    procedure ResetMotion(Frame: Integer; PositionX, PositionY: Double);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Apply(Video: PFILTER_PROC_VIDEO; const CurveDataText: string;
      const Settings: TShakeRuntimeSettings);
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
  const DeformMilliseconds: array of Double;
  SetImageMilliseconds, TotalMilliseconds: Double);
var
  CurrentTick: UInt64;
  I: Integer;
begin
  Inc(FPerfFrameCount);
  FPerfBufferMilliseconds := FPerfBufferMilliseconds + BufferMilliseconds;
  FPerfGetImageMilliseconds := FPerfGetImageMilliseconds +
    GetImageMilliseconds;
  for I := 0 to Min(High(DeformMilliseconds),
    SHAKE_CURVE_SET_COUNT - 1) do
    FPerfDeformMilliseconds[I] := FPerfDeformMilliseconds[I] +
      DeformMilliseconds[I];
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
    'Runtime performance: objectId=%d effectId=%d frames=%d size=%dx%d avgMs(total=%.3f buffer=%.3f getImage=%.3f deform1=%.3f deform2=%.3f setImage=%.3f) maxTotalMs=%.3f.',
    [Video^.Object_^.ID, Video^.Object_^.EffectID, FPerfFrameCount,
     FWidth, FHeight, FPerfTotalMilliseconds / FPerfFrameCount,
     FPerfBufferMilliseconds / FPerfFrameCount,
     FPerfGetImageMilliseconds / FPerfFrameCount,
     FPerfDeformMilliseconds[0] / FPerfFrameCount,
     FPerfDeformMilliseconds[1] / FPerfFrameCount,
     FPerfSetImageMilliseconds / FPerfFrameCount,
     FPerfMaximumTotalMilliseconds]));
  FPerfFrameCount := 0;
  FPerfBufferMilliseconds := 0;
  FPerfGetImageMilliseconds := 0;
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
    FPerfDeformMilliseconds[I] := 0;
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
  DeformationType: TShakeDeformationType);
var
  ByteCount: NativeInt;
  CurrentSource: Pointer;
  ErrorText: string;
  I: Integer;
  LastReadySet: Integer;
  NextDestination: Pointer;
  Succeeded: Boolean;
{$IFDEF DEBUG}
  BufferMilliseconds: Double;
  DeformMilliseconds: array[0..SHAKE_CURVE_SET_COUNT - 1] of Double;
  GetImageMilliseconds: Double;
  PerfStageStarted: Int64;
  PerfTotalStarted: Int64;
  SetImageMilliseconds: Double;
  TotalMilliseconds: Double;
{$ENDIF}
begin
  if not PrepareMaps(Width, Height, CurveDataText) then
    Exit;
{$IFDEF DEBUG}
  PerfTotalStarted := DebugTimerStart;
  PerfStageStarted := DebugTimerStart;
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
    DeformMilliseconds[I] := 0;
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
{$IFDEF DEBUG}
  GetImageMilliseconds := DebugTimerElapsedMilliseconds(PerfStageStarted);
{$ENDIF}
  CurrentSource := @FSource[0];
  LastReadySet := -1;
  for I := SHAKE_CURVE_SET_COUNT - 1 downto 0 do
    if FMapReady[I] then
    begin
      LastReadySet := I;
      Break;
    end;
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
    if FMapReady[I] then
    begin
      if I = LastReadySet then
        NextDestination := @FOutput[0]
      else
        NextDestination := @FWork[0];
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
        DebugLog(Format('Runtime deformation set %d failed: %s.',
          [I + 1, ErrorText]));
        Exit;
      end;
{$IFDEF DEBUG}
      DeformMilliseconds[I] :=
        DebugTimerElapsedMilliseconds(PerfStageStarted);
{$ENDIF}
      CurrentSource := NextDestination;
    end;
{$IFDEF DEBUG}
  PerfStageStarted := DebugTimerStart;
{$ENDIF}
  Video^.SetImageData(PPIXEL_RGBA(@FOutput[0]), Width, Height);
{$IFDEF DEBUG}
  SetImageMilliseconds := DebugTimerElapsedMilliseconds(PerfStageStarted);
  TotalMilliseconds := DebugTimerElapsedMilliseconds(PerfTotalStarted);
  RecordPerformance(Video, BufferMilliseconds, GetImageMilliseconds,
    DeformMilliseconds, SetImageMilliseconds, TotalMilliseconds);
{$ENDIF}
end;

procedure TShakeObjectState.Apply(Video: PFILTER_PROC_VIDEO;
  const CurveDataText: string; const Settings: TShakeRuntimeSettings);
var
  DisplacementX: Double;
  DisplacementY: Double;
  Frame: Integer;
  Height: Integer;
  Width: Integer;
begin
  if (Video = nil) or (Video^.Object_ = nil) or
    not Assigned(Video^.GetImageData) or
    not Assigned(Video^.SetImageData) then
    Exit;
  Width := Video^.Object_^.Width;
  Height := Video^.Object_^.Height;
  Frame := Video^.Object_^.Frame;
  if (Width <= 0) or (Height <= 0) or
    (NativeInt(Width) > High(NativeInt) div Height div 4) then
    Exit;

  if not Settings.TimeAxisEnabled then
  begin
    ResetMotion(Frame, Settings.PositionX, Settings.PositionY);
    Exit;
  end;
  AdvanceMotion(Frame, Settings);
  DisplacementX := EnsureRange(FOffsetX * Settings.HorizontalInfluence,
    -Settings.MaximumDeformation, Settings.MaximumDeformation);
  DisplacementY := EnsureRange(FOffsetY * Settings.VerticalInfluence,
    -Settings.MaximumDeformation, Settings.MaximumDeformation);
  if SameValue(DisplacementX, 0, 0.005) and
    SameValue(DisplacementY, 0, 0.005) then
    Exit;

  case Settings.DeformationType of
    sdtFixedOuter, sdtVariableOuter:
      ApplyDeformation(Video, CurveDataText, Width, Height,
        DisplacementX, DisplacementY, Settings.DeformationType);
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
  const CurveDataText: string; const Settings: TShakeRuntimeSettings);
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
    State.Apply(Video, CurveDataText, Settings);
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
