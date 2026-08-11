unit Shake_PPP_LastFrameCapture;

// Keeps the most recent composited AviUtl2 framebuffer for the settings preview.

interface

uses
  System.SysUtils,
  AviUtl2FilterTypes;

procedure InitializeLastFrameCapture;
procedure FinalizeLastFrameCapture;
procedure CaptureLastFrame(Video: PFILTER_PROC_VIDEO);
function CopyLastFrame(out Pixels: TBytes; out Width, Height: Integer;
  out Status: string): Boolean;

implementation

uses
  System.Math,
  Shake_PPP_DebugLog,
  Winapi.D3D11,
  Winapi.DXGIFormat,
  Winapi.Windows;

const
  MAX_CAPTURE_DIMENSION = 16384;

type
  TPixelWords = array[0..3] of Word;
  PPixelWords = ^TPixelWords;

var
  CaptureBuffer: Pointer;
  CaptureBufferSize: NativeInt;
  CaptureDevice: ID3D11Device;
  CaptureFormat: DXGI_FORMAT;
  CaptureHeight: Integer;
  CaptureInitialized: Boolean;
  CaptureLock: TRTLCriticalSection;
  CaptureStagingTexture: ID3D11Texture2D;
  CaptureStatus: string;
  CaptureWidth: Integer;
  LoggedCaptureSignature: string;
{$IFDEF DEBUG}
  CapturePerfCount: Integer;
  CapturePerfLastLogTick: UInt64;
  CapturePerfMaximumMilliseconds: Double;
  CapturePerfTotalMilliseconds: Double;
{$ENDIF}

function BytesPerPixel(Format: DXGI_FORMAT): Integer;
begin
  case Format of
    DXGI_FORMAT_R8G8B8A8_UNORM,
    DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
    DXGI_FORMAT_B8G8R8A8_UNORM,
    DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
      Result := 4;
    DXGI_FORMAT_R16G16B16A16_UNORM,
    DXGI_FORMAT_R16G16B16A16_FLOAT:
      Result := 8;
  else
    Result := 0;
  end;
end;

function HalfToSingle(Value: Word): Single;
var
  Exponent: Integer;
  Mantissa: Cardinal;
  ResultBits: Cardinal;
  SignBits: Cardinal;
begin
  SignBits := Cardinal(Value and $8000) shl 16;
  Exponent := (Value shr 10) and $1F;
  Mantissa := Value and $03FF;
  if Exponent = 0 then
  begin
    if Mantissa = 0 then
      ResultBits := SignBits
    else
    begin
      Exponent := -14;
      while (Mantissa and $0400) = 0 do
      begin
        Mantissa := Mantissa shl 1;
        Dec(Exponent);
      end;
      Mantissa := Mantissa and $03FF;
      ResultBits := SignBits or Cardinal(Exponent + 127) shl 23 or
        Mantissa shl 13;
    end;
  end
  else if Exponent = $1F then
    ResultBits := SignBits or $7F800000 or Mantissa shl 13
  else
    ResultBits := SignBits or Cardinal(Exponent + 112) shl 23 or
      Mantissa shl 13;
  Result := PSingle(@ResultBits)^;
end;

function FloatToByte(Value: Single): Byte;
begin
  if IsNan(Value) or (Value <= 0) then
    Exit(0);
  if Value >= 1 then
    Exit(255);
  Result := Round(Value * 255);
end;

procedure ResetCaptureResources;
begin
  CaptureStagingTexture := nil;
  CaptureDevice := nil;
end;

procedure SetCaptureError(const Value: string);
begin
  if CaptureStatus <> Value then
    DebugLog('Capture error: ' + Value);
  CaptureWidth := 0;
  CaptureHeight := 0;
  CaptureBufferSize := 0;
  CaptureStatus := Value;
end;

procedure InitializeLastFrameCapture;
begin
  if CaptureInitialized then
    Exit;
  InitializeCriticalSection(CaptureLock);
  CaptureBuffer := nil;
  CaptureBufferSize := 0;
  CaptureWidth := 0;
  CaptureHeight := 0;
  CaptureStatus := 'No framebuffer has been captured.';
  LoggedCaptureSignature := '';
{$IFDEF DEBUG}
  CapturePerfCount := 0;
  CapturePerfLastLogTick := 0;
  CapturePerfMaximumMilliseconds := 0;
  CapturePerfTotalMilliseconds := 0;
{$ENDIF}
  CaptureInitialized := True;
  DebugLog('Frame capture initialized.');
end;

procedure FinalizeLastFrameCapture;
begin
  if not CaptureInitialized then
    Exit;
  EnterCriticalSection(CaptureLock);
  try
    ResetCaptureResources;
    FreeMem(CaptureBuffer);
    CaptureBuffer := nil;
    CaptureBufferSize := 0;
    CaptureWidth := 0;
    CaptureHeight := 0;
  finally
    LeaveCriticalSection(CaptureLock);
  end;
  DeleteCriticalSection(CaptureLock);
  CaptureInitialized := False;
  DebugLog('Frame capture finalized.');
end;

procedure CaptureLastFrame(Video: PFILTER_PROC_VIDEO);
var
  ByteCount: NativeInt;
  Context: ID3D11DeviceContext;
  Destination: PByte;
  Device: ID3D11Device;
  Height: Integer;
  Mapped: D3D11_MAPPED_SUBRESOURCE;
  RowBytes: NativeInt;
  Source: PByte;
  SourceDesc: D3D11_TEXTURE2D_DESC;
  SourcePointer: Pointer;
  SourceKind: string;
  SourceTexture: ID3D11Texture2D;
  StagingDesc: D3D11_TEXTURE2D_DESC;
  Width: Integer;
  Y: Integer;
  CaptureSignature: string;
{$IFDEF DEBUG}
  CaptureElapsedMilliseconds: Double;
  CapturePerfStarted: Int64;
  CurrentTick: UInt64;
{$ENDIF}
begin
  if not CaptureInitialized then
    Exit;

{$IFDEF DEBUG}
  CapturePerfStarted := DebugTimerStart;
{$ENDIF}
  EnterCriticalSection(CaptureLock);
  try
    try
      if Video = nil then
      begin
        SetCaptureError('Video context is unavailable.');
        Exit;
      end;
      SourcePointer := nil;
      SourceKind := '';
      if Assigned(Video^.GetImageTexture2D) then
      begin
        SourcePointer := Video^.GetImageTexture2D();
        SourceKind := 'input image';
      end;
      if (SourcePointer = nil) and
        Assigned(Video^.GetFramebufferTexture2D) then
      begin
        SourcePointer := Video^.GetFramebufferTexture2D();
        SourceKind := 'framebuffer fallback';
      end;
      if SourcePointer = nil then
      begin
        SetCaptureError('Input image texture is unavailable.');
        Exit;
      end;

      SourceTexture := ID3D11Texture2D(SourcePointer);
      SourceTexture.GetDesc(SourceDesc);
      Width := SourceDesc.Width;
      Height := SourceDesc.Height;
      RowBytes := NativeInt(Width) * BytesPerPixel(SourceDesc.Format);
      if (Width <= 0) or (Height <= 0) or
        (Width > MAX_CAPTURE_DIMENSION) or
        (Height > MAX_CAPTURE_DIMENSION) then
      begin
        SetCaptureError(Format('Invalid framebuffer size: %d x %d.',
          [Width, Height]));
        Exit;
      end;
      if RowBytes = 0 then
      begin
        SetCaptureError(Format('Unsupported framebuffer DXGI format: %d.',
          [Ord(SourceDesc.Format)]));
        Exit;
      end;
      if SourceDesc.SampleDesc.Count <> 1 then
      begin
        SetCaptureError(Format('Unsupported framebuffer sample count: %d.',
          [SourceDesc.SampleDesc.Count]));
        Exit;
      end;

      SourceTexture.GetDevice(Device);
      if Device = nil then
      begin
        SetCaptureError('Framebuffer device is unavailable.');
        Exit;
      end;
      if (CaptureStagingTexture = nil) or
        (Pointer(CaptureDevice) <> Pointer(Device)) or
        (CaptureWidth <> Width) or (CaptureHeight <> Height) or
        (CaptureFormat <> SourceDesc.Format) then
      begin
        ResetCaptureResources;
        StagingDesc := SourceDesc;
        StagingDesc.MipLevels := 1;
        StagingDesc.ArraySize := 1;
        StagingDesc.Usage := D3D11_USAGE_STAGING;
        StagingDesc.BindFlags := 0;
        StagingDesc.CPUAccessFlags := D3D11_CPU_ACCESS_READ;
        StagingDesc.MiscFlags := 0;
        if Device.CreateTexture2D(StagingDesc, nil,
          CaptureStagingTexture) < 0 then
        begin
          SetCaptureError('Could not create the framebuffer staging texture.');
          Exit;
        end;
        CaptureDevice := Device;
      end;

      Device.GetImmediateContext(Context);
      if Context = nil then
      begin
        SetCaptureError('D3D11 immediate context is unavailable.');
        Exit;
      end;
      Context.CopyResource(CaptureStagingTexture, SourceTexture);
      FillChar(Mapped, SizeOf(Mapped), 0);
      if Context.Map(CaptureStagingTexture, 0, D3D11_MAP_READ, 0,
        Mapped) < 0 then
      begin
        SetCaptureError('Could not map the framebuffer staging texture.');
        Exit;
      end;
      try
        ByteCount := RowBytes * Height;
        if CaptureBufferSize <> ByteCount then
        begin
          ReallocMem(CaptureBuffer, ByteCount);
          CaptureBufferSize := ByteCount;
        end;
        Source := Mapped.pData;
        Destination := CaptureBuffer;
        for Y := 0 to Height - 1 do
        begin
          Move(Source^, Destination^, RowBytes);
          Inc(Source, Mapped.RowPitch);
          Inc(Destination, RowBytes);
        end;
      finally
        Context.Unmap(CaptureStagingTexture, 0);
      end;
      CaptureWidth := Width;
      CaptureHeight := Height;
      CaptureFormat := SourceDesc.Format;
      CaptureStatus := Format('%s: %d x %d, DXGI format %d.',
        [SourceKind, Width, Height, Ord(SourceDesc.Format)]);
      CaptureSignature := Format('%s:%d:%d:%d:%d',
        [SourceKind, Width, Height, Ord(SourceDesc.Format), Mapped.RowPitch]);
      if LoggedCaptureSignature <> CaptureSignature then
      begin
        LoggedCaptureSignature := CaptureSignature;
        DebugLog(Format(
          'Capture success: source=%s size=%dx%d format=%d rowBytes=%d rowPitch=%d bytes=%d.',
          [SourceKind, Width, Height, Ord(SourceDesc.Format), RowBytes,
           Mapped.RowPitch, ByteCount]));
      end;
    except
      on E: Exception do
        SetCaptureError('Framebuffer capture failed: ' + E.Message);
    end;
  finally
{$IFDEF DEBUG}
    CaptureElapsedMilliseconds :=
      DebugTimerElapsedMilliseconds(CapturePerfStarted);
    Inc(CapturePerfCount);
    CapturePerfTotalMilliseconds := CapturePerfTotalMilliseconds +
      CaptureElapsedMilliseconds;
    CapturePerfMaximumMilliseconds := Max(CapturePerfMaximumMilliseconds,
      CaptureElapsedMilliseconds);
    CurrentTick := GetTickCount64;
    if CapturePerfLastLogTick = 0 then
      CapturePerfLastLogTick := CurrentTick
    else if CurrentTick - CapturePerfLastLogTick >= 1000 then
    begin
      DebugLog(Format(
        'Capture performance: calls=%d avgMs=%.3f maxMs=%.3f size=%dx%d format=%d.',
        [CapturePerfCount,
         CapturePerfTotalMilliseconds / CapturePerfCount,
         CapturePerfMaximumMilliseconds, CaptureWidth, CaptureHeight,
         Ord(CaptureFormat)]));
      CapturePerfCount := 0;
      CapturePerfTotalMilliseconds := 0;
      CapturePerfMaximumMilliseconds := 0;
      CapturePerfLastLogTick := CurrentTick;
    end;
{$ENDIF}
    LeaveCriticalSection(CaptureLock);
  end;
end;

function CopyLastFrame(out Pixels: TBytes; out Width, Height: Integer;
  out Status: string): Boolean;
var
  Destination: PByte;
  I: NativeInt;
  PixelCount: NativeInt;
  Source: PByte;
  SourceWords: PPixelWords;
{$IFDEF DEBUG}
  AlphaMaximum: Byte;
  AlphaMinimum: Byte;
  ColorMaximum: Byte;
  ColorMinimum: Byte;
  NonBlackCount: NativeInt;
  SampleCount: NativeInt;
  SampleIndex: NativeInt;
  SampleStep: NativeInt;
{$ENDIF}
begin
  Pixels := nil;
  Width := 0;
  Height := 0;
  Status := '';
  if not CaptureInitialized then
    Exit(False);

  EnterCriticalSection(CaptureLock);
  try
    Status := CaptureStatus;
    Result := (CaptureBuffer <> nil) and (CaptureBufferSize > 0) and
      (CaptureWidth > 0) and (CaptureHeight > 0);
    if not Result then
    begin
      DebugLog('CopyLastFrame unavailable: ' + Status);
      Exit;
    end;
    Width := CaptureWidth;
    Height := CaptureHeight;
    PixelCount := NativeInt(Width) * Height;
    SetLength(Pixels, PixelCount * 4);
    Source := CaptureBuffer;
    Destination := @Pixels[0];
    case CaptureFormat of
      DXGI_FORMAT_R8G8B8A8_UNORM,
      DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
        Move(Source^, Destination^, Length(Pixels));
      DXGI_FORMAT_B8G8R8A8_UNORM,
      DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
        for I := 0 to PixelCount - 1 do
        begin
          Destination[0] := Source[2];
          Destination[1] := Source[1];
          Destination[2] := Source[0];
          Destination[3] := Source[3];
          Inc(Source, 4);
          Inc(Destination, 4);
        end;
      DXGI_FORMAT_R16G16B16A16_UNORM:
        begin
          SourceWords := PPixelWords(Source);
          for I := 0 to PixelCount - 1 do
          begin
            Destination[0] := SourceWords[0] div 257;
            Destination[1] := SourceWords[1] div 257;
            Destination[2] := SourceWords[2] div 257;
            Destination[3] := SourceWords[3] div 257;
            Inc(SourceWords);
            Inc(Destination, 4);
          end;
        end;
      DXGI_FORMAT_R16G16B16A16_FLOAT:
        begin
          SourceWords := PPixelWords(Source);
          for I := 0 to PixelCount - 1 do
          begin
            Destination[0] := FloatToByte(HalfToSingle(SourceWords[0]));
            Destination[1] := FloatToByte(HalfToSingle(SourceWords[1]));
            Destination[2] := FloatToByte(HalfToSingle(SourceWords[2]));
            Destination[3] := Round(EnsureRange(
              HalfToSingle(SourceWords[3]), 0.0, 1.0) * 255);
            Inc(SourceWords);
            Inc(Destination, 4);
          end;
        end;
    else
      Pixels := nil;
      Result := False;
    end;
{$IFDEF DEBUG}
    if Result then
    begin
      ColorMinimum := 255;
      ColorMaximum := 0;
      AlphaMinimum := 255;
      AlphaMaximum := 0;
      NonBlackCount := 0;
      SampleCount := 0;
      SampleStep := Max(1, PixelCount div 4096);
      SampleIndex := 0;
      while SampleIndex < PixelCount do
      begin
        Source := @Pixels[SampleIndex * 4];
        ColorMinimum := Min(ColorMinimum,
          Min(Source[0], Min(Source[1], Source[2])));
        ColorMaximum := Max(ColorMaximum,
          Max(Source[0], Max(Source[1], Source[2])));
        AlphaMinimum := Min(AlphaMinimum, Source[3]);
        AlphaMaximum := Max(AlphaMaximum, Source[3]);
        if (Source[0] <> 0) or (Source[1] <> 0) or (Source[2] <> 0) then
          Inc(NonBlackCount);
        Inc(SampleCount);
        Inc(SampleIndex, SampleStep);
      end;
      DebugLog(Format(
        'CopyLastFrame RGBA: size=%dx%d samples=%d nonBlack=%d color=%d..%d alpha=%d..%d.',
        [Width, Height, SampleCount, NonBlackCount, ColorMinimum,
         ColorMaximum, AlphaMinimum, AlphaMaximum]));
    end;
{$ENDIF}
  finally
    LeaveCriticalSection(CaptureLock);
  end;
end;

end.
