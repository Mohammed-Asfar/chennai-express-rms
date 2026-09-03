; Chennai Express RMS installer.
;
; Build with installer\build.ps1 rather than compiling this directly — the script
; checks that both halves were built, passes the version in, and prints the
; SHA-256 that publish:release needs.
;
; What this installs:
;   the Flutter desktop app, per-machine
;   the bundled backend, with its own Node runtime
;   an encrypted config.dat, generated on this machine at install time
;
; No Windows service is registered. The app starts the backend itself as a child
; process — see desktop\lib\core\backend\backend_process.dart. node.exe does not
; call StartServiceCtrlDispatcher, so a service pointing at it is killed after
; ninety seconds with error 1053, and the wrapper that works around it added a
; vendored binary and an elevated registration step that could fail in half a
; dozen ways.

#define AppName "Chennai Express"
#define AppPublisher "Chennai Express"
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

; Writing to Program Files needs elevation, and nothing else here does — the
; backend is started by the app rather than registered as a service.
;
; Program Files is kept deliberately: it is write-protected for standard users,
; which is now what stops a cashier replacing server.mjs or deleting config.dat.
; That is weaker than the ACL a service account allowed, but it is the same
; protection every other installed application relies on.
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

; The bundled backend, its private Node runtime and migrations.
Source: "{#BackendDir}\*"; DestDir: "{app}\backend"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#DesktopExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#DesktopExe}"; Tasks: desktopicon

[Run]
; Only the app launch lives here. Configuration runs from [Code] instead, so its
; exit code is checked — a [Run] entry that fails is reported nowhere, and an
; install that silently skipped it would leave an app with no cloud and no
; stable signing secret.
Filename: "{app}\{#DesktopExe}"; \
  Description: "Start {#AppName}"; \
  Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Generated after install, so Setup does not know about them.
Type: files; Name: "{app}\backend\config.dat"
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
  Stops a running copy before replacing its files.

  Windows will not overwrite a file that is in use, so an upgrade that skipped
  this would copy some files and leave others at the old version — the worst
  state to be in, because the till still starts.

  Both processes are ended: the app, and the backend it spawned. Killing only
  the app would leave a detached node holding port 4000, and the newly installed
  copy would then find the port taken.
}
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';

  Exec('taskkill.exe', '/F /IM {#DesktopExe}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  { By path, not by name: a developer's own node.exe must not be killed by
    installing this. }
  Exec(ExpandConstant('{cmd}'),
       '/c wmic process where "ExecutablePath=''' +
         ExpandConstant('{app}\backend\node\node.exe') + '''" delete',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  Sleep(1500);
end;

{
  Runs a PowerShell step and returns its exit code.

  Output is captured to a log rather than hidden. When this fails, the message is
  the only thing that tells anyone why — an earlier version ran it with runhidden
  and reported success while having done nothing.
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
  Writes the encrypted configuration, after the files are copied.

  It must succeed. Without it the backend starts with no cloud connection and a
  signing secret that changes on every launch, so a failure aborts the install
  rather than leaving a half-working product behind.
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

  { No service is registered. The app starts the backend itself as a child
    process — see desktop\lib\core\backend\backend_process.dart. node.exe does
    not speak the Service Control Manager protocol, and every attempt to
    register it produced a service the SCM killed after ninety seconds. }
end;
