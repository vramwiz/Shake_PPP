unit Shake_PPP_SettingsForm;

// Displays the latest pre-filter framebuffer and provides basic navigation.

interface

uses
  System.Classes,
  System.Types,
  System.SysUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  Vcl.Forms,
  Vcl.Graphics,
  Vcl.StdCtrls,
  Shake_PPP_CurveModel,
  Shake_PPP_StaticDeformer,
  Shake_PPP_ToolbarButtons;

type
  TFormShakeSettings = class(TForm)
    PreviewPaintBox: TPaintBox;
    StatusLabel: TLabel;
    TopPanel: TPanel;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    procedure PreviewPaintBoxDblClick(Sender: TObject);
    procedure PreviewPaintBoxMouseDown(Sender: TObject;
      Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure PreviewPaintBoxMouseMove(Sender: TObject;
      Shift: TShiftState; X, Y: Integer);
    procedure PreviewPaintBoxMouseUp(Sender: TObject;
      Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure PreviewPaintBoxPaint(Sender: TObject);
  private
    FBackground: TBitmap;
    FBackBuffer: TBitmap;
    FDeformedBackground: TBitmap;
    FDeformationMap: TShakeDeformationMap;
    FDeformedDirty: Boolean;
    FActiveCurveKind: TShakeCurveKind;
    FActiveCurveSetIndex: Integer;
    FCenterContour: TShakeCurve;
    FCurveSets: TShakeCurveSets;
    FCurrentVertexKind: TShakeVertexKind;
    FDragging: Boolean;
    FDragOrigin: TPoint;
    FFitToWindow: Boolean;
    FPaintLogged: Boolean;
    FPanMode: Boolean;
    FPanMoved: Boolean;
    FRightDownOnClosingSegment: Boolean;
    FOuterContour: TShakeCurve;
    FMotionTimer: TTimer;
    FMotionDragging: Boolean;
    FMotionInputLogged: Boolean;
    FMotionLastTick: UInt64;
    FMotionMousePosition: TPoint;
    FMotionOffsetX: Double;
    FMotionOffsetY: Double;
    FMotionVelocityX: Double;
    FMotionVelocityY: Double;
    FMotionMouseValid: Boolean;
    FSelectedVertex: Integer;
    FShowDeformed: Boolean;
    FPreviewRendering: Boolean;
    FOffset: TPoint;
    FOffsetOrigin: TPoint;
    FToolbar: TShakeToolbarButtons;
    FToolbarCenterContour: TShakeToolbarButton;
    FToolbarCornerPoint: TShakeToolbarButton;
    FToolbarDeformedView: TShakeToolbarButton;
    FToolbarOriginalView: TShakeToolbarButton;
    FToolbarOuterContour: TShakeToolbarButton;
    FToolbarPan: TShakeToolbarButton;
    FToolbarSmoothPoint: TShakeToolbarButton;
    FToolbarCurveSet1: TShakeToolbarButton;
    FToolbarCurveSet2: TShakeToolbarButton;
    FVertexDragging: Boolean;
    FZoomPercent: Integer;
    function ActiveCurve: TShakeCurve;
    procedure ApplyDarkTheme;
    function BackgroundDestinationRect: TRect;
    function CanvasToNormalized(X, Y: Integer; ClampToImage: Boolean;
      out Position: TPointF): Boolean;
    procedure BeginPan(X, Y: Integer);
    procedure CreateShapeToolbar;
    procedure DrawCurve(Canvas: TCanvas; Curve: TShakeCurve;
      CurveKind: TShakeCurveKind; IsActive: Boolean);
    procedure EnsureBackBuffer;
    procedure FitImage;
    function HitTestClosingSegment(X, Y: Integer): Boolean;
    function HitTestVertex(X, Y: Integer): Integer;
    function NormalizedToCanvas(const Position: TPointF): TPoint;
    procedure MarkDeformationDirty;
    procedure FeedMotionFromMouse(X, Y: Integer);
    procedure MotionTimerTick(Sender: TObject);
    procedure ResetMotionPreview;
    procedure SwitchCurveSet(Index: Integer);
    function UpdateDeformedPreview: Boolean;
    procedure SetEditorStatus;
    procedure ToolbarButtonExecute(Sender: TObject;
      Button: TShakeToolbarButton);
  public
    procedure SetBackgroundRgba(const Pixels: TBytes;
      Width, Height: Integer);
    procedure SetCaptureStatus(const Value: string);
    function TryLoadCurveDataText(const Text: string;
      out ErrorText: string): Boolean;
    function TrySaveCurveDataText(out Text, ErrorText: string): Boolean;
  end;

implementation

uses
  System.Math,
  Shake_PPP_CurveData,
  Shake_PPP_CurveRenderer,
  Shake_PPP_DebugLog,
  Winapi.DwmApi,
  Winapi.Windows;

{$R *.dfm}

type
  TControlAccess = class(TControl);

procedure TFormShakeSettings.ApplyDarkTheme;
const
  DARK_BACKGROUND = TColor($00202020);
  DARK_PANEL = TColor($00262626);
  DARK_TEXT = TColor($00E6E6E6);
  DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
  DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19;
var
  Enabled: BOOL;
begin
  Color := DARK_BACKGROUND;
  Font.Color := DARK_TEXT;
  TopPanel.ParentBackground := False;
  TopPanel.Color := DARK_PANEL;
  TopPanel.Font.Color := DARK_TEXT;
  StatusLabel.Font.Color := DARK_TEXT;
  Enabled := True;
  if DwmSetWindowAttribute(Handle, DWMWA_USE_IMMERSIVE_DARK_MODE,
    @Enabled, SizeOf(Enabled)) <> S_OK then
    DwmSetWindowAttribute(Handle, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD,
      @Enabled, SizeOf(Enabled));
end;

function TFormShakeSettings.ActiveCurve: TShakeCurve;
begin
  if FActiveCurveKind = sckOuterContour then
    Result := FOuterContour
  else
    Result := FCenterContour;
end;

function TFormShakeSettings.HitTestClosingSegment(X, Y: Integer): Boolean;
begin
  Result := TShakeCurveRenderer.HitTestClosingSegment(
    BackgroundDestinationRect, ActiveCurve, X, Y, CurrentPPI);
end;

function TFormShakeSettings.BackgroundDestinationRect: TRect;
var
  DrawHeight: Integer;
  DrawWidth: Integer;
  Scale: Double;
begin
  Result := PreviewPaintBox.ClientRect;
  if (FBackground.Width <= 0) or (FBackground.Height <= 0) then
    Exit;
  if FFitToWindow then
    Scale := Min(PreviewPaintBox.ClientWidth / FBackground.Width,
      PreviewPaintBox.ClientHeight / FBackground.Height)
  else
    Scale := FZoomPercent / 100.0;
  DrawWidth := Max(1, Round(FBackground.Width * Scale));
  DrawHeight := Max(1, Round(FBackground.Height * Scale));
  Result.Left := (PreviewPaintBox.ClientWidth - DrawWidth) div 2 + FOffset.X;
  Result.Top := (PreviewPaintBox.ClientHeight - DrawHeight) div 2 + FOffset.Y;
  Result.Right := Result.Left + DrawWidth;
  Result.Bottom := Result.Top + DrawHeight;
end;

function TFormShakeSettings.CanvasToNormalized(X, Y: Integer;
  ClampToImage: Boolean; out Position: TPointF): Boolean;
var
  Destination: TRect;
begin
  Result := False;
  if (FBackground.Width <= 0) or (FBackground.Height <= 0) then
    Exit;
  Destination := BackgroundDestinationRect;
  if (Destination.Width <= 0) or (Destination.Height <= 0) then
    Exit;
  Result := PtInRect(Destination, Point(X, Y));
  if not Result and not ClampToImage then
    Exit;
  Position.X := EnsureRange((X - Destination.Left) / Destination.Width,
    0.0, 1.0);
  Position.Y := EnsureRange((Y - Destination.Top) / Destination.Height,
    0.0, 1.0);
  Result := True;
end;

procedure TFormShakeSettings.BeginPan(X, Y: Integer);
begin
  FDragging := True;
  FPanMoved := False;
  FDragOrigin := Point(X, Y);
  FOffsetOrigin := FOffset;
  TControlAccess(PreviewPaintBox).MouseCapture := True;
  PreviewPaintBox.Cursor := crSizeAll;
end;

procedure TFormShakeSettings.EnsureBackBuffer;
begin
  if (FBackBuffer.Width = PreviewPaintBox.ClientWidth) and
    (FBackBuffer.Height = PreviewPaintBox.ClientHeight) then
    Exit;
  FBackBuffer.SetSize(Max(1, PreviewPaintBox.ClientWidth),
    Max(1, PreviewPaintBox.ClientHeight));
end;

procedure TFormShakeSettings.DrawCurve(Canvas: TCanvas; Curve: TShakeCurve;
  CurveKind: TShakeCurveKind; IsActive: Boolean);
begin
  TShakeCurveRenderer.Draw(Canvas, FBackBuffer.Width, FBackBuffer.Height,
    BackgroundDestinationRect, Curve, CurveKind, IsActive,
    FSelectedVertex, CurrentPPI);
end;

procedure TFormShakeSettings.MarkDeformationDirty;
begin
  FDeformedDirty := True;
  FDeformationMap.Clear;
end;

procedure TFormShakeSettings.FeedMotionFromMouse(X, Y: Integer);
const
  MOUSE_IMPULSE_GAIN = 6.0;
var
  DeltaX: Integer;
  DeltaY: Integer;
  Destination: TRect;
  ImageDeltaX: Double;
  ImageDeltaY: Double;
begin
  if not FPanMode or not FMotionDragging then
    Exit;
  if not FMotionMouseValid then
  begin
    FMotionMousePosition := Point(X, Y);
    FMotionMouseValid := True;
    Exit;
  end;
  DeltaX := EnsureRange(X - FMotionMousePosition.X, -100, 100);
  DeltaY := EnsureRange(Y - FMotionMousePosition.Y, -100, 100);
  FMotionMousePosition := Point(X, Y);
  if (DeltaX = 0) and (DeltaY = 0) then
    Exit;
  Destination := BackgroundDestinationRect;
  if (Destination.Width <= 0) or (Destination.Height <= 0) then
    Exit;
  ImageDeltaX := DeltaX * FBackground.Width / Destination.Width;
  // Bitmap scanlines are bottom-up, so the deformation engine's vertical
  // velocity input must be inverted from the screen's downward-positive Y.
  ImageDeltaY := -DeltaY * FBackground.Height / Destination.Height;
  FMotionVelocityX := FMotionVelocityX + ImageDeltaX * MOUSE_IMPULSE_GAIN;
  FMotionVelocityY := FMotionVelocityY + ImageDeltaY * MOUSE_IMPULSE_GAIN;
  FMotionVelocityX := EnsureRange(FMotionVelocityX,
    -FBackground.Width * 2.0, FBackground.Width * 2.0);
  FMotionVelocityY := EnsureRange(FMotionVelocityY,
    -FBackground.Height * 2.0, FBackground.Height * 2.0);
  if not FMotionInputLogged then
  begin
    FMotionInputLogged := True;
    DebugLog(Format(
      'Motion drag input: canvasDelta=%d,%d imageDelta=%.1f,%.1f velocity=%.1f,%.1f.',
      [DeltaX, DeltaY, ImageDeltaX, ImageDeltaY,
       FMotionVelocityX, FMotionVelocityY]));
  end;
  FMotionLastTick := GetTickCount64;
  FMotionTimer.Enabled := True;
end;

procedure TFormShakeSettings.ResetMotionPreview;
var
  ErrorText: string;
begin
  FMotionOffsetX := 0;
  FMotionOffsetY := 0;
  FMotionVelocityX := 0;
  FMotionVelocityY := 0;
  FMotionDragging := False;
  FMotionInputLogged := False;
  FMotionMouseValid := False;
  FMotionLastTick := GetTickCount64;
  // Keep the lightweight timer alive to poll dragging even when the
  // TPaintBox does not deliver mouse capture events on the host window.
  FMotionTimer.Enabled := True;
  if (FDeformationMap.Width <> FBackground.Width) or
    (FDeformationMap.Height <> FBackground.Height) then
    if not FDeformationMap.Build(FBackground.Width, FBackground.Height,
      FOuterContour, FCenterContour, ErrorText) then
    begin
      StatusLabel.Caption := '動作プレビュー：曲線を閉じてください。';
      Exit;
    end;
  if FDeformationMap.Apply(FBackground, FDeformedBackground,
    0, 0, ErrorText) then
  begin
    FDeformedDirty := False;
    PreviewPaintBox.Invalidate;
  end;
end;

procedure TFormShakeSettings.MotionTimerTick(Sender: TObject);
var
  Converged: Boolean;
  DeltaSeconds: Double;
  ErrorText: string;
  MaximumX: Double;
  MaximumY: Double;
  NowTick: UInt64;
  PointerPosition: TPoint;
begin
  if not FPanMode or not FShowDeformed or FPreviewRendering then
    Exit;
  GetCursorPos(PointerPosition);
  PointerPosition := PreviewPaintBox.ScreenToClient(PointerPosition);
  if GetAsyncKeyState(VK_LBUTTON) < 0 then
  begin
    if not FMotionDragging then
    begin
      BeginPan(PointerPosition.X, PointerPosition.Y);
      FMotionDragging := True;
      FMotionMousePosition := PointerPosition;
      FMotionMouseValid := True;
      DebugLog(Format('Motion drag polling started at %d,%d.',
        [PointerPosition.X, PointerPosition.Y]));
    end
    else
    begin
      if not FPanMoved and
        (Abs(PointerPosition.X - FDragOrigin.X) < 3) and
        (Abs(PointerPosition.Y - FDragOrigin.Y) < 3) then
        Exit;
      FPanMoved := True;
      FOffset.X := FOffsetOrigin.X + PointerPosition.X - FDragOrigin.X;
      FOffset.Y := FOffsetOrigin.Y + PointerPosition.Y - FDragOrigin.Y;
      FeedMotionFromMouse(PointerPosition.X, PointerPosition.Y);
      PreviewPaintBox.Invalidate;
    end;
  end
  else if FMotionDragging then
  begin
    FMotionDragging := False;
    FMotionMouseValid := False;
    FDragging := False;
    TControlAccess(PreviewPaintBox).MouseCapture := False;
    PreviewPaintBox.Cursor := crDefault;
  end;
  if (Abs(FMotionOffsetX) < 0.1) and (Abs(FMotionOffsetY) < 0.1) and
    (Abs(FMotionVelocityX) < 0.5) and (Abs(FMotionVelocityY) < 0.5) then
    Exit;
  FPreviewRendering := True;
  try
    if (FDeformationMap.Width <> FBackground.Width) or
      (FDeformationMap.Height <> FBackground.Height) then
    begin
      if not FDeformationMap.Build(FBackground.Width, FBackground.Height,
        FOuterContour, FCenterContour, ErrorText) then
      begin
        FMotionTimer.Enabled := False;
        if ErrorText = 'OUTER_NOT_CLOSED' then
          ErrorText := '外周を閉じてください。'
        else if ErrorText = 'CENTER_NOT_CLOSED' then
          ErrorText := '重心・頂点範囲を閉じてください。';
        StatusLabel.Caption := '動作プレビュー：' + ErrorText;
        Exit;
      end;
    end;
    NowTick := GetTickCount64;
    DeltaSeconds := EnsureRange((NowTick - FMotionLastTick) / 1000.0,
      0.001, 0.1);
    FMotionLastTick := NowTick;
    // Underdamped spring: pointer movement adds velocity; the spring then
    // overshoots and returns to the undeformed origin.
    FMotionVelocityX := FMotionVelocityX +
      (-22.0 * FMotionOffsetX - 5.0 * FMotionVelocityX) * DeltaSeconds;
    FMotionVelocityY := FMotionVelocityY +
      (-18.0 * FMotionOffsetY - 4.5 * FMotionVelocityY) * DeltaSeconds;
    FMotionOffsetX := FMotionOffsetX + FMotionVelocityX * DeltaSeconds;
    FMotionOffsetY := FMotionOffsetY + FMotionVelocityY * DeltaSeconds;
    MaximumX := FBackground.Width * 0.08;
    MaximumY := FBackground.Height * 0.06;
    FMotionOffsetX := EnsureRange(FMotionOffsetX, -MaximumX, MaximumX);
    FMotionOffsetY := EnsureRange(FMotionOffsetY, -MaximumY, MaximumY);
    Converged := (Abs(FMotionOffsetX) < 0.1) and
      (Abs(FMotionOffsetY) < 0.1) and
      (Abs(FMotionVelocityX) < 0.5) and
      (Abs(FMotionVelocityY) < 0.5);
    if Converged then
    begin
      FMotionOffsetX := 0;
      FMotionOffsetY := 0;
      FMotionVelocityX := 0;
      FMotionVelocityY := 0;
    end;
    if not FDeformationMap.Apply(FBackground, FDeformedBackground,
      FMotionOffsetX, FMotionOffsetY, ErrorText) then
    begin
      FMotionTimer.Enabled := False;
      StatusLabel.Caption := '動作プレビューを更新できません：' + ErrorText;
      Exit;
    end;
    FDeformedDirty := False;
    if Converged then
    begin
      StatusLabel.Caption :=
        '動作プレビュー：マウスを動かすと揺れます';
      DebugLog('Motion preview converged to the undeformed origin.');
    end;
    PreviewPaintBox.Invalidate;
  finally
    FPreviewRendering := False;
  end;
end;

function TFormShakeSettings.UpdateDeformedPreview: Boolean;
var
  ErrorText: string;
  HorizontalDisplacement: Double;
  VerticalDisplacement: Double;
begin
  if not FDeformedDirty then
    Exit(True);
  // The first-stage preview intentionally uses a fixed, clearly visible input.
  HorizontalDisplacement := FBackground.Width * 0.06;
  VerticalDisplacement := -FBackground.Height * 0.035;
  Result := FDeformationMap.Build(FBackground.Width, FBackground.Height,
    FOuterContour, FCenterContour, ErrorText);
  if Result then
    Result := FDeformationMap.Apply(FBackground, FDeformedBackground,
      HorizontalDisplacement, VerticalDisplacement, ErrorText);
  if Result then
  begin
    FDeformedDirty := False;
    DebugLog(Format('Static deformation preview updated: offset=%.1f,%.1f.',
      [HorizontalDisplacement, VerticalDisplacement]));
  end
  else
  begin
    if ErrorText = 'NO_IMAGE' then
      ErrorText := 'プレビュー画像がありません。'
    else if ErrorText = 'OUTER_NOT_CLOSED' then
      ErrorText := '外周を閉じてください。'
    else if ErrorText = 'CENTER_NOT_CLOSED' then
      ErrorText := '重心・頂点範囲を閉じてください。';
    StatusLabel.Caption := '変形プレビュー：' + ErrorText;
    DebugLog('Static deformation preview rejected: ' + ErrorText);
  end;
end;

function TFormShakeSettings.HitTestVertex(X, Y: Integer): Integer;
begin
  Result := TShakeCurveRenderer.HitTestVertex(BackgroundDestinationRect,
    ActiveCurve, X, Y, CurrentPPI);
end;

function TFormShakeSettings.NormalizedToCanvas(
  const Position: TPointF): TPoint;
begin
  Result := TShakeCurveRenderer.ToCanvas(BackgroundDestinationRect, Position);
end;

procedure TFormShakeSettings.CreateShapeToolbar;
const
  TOOLBAR_OUTER_CONTOUR = 1;
  TOOLBAR_CENTER_CONTOUR = 2;
  TOOLBAR_PAN = 3;
  TOOLBAR_CORNER_POINT = 4;
  TOOLBAR_SMOOTH_POINT = 5;
  TOOLBAR_ORIGINAL_VIEW = 6;
  TOOLBAR_DEFORMED_VIEW = 7;
  TOOLBAR_FIT = 8;
  TOOLBAR_CURVE_SET_1 = 9;
  TOOLBAR_CURVE_SET_2 = 10;
var
  Extent: Integer;
begin
  Extent := MulDiv(28, CurrentPPI, 96);
  FToolbar := TShakeToolbarButtons.Create(Self);
  FToolbar.Parent := TopPanel;
  FToolbar.SetBounds(MulDiv(8, CurrentPPI, 96),
    MulDiv(4, CurrentPPI, 96), MulDiv(322, CurrentPPI, 96), Extent);
  FToolbar.ButtonExtent := Extent;
  FToolbar.SeparatorExtent := MulDiv(6, CurrentPPI, 96);
  FToolbar.Color := TopPanel.Color;
  FToolbar.ParentBackground := False;
  FToolbar.OnButtonExecute := ToolbarButtonExecute;
  FToolbarCurveSet1 := FToolbar.AddToggle('形状セット1',
    stgCurveSet1, TOOLBAR_CURVE_SET_1);
  FToolbarCurveSet2 := FToolbar.AddToggle('形状セット2',
    stgCurveSet2, TOOLBAR_CURVE_SET_2);
  FToolbar.AddSeparator;
  FToolbarOuterContour := FToolbar.AddToggle('外周を編集',
    stgOuterContour, TOOLBAR_OUTER_CONTOUR);
  FToolbarCenterContour := FToolbar.AddToggle('重心・頂点範囲を編集',
    stgCenterContour, TOOLBAR_CENTER_CONTOUR);
  FToolbar.AddSeparator;
  FToolbarPan := FToolbar.AddToggle(
    '動作プレビュー（左ドラッグで画像を移動して揺らす）',
    stgMotionPreview, TOOLBAR_PAN);
  FToolbar.AddSeparator;
  FToolbarCornerPoint := FToolbar.AddToggle('鋭角頂点',
    stgCornerPoint, TOOLBAR_CORNER_POINT);
  FToolbarSmoothPoint := FToolbar.AddToggle('滑らかな頂点',
    stgSmoothPoint, TOOLBAR_SMOOTH_POINT);
  FToolbar.AddSeparator;
  FToolbarOriginalView := FToolbar.AddToggle('元画像',
    stgOriginalView, TOOLBAR_ORIGINAL_VIEW);
  FToolbarDeformedView := FToolbar.AddToggle('固定量の変形プレビュー',
    stgDeformedView, TOOLBAR_DEFORMED_VIEW);
  FToolbar.AddCommand('全体表示', stgFit, TOOLBAR_FIT);
  FToolbarOuterContour.CheckState := stcsChecked;
  FToolbarCurveSet1.CheckState := stcsChecked;
  FToolbarSmoothPoint.CheckState := stcsChecked;
  FToolbarOriginalView.CheckState := stcsChecked;
  FPanMode := False;
  FShowDeformed := False;
end;

procedure TFormShakeSettings.FitImage;
begin
  FFitToWindow := True;
  FOffset := Point(0, 0);
  PreviewPaintBox.Invalidate;
end;

procedure TFormShakeSettings.FormCreate(Sender: TObject);
var
  I: Integer;
begin
  ApplyDarkTheme;
  FBackground := Vcl.Graphics.TBitmap.Create;
  FBackBuffer := Vcl.Graphics.TBitmap.Create;
  FDeformedBackground := Vcl.Graphics.TBitmap.Create;
  FDeformationMap := TShakeDeformationMap.Create;
  FMotionTimer := TTimer.Create(Self);
  FMotionTimer.Enabled := False;
  FMotionTimer.Interval := 50;
  FMotionTimer.OnTimer := MotionTimerTick;
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
  begin
    FCurveSets[I].OuterContour := TShakeCurve.Create;
    FCurveSets[I].CenterContour := TShakeCurve.Create;
  end;
  FActiveCurveSetIndex := 0;
  FOuterContour := FCurveSets[0].OuterContour;
  FCenterContour := FCurveSets[0].CenterContour;
  FBackBuffer.PixelFormat := pf32bit;
  FDeformedBackground.PixelFormat := pf32bit;
  FDeformedDirty := True;
  DoubleBuffered := True;
  TControlAccess(PreviewPaintBox).ControlStyle :=
    TControlAccess(PreviewPaintBox).ControlStyle + [csOpaque];
  FFitToWindow := True;
  FOffset := Point(0, 0);
  FActiveCurveKind := sckOuterContour;
  FCurrentVertexKind := svkSmooth;
  FSelectedVertex := -1;
  FZoomPercent := 100;
  CreateShapeToolbar;
  SetEditorStatus;
  DebugLog('Settings form created.');
end;

procedure TFormShakeSettings.FormDestroy(Sender: TObject);
var
  I: Integer;
begin
  DebugLog('Settings form destroyed.');
  FMotionTimer.Enabled := False;
  FreeAndNil(FMotionTimer);
  FDeformationMap.Free;
  for I := SHAKE_CURVE_SET_COUNT - 1 downto 0 do
  begin
    FCurveSets[I].CenterContour.Free;
    FCurveSets[I].OuterContour.Free;
  end;
  FDeformedBackground.Free;
  FBackBuffer.Free;
  FBackground.Free;
end;

procedure TFormShakeSettings.FormMouseWheel(Sender: TObject;
  Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint;
  var Handled: Boolean);
var
  Delta: Integer;
begin
  if WheelDelta > 0 then
    Delta := 25
  else
    Delta := -25;
  FZoomPercent := EnsureRange(FZoomPercent + Delta, 25, 400);
  FFitToWindow := False;
  PreviewPaintBox.Invalidate;
  Handled := True;
end;

procedure TFormShakeSettings.PreviewPaintBoxDblClick(Sender: TObject);
var
  Curve: TShakeCurve;
  HitIndex: Integer;
  MousePoint: TPoint;
begin
  if FPanMode then
  begin
    FitImage;
    Exit;
  end;
  MousePoint := PreviewPaintBox.ScreenToClient(Mouse.CursorPos);
  Curve := ActiveCurve;
  HitIndex := HitTestVertex(MousePoint.X, MousePoint.Y);
  if (HitIndex = 0) and (Curve.Count >= 3) then
  begin
    Curve.Closed := True;
    FSelectedVertex := 0;
  end
  else if HitIndex = Curve.Count - 1 then
  begin
    Curve.Closed := False;
    FSelectedVertex := HitIndex;
  end;
  MarkDeformationDirty;
  if FShowDeformed then
    UpdateDeformedPreview;
  SetEditorStatus;
  PreviewPaintBox.Invalidate;
end;

procedure TFormShakeSettings.PreviewPaintBoxMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  Curve: TShakeCurve;
  HitIndex: Integer;
  Position: TPointF;
begin
  FRightDownOnClosingSegment := False;
  if FPanMode and (Button = mbLeft) then
  begin
    BeginPan(X, Y);
    FMotionDragging := True;
    FMotionMousePosition := Point(X, Y);
    FMotionMouseValid := True;
    DebugLog(Format('Motion drag started at %d,%d.', [X, Y]));
    Exit;
  end;
  if (Button = mbMiddle) or (FPanMode and (Button = mbRight)) then
  begin
    BeginPan(X, Y);
    Exit;
  end;
  Curve := ActiveCurve;
  HitIndex := HitTestVertex(X, Y);
  if Button = mbRight then
  begin
    if HitIndex >= 0 then
    begin
      Curve.DeleteVertex(HitIndex);
      MarkDeformationDirty;
      if FShowDeformed then
        UpdateDeformedPreview;
      FSelectedVertex := -1;
      SetEditorStatus;
      PreviewPaintBox.Invalidate;
      Exit;
    end;
    FRightDownOnClosingSegment := HitTestClosingSegment(X, Y);
    BeginPan(X, Y);
    Exit;
  end;
  if Button <> mbLeft then
    Exit;
  if HitIndex < 0 then
  begin
    if not CanvasToNormalized(X, Y, False, Position) then
      Exit;
    HitIndex := Curve.AddVertex(Position, FCurrentVertexKind);
    MarkDeformationDirty;
  end;
  FSelectedVertex := HitIndex;
  FVertexDragging := True;
  TControlAccess(PreviewPaintBox).MouseCapture := True;
  PreviewPaintBox.Cursor := crCross;
  SetEditorStatus;
  PreviewPaintBox.Invalidate;
end;

procedure TFormShakeSettings.ToolbarButtonExecute(Sender: TObject;
  Button: TShakeToolbarButton);
begin
  case Button.Tag of
    1:
      begin
        FActiveCurveKind := sckOuterContour;
        FSelectedVertex := -1;
        FToolbarOuterContour.CheckState := stcsChecked;
        FToolbarCenterContour.CheckState := stcsUnchecked;
        FToolbarPan.CheckState := stcsUnchecked;
        FPanMode := False;
        FMotionTimer.Enabled := False;
        FShowDeformed := False;
        FToolbarOriginalView.CheckState := stcsChecked;
        FToolbarDeformedView.CheckState := stcsUnchecked;
      end;
    2:
      begin
        FActiveCurveKind := sckCenterContour;
        FSelectedVertex := -1;
        FToolbarOuterContour.CheckState := stcsUnchecked;
        FToolbarCenterContour.CheckState := stcsChecked;
        FToolbarPan.CheckState := stcsUnchecked;
        FPanMode := False;
        FMotionTimer.Enabled := False;
        FShowDeformed := False;
        FToolbarOriginalView.CheckState := stcsChecked;
        FToolbarDeformedView.CheckState := stcsUnchecked;
      end;
    3:
      begin
        FPanMode := not FPanMode;
        if FPanMode then
        begin
          FToolbarOuterContour.CheckState := stcsUnchecked;
          FToolbarCenterContour.CheckState := stcsUnchecked;
          FToolbarPan.CheckState := stcsChecked;
          FShowDeformed := True;
          FToolbarOriginalView.CheckState := stcsUnchecked;
          FToolbarDeformedView.CheckState := stcsChecked;
          ResetMotionPreview;
        end
        else
        begin
          FToolbarPan.CheckState := stcsUnchecked;
          FShowDeformed := False;
          FMotionTimer.Enabled := False;
          FToolbarOriginalView.CheckState := stcsChecked;
          FToolbarDeformedView.CheckState := stcsUnchecked;
          if FActiveCurveKind = sckOuterContour then
            FToolbarOuterContour.CheckState := stcsChecked
          else
            FToolbarCenterContour.CheckState := stcsChecked;
        end;
      end;
    4:
      begin
        FCurrentVertexKind := svkCorner;
        FToolbarCornerPoint.CheckState := stcsChecked;
        FToolbarSmoothPoint.CheckState := stcsUnchecked;
        if FSelectedVertex >= 0 then
        begin
          ActiveCurve.SetVertexKind(FSelectedVertex, FCurrentVertexKind);
          MarkDeformationDirty;
        end;
      end;
    5:
      begin
        FCurrentVertexKind := svkSmooth;
        FToolbarCornerPoint.CheckState := stcsUnchecked;
        FToolbarSmoothPoint.CheckState := stcsChecked;
        if FSelectedVertex >= 0 then
        begin
          ActiveCurve.SetVertexKind(FSelectedVertex, FCurrentVertexKind);
          MarkDeformationDirty;
        end;
      end;
    6:
      begin
        FShowDeformed := False;
        FMotionTimer.Enabled := False;
        FToolbarOriginalView.CheckState := stcsChecked;
        FToolbarDeformedView.CheckState := stcsUnchecked;
      end;
    7:
      begin
        FShowDeformed := True;
        if FPanMode then
          ResetMotionPreview;
        FToolbarOriginalView.CheckState := stcsUnchecked;
        FToolbarDeformedView.CheckState := stcsChecked;
      end;
    8:
      FitImage;
    9:
      SwitchCurveSet(0);
    10:
      SwitchCurveSet(1);
  end;
  SetEditorStatus;
  if FShowDeformed and not FPanMode then
    UpdateDeformedPreview;
  PreviewPaintBox.Invalidate;
end;

procedure TFormShakeSettings.SwitchCurveSet(Index: Integer);
begin
  if (Index < 0) or (Index >= SHAKE_CURVE_SET_COUNT) then
    Exit;
  FActiveCurveSetIndex := Index;
  FOuterContour := FCurveSets[Index].OuterContour;
  FCenterContour := FCurveSets[Index].CenterContour;
  FSelectedVertex := -1;
  FPanMode := False;
  FMotionTimer.Enabled := False;
  FShowDeformed := False;
  FToolbarCurveSet1.CheckState := TShakeToolbarCheckState(
    Ord(Index = 0));
  FToolbarCurveSet2.CheckState := TShakeToolbarCheckState(
    Ord(Index = 1));
  FToolbarPan.CheckState := stcsUnchecked;
  FToolbarOriginalView.CheckState := stcsChecked;
  FToolbarDeformedView.CheckState := stcsUnchecked;
  if FActiveCurveKind = sckOuterContour then
  begin
    FToolbarOuterContour.CheckState := stcsChecked;
    FToolbarCenterContour.CheckState := stcsUnchecked;
  end
  else
  begin
    FToolbarOuterContour.CheckState := stcsUnchecked;
    FToolbarCenterContour.CheckState := stcsChecked;
  end;
  MarkDeformationDirty;
  SetEditorStatus;
  PreviewPaintBox.Invalidate;
end;

procedure TFormShakeSettings.PreviewPaintBoxMouseMove(Sender: TObject;
  Shift: TShiftState; X, Y: Integer);
var
  Position: TPointF;
begin
  if FPanMode and (ssLeft in Shift) then
  begin
    if not FMotionDragging then
    begin
      BeginPan(X, Y);
      FMotionDragging := True;
      FMotionMousePosition := Point(X, Y);
      FMotionMouseValid := True;
    end;
    if not FPanMoved and (Abs(X - FDragOrigin.X) < 3) and
      (Abs(Y - FDragOrigin.Y) < 3) then
      Exit;
    FPanMoved := True;
    FOffset.X := FOffsetOrigin.X + X - FDragOrigin.X;
    FOffset.Y := FOffsetOrigin.Y + Y - FDragOrigin.Y;
    FeedMotionFromMouse(X, Y);
    PreviewPaintBox.Invalidate;
  end
  else if FDragging then
  begin
    if not FPanMoved and (Abs(X - FDragOrigin.X) < 3) and
      (Abs(Y - FDragOrigin.Y) < 3) then
      Exit;
    FPanMoved := True;
    FOffset.X := FOffsetOrigin.X + X - FDragOrigin.X;
    FOffset.Y := FOffsetOrigin.Y + Y - FDragOrigin.Y;
    PreviewPaintBox.Invalidate;
  end
  else if FVertexDragging and (FSelectedVertex >= 0) and
    CanvasToNormalized(X, Y, True, Position) then
  begin
    ActiveCurve.SetVertexPosition(FSelectedVertex, Position);
    MarkDeformationDirty;
    PreviewPaintBox.Invalidate;
  end;
end;

procedure TFormShakeSettings.PreviewPaintBoxMouseUp(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  Curve: TShakeCurve;
  DeltaX: Integer;
  DeltaY: Integer;
  FirstPoint: TPoint;
  Radius: Integer;
begin
  if (Button = mbLeft) and FMotionDragging then
  begin
    FMotionDragging := False;
    FMotionMouseValid := False;
    FDragging := False;
    TControlAccess(PreviewPaintBox).MouseCapture := False;
    PreviewPaintBox.Cursor := crDefault;
    Exit;
  end;
  if (Button = mbLeft) and FVertexDragging then
  begin
    Curve := ActiveCurve;
    if not Curve.Closed and (Curve.Count >= 4) and
      (FSelectedVertex = Curve.Count - 1) then
    begin
      FirstPoint := NormalizedToCanvas(Curve[0].Position);
      DeltaX := X - FirstPoint.X;
      DeltaY := Y - FirstPoint.Y;
      Radius := Max(7, MulDiv(10, CurrentPPI, 96));
      if DeltaX * DeltaX + DeltaY * DeltaY <= Radius * Radius then
      begin
        Curve.DeleteVertex(Curve.Count - 1);
        Curve.Closed := True;
        MarkDeformationDirty;
        FSelectedVertex := 0;
        SetEditorStatus;
      end;
    end;
    FVertexDragging := False;
  end;
  if (Button = mbRight) and FDragging and not FPanMoved and
    FRightDownOnClosingSegment then
  begin
    Curve := ActiveCurve;
    Curve.Closed := False;
    MarkDeformationDirty;
    FSelectedVertex := Curve.Count - 1;
    SetEditorStatus;
    PreviewPaintBox.Invalidate;
  end;
  if ((Button = mbLeft) or (Button = mbMiddle) or (Button = mbRight)) and
    FDragging then
    FDragging := False;
  FRightDownOnClosingSegment := False;
  if not FDragging and not FVertexDragging then
  begin
    TControlAccess(PreviewPaintBox).MouseCapture := False;
    PreviewPaintBox.Cursor := crDefault;
  end;
  if FShowDeformed and FDeformedDirty then
  begin
    UpdateDeformedPreview;
    PreviewPaintBox.Invalidate;
  end;
end;

procedure TFormShakeSettings.PreviewPaintBoxPaint(Sender: TObject);
var
  BufferCanvas: TCanvas;
  Destination: TRect;
begin
  EnsureBackBuffer;
  BufferCanvas := FBackBuffer.Canvas;
  BufferCanvas.Brush.Style := bsSolid;
  BufferCanvas.Brush.Color := clBlack;
  BufferCanvas.FillRect(Rect(0, 0, FBackBuffer.Width, FBackBuffer.Height));
  if (FBackground.Width <= 0) or (FBackground.Height <= 0) then
  begin
    if not FPaintLogged then
    begin
      FPaintLogged := True;
      DebugLog('Preview paint: no background bitmap.');
    end;
    PreviewPaintBox.Canvas.Draw(0, 0, FBackBuffer);
    Exit;
  end;
  Destination := BackgroundDestinationRect;
  if not FPaintLogged then
  begin
    FPaintLogged := True;
    DebugLog(Format('Preview paint: bitmap=%dx%d destination=(%d,%d)-(%d,%d).',
      [FBackground.Width, FBackground.Height, Destination.Left,
       Destination.Top, Destination.Right, Destination.Bottom]));
  end;
  SetStretchBltMode(BufferCanvas.Handle, HALFTONE);
  if FShowDeformed and not FDeformedDirty and
    (FDeformedBackground.Width > 0) then
    BufferCanvas.StretchDraw(Destination, FDeformedBackground)
  else
    BufferCanvas.StretchDraw(Destination, FBackground);
  if FActiveCurveKind = sckOuterContour then
  begin
    DrawCurve(BufferCanvas, FCenterContour, sckCenterContour, False);
    DrawCurve(BufferCanvas, FOuterContour, sckOuterContour, True);
  end
  else
  begin
    DrawCurve(BufferCanvas, FOuterContour, sckOuterContour, False);
    DrawCurve(BufferCanvas, FCenterContour, sckCenterContour, True);
  end;
  PreviewPaintBox.Canvas.Draw(0, 0, FBackBuffer);
end;

procedure TFormShakeSettings.SetEditorStatus;
const
  CurveNames: array[TShakeCurveKind] of string =
    ('外周', '重心・頂点範囲');
  VertexNames: array[TShakeVertexKind] of string =
    ('鋭角', '滑らか');
  ClosedNames: array[Boolean] of string = ('開', '閉');
begin
  if FPanMode then
    StatusLabel.Caption := Format(
      'セット%d・%s：動作プレビュー（左ドラッグで画像移動＋揺れ／右ドラッグは表示移動のみ）',
      [FActiveCurveSetIndex + 1, CurveNames[FActiveCurveKind]])
  else
    StatusLabel.Caption := Format(
      'セット%d・%s（%s）：左クリックで%s頂点を追加／頂点を右クリック削除／空所を右ドラッグ移動　頂点数 %d',
      [FActiveCurveSetIndex + 1, CurveNames[FActiveCurveKind], ClosedNames[ActiveCurve.Closed],
       VertexNames[FCurrentVertexKind], ActiveCurve.Count]);
end;

procedure TFormShakeSettings.SetBackgroundRgba(const Pixels: TBytes;
  Width, Height: Integer);
var
  Destination: PByte;
  Source: PByte;
  X: Integer;
  Y: Integer;
begin
  if (Width <= 0) or (Height <= 0) or
    (Length(Pixels) <> NativeInt(Width) * Height * 4) then
  begin
    DebugLog(Format('SetBackgroundRgba rejected: size=%dx%d bytes=%d.',
      [Width, Height, Length(Pixels)]));
    Exit;
  end;
  FBackground.PixelFormat := pf32bit;
  FBackground.SetSize(Width, Height);
  Source := @Pixels[0];
  for Y := 0 to Height - 1 do
  begin
    Destination := FBackground.ScanLine[Y];
    for X := 0 to Width - 1 do
    begin
      Destination[0] := Source[2];
      Destination[1] := Source[1];
      Destination[2] := Source[0];
      Destination[3] := Source[3];
      Inc(Destination, 4);
      Inc(Source, 4);
    end;
  end;
  FPaintLogged := False;
  MarkDeformationDirty;
  DebugLog(Format('SetBackgroundRgba accepted: size=%dx%d bytes=%d.',
    [Width, Height, Length(Pixels)]));
  FitImage;
end;

procedure TFormShakeSettings.SetCaptureStatus(const Value: string);
begin
  StatusLabel.Caption := Value;
  DebugLog('Capture status shown: ' + Value);
end;

function TFormShakeSettings.TryLoadCurveDataText(const Text: string;
  out ErrorText: string): Boolean;
begin
  Result := TryDecodeCurveSets(Text, FCurveSets, ErrorText);
  if Result then
  begin
    FSelectedVertex := -1;
    MarkDeformationDirty;
    SetEditorStatus;
    PreviewPaintBox.Invalidate;
  end;
end;

function TFormShakeSettings.TrySaveCurveDataText(
  out Text, ErrorText: string): Boolean;
begin
  Result := TryEncodeCurveSets(FCurveSets, Text, ErrorText);
end;

end.
