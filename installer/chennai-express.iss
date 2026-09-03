; Chennai Express RMS installer.
;
; Build with installer\build.ps1 rather than compiling this directly — the script
; checks that both halves were built, passes the version in, and prints the
; SHA-256 that publish:release needs.
;
; What this installs:
;   the Flutter desktop app, per-machine
;   the bundled backend, with its own Node runtime
;   the backend as an auto-starting Windows service
;   an encrypted config.dat, generated on this machine at install time
;
; The install directory is then locked to Administrators and SYSTEM. That ACL is
; what stops a cashier reading the connection string or replacing the server, and
; without it the licence check is decoration.

#define AppName "Chennai Express"
#define AppPublisher "Chennai Express"
#define ServiceName "ChennaiExpressRMS"
#define DesktopExe "chennai_express_pos.exe"

; Passed by build.ps1 (/DAppVersion=...). The fallback keeps a manual compile
; working, but a release should always carry the real version.
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#ifndef DesktopDir
  #define DesktopDir "..\desktop\build\windows\x64\runner\Release"
#endif

#ifndef BackendDir
  #define BackendDir "..\backend\dist-bundle"
#endif

[Setup]
AppId={{8F3A6C21-4D7E-4B29-9A15-2E7C8D4F1B60}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=chennai-express-setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

; The service must be installed and the directory ACL'd, both of which need
; elevation. Asking once up front beats failing halfway through.
PrivilegesRequired=admin

; The backend ships a 64-bit Node and Flutter builds x64 only.
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible

UninstallDisplayIcon={app}\{#DesktopExe}
SetupIconFile=..\desktop\windows\runner\resources\app_icon.ico

; A till running an update must not be asked to close the app it is already
; closing. Setup detects the running instance instead.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
; The Flutter app.
Source: "{#DesktopDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; The bundled backend, its private Node runtime, migrations and service script.
Source: "{#BackendDir}\*"; DestDir: "{app}\backend"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#DesktopExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#DesktopExe}"; Tasks: desktopicon

[Run]
; Only the app launch lives here. Configuration and the service are run from
; [Code] instead, so their exit codes are checked — a [Run] entry that fails is
; reported nowhere, and an install that skips the service produces an app which
; looks installed and can never start.
Filename: "{app}\{#DesktopExe}"; \
  Description: "Start {#AppName}"; \
  Flags: nowait postinstall skipifsilent

[UninstallRun]
; Through the wrapper, and before the files go: it cannot deregister itself once
; its own executable has been deleted.
Filename: "{app}\backend\chennai-service.exe"; Parameters: "stop"; \
  RunOnceId: "StopService"; Flags: runhidden waituntilterminated

Filename: "{app}\backend\chennai-service.exe"; Parameters: "uninstall"; \
  RunOnceId: "RemoveService"; \
  Flags: runhidden waituntilterminated

[UninstallDelete]
; Generated after install, so Setup does not know about them.
Type: files; Name: "{app}\backend\config.dat"
Type: files; Name: "{app}\backend\chennai-service.xml"
Type: filesandordirs; Name: "{app}\backend\logs"

[Code]

{
  A line beginning with a hash is read as a preprocessor directive, even inside
  a comment, so the usual character-code escape cannot start a continuation
  line. Naming it sidesteps that and reads better in the messages below.
}
const
  NL = #13#10;

{
  The local database is deliberately NOT deleted on uninstall.

  It holds bills, and Indian GST requires six years of retention. An uninstall —
  which is also what an operator runs before a clean reinstall — must never be
  the thing that destroys a restaurant's financial records. The data directory is
  left in place and reused if the app is installed again.
}

function InitializeUninstall(): Boolean;
begin
  Result := MsgBox(
    'Remove Chennai Express from this PC?' + #13#10 + #13#10 +
    'Your bills and settings will be kept. Reinstalling will pick them up again.',
    mbConfirmation, MB_YESNO) = IDYES;
end;

{
  Refuses to install over a running service without stopping it first.

  Windows will not replace a file that is in use, so an upgrade that skipped this
  would copy some files and silently leave others at the old version — the worst
  possible state, because the till still starts.
}
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';

  if Exec('sc.exe', 'query {#ServiceName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if ResultCode = 0 then
    begin
      { Through the wrapper if it is there, so the child node process is stopped
        too — sc.exe stop reaches the wrapper but need not reach its children. }
      if FileExists(ExpandConstant('{app}\backend\chennai-service.exe')) then
        Exec(ExpandConstant('{cmd}'),
             '/c ""' + ExpandConstant('{app}\backend\chennai-service.exe') + '" stop"',
             '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
      else
        Exec('sc.exe', 'stop {#ServiceName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

      { The service manager returns before the process has exited. }
      Sleep(3000);
    end;
  end;
end;

{
  Runs a PowerShell step and returns its exit code.

  Output is captured to a log rather than hidden. When one of these fails, the
  message is the only thing that tells anyone why — an earlier version ran both
  steps with runhidden and reported success while installing no service at all.
}
function RunPowerShell(const ScriptArgs: String; var Output: String): Integer;
var
  ResultCode: Integer;
  LogFile: String;
  Lines: TArrayOfString;
  I: Integer;
begin
  LogFile := ExpandConstant('{tmp}\step.log');

  { Out-File -Encoding ASCII, not Tee-Object: Tee-Object writes UTF-16, and
    LoadStringsFromFile reads bytes, so the message arrives as mojibake — the
    first attempt at this showed a three-character error nobody could act on. }
  if not Exec(
    'powershell.exe',
    '-NoProfile -ExecutionPolicy Bypass -Command "& { ' + ScriptArgs +
      ' } *>&1 | Out-File -FilePath ''' + LogFile + ''' -Encoding ASCII"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    Output := 'PowerShell could not be started.';
    Result := -1;
    Exit;
  end;

  Output := '';
  if LoadStringsFromFile(LogFile, Lines) then
  begin
    for I := 0 to GetArrayLength(Lines) - 1 do
      Output := Output + Lines[I] + #13#10;
  end;

  Result := ResultCode;
end;

{
  Writes the configuration and installs the service, after the files are copied.

  Both must succeed. Without the service there is no backend, and the app shows
  nothing but an unreachable-service screen — so a failure here aborts the
  install rather than leaving a half-working product behind.
}
procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
  Output: String;
begin
  if CurStep <> ssPostInstall then
    Exit;

  WizardForm.StatusLabel.Caption := 'Preparing configuration...';
  Code := RunPowerShell(
    '& ''' + ExpandConstant('{app}\backend\configure.ps1') +
      ''' -Path ''' + ExpandConstant('{app}\backend') + '''', Output);

  if Code <> 0 then
  begin
    MsgBox('The configuration could not be written.' + NL + NL + Output + NL +
      'Setup will not continue.', mbCriticalError, MB_OK);
    Abort;
  end;

  WizardForm.StatusLabel.Caption := 'Installing the billing service...';
  Code := RunPowerShell(
    '& ''' + ExpandConstant('{app}\backend\service.ps1') +
      ''' install -Path ''' + ExpandConstant('{app}\backend') + '''', Output);

  if Code <> 0 then
  begin
    MsgBox('The billing service could not be installed.' + NL + NL + Output + NL +
      'The application cannot run without it. Setup will not continue.',
      mbCriticalError, MB_OK);
    Abort;
  end;
end;
