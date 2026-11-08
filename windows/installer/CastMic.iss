; CastMic Windows インストーラー (Inno Setup 6)
; CI が以下を用意してから iscc で作る:
;   ..\..\out\app\      … dotnet publish の出力
;   ..\..\out\driver\   … CastMicAudio.inf/.sys/.cat
;   ..\..\out\driver\CastMicAudio.cer … テスト署名用証明書

#define AppVersion GetEnv("CASTMIC_VERSION")
#if AppVersion == ""
  #define AppVersion "0.1.0"
#endif

[Setup]
AppId={{6B1C5B3E-2F4A-4C61-9D0B-4F2C1A7E9C12}
AppName=CastMic
AppVersion={#AppVersion}
AppPublisher=CastMic
DefaultDirName={autopf}\CastMic
DefaultGroupName=CastMic
OutputDir=..\..\out
OutputBaseFilename=CastMic-Setup-{#AppVersion}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\CastMic.exe

[Languages]
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"

[Tasks]
Name: "driver"; Description: "CastMic 仮想オーディオドライバをインストール (マイク / スピーカーとして認識させる)"; GroupDescription: "ドライバ:"
Name: "testsign"; Description: "テスト署名モードを有効にする (自作ドライバの読み込みに必要・再起動後に有効)"; GroupDescription: "ドライバ:"; Flags: unchecked
Name: "firewall"; Description: "ファイアウォールで CastMic の通信 (TCP 48100) を許可"; GroupDescription: "ネットワーク:"
Name: "autostart"; Description: "Windows 起動時に CastMic を開始"; GroupDescription: "その他:"; Flags: unchecked

[Files]
Source: "..\..\out\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs
Source: "..\..\out\driver\CastMicAudio.inf"; DestDir: "{app}\driver"; Flags: ignoreversion
Source: "..\..\out\driver\CastMicAudio.sys"; DestDir: "{app}\driver"; Flags: ignoreversion
Source: "..\..\out\driver\castmicaudio.cat"; DestDir: "{app}\driver"; Flags: ignoreversion
Source: "..\..\out\driver\CastMicAudio.cer"; DestDir: "{app}\driver"; Flags: ignoreversion

[Icons]
Name: "{group}\CastMic"; Filename: "{app}\CastMic.exe"
Name: "{group}\CastMic をアンインストール"; Filename: "{uninstallexe}"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "CastMic"; ValueData: """{app}\CastMic.exe"" --background"; Tasks: autostart; Flags: uninsdeletevalue

[Run]
; テスト署名の証明書を信頼 → ドライバ導入
Filename: "{sys}\certutil.exe"; Parameters: "-f -addstore Root ""{app}\driver\CastMicAudio.cer"""; Tasks: driver; Flags: runhidden; StatusMsg: "証明書を登録しています..."
Filename: "{sys}\certutil.exe"; Parameters: "-f -addstore TrustedPublisher ""{app}\driver\CastMicAudio.cer"""; Tasks: driver; Flags: runhidden
Filename: "{app}\CastMic.exe"; Parameters: "--install-driver ""{app}\driver\CastMicAudio.inf"""; Tasks: driver; Flags: runhidden waituntilterminated; StatusMsg: "ドライバをインストールしています..."
Filename: "{sys}\bcdedit.exe"; Parameters: "/set testsigning on"; Tasks: testsign; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""CastMic"" dir=in action=allow protocol=TCP localport=48100 program=""{app}\CastMic.exe"" profile=any"; Tasks: firewall; Flags: runhidden
Filename: "{sys}\regsvr32.exe"; Parameters: "/s ""{app}\CastMicCam.dll"""; Flags: runhidden; StatusMsg: "仮想カメラを登録しています..."; Check: IsWin11
Filename: "{app}\CastMic.exe"; Description: "CastMic を起動"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{sys}\regsvr32.exe"; Parameters: "/u /s ""{app}\CastMicCam.dll"""; Flags: runhidden; RunOnceId: "UnregisterCam"
Filename: "{app}\CastMic.exe"; Parameters: "--remove-driver"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveDriver"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""CastMic"""; Flags: runhidden; RunOnceId: "RemoveFirewall"

[Code]
function IsWin11(): Boolean;
var V: TWindowsVersion;
begin
  GetWindowsVersionEx(V);
  Result := V.Build >= 22000;
end;

function NeedRestart(): Boolean;
begin
  Result := WizardIsTaskSelected('testsign');
end;
