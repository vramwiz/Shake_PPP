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
    stgFit
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
    property CheckState: TShakeToolbarCheckState read FCheckState
      write SetCheckState default stcsUnchecked;
    property Enabled;
    property Hint;
    property ParentShowHint;
    property ShowHint;
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
  case FGlyph of
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
  end;
  Canvas.Pen.Width := 1;
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
