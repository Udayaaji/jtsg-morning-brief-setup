; JTSG Morning Brief bootstrapper. Carries the launcher and the setup logic
; only; everything else is fetched at install time, so this file never goes
; stale. No admin rights, no system PATH change, one folder under
; %LOCALAPPDATA%.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppName "JTSG Morning Brief"
#define RepoOwner "Udayaaji"
#define RepoName "jtsg-morning-brief-pipeline"

[Setup]
AppId={{7E2D1A5C-3B0F-4E2A-9C7D-1F6B2A9E4C11}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=JTSG Morning Brief
DefaultDirName={localappdata}\JTSG Morning Brief
DisableDirPage=yes
DefaultGroupName=JTSG Morning Brief
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=JTSG-Morning-Brief-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#AppName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupLogging=yes

[Files]
Source: "app\*"; DestDir: "{app}\app"; Excludes: "uv.exe,version.txt"; Flags: ignoreversion recursesubdirs
; HELP.html is the only doc that ships to the machine: it covers life AFTER
; install, so the client is not sent back to GitHub to remember what a
; notification means. INSTALL_GUIDE.md and its screenshot stay in the repo,
; where they are read before the install exists. HTML, not Markdown, because
; Windows has no default handler for .md and a Help shortcut that opens a
; "how do you want to open this file?" prompt is worse than none.
Source: "docs\HELP.html"; DestDir: "{app}\docs"; Flags: ignoreversion

[Icons]
Name: "{group}\Sign in to Claude"; Filename: "{app}\app\Sign in to Claude.cmd"
Name: "{group}\Run Morning Brief now"; Filename: "{app}\app\Run Morning Brief now.cmd"
Name: "{group}\Morning Brief schedule"; Filename: "{app}\pristine\jtsg_schedule.bat"
Name: "{group}\Morning Brief folder"; Filename: "{code:GetDeliveryFolder}"
Name: "{group}\Help"; Filename: "{app}\docs\HELP.html"

; bootstrap.ps1 is not run from here: [Run] ignores exit codes, so a setup
; failure would be invisible. It runs from CurStepChanged(ssPostInstall)
; instead, which can read the exit code and show the reason.
[Run]
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File ""{app}\app\jtsg_launcher.ps1"""; Description: "Generate today's brief now"; Flags: postinstall nowait unchecked skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -File ""{app}\app\uninstall_cleanup.ps1"""; Flags: runhidden; RunOnceId: "cleanup"

[UninstallDelete]
; app\ carries uv.exe and version.txt, which bootstrap wrote after the install
; and which are therefore not in the uninstall log.
Type: filesandordirs; Name: "{app}\app"
Type: filesandordirs; Name: "{app}\pristine"
Type: filesandordirs; Name: "{app}\pristine_prev"
Type: filesandordirs; Name: "{app}\workspace"
Type: filesandordirs; Name: "{app}\venv"
Type: filesandordirs; Name: "{app}\python"
Type: filesandordirs; Name: "{app}\uv_cache"
Type: filesandordirs; Name: "{app}\claude_profile"
Type: filesandordirs; Name: "{app}\state"
Type: filesandordirs; Name: "{app}\logs"
Type: files; Name: "{app}\config.json"

[Code]
var
  KeyPage: TInputQueryWizardPage;
  DirPage: TInputDirWizardPage;

function GetDeliveryFolder(Param: String): String;
begin
  Result := DirPage.Values[0];
end;

procedure InitializeWizard;
begin
  KeyPage := CreateInputQueryPage(wpWelcome, 'Access key',
    'Paste the access key you were sent',
    'The key lets this computer download the Morning Brief pipeline. Keep it private.');
  KeyPage.Add('Access key:', True);
  DirPage := CreateInputDirPage(KeyPage.ID, 'Delivery folder',
    'Where should each morning''s brief be saved?',
    'The PDF, the social pack, the sources file and the status report are saved here every morning.',
    False, '');
  DirPage.Add('');
  DirPage.Values[0] := ExpandConstant('{userdocs}\JTSG Morning Brief');
end;

function KeyStatus(const Key: String): Integer;
var
  Http: Variant;
begin
  Result := -1;
  try
    Http := CreateOleObject('WinHttp.WinHttpRequest.5.1');
    Http.Open('GET', 'https://api.github.com/repos/{#RepoOwner}/{#RepoName}/branches/stable', False);
    Http.SetTimeouts(5000, 5000, 10000, 10000);
    Http.SetRequestHeader('Authorization', 'Bearer ' + Key);
    Http.SetRequestHeader('User-Agent', 'jtsg-morning-brief-setup');
    Http.Send('');
    Result := Http.Status;
  except
    Result := -1;
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Status: Integer;
begin
  Result := True;
  if CurPageID = KeyPage.ID then
  begin
    if Trim(KeyPage.Values[0]) = '' then
    begin
      MsgBox('Please paste the access key.', mbError, MB_OK);
      Result := False;
      exit;
    end;
    Status := KeyStatus(Trim(KeyPage.Values[0]));
    if Status = -1 then
    begin
      MsgBox('Internet is required to install. Please connect and try again.', mbError, MB_OK);
      Result := False;
    end
    else if Status <> 200 then
    begin
      MsgBox('This access key was not accepted (HTTP ' + IntToStr(Status) + '). Check for missing characters and try again.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function JsonEscape(const S: String): String;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    if S[I] = '\' then Result := Result + '\\'
    else if S[I] = '"' then Result := Result + '\"'
    else Result := Result + S[I];
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Cfg: String;
  FailPath: String;
  Reason: String;
  ReasonBytes: AnsiString;
  ResultCode: Integer;
  Started: Boolean;
begin
  if CurStep = ssInstall then
  begin
    Cfg := '{' + #13#10 +
      '  "delivery_folder": "' + JsonEscape(DirPage.Values[0]) + '",' + #13#10 +
      '  "access_key": "' + JsonEscape(Trim(KeyPage.Values[0])) + '",' + #13#10 +
      '  "repo_zip_url": "https://api.github.com/repos/{#RepoOwner}/{#RepoName}/zipball/stable",' + #13#10 +
      '  "claude_exe": "",' + #13#10 +
      '  "toast": true,' + #13#10 +
      '  "max_attempts_per_day": 2' + #13#10 +
      '}' + #13#10;
    ForceDirectories(ExpandConstant('{app}'));
    SaveStringToFile(ExpandConstant('{app}\config.json'), Cfg, False);
  end;

  if CurStep = ssPostInstall then
  begin
    Started := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-ExecutionPolicy Bypass -NoProfile -File "' + ExpandConstant('{app}\app\bootstrap.ps1') + '"',
      ExpandConstant('{app}\app'), SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode);
    if (not Started) or (ResultCode <> 0) then
    begin
      Reason := '';
      FailPath := ExpandConstant('{app}\logs\setup_failed.txt');
      if FileExists(FailPath) then
      begin
        if LoadStringFromFile(FailPath, ReasonBytes) then
          Reason := Trim(ReasonBytes);
      end;
      if Reason = '' then
        Reason := 'The setup step could not be started.';
      MsgBox('Setup did not complete.' + #13#10#13#10 + Reason + #13#10#13#10 +
        'Take a screenshot of this message and send it to support.', mbError, MB_OK);
    end;
  end;
end;
