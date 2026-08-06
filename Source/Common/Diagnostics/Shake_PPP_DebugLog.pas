unit Shake_PPP_DebugLog;

// Writes diagnostics only when the plugin is compiled with DEBUG defined.

interface

procedure ResetDebugLog;
procedure DebugLog(const MessageText: string);

implementation

{$IFDEF DEBUG}

uses
  System.Classes,
  System.IOUtils,
  System.SysUtils,
  Winapi.Windows;

const
  DEBUG_LOG_FILE =
    'C:\ProgramData\aviutl2\Plugin\Shake_PPP\Shake_PPP_debug.log';

var
  DebugLogLock: TRTLCriticalSection;

procedure DebugLog(const MessageText: string);
var
  Line: string;
begin
  try
    EnterCriticalSection(DebugLogLock);
    try
      Line := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) +
        Format(' [thread %d] ', [GetCurrentThreadId]) + MessageText + sLineBreak;
      TFile.AppendAllText(DEBUG_LOG_FILE, Line, TEncoding.UTF8);
    finally
      LeaveCriticalSection(DebugLogLock);
    end;
  except
    // Diagnostics must never affect the host application.
  end;
end;

procedure ResetDebugLog;
begin
  try
    EnterCriticalSection(DebugLogLock);
    try
      if TFile.Exists(DEBUG_LOG_FILE) then
        TFile.Delete(DEBUG_LOG_FILE);
    finally
      LeaveCriticalSection(DebugLogLock);
    end;
  except
    // Diagnostics must never affect the host application.
  end;
  DebugLog('Debug log started.');
end;

initialization
  InitializeCriticalSection(DebugLogLock);

finalization
  DeleteCriticalSection(DebugLogLock);

{$ELSE}

procedure DebugLog(const MessageText: string);
begin
end;

procedure ResetDebugLog;
begin
end;

{$ENDIF}

end.

