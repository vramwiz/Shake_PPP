object FormShakeSettings: TFormShakeSettings
  Left = 0
  Top = 0
  Caption = #33016#25594#12428#35373#23450
  ClientHeight = 640
  ClientWidth = 960
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poScreenCenter
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnMouseWheel = FormMouseWheel
  TextHeight = 15
  object PreviewPaintBox: TPaintBox
    Left = 0
    Top = 64
    Width = 960
    Height = 528
    Align = alClient
    OnDblClick = PreviewPaintBoxDblClick
    OnMouseDown = PreviewPaintBoxMouseDown
    OnMouseMove = PreviewPaintBoxMouseMove
    OnMouseUp = PreviewPaintBoxMouseUp
    OnPaint = PreviewPaintBoxPaint
    ExplicitTop = 56
    ExplicitHeight = 536
  end
  object TopPanel: TPanel
    Left = 0
    Top = 0
    Width = 960
    Height = 64
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object ZoomLabel: TLabel
      Left = 284
      Top = 10
      Width = 20
      Height = 15
      Caption = 'Fit'
    end
    object StatusLabel: TLabel
      Left = 12
      Top = 39
      Width = 936
      Height = 17
      AutoSize = False
      Caption = 'No framebuffer has been captured.'
      EllipsisPosition = epEndEllipsis
    end
    object FitButton: TButton
      Left = 12
      Top = 6
      Width = 90
      Height = 27
      Caption = #20840#20307#34920#31034
      TabOrder = 0
      OnClick = FitButtonClick
    end
    object ZoomTrackBar: TTrackBar
      Left = 112
      Top = 4
      Width = 160
      Height = 32
      Max = 400
      Min = 25
      Frequency = 25
      Position = 100
      ShowSelRange = False
      TabOrder = 1
      ThumbLength = 16
      TickMarks = tmBoth
      TickStyle = tsNone
      OnChange = ZoomTrackBarChange
    end
  end
  object BottomPanel: TPanel
    Left = 0
    Top = 592
    Width = 960
    Height = 48
    Align = alBottom
    BevelOuter = bvNone
    TabOrder = 1
    object CloseButton: TButton
      Left = 864
      Top = 10
      Width = 84
      Height = 28
      Anchors = [akTop, akRight]
      Caption = #38281#12376#12427
      ModalResult = 8
      TabOrder = 0
    end
  end
end

