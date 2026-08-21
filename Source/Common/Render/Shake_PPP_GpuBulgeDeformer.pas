unit Shake_PPP_GpuBulgeDeformer;

interface

uses
  System.SysUtils,
  AviUtl2FilterTypes,
  Shake_PPP_BulgeSettings,
  Shake_PPP_CurveData,
  Shake_PPP_CurveModel,
  Shake_PPP_StaticDeformer;

type
  TGpuBulgeProcessor = class sealed
  private
    FConstantBuffers: array[0..SHAKE_CURVE_SET_COUNT - 1] of IInterface;
    FDeferredContext: IInterface;
    FDevice: IInterface;
    FFormat: Integer;
    FHeight: Integer;
    FOutputPixels: TBytes;
    FOutputTexture: IInterface;
    FOutputUnorderedView: IInterface;
    FReadbackTexture: IInterface;
    FRgba8Shader: IInterface;
    FSampler: IInterface;
    FShader: IInterface;
    FShakeShader: IInterface;
    FWeightDirty: array[0..SHAKE_CURVE_SET_COUNT - 1] of Boolean;
    FWeightShaderViews: array[0..SHAKE_CURVE_SET_COUNT - 1] of IInterface;
    FWeightTextures: array[0..SHAKE_CURVE_SET_COUNT - 1] of IInterface;
    FWidth: Integer;
    FWorkShaderViews: array[0..1] of IInterface;
    FWorkTextures: array[0..1] of IInterface;
    FWorkUnorderedViews: array[0..1] of IInterface;
{$IFDEF DEBUG}
    FPerfCallCount: Integer;
    FPerfLastLogTick: UInt64;
    FPerfMaximumMilliseconds: Double;
    FPerfTotalMilliseconds: Double;
{$ENDIF}
    procedure ClearDeviceResources;
    function EnsureDeviceResources(SourceTexture: Pointer;
      out ErrorText: string): Boolean;
    function EnsureWeightResource(Index: Integer;
      WeightMap: TShakeDeformationMap; out ErrorText: string): Boolean;
    function ApplyCore(Video: PFILTER_PROC_VIDEO;
      const CurveSets: TShakeCurveSets;
      const Maps: array of TShakeDeformationMap;
      const MapReady: array of Boolean;
      const Settings: TBulgeRuntimeSettings;
      BulgeEnabled, ShakeEnabled, VariableOuter: Boolean;
      DisplacementX, DisplacementY: Double;
      out OutputPixels: Pointer; out ErrorText: string): Boolean;
{$IFDEF DEBUG}
    procedure RecordPerformance(ElapsedMilliseconds: Double);
{$ENDIF}
  public
    constructor Create;
    destructor Destroy; override;
    procedure InvalidateWeights;
    function ApplyToBuffer(Video: PFILTER_PROC_VIDEO;
      const CurveSets: TShakeCurveSets;
      const Maps: array of TShakeDeformationMap;
      const MapReady: array of Boolean;
      const Settings: TBulgeRuntimeSettings;
      out OutputPixels: Pointer; out ErrorText: string): Boolean;
    function Apply(Video: PFILTER_PROC_VIDEO;
      const CurveSets: TShakeCurveSets;
      const Maps: array of TShakeDeformationMap;
      const MapReady: array of Boolean;
      const Settings: TBulgeRuntimeSettings;
      out ErrorText: string): Boolean;
    function ApplyCombined(Video: PFILTER_PROC_VIDEO;
      const CurveSets: TShakeCurveSets;
      const Maps: array of TShakeDeformationMap;
      const MapReady: array of Boolean;
      const Settings: TBulgeRuntimeSettings;
      BulgeEnabled, ShakeEnabled, VariableOuter: Boolean;
      DisplacementX, DisplacementY: Double;
      out ErrorText: string): Boolean;
  end;

implementation

uses
  System.Classes,
  System.Math,
  Winapi.D3D11,
  Winapi.DxgiFormat,
  Winapi.Windows,
  Shake_PPP_DebugLog;

{$R 'Shader\Shake_PPP_BulgeCompute.res'}

type
  TGpuBulgeConstants = packed record
    ImageWidth: Cardinal;
    ImageHeight: Cardinal;
    ActiveLeft: Cardinal;
    ActiveTop: Cardinal;
    ActiveWidth: Cardinal;
    ActiveHeight: Cardinal;
    Padding0: Cardinal;
    Padding1: Cardinal;
    Amount: Single;
    ShapeExponent: Single;
    CenterX: Single;
    CenterY: Single;
    OuterHalfWidth: Single;
    OuterHalfHeight: Single;
    GravityResponse: Single;
    Padding2: Single;
    GravityDirectionX: Single;
    GravityDirectionY: Single;
    OpacityResponse: Single;
    ShadingStrength: Single;
    HighlightStrength: Single;
    LightX: Single;
    LightY: Single;
    LightZ: Single;
    HalfX: Single;
    HalfY: Single;
    HalfZ: Single;
    Padding3: Single;
  end;

const
  THREAD_GROUP_SIZE = 16;

function FailedResult(Value: HRESULT): Boolean; inline;
begin
  Result := Value < 0;
end;

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

constructor TGpuBulgeProcessor.Create;
begin
  inherited Create;
  InvalidateWeights;
end;

destructor TGpuBulgeProcessor.Destroy;
begin
  ClearDeviceResources;
  inherited;
end;

procedure TGpuBulgeProcessor.InvalidateWeights;
var
  I: Integer;
begin
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
    FWeightDirty[I] := True;
end;

procedure TGpuBulgeProcessor.ClearDeviceResources;
var
  I: Integer;
begin
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
  begin
    FWeightShaderViews[I] := nil;
    FWeightTextures[I] := nil;
    FConstantBuffers[I] := nil;
  end;
  for I := 0 to 1 do
  begin
    FWorkUnorderedViews[I] := nil;
    FWorkShaderViews[I] := nil;
    FWorkTextures[I] := nil;
  end;
  FSampler := nil;
  FShader := nil;
  FShakeShader := nil;
  FRgba8Shader := nil;
  FOutputUnorderedView := nil;
  FOutputTexture := nil;
  FReadbackTexture := nil;
  FOutputPixels := nil;
  FDeferredContext := nil;
  FDevice := nil;
  FWidth := 0;
  FHeight := 0;
  FFormat := -1;
  InvalidateWeights;
end;

function TGpuBulgeProcessor.EnsureDeviceResources(SourceTexture: Pointer;
  out ErrorText: string): Boolean;
var
  BufferDesc: TD3D11_BUFFER_DESC;
  ComputeShader: ID3D11ComputeShader;
  ConstantBuffer: ID3D11Buffer;
  DeferredContext: ID3D11DeviceContext;
  Desc: TD3D11_TEXTURE2D_DESC;
  Device: ID3D11Device;
  I: Integer;
  ResourceStream: TResourceStream;
  Rgba8Shader: ID3D11ComputeShader;
  Sampler: ID3D11SamplerState;
  SamplerDesc: TD3D11_SAMPLER_DESC;
  ShaderView: ID3D11ShaderResourceView;
  ShakeShader: ID3D11ComputeShader;
  Source: ID3D11Texture2D;
  Texture: ID3D11Texture2D;
  UnorderedView: ID3D11UnorderedAccessView;
begin
  Result := False;
  ErrorText := '';
  if SourceTexture = nil then
  begin
    ErrorText := 'GPU_INPUT_TEXTURE_NIL';
    Exit;
  end;
  Source := ID3D11Texture2D(SourceTexture);
  Source.GetDesc(Desc);
  Source.GetDevice(Device);
  if Device = nil then
  begin
    ErrorText := 'GPU_DEVICE_NIL';
    Exit;
  end;
  if (Desc.MipLevels <> 1) or (Desc.ArraySize <> 1) or
    (Desc.SampleDesc.Count <> 1) or
    not (Desc.Format in [DXGI_FORMAT_R16G16B16A16_FLOAT,
      DXGI_FORMAT_R8G8B8A8_UNORM]) then
  begin
    ErrorText := Format('GPU_FORMAT_UNSUPPORTED_%d', [Ord(Desc.Format)]);
    Exit;
  end;
  if (FDevice <> nil) and (Pointer(FDevice) = Pointer(Device)) and
    (FWidth = Integer(Desc.Width)) and (FHeight = Integer(Desc.Height)) and
    (FFormat = Ord(Desc.Format)) then
    Exit(True);

  ClearDeviceResources;
  if FailedResult(Device.CreateDeferredContext(0, DeferredContext)) then
  begin
    ErrorText := 'GPU_DEFERRED_CONTEXT_FAILED';
    Exit;
  end;
  try
    ResourceStream := TResourceStream.Create(HInstance, 'BULGE_COMPUTE',
      RT_RCDATA);
    try
      if FailedResult(Device.CreateComputeShader(ResourceStream.Memory,
        ResourceStream.Size, nil, ComputeShader)) then
      begin
        ErrorText := 'GPU_COMPUTE_SHADER_FAILED';
        Exit;
      end;
    finally
      ResourceStream.Free;
    end;
    ResourceStream := TResourceStream.Create(HInstance, 'SHAKE_COMPUTE',
      RT_RCDATA);
    try
      if FailedResult(Device.CreateComputeShader(ResourceStream.Memory,
        ResourceStream.Size, nil, ShakeShader)) then
      begin
        ErrorText := 'GPU_SHAKE_SHADER_FAILED';
        Exit;
      end;
    finally
      ResourceStream.Free;
    end;
    ResourceStream := TResourceStream.Create(HInstance, 'RGBA8_COMPUTE',
      RT_RCDATA);
    try
      if FailedResult(Device.CreateComputeShader(ResourceStream.Memory,
        ResourceStream.Size, nil, Rgba8Shader)) then
      begin
        ErrorText := 'GPU_RGBA8_SHADER_FAILED';
        Exit;
      end;
    finally
      ResourceStream.Free;
    end;

    FillChar(SamplerDesc, SizeOf(SamplerDesc), 0);
    SamplerDesc.Filter := D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    SamplerDesc.AddressU := D3D11_TEXTURE_ADDRESS_CLAMP;
    SamplerDesc.AddressV := D3D11_TEXTURE_ADDRESS_CLAMP;
    SamplerDesc.AddressW := D3D11_TEXTURE_ADDRESS_CLAMP;
    SamplerDesc.MaxAnisotropy := 1;
    SamplerDesc.ComparisonFunc := D3D11_COMPARISON_NEVER;
    SamplerDesc.MaxLOD := 3.402823466e+38;
    if FailedResult(Device.CreateSamplerState(SamplerDesc, Sampler)) then
    begin
      ErrorText := 'GPU_SAMPLER_FAILED';
      Exit;
    end;

    Desc.MipLevels := 1;
    Desc.ArraySize := 1;
    Desc.Usage := D3D11_USAGE_DEFAULT;
    Desc.BindFlags := D3D11_BIND_SHADER_RESOURCE or
      D3D11_BIND_UNORDERED_ACCESS;
    Desc.CPUAccessFlags := 0;
    Desc.MiscFlags := 0;
    for I := 0 to 1 do
    begin
      if FailedResult(Device.CreateTexture2D(Desc, nil, Texture)) then
      begin
        ErrorText := Format('GPU_WORK_TEXTURE_%d_FAILED', [I]);
        Exit;
      end;
      if FailedResult(Device.CreateShaderResourceView(Texture, nil,
        ShaderView)) then
      begin
        ErrorText := Format('GPU_WORK_SRV_%d_FAILED', [I]);
        Exit;
      end;
      if FailedResult(Device.CreateUnorderedAccessView(Texture, nil,
        UnorderedView)) then
      begin
        ErrorText := Format('GPU_WORK_UAV_%d_FAILED', [I]);
        Exit;
      end;
      FWorkTextures[I] := Texture;
      FWorkShaderViews[I] := ShaderView;
      FWorkUnorderedViews[I] := UnorderedView;
    end;

    Desc.Format := DXGI_FORMAT_R8G8B8A8_UNORM;
    Desc.Usage := D3D11_USAGE_DEFAULT;
    Desc.BindFlags := D3D11_BIND_UNORDERED_ACCESS;
    Desc.CPUAccessFlags := 0;
    if FailedResult(Device.CreateTexture2D(Desc, nil, Texture)) then
    begin
      ErrorText := 'GPU_OUTPUT_TEXTURE_FAILED';
      Exit;
    end;
    if FailedResult(Device.CreateUnorderedAccessView(Texture, nil,
      UnorderedView)) then
    begin
      ErrorText := 'GPU_OUTPUT_UAV_FAILED';
      Exit;
    end;
    FOutputTexture := Texture;
    FOutputUnorderedView := UnorderedView;
    Desc.Usage := D3D11_USAGE_STAGING;
    Desc.BindFlags := 0;
    Desc.CPUAccessFlags := D3D11_CPU_ACCESS_READ;
    if FailedResult(Device.CreateTexture2D(Desc, nil, Texture)) then
    begin
      ErrorText := 'GPU_READBACK_TEXTURE_FAILED';
      Exit;
    end;
    FReadbackTexture := Texture;
    SetLength(FOutputPixels, Desc.Width * Desc.Height * 4);

    FillChar(BufferDesc, SizeOf(BufferDesc), 0);
    BufferDesc.ByteWidth := SizeOf(TGpuBulgeConstants);
    BufferDesc.Usage := D3D11_USAGE_DEFAULT;
    BufferDesc.BindFlags := D3D11_BIND_CONSTANT_BUFFER;
    for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
    begin
      if FailedResult(Device.CreateBuffer(BufferDesc, nil,
        ConstantBuffer)) then
      begin
        ErrorText := Format('GPU_CONSTANT_BUFFER_%d_FAILED', [I]);
        Exit;
      end;
      FConstantBuffers[I] := ConstantBuffer;
    end;

    FDevice := Device;
    FDeferredContext := DeferredContext;
    FShader := ComputeShader;
    FShakeShader := ShakeShader;
    FRgba8Shader := Rgba8Shader;
    FSampler := Sampler;
    FWidth := Desc.Width;
    FHeight := Desc.Height;
    FFormat := Ord(Desc.Format);
    InvalidateWeights;
    Result := True;
  except
    on E: Exception do
    begin
      ErrorText := 'GPU_INIT_' + E.ClassName + '_' + E.Message;
      ClearDeviceResources;
    end;
  end;
end;

function TGpuBulgeProcessor.EnsureWeightResource(Index: Integer;
  WeightMap: TShakeDeformationMap; out ErrorText: string): Boolean;
var
  Desc: TD3D11_TEXTURE2D_DESC;
  Device: ID3D11Device;
  InitialData: TD3D11_SUBRESOURCE_DATA;
  ShaderView: ID3D11ShaderResourceView;
  Texture: ID3D11Texture2D;
  Weights: TArray<Single>;
begin
  Result := False;
  ErrorText := '';
  if (Index < 0) or (Index >= SHAKE_CURVE_SET_COUNT) or
    (WeightMap = nil) then
  begin
    ErrorText := 'GPU_WEIGHT_ARGUMENT';
    Exit;
  end;
  if not FWeightDirty[Index] and (FWeightTextures[Index] <> nil) then
    Exit(True);
  Device := ID3D11Device(FDevice);
  WeightMap.CopyScreenWeightsToSingles(Weights);
  if Length(Weights) <> FWidth * FHeight then
  begin
    ErrorText := 'GPU_WEIGHT_SIZE';
    Exit;
  end;
  FillChar(Desc, SizeOf(Desc), 0);
  Desc.Width := FWidth;
  Desc.Height := FHeight;
  Desc.MipLevels := 1;
  Desc.ArraySize := 1;
  Desc.Format := DXGI_FORMAT_R32_FLOAT;
  Desc.SampleDesc.Count := 1;
  Desc.Usage := D3D11_USAGE_DEFAULT;
  Desc.BindFlags := D3D11_BIND_SHADER_RESOURCE;
  FillChar(InitialData, SizeOf(InitialData), 0);
  InitialData.pSysMem := @Weights[0];
  InitialData.SysMemPitch := FWidth * SizeOf(Single);
  if FailedResult(Device.CreateTexture2D(Desc, @InitialData, Texture)) or
    FailedResult(Device.CreateShaderResourceView(Texture, nil,
      ShaderView)) then
  begin
    ErrorText := Format('GPU_WEIGHT_RESOURCE_%d_FAILED', [Index]);
    Exit;
  end;
  FWeightTextures[Index] := Texture;
  FWeightShaderViews[Index] := ShaderView;
  FWeightDirty[Index] := False;
  Result := True;
end;

{$IFDEF DEBUG}
procedure TGpuBulgeProcessor.RecordPerformance(ElapsedMilliseconds: Double);
var
  CurrentTick: UInt64;
begin
  Inc(FPerfCallCount);
  FPerfTotalMilliseconds := FPerfTotalMilliseconds + ElapsedMilliseconds;
  FPerfMaximumMilliseconds := Max(FPerfMaximumMilliseconds,
    ElapsedMilliseconds);
  CurrentTick := GetTickCount64;
  if FPerfLastLogTick = 0 then
    FPerfLastLogTick := CurrentTick
  else if CurrentTick - FPerfLastLogTick >= 1000 then
  begin
    DebugLog(Format(
      'Runtime GPU performance: calls=%d avgCpuRoundTripMs=%.3f maxCpuRoundTripMs=%.3f size=%dx%d.',
      [FPerfCallCount, FPerfTotalMilliseconds / FPerfCallCount,
       FPerfMaximumMilliseconds, FWidth, FHeight]));
    FPerfCallCount := 0;
    FPerfTotalMilliseconds := 0;
    FPerfMaximumMilliseconds := 0;
    FPerfLastLogTick := CurrentTick;
  end;
end;
{$ENDIF}

function TGpuBulgeProcessor.ApplyCore(Video: PFILTER_PROC_VIDEO;
  const CurveSets: TShakeCurveSets;
  const Maps: array of TShakeDeformationMap;
  const MapReady: array of Boolean;
  const Settings: TBulgeRuntimeSettings;
  BulgeEnabled, ShakeEnabled, VariableOuter: Boolean;
  DisplacementX, DisplacementY: Double;
  out OutputPixels: Pointer; out ErrorText: string): Boolean;
var
  AffectedBottom: Integer;
  AffectedLeft: Integer;
  AffectedRight: Integer;
  AffectedTop: Integer;
  BaseCenterX: Double;
  BaseCenterY: Double;
  CommandList: ID3D11CommandList;
  Constants: TGpuBulgeConstants;
  ConstantBuffer: ID3D11Buffer;
  Context: ID3D11DeviceContext;
  CurrentIndex: Integer;
  Device: ID3D11Device;
  DirectionRadians: Double;
  GravityResponse: Double;
  HalfLength: Double;
  I: Integer;
  ImmediateContext: ID3D11DeviceContext;
  Mapped: TD3D11_MAPPED_SUBRESOURCE;
  NextIndex: Integer;
  NoClassInstance: ID3D11ClassInstance;
  NoShaderView: ID3D11ShaderResourceView;
  NoUnorderedView: ID3D11UnorderedAccessView;
  OuterHalfHeight: Double;
  OuterHalfWidth: Double;
  Rgba8Shader: ID3D11ComputeShader;
  Sampler: ID3D11SamplerState;
  Shader: ID3D11ComputeShader;
  ShakeShader: ID3D11ComputeShader;
  ShaderViews: array[0..1] of ID3D11ShaderResourceView;
  SourceTexture: Pointer;
  Source: ID3D11Texture2D;
  UnorderedView: ID3D11UnorderedAccessView;
  Y: Integer;
  ShiftX: Double;
  ShiftY: Double;
{$IFDEF DEBUG}
  StartedAt: Int64;
{$ENDIF}
begin
  Result := False;
  OutputPixels := nil;
  ErrorText := '';
{$IFDEF DEBUG}
  StartedAt := DebugTimerStart;
{$ENDIF}
  if (Video = nil) or not Assigned(Video^.GetImageTexture2D) then
  begin
    ErrorText := 'GPU_TEXTURE_CALLBACK_UNAVAILABLE';
    Exit;
  end;
  SourceTexture := Video^.GetImageTexture2D();
  if not EnsureDeviceResources(SourceTexture, ErrorText) then
    Exit;
  Source := ID3D11Texture2D(SourceTexture);

  Context := ID3D11DeviceContext(FDeferredContext);
  Device := ID3D11Device(FDevice);
  Shader := ID3D11ComputeShader(FShader);
  ShakeShader := ID3D11ComputeShader(FShakeShader);
  Rgba8Shader := ID3D11ComputeShader(FRgba8Shader);
  Sampler := ID3D11SamplerState(FSampler);
  Context.ClearState;
  Context.CopyResource(ID3D11Resource(FWorkTextures[0]), Source);
  CurrentIndex := 0;
  if BulgeEnabled then
    for I := 0 to Min(High(Maps), SHAKE_CURVE_SET_COUNT - 1) do
      if (I <= High(MapReady)) and MapReady[I] then
    begin
      if not EnsureWeightResource(I, Maps[I], ErrorText) then
        Exit;
      NextIndex := 1 - CurrentIndex;
      Context.CopyResource(ID3D11Resource(FWorkTextures[NextIndex]),
        ID3D11Resource(FWorkTextures[CurrentIndex]));
      FillChar(Constants, SizeOf(Constants), 0);
      Constants.ImageWidth := FWidth;
      Constants.ImageHeight := FHeight;
      Constants.ActiveLeft := Maps[I].ActiveLeft;
      Constants.ActiveTop := Maps[I].ActiveTop;
      Constants.ActiveWidth := Maps[I].ActiveRight - Maps[I].ActiveLeft + 1;
      Constants.ActiveHeight := Maps[I].ActiveBottom - Maps[I].ActiveTop + 1;
      Constants.Amount := Settings.Amount;
      Constants.ShapeExponent := Power(2.0,
        (0.5 - EnsureRange(Settings.Shape, 0.0, 1.0)) * 2.0);
      CalculateGeometry(FWidth, FHeight, CurveSets[I].OuterContour,
        CurveSets[I].CenterContour, BaseCenterX, BaseCenterY,
        OuterHalfWidth, OuterHalfHeight);
      Constants.CenterX := EnsureRange(BaseCenterX + Settings.CenterX *
        OuterHalfWidth, 0.0, FWidth - 1.0);
      Constants.CenterY := EnsureRange(BaseCenterY + Settings.CenterY *
        OuterHalfHeight, 0.0, FHeight - 1.0);
      Constants.OuterHalfWidth := OuterHalfWidth;
      Constants.OuterHalfHeight := OuterHalfHeight;
      GravityResponse := EnsureRange(Settings.Gravity, 0.0, 1.0) *
        (0.5 + EnsureRange(Settings.Mass, 0.0, 1.0)) *
        (1.5 - EnsureRange(Settings.Tension, 0.0, 1.0));
      Constants.GravityResponse := EnsureRange(GravityResponse, 0.0, 2.0);
      DirectionRadians := DegToRad(Settings.GravityDirection);
      Constants.GravityDirectionX := Cos(DirectionRadians);
      Constants.GravityDirectionY := Sin(DirectionRadians);
      Constants.OpacityResponse := EnsureRange(Settings.OpacityResponse,
        0.0, 1.0);
      Constants.ShadingStrength := EnsureRange(Settings.ShadingStrength,
        0.0, 1.0);
      Constants.HighlightStrength := EnsureRange(Settings.HighlightStrength,
        0.0, 1.0);
      DirectionRadians := DegToRad(Settings.LightDirection);
      Constants.LightX := Cos(DirectionRadians) * 0.7071067811865475;
      Constants.LightY := Sin(DirectionRadians) * 0.7071067811865475;
      Constants.LightZ := 0.7071067811865475;
      Constants.HalfX := Constants.LightX;
      Constants.HalfY := Constants.LightY;
      Constants.HalfZ := Constants.LightZ + 1.0;
      HalfLength := Sqrt(Constants.HalfX * Constants.HalfX +
        Constants.HalfY * Constants.HalfY +
        Constants.HalfZ * Constants.HalfZ);
      Constants.HalfX := Constants.HalfX / HalfLength;
      Constants.HalfY := Constants.HalfY / HalfLength;
      Constants.HalfZ := Constants.HalfZ / HalfLength;
      ConstantBuffer := ID3D11Buffer(FConstantBuffers[I]);
      Context.UpdateSubresource(ConstantBuffer, 0, nil, @Constants, 0, 0);
      ShaderViews[0] := ID3D11ShaderResourceView(
        FWorkShaderViews[CurrentIndex]);
      ShaderViews[1] := ID3D11ShaderResourceView(FWeightShaderViews[I]);
      UnorderedView := ID3D11UnorderedAccessView(
        FWorkUnorderedViews[NextIndex]);
      Context.CSSetShader(Shader, NoClassInstance, 0);
      Context.CSSetShaderResources(0, 2, ShaderViews[0]);
      Context.CSSetUnorderedAccessViews(0, 1, UnorderedView, nil);
      Context.CSSetSamplers(0, 1, Sampler);
      Context.CSSetConstantBuffers(0, 1, ConstantBuffer);
      Context.Dispatch((Constants.ActiveWidth + THREAD_GROUP_SIZE - 1) div
        THREAD_GROUP_SIZE,
        (Constants.ActiveHeight + THREAD_GROUP_SIZE - 1) div
        THREAD_GROUP_SIZE, 1);
      Context.CSSetShaderResources(0, 1, NoShaderView);
      Context.CSSetUnorderedAccessViews(0, 1, NoUnorderedView, nil);
      CurrentIndex := NextIndex;
    end;
  if ShakeEnabled then
    for I := 0 to Min(High(Maps), SHAKE_CURVE_SET_COUNT - 1) do
      if (I <= High(MapReady)) and MapReady[I] then
      begin
        if not EnsureWeightResource(I, Maps[I], ErrorText) then
          Exit;
        NextIndex := 1 - CurrentIndex;
        Context.CopyResource(ID3D11Resource(FWorkTextures[NextIndex]),
          ID3D11Resource(FWorkTextures[CurrentIndex]));
        if VariableOuter then
        begin
          ShiftX := DisplacementX * 0.35;
          ShiftY := DisplacementY * 0.35;
          AffectedLeft := EnsureRange(Maps[I].ActiveLeft +
            Floor(Min(0.0, ShiftX)), 0, FWidth - 1);
          AffectedTop := EnsureRange(Maps[I].ActiveTop +
            Floor(Min(0.0, ShiftY)), 0, FHeight - 1);
          AffectedRight := EnsureRange(Maps[I].ActiveRight +
            Ceil(Max(0.0, ShiftX)), 0, FWidth - 1);
          AffectedBottom := EnsureRange(Maps[I].ActiveBottom +
            Ceil(Max(0.0, ShiftY)), 0, FHeight - 1);
        end
        else
        begin
          AffectedLeft := Maps[I].ActiveLeft;
          AffectedTop := Maps[I].ActiveTop;
          AffectedRight := Maps[I].ActiveRight;
          AffectedBottom := Maps[I].ActiveBottom;
        end;
        FillChar(Constants, SizeOf(Constants), 0);
        Constants.ImageWidth := FWidth;
        Constants.ImageHeight := FHeight;
        Constants.ActiveLeft := AffectedLeft;
        Constants.ActiveTop := AffectedTop;
        Constants.ActiveWidth := AffectedRight - AffectedLeft + 1;
        Constants.ActiveHeight := AffectedBottom - AffectedTop + 1;
        Constants.Amount := DisplacementX;
        Constants.ShapeExponent := DisplacementY;
        Constants.CenterX := Ord(VariableOuter);
        ConstantBuffer := ID3D11Buffer(FConstantBuffers[I]);
        Context.UpdateSubresource(ConstantBuffer, 0, nil, @Constants, 0, 0);
        ShaderViews[0] := ID3D11ShaderResourceView(
          FWorkShaderViews[CurrentIndex]);
        ShaderViews[1] := ID3D11ShaderResourceView(FWeightShaderViews[I]);
        UnorderedView := ID3D11UnorderedAccessView(
          FWorkUnorderedViews[NextIndex]);
        Context.CSSetShader(ShakeShader, NoClassInstance, 0);
        Context.CSSetShaderResources(0, 2, ShaderViews[0]);
        Context.CSSetUnorderedAccessViews(0, 1, UnorderedView, nil);
        Context.CSSetSamplers(0, 1, Sampler);
        Context.CSSetConstantBuffers(0, 1, ConstantBuffer);
        Context.Dispatch((Constants.ActiveWidth + THREAD_GROUP_SIZE - 1) div
          THREAD_GROUP_SIZE,
          (Constants.ActiveHeight + THREAD_GROUP_SIZE - 1) div
          THREAD_GROUP_SIZE, 1);
        Context.CSSetShaderResources(0, 1, NoShaderView);
        Context.CSSetShaderResources(1, 1, NoShaderView);
        Context.CSSetUnorderedAccessViews(0, 1, NoUnorderedView, nil);
        CurrentIndex := NextIndex;
      end;
  FillChar(Constants, SizeOf(Constants), 0);
  Constants.ImageWidth := FWidth;
  Constants.ImageHeight := FHeight;
  ConstantBuffer := ID3D11Buffer(FConstantBuffers[0]);
  Context.UpdateSubresource(ConstantBuffer, 0, nil, @Constants, 0, 0);
  ShaderViews[0] := ID3D11ShaderResourceView(
    FWorkShaderViews[CurrentIndex]);
  UnorderedView := ID3D11UnorderedAccessView(FOutputUnorderedView);
  Context.CSSetShader(Rgba8Shader, NoClassInstance, 0);
  Context.CSSetShaderResources(0, 1, ShaderViews[0]);
  Context.CSSetUnorderedAccessViews(0, 1, UnorderedView, nil);
  Context.CSSetConstantBuffers(0, 1, ConstantBuffer);
  Context.Dispatch((FWidth + THREAD_GROUP_SIZE - 1) div THREAD_GROUP_SIZE,
    (FHeight + THREAD_GROUP_SIZE - 1) div THREAD_GROUP_SIZE, 1);
  Context.CSSetShaderResources(0, 1, NoShaderView);
  Context.CSSetUnorderedAccessViews(0, 1, NoUnorderedView, nil);
  Context.CopyResource(ID3D11Resource(FReadbackTexture),
    ID3D11Resource(FOutputTexture));
  if FailedResult(Context.FinishCommandList(False, CommandList)) then
  begin
    ErrorText := 'GPU_COMMAND_LIST_FAILED';
    Exit;
  end;
  Device.GetImmediateContext(ImmediateContext);
  if ImmediateContext = nil then
  begin
    ErrorText := 'GPU_IMMEDIATE_CONTEXT_NIL';
    Exit;
  end;
  ImmediateContext.ExecuteCommandList(CommandList, True);
  FillChar(Mapped, SizeOf(Mapped), 0);
  if FailedResult(ImmediateContext.Map(ID3D11Resource(FReadbackTexture), 0,
    D3D11_MAP_READ, 0, Mapped)) then
  begin
    ErrorText := 'GPU_READBACK_MAP_FAILED';
    Exit;
  end;
  try
    for Y := 0 to FHeight - 1 do
      Move(PByte(Mapped.pData)[NativeInt(Y) * Mapped.RowPitch],
        FOutputPixels[NativeInt(Y) * FWidth * 4], FWidth * 4);
  finally
    ImmediateContext.Unmap(ID3D11Resource(FReadbackTexture), 0);
  end;
  OutputPixels := @FOutputPixels[0];
{$IFDEF DEBUG}
  RecordPerformance(DebugTimerElapsedMilliseconds(StartedAt));
{$ENDIF}
  Result := True;
end;

function TGpuBulgeProcessor.ApplyToBuffer(Video: PFILTER_PROC_VIDEO;
  const CurveSets: TShakeCurveSets;
  const Maps: array of TShakeDeformationMap;
  const MapReady: array of Boolean;
  const Settings: TBulgeRuntimeSettings;
  out OutputPixels: Pointer; out ErrorText: string): Boolean;
begin
  Result := ApplyCore(Video, CurveSets, Maps, MapReady, Settings,
    True, False, False, 0, 0, OutputPixels, ErrorText);
end;

function TGpuBulgeProcessor.Apply(Video: PFILTER_PROC_VIDEO;
  const CurveSets: TShakeCurveSets;
  const Maps: array of TShakeDeformationMap;
  const MapReady: array of Boolean;
  const Settings: TBulgeRuntimeSettings;
  out ErrorText: string): Boolean;
var
  OutputPixels: Pointer;
begin
  Result := False;
  if (Video = nil) or not Assigned(Video^.SetImageData) then
  begin
    ErrorText := 'GPU_OUTPUT_CALLBACK_UNAVAILABLE';
    Exit;
  end;
  if not ApplyToBuffer(Video, CurveSets, Maps, MapReady, Settings,
    OutputPixels, ErrorText) then
    Exit;
  Video^.SetImageData(PPIXEL_RGBA(OutputPixels), FWidth, FHeight);
  Result := True;
end;

function TGpuBulgeProcessor.ApplyCombined(Video: PFILTER_PROC_VIDEO;
  const CurveSets: TShakeCurveSets;
  const Maps: array of TShakeDeformationMap;
  const MapReady: array of Boolean;
  const Settings: TBulgeRuntimeSettings;
  BulgeEnabled, ShakeEnabled, VariableOuter: Boolean;
  DisplacementX, DisplacementY: Double;
  out ErrorText: string): Boolean;
var
  OutputPixels: Pointer;
begin
  Result := False;
  if (Video = nil) or not Assigned(Video^.SetImageData) then
  begin
    ErrorText := 'GPU_OUTPUT_CALLBACK_UNAVAILABLE';
    Exit;
  end;
  if not ApplyCore(Video, CurveSets, Maps, MapReady, Settings,
    BulgeEnabled, ShakeEnabled, VariableOuter, DisplacementX,
    DisplacementY, OutputPixels, ErrorText) then
    Exit;
  Video^.SetImageData(PPIXEL_RGBA(OutputPixels), FWidth, FHeight);
  Result := True;
end;

end.
