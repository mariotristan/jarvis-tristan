; Inno Setup 6 script for the Windows installer of the `tristan` command.
;
; Built by scripts\package-windows-installer.ps1, which first lets scripts\package-windows.ps1 fill the staging folder
; that the zip is made from, so the installer and the zip carry exactly the same files:
;   ISCC.exe /DAppVersion=1.2.3 /DStageDir=<dist\Tristan-1.2.3-windows-x64> /O<dist> scripts\windows\tristan.iss
; Output: Tristan-<version>-windows-x64-setup.exe
;
; Per user by default (no administrator rights, %LocalAppData%\Programs\Tristan); for all users in Program Files
; (asks for administrator rights) when chosen in the dialog or with /ALLUSERS. Silent install, for example:
;   Tristan-1.2.3-windows-x64-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /TASKS="addtopath" /LOG="setup.log"
; /DIR="..." picks the folder, /TASKS="" skips the PATH change. Uninstall:
;   "%LocalAppData%\Programs\Tristan\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
; The uninstaller removes the program folder and its own PATH entry, and keeps the user's data: settings and history
; in %APPDATA%\Tristan, secrets in Windows Credential Manager.
;
; Keep AppId forever: it is how a newer installer finds and upgrades an older install.

#ifndef AppVersion
  #error Define the version: ISCC.exe /DAppVersion=1.2.3 ...
#endif
#ifndef StageDir
  #error Define the staging folder: ISCC.exe /DStageDir=<folder made by package-windows.ps1> ...
#endif
#if !FileExists(StageDir + "\tristan.exe")
  #error StageDir has no tristan.exe: run scripts\package-windows.ps1 first
#endif

[Setup]
AppId={{4FDD8719-7E92-4C61-836C-2A77373ACADD}
AppName=Tristan
AppVersion={#AppVersion}
AppVerName=Tristan {#AppVersion}
AppPublisher=Tristan contributors
AppPublisherURL=https://github.com/mariotristan/jarvis-tristan
AppSupportURL=https://github.com/mariotristan/jarvis-tristan/issues
AppUpdatesURL=https://github.com/mariotristan/jarvis-tristan/releases
VersionInfoProductName=Tristan
VersionInfoDescription=Tristan setup
DefaultDirName={autopf}\Tristan
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline dialog
UsedUserAreasWarning=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
Compression=lzma2
SolidCompression=yes
OutputBaseFilename=Tristan-{#AppVersion}-windows-x64-setup
LicenseFile={#StageDir}\LICENSE.txt
ChangesEnvironment=yes
; Nothing here needs a restart, and Setup never starts tristan.exe (not even one it had to close).
AlwaysRestart=no
RestartIfNeededByRun=no
RestartApplications=no
UninstallDisplayIcon={app}\tristan.exe
WizardStyle=modern

[Tasks]
Name: "addtopath"; Description: "Add Tristan to my PATH"; GroupDescription: "Command line:"

[InstallDelete]
; An upgrade must not keep a DLL that the newer version no longer ships.
Type: files; Name: "{app}\*.dll"

[Files]
; The whole staging folder: tristan.exe, its DLLs, LICENSE.txt, README.txt and THIRD-PARTY-NOTICES.txt.
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Messages]
FinishedLabelNoIcons=Setup has finished installing [name] on your computer.%n%nIf you added Tristan to your PATH, open a new terminal (Windows Terminal, PowerShell or cmd) and run: tristan --version

[Code]
// PATH handling. Per user: HKCU\Environment. All users: HKLM\...\Session Manager\Environment. The install folder is
// appended to Path only when that exact entry (case-insensitive, ignoring a trailing backslash) is not there yet, the
// value keeps its registry type (REG_EXPAND_SZ stays REG_EXPAND_SZ) and every other entry is kept as it is. Uninstall
// removes only that entry. A Path that did not exist is created as REG_EXPAND_SZ, and a Path left empty by the
// uninstall is deleted.

const
  UserEnvironmentKey = 'Environment';
  SystemEnvironmentKey = 'System\CurrentControlSet\Control\Session Manager\Environment';
  PathValueName = 'Path';
  TristanKeyQueryValue = 1;      // KEY_QUERY_VALUE
  TristanRegExpandSz = 2;        // REG_EXPAND_SZ
  TristanRawHkcu = -2147483647;  // HKEY_CURRENT_USER ($80000001) as passed to advapi32
  TristanRawHklm = -2147483646;  // HKEY_LOCAL_MACHINE ($80000002)

// Inno Setup's Reg* functions do not report a value's type, so it is read directly.
function TristanRegOpenKeyEx(Key: Integer; SubKey: String; Options: Integer; Access: Integer; var Opened: Integer): Integer;
  external 'RegOpenKeyExW@advapi32.dll stdcall';
function TristanRegQueryValueType(Key: Integer; ValueName: String; Reserved: Integer; var ValueType: Integer; Data: Integer; DataSize: Integer): Integer;
  external 'RegQueryValueExW@advapi32.dll stdcall';
function TristanRegCloseKey(Key: Integer): Integer;
  external 'RegCloseKey@advapi32.dll stdcall';

function EnvironmentRoot: Integer;
begin
  if IsAdminInstallMode then
    Result := HKEY_LOCAL_MACHINE
  else
    Result := HKEY_CURRENT_USER;
end;

function EnvironmentRawRoot: Integer;
begin
  if IsAdminInstallMode then
    Result := TristanRawHklm
  else
    Result := TristanRawHkcu;
end;

function EnvironmentKey: String;
begin
  if IsAdminInstallMode then
    Result := SystemEnvironmentKey
  else
    Result := UserEnvironmentKey;
end;

// True only when Path exists and is REG_EXPAND_SZ.
function PathIsExpandString: Boolean;
var
  Opened, ValueType: Integer;
begin
  Result := False;
  Opened := 0;
  if TristanRegOpenKeyEx(EnvironmentRawRoot, EnvironmentKey, 0, TristanKeyQueryValue, Opened) = 0 then
  begin
    ValueType := 0;
    if TristanRegQueryValueType(Opened, PathValueName, 0, ValueType, 0, 0) = 0 then
      Result := (ValueType = TristanRegExpandSz);
    TristanRegCloseKey(Opened);
  end;
end;

function NormalizePathEntry(Entry: String): String;
begin
  Result := Lowercase(Entry);
  while Length(Result) > 0 do
  begin
    if Copy(Result, Length(Result), 1) <> '\' then
      Break;
    Delete(Result, Length(Result), 1);
  end;
end;

function PathHasEntry(PathValue, Dir: String): Boolean;
var
  Rest, Entry, Target: String;
  Separator: Integer;
begin
  Result := False;
  Target := NormalizePathEntry(Dir);
  Rest := PathValue;
  repeat
    Separator := Pos(';', Rest);
    if Separator = 0 then
      Entry := Rest
    else
    begin
      Entry := Copy(Rest, 1, Separator - 1);
      Rest := Copy(Rest, Separator + 1, Length(Rest));
    end;
    if NormalizePathEntry(Entry) = Target then
    begin
      Result := True;
      Exit;
    end;
  until Separator = 0;
end;

// PathValue without every entry equal to Dir; all other entries, empty ones included, are kept in order.
function PathWithoutEntry(PathValue, Dir: String): String;
var
  Rest, Entry, Target: String;
  Separator: Integer;
  First: Boolean;
begin
  Result := '';
  First := True;
  Target := NormalizePathEntry(Dir);
  Rest := PathValue;
  repeat
    Separator := Pos(';', Rest);
    if Separator = 0 then
      Entry := Rest
    else
    begin
      Entry := Copy(Rest, 1, Separator - 1);
      Rest := Copy(Rest, Separator + 1, Length(Rest));
    end;
    if NormalizePathEntry(Entry) <> Target then
    begin
      if First then
        Result := Entry
      else
        Result := Result + ';' + Entry;
      First := False;
    end;
  until Separator = 0;
end;

procedure AddInstallDirToPath;
var
  Dir, OldPath, NewPath: String;
  Exists, Written: Boolean;
begin
  Dir := ExpandConstant('{app}');
  OldPath := '';
  Exists := RegValueExists(EnvironmentRoot, EnvironmentKey, PathValueName);
  if Exists then
  begin
    if not RegQueryStringValue(EnvironmentRoot, EnvironmentKey, PathValueName, OldPath) then
    begin
      Log('Path is not a string value; it was left unchanged.');
      SuppressibleMsgBox('Tristan was installed, but Path is not a text value, so ' + Dir + ' was not added to it.', mbError, MB_OK, IDOK);
      Exit;
    end;
  end;
  if PathHasEntry(OldPath, Dir) then
  begin
    Log('Path already contains ' + Dir + '; it was left unchanged.');
    Exit;
  end;
  // Always ";" + Dir, even after a trailing ";": removing the entry then gives back the old value exactly.
  if OldPath = '' then
    NewPath := Dir
  else
    NewPath := OldPath + ';' + Dir;
  if (not Exists) or PathIsExpandString then
    Written := RegWriteExpandStringValue(EnvironmentRoot, EnvironmentKey, PathValueName, NewPath)
  else
    Written := RegWriteStringValue(EnvironmentRoot, EnvironmentKey, PathValueName, NewPath);
  if Written then
    Log('Added ' + Dir + ' to Path.')
  else
  begin
    Log('Could not write Path.');
    SuppressibleMsgBox('Tristan was installed, but ' + Dir + ' could not be added to your PATH.', mbError, MB_OK, IDOK);
  end;
end;

procedure RemoveInstallDirFromPath;
var
  Dir, OldPath, NewPath: String;
  Written: Boolean;
begin
  Dir := ExpandConstant('{app}');
  if not RegQueryStringValue(EnvironmentRoot, EnvironmentKey, PathValueName, OldPath) then
    Exit;
  if not PathHasEntry(OldPath, Dir) then
  begin
    Log('Path does not contain ' + Dir + '; it was left unchanged.');
    Exit;
  end;
  NewPath := PathWithoutEntry(OldPath, Dir);
  if NewPath = '' then
    Written := RegDeleteValue(EnvironmentRoot, EnvironmentKey, PathValueName)
  else if PathIsExpandString then
    Written := RegWriteExpandStringValue(EnvironmentRoot, EnvironmentKey, PathValueName, NewPath)
  else
    Written := RegWriteStringValue(EnvironmentRoot, EnvironmentKey, PathValueName, NewPath);
  if Written then
    Log('Removed ' + Dir + ' from Path.')
  else
    Log('Could not write Path.');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('addtopath') then
    AddInstallDirToPath;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  // usUninstall comes before the files are removed, so the PATH entry is gone before the folder is.
  if CurUninstallStep = usUninstall then
    RemoveInstallDirFromPath;
  if (CurUninstallStep = usDone) and (not UninstallSilent) then
    MsgBox('Tristan was removed from this computer.' + #13#10 + #13#10 +
      'Your settings and history in %APPDATA%\Tristan and your secrets in Windows Credential Manager were kept. ' +
      'To remove them too, see "Uninstall" on https://mariotristan.github.io/jarvis-tristan/windows.html#uninstall',
      mbInformation, MB_OK);
end;
