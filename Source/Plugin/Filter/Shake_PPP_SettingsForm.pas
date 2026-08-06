unit Shake_PPP_SettingsForm;

// Displays the latest pre-filter framebuffer and provides basic navigation.

interface

uses
  System.Classes,
  System.Types,
  System.SysUtils,
  Vcl.ComCtrls,
  Vcl.Controls,
  Vcl.ExtCtrls,
  Vcl.Forms,
  Vcl.Graphics,
  Vcl.StdCtrls;

type
  TFormShakeSettings = class(TForm)
    BottomPanel: TPanel;
    CloseButton: TButton;
    FitButton: TButton;
    PreviewPaintBox: TPaintBox;
    StatusLabel: TLabel;
    TopPanel: TPanel;
    ZoomLabel: TLabel;
    ZoomTrackBar: TTrackBar;
    procedure FitButtonClick(Sender: TObject);
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
    procedure ZoomTrackBarChange(Sender: TObject);
  private
    FBackground: TBitmap;
    FBackBuffer: TBitmap;
    FDragging: Boolean;
    FDragOrigin: TPoint;
    FFitToWindow: Boolean;
    FPaintLogged: Boolean;
    FOffset: TPoint;
    FOffsetOrigin: TPoint;
    function BackgroundDestinationRect: TRect;
    procedure EnsureBackBuffer;
    procedure FitImage;
    procedure UpdateZoomLabel;
  public
    procedure SetBackgroundRgba(const Pixels: TBytes;
      Width, Height: Integer);
    procedure SetCaptureStatus(const Value: string);
  end;

implementation

uses
  System.Math,
  Shake_PPP_DebugLog,
  Winapi.Windows;

{$R *.dfm}

type
  TControlAccess = class(TControl);

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
    Scale := ZoomTrackBar.Position / 100.0;
  DrawWidth := Max(1, Round(FBackground.Width * Scale));
  DrawHeight := Max(1, Round(FBackground.Height * Scale));
  Result.Left := (PreviewPaintBox.ClientWidth - DrawWidth) div 2 + FOffset.X;
  Result.Top := (PreviewPaintBox.ClientHeight - DrawHeight) div 2 + FOffset.Y;
  Result.Right := Result.Left + DrawWidth;
  Result.Bottom := Result.Top + DrawHeight;
end;

procedure TFormShakeSettings.FitButtonClick(Sender: TObject);
begin
  FitImage;
end;

procedure TFormShakeSettings.EnsureBackBuffer;
begin
  if (FBackBuffer.Width = PreviewPaintBox.ClientWidth) and
    (FBackBuffer.Height = PreviewPaintBox.ClientHeight) then
    Exit;
  FBackBuffer.SetSize(Max(1, PreviewPaintBox.ClientWidth),
    Max(1, PreviewPaintBox.ClientHeight));
end;

procedure TFormShakeSettings.FitImage;
begin
  FFitToWindow := True;
  FOffset := Point(0, 0);
  UpdateZoomLabel;
  PreviewPaintBox.Invalidate;
end;

procedure TFormShakeSettings.FormCreate(Sender: TObject);
begin
  FBackground := Vcl.Graphics.TBitmap.Create;
  FBackBuffer := Vcl.Graphics.TBitmap.Create;
  FBackBuffer.PixelFormat := pf32bit;
  DoubleBuffered := True;
  TControlAccess(PreviewPaintBox).ControlStyle :=
    TControlAccess(PreviewPaintBox).ControlStyle + [csOpaque];
  FFitToWindow := True;
  FOffset := Point(0, 0);
  ZoomTrackBar.Position := 100;
  UpdateZoomLabel;
  DebugLog('Settings form created.');
end;

procedure TFormShakeSettings.FormDestroy(Sender: TObject);
begin
  DebugLog('Settings form destroyed.');
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
  ZoomTrackBar.Position := EnsureRange(ZoomTrackBar.Position + Delta,
    ZoomTrackBar.Min, ZoomTrackBar.Max);
  ZoomTrackBarChange(ZoomTrackBar);
  Handled := True;
end;

procedure TFormShakeSettings.PreviewPaintBoxDblClick(Sender: TObject);
begin
  FitImage;
end;

procedure TFormShakeSettings.PreviewPaintBoxMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then
    Exit;
  FDragging := True;
  FDragOrigin := Point(X, Y);
  FOffsetOrigin := FOffset;
  TControlAccess(PreviewPaintBox).MouseCapture := True;
  PreviewPaintBox.Cursor := crSizeAll;
end;

procedure TFormShakeSettings.PreviewPaintBoxMouseMove(Sender: TObject;
  Shift: TShiftState; X, Y: Integer);
begin
  if not FDragging then
    Exit;
  FFitToWindow := False;
  FOffset.X := FOffsetOrigin.X + X - FDragOrigin.X;
  FOffset.Y := FOffsetOrigin.Y + Y - FDragOrigin.Y;
  UpdateZoomLabel;
  PreviewPaintBox.Invalidate;
end;

procedure TFormShakeSettings.PreviewPaintBoxMouseUp(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then
    Exit;
  FDragging := False;
  TControlAccess(PreviewPaintBox).MouseCapture := False;
  PreviewPaintBox.Cursor := crDefault;
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
  BufferCanvas.StretchDraw(Destination, FBackground);
  PreviewPaintBox.Canvas.Draw(0, 0, FBackBuffer);
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
  DebugLog(Format('SetBackgroundRgba accepted: size=%dx%d bytes=%d.',
    [Width, Height, Length(Pixels)]));
  FitImage;
end;

procedure TFormShakeSettings.SetCaptureStatus(const Value: string);
begin
  StatusLabel.Caption := Value;
  DebugLog('Capture status shown: ' + Value);
end;

procedure TFormShakeSettings.UpdateZoomLabel;
begin
  if FFitToWindow then
    ZoomLabel.Caption := 'Fit'
  else
    ZoomLabel.Caption := Format('%d%%', [ZoomTrackBar.Position]);
end;

procedure TFormShakeSettings.ZoomTrackBarChange(Sender: TObject);
begin
  FFitToWindow := False;
  UpdateZoomLabel;
  PreviewPaintBox.Invalidate;
end;

end.
