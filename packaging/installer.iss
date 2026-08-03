; ============================================================================
;  Instalador de Registro Horario de Producción (Cadena)
; ============================================================================
;  Compilar con Inno Setup 6:
;      iscc packaging\installer.iss
;  Requiere que dist\RegistroHorario.exe exista (pyinstaller ya ejecutado).
;  Genera: dist\installer\RegistroHorarioSetup-<version>.exe
; ============================================================================

#define AppName "Registro Horario de Produccion"
#define AppShortName "RegistroHorario"
#define AppVersion "1.0.0"
#define AppPublisher "JOMIPSA"
#define ExeName "RegistroHorario.exe"

[Setup]
AppId={{8E3C1A94-5B7D-4E2F-9C61-0A7D4F2B8E13}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppShortName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\dist\installer
OutputBaseFilename={#AppShortName}Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; The service/scheduled task and Program Files both need elevation.
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#AppName}

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Files]
Source: "..\dist\{#ExeName}";                  DestDir: "{app}"; Flags: ignoreversion
Source: "registro-horario.env.example";        DestDir: "{app}"; Flags: ignoreversion
; Only install the config file if the admin has not already customised one.
Source: "registro-horario.env.example";        DestDir: "{app}"; DestName: "registro-horario.env"; Flags: onlyifdoesntexist
Source: "..\sql\schema.sql";                   DestDir: "{app}\sql"; Flags: ignoreversion
Source: "..\sql\create_app_user.sql";          DestDir: "{app}\sql"; Flags: ignoreversion
Source: "..\README.md";                        DestDir: "{app}"; Flags: ignoreversion

[Dirs]
; Writable folder for the SQLite demo database and any local state.
Name: "{app}\datos"; Permissions: users-modify

[Icons]
Name: "{group}\Probar en modo demostracion"; Filename: "{app}\{#ExeName}"; Parameters: "--demo"; Comment: "Datos de ejemplo, sin conexion a la base de datos"
Name: "{group}\Editar configuracion";        Filename: "notepad.exe"; Parameters: """{app}\registro-horario.env"""
Name: "{group}\Abrir la aplicacion";         Filename: "http://localhost:8000/"
Name: "{group}\Desinstalar {#AppName}";      Filename: "{uninstallexe}"

[Tasks]
Name: "autostart"; Description: "Arrancar automaticamente al encender el servidor (recomendado en el servidor)"; GroupDescription: "Servidor:"
Name: "firewall";  Description: "Permitir el puerto 8000 en el Firewall de Windows (para que otros equipos accedan)"; GroupDescription: "Servidor:"

[Run]
; --- Autostart as a scheduled task running at boot under SYSTEM -------------
; A scheduled task is used instead of `sc create` because a plain console
; executable does not implement the Windows service control protocol and would
; be killed as unresponsive. This starts at boot, survives reboots and needs no
; extra third-party wrapper. For a true service (with recovery actions), wrap
; the exe with NSSM or WinSW instead.
Filename: "{sys}\schtasks.exe"; \
  Parameters: "/Create /F /TN ""{#AppShortName}"" /TR ""\""{app}\{#ExeName}\"" --no-browser"" /SC ONSTART /RU SYSTEM /RL HIGHEST"; \
  StatusMsg: "Registrando el arranque automatico..."; Flags: runhidden waituntilterminated; Tasks: autostart

Filename: "{sys}\netsh.exe"; \
  Parameters: "advfirewall firewall add rule name=""{#AppName}"" dir=in action=allow protocol=TCP localport=8000"; \
  StatusMsg: "Configurando el Firewall de Windows..."; Flags: runhidden waituntilterminated; Tasks: firewall

; Start it right away so the admin does not have to reboot to test.
Filename: "{sys}\schtasks.exe"; Parameters: "/Run /TN ""{#AppShortName}"""; \
  StatusMsg: "Iniciando la aplicacion..."; Flags: runhidden waituntilterminated; Tasks: autostart

Filename: "notepad.exe"; Parameters: """{app}\registro-horario.env"""; \
  Description: "Editar la configuracion ahora (conexion a la base de datos)"; \
  Flags: postinstall skipifsilent unchecked

Filename: "{app}\{#ExeName}"; Parameters: "--demo"; \
  Description: "Probar ahora en modo demostracion"; \
  Flags: postinstall skipifsilent nowait unchecked

[UninstallRun]
Filename: "{sys}\schtasks.exe"; Parameters: "/End /TN ""{#AppShortName}"""; Flags: runhidden; RunOnceId: "StopTask"
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /F /TN ""{#AppShortName}"""; Flags: runhidden; RunOnceId: "DelTask"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#AppName}"""; Flags: runhidden; RunOnceId: "DelFwRule"

[UninstallDelete]
; Remove the demo database, but never the admin's edited configuration.
Type: filesandordirs; Name: "{app}\datos"

[Messages]
spanish.FinishedLabel=La instalacion ha terminado.%n%nSIGUIENTE PASO: edita registro-horario.env con la cadena de conexion a la base de datos antes de usarlo en produccion.%n%nLa aplicacion estara disponible en http://localhost:8000/ y, desde otros equipos, en http://<nombre-del-servidor>:8000/
