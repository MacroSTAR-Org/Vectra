; Vectra 便携版（Inno Setup 6）
;
; 双击 -> 把程序解到 exe 旁边的 Vectra\ 目录 -> 直接运行。
; 不写注册表、不建快捷方式、不留卸载项，删目录即卸干净。
; 用户数据也在该目录内（Vectra\userdata\），整个目录拷走就是完整迁移。
;
; 为什么不用 7-Zip 的自解压：7-Zip 装的是 7z.sfx（纯 GUI 解压模块），
; 它根本不支持 RunProgram —— 实测能正确解包、exit code 0，但程序永远不启动，
; 换成 %%T 写法还会弹出解压对话框卡住。支持自动运行的 7zS.sfx 属于 LZMA SDK，
; 不随 7-Zip 安装。既然已经用 Inno 出安装版，便携版也用它，少一个依赖。
;
; 编译：ISCC.exe installer\vectra_portable.iss

#define AppName "Vectra"
#define AppNameEn "Vectra"
#define AppExe "vectra.exe"
#define SrcDir "..\build\windows\x64\runner\Release"

; 版本号由 build_release.bat 从 pubspec.yaml 读出后用 /DAppVersion= 传进来，
; 这里不写死。单独手工跑 ISCC 时退回下面的占位值，出来的包名会带 dev 字样，
; 一眼能看出不是正式产物。
#ifndef AppVersion
  #define AppVersion "0.0.0.0-dev"
#endif

[Setup]
AppId={{C1522C3A-7782-42CE-A7EC-4C48431FD1D2}}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} v{#AppVersion} 便携版
AppPublisher=MacroSTAR Studio
; {src} = 这个 exe 自己所在的目录，所以是"解到自己旁边"
DefaultDirName={src}\{#AppNameEn}
PrivilegesRequired=lowest
OutputDir=out
OutputBaseFilename={#AppName}-{#AppVersion}-便携版
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; 便携：不留任何系统痕迹
Uninstallable=no
CreateUninstallRegKey=no
UpdateUninstallLogAppName=no
UsePreviousAppDir=no
; 一路无需交互
DisableWelcomePage=yes
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableFinishedPage=yes
ShowLanguageDialog=no
CloseApplications=yes

[Languages]
Name: "chinese"; MessagesFile: "ChineseSimplified.isl"

[Files]
Source: "{#SrcDir}\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SrcDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SrcDir}\native_assets.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#SrcDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Run]
; nowait + runasoriginaluser：解完直接把程序拉起来
Filename: "{app}\{#AppExe}"; Flags: nowait postinstall skipifsilent runasoriginaluser
