unit Shake_PPP_ToolbarButtons;

// Provides DPI-aware procedural buttons for the shape editor toolbar.

interface

uses
  System.Classes,
  System.Generics.Collections,
  System.Types,
  System.UITypes,
  Winapi.Messages,
  Vcl.Controls,
  Vcl.ExtCtrls,
  Vcl.Graphics;

type
  TShakeToolbarButtonKind = (stbkCommand, stbkToggle, stbkSeparator);
  TShakeToolbarCheckState = (stcsUnchecked, stcsChecked);
  TShakeToolbarGlyph = (
    stgNone,
    stgCurveSet1,
    stgCurveSet2,
    stgOuterContour,
    stgCenterContour,
    stgMotionPreview,
    stgCornerPoint,
    stgSmoothPoint,
    stgOriginalView,
    stgDeformedView,
    stgFit,
    stgArcStart,
    stgArcEnd,
    stgArcReverse
  );

  TShakeToolbarButton = class;
  TShakeToolbarButtonExecuteEvent = procedure(Sender: TObject;
    Button: TShakeToolbarButton) of object;

  TShakeToolbarButton = class(TCustomControl)
  private
    FCheckState: TShakeToolbarCheckState;
    FGlyph: TShakeToolbarGlyph;
    FGroupIndex: Integer;
    FHot: Boolean;
    FKind: TShakeToolbarButtonKind;
    FOnExecute: TShakeToolbarButtonExecuteEvent;
    FOwnerExecute: TShakeToolbarButtonExecuteEvent;
    FPressed: Boolean;
    procedure SetCheckState(Value: TShakeToolbarCheckState);
  protected
    procedure CMMouseEnter(var Message: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Execute;
    property Glyph: TShakeToolbarGlyph read FGlyph write FGlyph;
    property GroupIndex: Integer read FGroupIndex write FGroupIndex;
    property Kind: TShakeToolbarButtonKind read FKind write FKind;
    property OnExecute: TShakeToolbarButtonExecuteEvent read FOnExecute
      write FOnExecute;
  published
    property Caption;
    property CheckState: TShakeToolbarCheckState read FCheckState
      write SetCheckState default stcsUnchecked;
    property Enabled;
    property Font;
    property Hint;
    property OnClick;
    property ParentFont;
    property ParentShowHint;
    property ShowHint;
    property TabOrder;
    property TabStop;
    property Visible;
  end;

  TShakeDarkTrackBar = class(TCustomControl)
  private
    FDragging: Boolean;
    FMax: Integer;
    FMin: Integer;
    FOnChange: TNotifyEvent;
    FPageSize: Integer;
    FPosition: Integer;
    procedure SetMax(Value: Integer);
    procedure SetMin(Value: Integer);
    procedure SetPosition(Value: Integer);
    procedure UpdatePositionFromMouse(X: Integer);
  protected
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Anchors;
    property Enabled;
    property Max: Integer read FMax write SetMax default 100;
    property Min: Integer read FMin write SetMin default 0;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property PageSize: Integer read FPageSize write FPageSize default 10;
    property Position: Integer read FPosition write SetPosition default 0;
    property TabOrder;
    property TabStop;
    property Visible;
  end;

  TShakeToolbarButtons = class(TCustomPanel)
  private
    FButtonExtent: Integer;
    FItems: TObjectList<TShakeToolbarButton>;
    FOnButtonExecute: TShakeToolbarButtonExecuteEvent;
    FSeparatorExtent: Integer;
    procedure ButtonExecute(Sender: TObject; Button: TShakeToolbarButton);
    procedure UpdateLayout;
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function AddButton(const HintText: string; Glyph: TShakeToolbarGlyph;
      Kind: TShakeToolbarButtonKind; TagValue: NativeInt;
      GroupIndex: Integer = 0):
      TShakeToolbarButton;
    function AddCommand(const HintText: string; Glyph: TShakeToolbarGlyph;
      TagValue: NativeInt): TShakeToolbarButton;
    function AddToggle(const HintText: string; Glyph: TShakeToolbarGlyph;
      TagValue: NativeInt; GroupIndex: Integer = 0): TShakeToolbarButton;
    procedure AddSeparator;
    property ButtonExtent: Integer read FButtonExtent write FButtonExtent;
    property SeparatorExtent: Integer read FSeparatorExtent
      write FSeparatorExtent;
  published
    property Align;
    property Anchors;
    property Color;
    property OnButtonExecute: TShakeToolbarButtonExecuteEvent
      read FOnButtonExecute write FOnButtonExecute;
    property ParentBackground;
    property ParentColor;
  end;

implementation

uses
  System.Math,
  Winapi.Windows;

function BlendColor(Base, Overlay: TColor; Amount: Byte): TColor;
var
  B: Cardinal;
  O: Cardinal;
  Inverse: Cardinal;
begin
  B := ColorToRGB(Base);
  O := ColorToRGB(Overlay);
  Inverse := 255 - Amount;
  Result := TColor(
    (((B and $FF) * Inverse + (O and $FF) * Amount) div 255) or
    (((((B shr 8) and $FF) * Inverse + ((O shr 8) and $FF) * Amount)
      div 255) shl 8) or
    (((((B shr 16) and $FF) * Inverse + ((O shr 16) and $FF) * Amount)
      div 255) shl 16));
end;

constructor TShakeToolbarButton.Create(AOwner: TComponent);
begin
  inherited;
  ControlStyle := ControlStyle + [csClickEvents, csCaptureMouse];
  FCheckState := stcsUnchecked;
  FGroupIndex := 0;
  FKind := stbkCommand;
  ParentShowHint := True;
  TabStop := True;
end;

procedure TShakeToolbarButton.CMMouseEnter(var Message: TMessage);
begin
  inherited;
  FHot := True;
  Invalidate;
end;

procedure TShakeToolbarButton.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  FHot := False;
  Invalidate;
end;

procedure TShakeToolbarButton.Execute;
begin
  if not Enabled or (FKind = stbkSeparator) then
    Exit;
  Click;
  if Assigned(FOnExecute) then
    FOnExecute(Self, Self);
  if Assigned(FOwnerExecute) then
    FOwnerExecute(Self, Self);
end;

procedure TShakeToolbarButton.MouseDown(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if (Button <> mbLeft) or not Enabled or (FKind = stbkSeparator) then
    Exit;
  FPressed := True;
  MouseCapture := True;
  Invalidate;
end;

procedure TShakeToolbarButton.MouseUp(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  ShouldExecute: Boolean;
begin
  inherited;
  if (Button <> mbLeft) or not FPressed then
    Exit;
  ShouldExecute := PtInRect(ClientRect, Point(X, Y));
  FPressed := False;
  MouseCapture := False;
  Invalidate;
  if ShouldExecute then
    Execute;
end;

procedure TShakeToolbarButton.Paint;
var
  BackColor: TColor;
  BorderColor: TColor;
  ColorValue: Cardinal;
  DarkBackground: Boolean;
  H: Integer;
  MidX: Integer;
  MidY: Integer;
  P: array[0..3] of TPoint;
  TextRect: TRect;
  TextColor: TColor;
begin
  H := Min(ClientWidth, ClientHeight);
  MidX := ClientWidth div 2;
  MidY := ClientHeight div 2;
  if Parent <> nil then
    BackColor := Parent.Brush.Color
  else
    BackColor := clBtnFace;
  ColorValue := ColorToRGB(BackColor);
  DarkBackground := (((ColorValue and $FF) * 299 +
    ((ColorValue shr 8) and $FF) * 587 +
    ((ColorValue shr 16) and $FF) * 114) div 1000) < 128;
  if DarkBackground then
    BorderColor := BlendColor(BackColor, clWhite, 75)
  else
    BorderColor := BlendColor(BackColor, clBtnShadow, 100);
  if FPressed then
    BackColor := BlendColor(BackColor, clHighlight, 90)
  else if FCheckState = stcsChecked then
    BackColor := BlendColor(BackColor, clHighlight, 65)
  else if FHot then
    BackColor := BlendColor(BackColor, clWhite, 10);
  { Glyph drawing leaves the brush transparent. Restore it before clearing the
    control or an old checked background remains visible after unchecking. }
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := BackColor;
  Canvas.Pen.Color := BackColor;
  Canvas.Rectangle(ClientRect);
  if FPressed or (FCheckState = stcsChecked) then
  begin
    Canvas.Brush.Style := bsClear;
    Canvas.Pen.Color := BorderColor;
    Canvas.Rectangle(0, 0, ClientWidth, ClientHeight);
  end;
  if FKind = stbkSeparator then
  begin
    Canvas.Pen.Color := BorderColor;
    Canvas.MoveTo(MidX, H div 4);
    Canvas.LineTo(MidX, H - H div 4);
    Exit;
  end;
  if Enabled then
  begin
    if DarkBackground then
      TextColor := RGB(225, 225, 225)
    else
      TextColor := clWindowText;
  end
  else if DarkBackground then
    TextColor := RGB(105, 105, 105)
  else
    TextColor := clGrayText;
  Canvas.Pen.Color := TextColor;
  Canvas.Pen.Width := Max(1, H div 18);
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Assign(Font);
  Canvas.Font.Color := TextColor;
  TextRect := ClientRect;
  case FGlyph of
    stgNone:
      DrawText(Canvas.Handle, PChar(Caption), -1, TextRect,
        DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_END_ELLIPSIS);
    stgCurveSet1,
    stgCurveSet2:
      begin
        Canvas.Rectangle(MidX - H div 3, MidY - H div 3,
          MidX + H div 3 + 1, MidY + H div 3 + 1);
        Canvas.Font.Color := TextColor;
        Canvas.Font.Style := [fsBold];
        if FGlyph = stgCurveSet1 then
          Canvas.TextOut(MidX - Canvas.TextWidth('1') div 2,
            MidY - Canvas.TextHeight('1') div 2, '1')
        else
          Canvas.TextOut(MidX - Canvas.TextWidth('2') div 2,
            MidY - Canvas.TextHeight('2') div 2, '2');
        Canvas.Font.Style := [];
      end;
    stgOuterContour:
      begin
        Canvas.Pen.Color := $00D8A020;
        Canvas.Ellipse(MidX - H div 3, MidY - H div 3,
          MidX + H div 3, MidY + H div 3);
        Canvas.Brush.Color := Canvas.Pen.Color;
        Canvas.Rectangle(MidX - H div 3 - 2, MidY - 2,
          MidX - H div 3 + 3, MidY + 3);
      end;
    stgCenterContour:
      begin
        Canvas.Pen.Color := $003080F0;
        Canvas.Ellipse(MidX - H div 4, MidY - H div 4,
          MidX + H div 4, MidY + H div 4);
        Canvas.Brush.Color := Canvas.Pen.Color;
        Canvas.Ellipse(MidX - 3, MidY - 3, MidX + 4, MidY + 4);
      end;
    stgMotionPreview:
      begin
        Canvas.Rectangle(MidX - 11, MidY - 8, MidX + 12, MidY + 9);
        Canvas.Brush.Style := bsSolid;
        Canvas.Brush.Color := TextColor;
        Canvas.Polygon([Point(MidX - 3, MidY - 5),
          Point(MidX + 7, MidY), Point(MidX - 3, MidY + 6)]);
        Canvas.Brush.Style := bsClear;
      end;
    stgCornerPoint:
      begin
        Canvas.Polyline([Point(MidX - 10, MidY + 7),
          Point(MidX, MidY - 7), Point(MidX + 10, MidY + 7)]);
        Canvas.Brush.Color := TextColor;
        Canvas.Rectangle(MidX - 3, MidY - 10, MidX + 4, MidY - 3);
      end;
    stgSmoothPoint:
      begin
        P[0] := Point(MidX - 11, MidY + 6);
        P[1] := Point(MidX - 5, MidY - 8);
        P[2] := Point(MidX + 5, MidY - 8);
        P[3] := Point(MidX + 11, MidY + 6);
        PolyBezier(Canvas.Handle, P[0], 4);
        Canvas.Pen.Width := 1;
        Canvas.MoveTo(MidX - 8, MidY - 5);
        Canvas.LineTo(MidX + 8, MidY - 5);
        Canvas.Brush.Color := TextColor;
        Canvas.Ellipse(MidX - 3, MidY - 8, MidX + 4, MidY - 1);
      end;
    stgOriginalView:
      begin
        Canvas.Rectangle(MidX - 10, MidY - 8, MidX + 11, MidY + 9);
        Canvas.Polyline([Point(MidX - 8, MidY + 5),
          Point(MidX - 2, MidY - 1), Point(MidX + 2, MidY + 3),
          Point(MidX + 8, MidY - 4)]);
        Canvas.Ellipse(MidX - 6, MidY - 5, MidX - 2, MidY - 1);
      end;
    stgDeformedView:
      begin
        Canvas.Rectangle(MidX - 10, MidY - 8, MidX + 11, MidY + 9);
        P[0] := Point(MidX - 8, MidY + 4);
        P[1] := Point(MidX - 2, MidY - 7);
        P[2] := Point(MidX + 3, MidY + 9);
        P[3] := Point(MidX + 8, MidY - 3);
        PolyBezier(Canvas.Handle, P[0], 4);
      end;
    stgFit:
      begin
        Canvas.MoveTo(MidX - 10, MidY - 3);
        Canvas.LineTo(MidX - 10, MidY - 9);
        Canvas.LineTo(MidX - 4, MidY - 9);
        Canvas.MoveTo(MidX + 10, MidY - 3);
        Canvas.LineTo(MidX + 10, MidY - 9);
        Canvas.LineTo(MidX + 4, MidY - 9);
        Canvas.MoveTo(MidX - 10, MidY + 3);
        Canvas.LineTo(MidX - 10, MidY + 9);
        Canvas.LineTo(MidX - 4, MidY + 9);
        Canvas.MoveTo(MidX + 10, MidY + 3);
        Canvas.LineTo(MidX + 10, MidY + 9);
        Canvas.LineTo(MidX + 4, MidY + 9);
      end;
    stgArcStart,
    stgArcEnd,
    stgArcReverse:
      begin
        Canvas.Arc(MidX - 10, MidY - 9, MidX + 11, MidY + 10,
          MidX - 8, MidY + 6, MidX + 8, MidY + 6);
        Canvas.Font.Color := TextColor;
        Canvas.Font.Style := [fsBold];
        if FGlyph = stgArcStart then
          Canvas.TextOut(MidX - Canvas.TextWidth('S') div 2,
            MidY - Canvas.TextHeight('S') div 2, 'S')
        else if FGlyph = stgArcEnd then
          Canvas.TextOut(MidX - Canvas.TextWidth('E') div 2,
            MidY - Canvas.TextHeight('E') div 2, 'E')
        else
          Canvas.TextOut(MidX - Canvas.TextWidth('R') div 2,
            MidY - Canvas.TextHeight('R') div 2, 'R');
        Canvas.Font.Style := [];
      end;
  end;
  Canvas.Pen.Width := 1;
end;

constructor TShakeDarkTrackBar.Create(AOwner: TComponent);
begin
  inherited;
  ControlStyle := ControlStyle + [csClickEvents, csCaptureMouse,
    csOpaque];
  FMin := 0;
  FMax := 100;
  FPageSize := 10;
  FPosition := 0;
  TabStop := True;
  Height := 30;
end;

procedure TShakeDarkTrackBar.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited;
  case Key of
    VK_LEFT, VK_DOWN:
      Position := Position - 1;
    VK_RIGHT, VK_UP:
      Position := Position + 1;
    VK_PRIOR:
      Position := Position + System.Math.Max(1, FPageSize);
    VK_NEXT:
      Position := Position - System.Math.Max(1, FPageSize);
    VK_HOME:
      Position := FMin;
    VK_END:
      Position := FMax;
  else
    Exit;
  end;
  Key := 0;
end;

procedure TShakeDarkTrackBar.MouseDown(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if (Button <> mbLeft) or not Enabled then
    Exit;
  SetFocus;
  FDragging := True;
  MouseCapture := True;
  UpdatePositionFromMouse(X);
end;

procedure TShakeDarkTrackBar.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FDragging then
    UpdatePositionFromMouse(X);
end;

procedure TShakeDarkTrackBar.MouseUp(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if (Button <> mbLeft) or not FDragging then
    Exit;
  UpdatePositionFromMouse(X);
  FDragging := False;
  MouseCapture := False;
end;

procedure TShakeDarkTrackBar.Paint;
const
  DARK_BORDER = TColor($00505050);
  DARK_FILL = TColor($00D77800);
  DARK_TRACK = TColor($003A3A3A);
var
  BackColor: TColor;
  FillRight: Integer;
  RangeValue: Integer;
  TrackRect: TRect;
  ThumbX: Integer;
  ThumbRadius: Integer;
begin
  if Parent <> nil then
    BackColor := Parent.Brush.Color
  else
    BackColor := TColor($00262626);
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := BackColor;
  Canvas.FillRect(ClientRect);

  ThumbRadius := System.Math.Max(5, MulDiv(7, CurrentPPI, 96));
  TrackRect := Rect(ThumbRadius, ClientHeight div 2 - System.Math.Max(2,
    MulDiv(2, CurrentPPI, 96)), ClientWidth - ThumbRadius,
    ClientHeight div 2 + System.Math.Max(2,
      MulDiv(2, CurrentPPI, 96)) + 1);
  RangeValue := System.Math.Max(1, FMax - FMin);
  ThumbX := TrackRect.Left + MulDiv(TrackRect.Width,
    FPosition - FMin, RangeValue);

  Canvas.Brush.Color := DARK_TRACK;
  Canvas.Pen.Color := DARK_BORDER;
  Canvas.Rectangle(TrackRect);
  FillRight := EnsureRange(ThumbX, TrackRect.Left, TrackRect.Right);
  if FillRight > TrackRect.Left then
  begin
    Canvas.Brush.Color := DARK_FILL;
    Canvas.Pen.Color := DARK_FILL;
    Canvas.Rectangle(TrackRect.Left + 1, TrackRect.Top + 1,
      FillRight, TrackRect.Bottom - 1);
  end;

  if Enabled then
    Canvas.Brush.Color := DARK_FILL
  else
    Canvas.Brush.Color := DARK_BORDER;
  Canvas.Pen.Color := BlendColor(Canvas.Brush.Color, clWhite, 55);
  Canvas.Ellipse(ThumbX - ThumbRadius, ClientHeight div 2 - ThumbRadius,
    ThumbX + ThumbRadius + 1, ClientHeight div 2 + ThumbRadius + 1);
  if Focused then
  begin
    Canvas.Brush.Style := bsClear;
    Canvas.Pen.Color := BlendColor(BackColor, clWhite, 70);
    Canvas.Rectangle(1, 1, ClientWidth - 1, ClientHeight - 1);
  end;
end;

procedure TShakeDarkTrackBar.SetMax(Value: Integer);
begin
  if Value <= FMin then
    Value := FMin + 1;
  if FMax = Value then
    Exit;
  FMax := Value;
  SetPosition(FPosition);
  Invalidate;
end;

procedure TShakeDarkTrackBar.SetMin(Value: Integer);
begin
  if Value >= FMax then
    Value := FMax - 1;
  if FMin = Value then
    Exit;
  FMin := Value;
  SetPosition(FPosition);
  Invalidate;
end;

procedure TShakeDarkTrackBar.SetPosition(Value: Integer);
begin
  Value := EnsureRange(Value, FMin, FMax);
  if FPosition = Value then
    Exit;
  FPosition := Value;
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TShakeDarkTrackBar.UpdatePositionFromMouse(X: Integer);
var
  RangeWidth: Integer;
  ThumbRadius: Integer;
begin
  ThumbRadius := System.Math.Max(5, MulDiv(7, CurrentPPI, 96));
  RangeWidth := System.Math.Max(1, ClientWidth - ThumbRadius * 2);
  Position := FMin + MulDiv(EnsureRange(X - ThumbRadius, 0, RangeWidth),
    FMax - FMin, RangeWidth);
end;

procedure TShakeToolbarButton.SetCheckState(Value: TShakeToolbarCheckState);
begin
  if FCheckState = Value then
    Exit;
  FCheckState := Value;
  Invalidate;
end;

constructor TShakeToolbarButtons.Create(AOwner: TComponent);
begin
  inherited;
  BevelOuter := bvNone;
  FButtonExtent := 28;
  FSeparatorExtent := 6;
  FItems := TObjectList<TShakeToolbarButton>.Create(True);
end;

destructor TShakeToolbarButtons.Destroy;
begin
  FItems.Free;
  inherited;
end;

function TShakeToolbarButtons.AddButton(const HintText: string;
  Glyph: TShakeToolbarGlyph; Kind: TShakeToolbarButtonKind;
  TagValue: NativeInt; GroupIndex: Integer): TShakeToolbarButton;
begin
  Result := TShakeToolbarButton.Create(Self);
  Result.Parent := Self;
  Result.Hint := HintText;
  Result.ShowHint := True;
  Result.Glyph := Glyph;
  Result.Kind := Kind;
  Result.GroupIndex := GroupIndex;
  Result.Tag := TagValue;
  Result.FOwnerExecute := ButtonExecute;
  FItems.Add(Result);
  UpdateLayout;
end;

function TShakeToolbarButtons.AddCommand(const HintText: string;
  Glyph: TShakeToolbarGlyph; TagValue: NativeInt): TShakeToolbarButton;
begin
  Result := AddButton(HintText, Glyph, stbkCommand, TagValue);
end;

function TShakeToolbarButtons.AddToggle(const HintText: string;
  Glyph: TShakeToolbarGlyph; TagValue: NativeInt;
  GroupIndex: Integer): TShakeToolbarButton;
begin
  Result := AddButton(HintText, Glyph, stbkToggle, TagValue, GroupIndex);
end;

procedure TShakeToolbarButtons.AddSeparator;
begin
  AddButton('', stgNone, stbkSeparator, -1);
end;

procedure TShakeToolbarButtons.ButtonExecute(Sender: TObject;
  Button: TShakeToolbarButton);
var
  Item: TShakeToolbarButton;
begin
  { Radio groups are enforced here, independently of the form state.  This
    prevents a delayed repaint or a future handler change from leaving two
    mutually exclusive tools selected. }
  if (Button.Kind = stbkToggle) and (Button.GroupIndex > 0) then
    for Item in FItems do
      if (Item.Kind = stbkToggle) and
        (Item.GroupIndex = Button.GroupIndex) then
        if Item = Button then
          Item.CheckState := stcsChecked
        else
          Item.CheckState := stcsUnchecked;
  if Assigned(FOnButtonExecute) then
    FOnButtonExecute(Self, Button);
end;

procedure TShakeToolbarButtons.Resize;
begin
  inherited;
  UpdateLayout;
end;

procedure TShakeToolbarButtons.UpdateLayout;
var
  Item: TShakeToolbarButton;
  ItemWidth: Integer;
  X: Integer;
begin
  X := 0;
  for Item in FItems do
  begin
    if Item.Kind = stbkSeparator then
      ItemWidth := FSeparatorExtent
    else
      ItemWidth := FButtonExtent;
    Item.SetBounds(X, 0, ItemWidth, FButtonExtent);
    Inc(X, ItemWidth);
  end;
end;

end.
