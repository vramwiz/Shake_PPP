unit AviUtl2FilterTypes;

{$ALIGN 8}

interface

type
  LPCWSTR = PWideChar;
  OBJECT_HANDLE = Pointer;

  PEDIT_SECTION = ^TEDIT_SECTION;
  TFilterItemButtonCallback = procedure(Edit: PEDIT_SECTION); cdecl;
  TSetObjectItemValueFunc = function(Obj: OBJECT_HANDLE; Effect: LPCWSTR;
    Item: LPCWSTR; Value: PAnsiChar): LongBool; cdecl;
  TGetFocusObjectFunc = function: OBJECT_HANDLE; cdecl;

  // AviUtl2 SDKの先頭からGetFocusObjectまでと同じ配置。
  TEDIT_SECTION = record
    Info: Pointer;
    CreateObjectFromAlias: Pointer;
    FindObject: Pointer;
    CountObjectEffect: Pointer;
    GetObjectLayerFrame: Pointer;
    GetObjectAlias: Pointer;
    GetObjectItemValue: Pointer;
    SetObjectItemValue: TSetObjectItemValueFunc;
    MoveObject: Pointer;
    DeleteObject: Pointer;
    GetFocusObject: TGetFocusObjectFunc;
  end;

  PSCENE_INFO = ^TSCENE_INFO;
  TSCENE_INFO = record
    Width, Height: Integer;
    Rate, Scale: Integer;
    SampleRate: Integer;
  end;

  POBJECT_INFO = ^TOBJECT_INFO;
  TOBJECT_INFO = record
    ID: Int64;
    Frame: Integer;
    FrameTotal: Integer;
    Time: Double;
    TimeTotal: Double;
    Width, Height: Integer;
    SampleIndex: Int64;
    SampleTotal: Int64;
    SampleNum: Integer;
    ChannelNum: Integer;
    EffectID: Int64;
    Flag: Integer;
    Layer: Integer;
    Index: Integer;
    Num: Integer;
    FrameS: Integer;
    FrameE: Integer;
    EffectLayer: Integer;
  end;

  POBJECT_IMAGE_PARAM = ^TOBJECT_IMAGE_PARAM;
  TOBJECT_IMAGE_PARAM = record
    X, Y, Z: Single;
    RX, RY, RZ: Single;
    SX, SY, SZ: Single;
    CX, CY, CZ: Single;
    Alpha: Single;
  end;

  TPIXEL_RGBA = packed record
    R, G, B, A: Byte;
  end;
  PPIXEL_RGBA = ^TPIXEL_RGBA;

  TFILTER_PROC_VIDEO_GET_TEX2D = function: Pointer; cdecl;
  TFILTER_PROC_VIDEO_GET_OUTPUT_IMAGE_PARAM = function(Obj: OBJECT_HANDLE;
    Offset: Double; Param: POBJECT_IMAGE_PARAM; ParamSize: Integer): Byte; cdecl;
  TFILTER_PROC_VIDEO_GET_IMAGE_OBJECT = function(Layer: Integer;
    Offset: Double): OBJECT_HANDLE; cdecl;
  PFILTER_PROC_VIDEO = ^TFILTER_PROC_VIDEO;
  TFILTER_PROC_VIDEO = record
    Scene: PSCENE_INFO;
    Object_: POBJECT_INFO;
    GetImageData: procedure(Buffer: PPIXEL_RGBA); cdecl;
    SetImageData: procedure(Buffer: PPIXEL_RGBA; Width, Height: Integer); cdecl;
    GetImageTexture2D: TFILTER_PROC_VIDEO_GET_TEX2D;
    GetFramebufferTexture2D: TFILTER_PROC_VIDEO_GET_TEX2D;
    Edit: PEDIT_SECTION;
    Param: POBJECT_IMAGE_PARAM;
    GetOutputImageParam: TFILTER_PROC_VIDEO_GET_OUTPUT_IMAGE_PARAM;
    GetImageObject: TFILTER_PROC_VIDEO_GET_IMAGE_OBJECT;
  end;

  TFuncProcVideo = function(Video: PFILTER_PROC_VIDEO): Byte; cdecl;
  TFuncProcAudio = function(Audio: Pointer): Byte; cdecl;

  PFILTER_ITEM_STRING = ^TFILTER_ITEM_STRING;
  TFILTER_ITEM_STRING = record
    ItemType: LPCWSTR;
    Name: LPCWSTR;
    Value: LPCWSTR;
  end;

  PFILTER_ITEM_TRACK = ^TFILTER_ITEM_TRACK;
  TFILTER_ITEM_TRACK = record
    ItemType: LPCWSTR;
    Name: LPCWSTR;
    Value: Double;
    S: Double;
    E: Double;
    Step: Double;
  end;

  PFILTER_ITEM_CHECK = ^TFILTER_ITEM_CHECK;
  TFILTER_ITEM_CHECK = record
    ItemType: LPCWSTR;
    Name: LPCWSTR;
    Value: Byte;
  end;

  PFILTER_ITEM_BUTTON = ^TFILTER_ITEM_BUTTON;
  TFILTER_ITEM_BUTTON = record
    ItemType: LPCWSTR;
    Name: LPCWSTR;
    Callback: TFilterItemButtonCallback;
  end;

  PFILTER_PLUGIN_TABLE = ^TFILTER_PLUGIN_TABLE;
  TFILTER_PLUGIN_TABLE = record
    Flag: Integer;
    Name: LPCWSTR;
    Label_: LPCWSTR;
    Information: LPCWSTR;
    Items: ^Pointer;
    Func_Proc_Video: TFuncProcVideo;
    Func_Proc_Audio: TFuncProcAudio;
  end;

const
  FILTER_FLAG_VIDEO = 1;
  FILTER_FLAG_FILTER = 8;

implementation

end.
