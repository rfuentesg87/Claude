<#
.SYNOPSIS
    Instala Registro Horario de Producción como servicio web en un servidor Windows.

.DESCRIPTION
    Despliegue desde el código fuente, sin ejecutables empaquetados:
      1. Crea un entorno virtual de Python aislado.
      2. Instala las dependencias (Flask, waitress, pyodbc).
      3. Genera registro-horario.env con una RHP_SECRET_KEY aleatoria.
      4. Registra una tarea programada que arranca la aplicación al encender el
         servidor (como SYSTEM, con reintentos si se cae).
      5. Abre el puerto en el Firewall de Windows.
      6. Arranca la aplicación.

    Las usuarias acceden por navegador a http://<nombre-del-servidor>:<puerto>/
    No se instala nada en sus equipos.

.EXAMPLE
    # Desde la carpeta del repositorio, en PowerShell COMO ADMINISTRADOR:
    .\deploy\install-server.ps1

.EXAMPLE
    .\deploy\install-server.ps1 -Port 8080
#>
[CmdletBinding()]
param(
    [int]$Port = 8000,
    [string]$TaskName = "RegistroHorario",
    # Omite la instalación de pyodbc (útil si solo se va a usar el backend sqlite).
    [switch]$SkipMssqlDriver
)

$ErrorActionPreference = "Stop"

function Write-Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    [!]  $msg" -ForegroundColor Yellow }

# --- 0. Comprobaciones previas ----------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Ejecuta este script en una consola de PowerShell ABIERTA COMO ADMINISTRADOR."
}

# La raíz del proyecto es la carpeta padre de deploy\
$AppDir = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $AppDir "launcher.py"))) {
    throw "No encuentro launcher.py en $AppDir. Ejecuta el script desde la carpeta del repositorio."
}
Write-Host "Carpeta de la aplicacion: $AppDir"

# --- 1. Localizar Python -----------------------------------------------------
Write-Step "Buscando Python 3"
$pythonCmd = $null
foreach ($candidate in @("py", "python3", "python")) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) {
        $argsList = if ($candidate -eq "py") { @("-3", "--version") } else { @("--version") }
        try {
            $ver = & $cmd.Source @argsList 2>&1
            if ($ver -match "Python 3\.(\d+)") {
                if ([int]$Matches[1] -ge 9) { $pythonCmd = $cmd.Source; $pyArgs = if ($candidate -eq "py") { @("-3") } else { @() }; break }
                Write-Warn2 "$candidate es $ver (se requiere 3.9 o superior)"
            }
        } catch { }
    }
}
if (-not $pythonCmd) {
    throw @"
No se ha encontrado Python 3.9+ en este servidor.
Instalalo desde https://www.python.org/downloads/windows/ marcando
"Add python.exe to PATH", y vuelve a ejecutar este script.
"@
}
Write-Ok "Python encontrado: $pythonCmd"

# --- 2. Entorno virtual ------------------------------------------------------
Write-Step "Creando el entorno virtual"
$VenvDir = Join-Path $AppDir ".venv"
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
if (-not (Test-Path $VenvPython)) {
    & $pythonCmd @pyArgs -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { throw "Fallo la creacion del entorno virtual." }
    Write-Ok "Entorno virtual creado en $VenvDir"
} else {
    Write-Ok "El entorno virtual ya existia; se reutiliza."
}

Write-Step "Instalando dependencias"
& $VenvPython -m pip install --upgrade pip --quiet
$reqFile = if ($SkipMssqlDriver) { "requirements.txt" } else { "requirements-mssql.txt" }
& $VenvPython -m pip install -r (Join-Path $AppDir $reqFile) --quiet
if ($LASTEXITCODE -ne 0) { throw "Fallo la instalacion de dependencias ($reqFile)." }
Write-Ok "Dependencias instaladas desde $reqFile"

# Aviso si falta el driver ODBC (necesario para el backend mssql)
if (-not $SkipMssqlDriver) {
    try {
        $drivers = Get-OdbcDriver -ErrorAction Stop | Select-Object -ExpandProperty Name
        if ($drivers -match "ODBC Driver 1[78] for SQL Server") {
            Write-Ok "Driver ODBC de SQL Server detectado."
        } else {
            Write-Warn2 "No se detecta el 'ODBC Driver 18 for SQL Server'."
            Write-Warn2 "Instalalo (msodbcsql18) o la conexion al warehouse fallara."
        }
    } catch {
        Write-Warn2 "No se pudo comprobar el driver ODBC; verificalo manualmente."
    }
}

# --- 3. Configuración --------------------------------------------------------
Write-Step "Preparando la configuracion"
$EnvFile = Join-Path $AppDir "registro-horario.env"
if (Test-Path $EnvFile) {
    Write-Ok "registro-horario.env ya existe; NO se toca (se conservan tus credenciales)."
} else {
    Copy-Item (Join-Path $AppDir "packaging\registro-horario.env.example") $EnvFile

    # Clave de sesión aleatoria (96 caracteres hexadecimales).
    $bytes = New-Object byte[] 48
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($bytes)
    $secret = -join ($bytes | ForEach-Object { $_.ToString("x2") })

    $content = Get-Content $EnvFile -Raw -Encoding UTF8
    $content = $content -replace 'RHP_SECRET_KEY=.*', "RHP_SECRET_KEY=$secret"
    $content = $content -replace 'RHP_PORT=.*', "RHP_PORT=$Port"
    Set-Content -Path $EnvFile -Value $content -Encoding UTF8 -NoNewline

    Write-Ok "registro-horario.env creado con una RHP_SECRET_KEY aleatoria."
    Write-Warn2 "PENDIENTE: edita ese fichero y pon RHP_MSSQL_CONNECTION_STRING."
}

# --- 4. Tarea programada al arranque ----------------------------------------
Write-Step "Registrando el arranque automatico"
$launcher = Join-Path $AppDir "launcher.py"
$action = New-ScheduledTaskAction -Execute $VenvPython `
            -Argument "`"$launcher`" --no-browser" -WorkingDirectory $AppDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$taskPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
            -LogonType ServiceAccount -RunLevel Highest
# Sin límite de tiempo (es un servidor de larga duración) y con reintentos,
# que es lo que aporta una tarea programada frente a lanzarlo a mano.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Principal $taskPrincipal -Settings $settings -Force | Out-Null
Write-Ok "Tarea '$TaskName' registrada (arranca al encender el servidor)."

# --- 5. Firewall -------------------------------------------------------------
Write-Step "Configurando el Firewall de Windows"
$ruleName = "Registro Horario de Produccion ($Port)"
if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) {
    Write-Ok "La regla de firewall ya existia."
} else {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $Port -Profile Domain, Private | Out-Null
    Write-Ok "Puerto TCP $Port permitido (perfiles Dominio y Privado)."
}

# --- 6. Arrancar -------------------------------------------------------------
Write-Step "Arrancando la aplicacion"
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 6
$ok = $false
try {
    $resp = Invoke-WebRequest "http://127.0.0.1:$Port/login" -UseBasicParsing -TimeoutSec 10
    $ok = ($resp.StatusCode -eq 200)
} catch { }

$hostName = $env:COMPUTERNAME
Write-Host ""
Write-Host ("=" * 74)
if ($ok) {
    Write-Host " INSTALACION COMPLETADA - la aplicacion responde correctamente." -ForegroundColor Green
} else {
    Write-Host " INSTALACION COMPLETADA - pero la aplicacion aun no responde." -ForegroundColor Yellow
    Write-Host " Esto es normal si todavia no has configurado la base de datos."
}
Write-Host ("=" * 74)
Write-Host ""
Write-Host " Acceso para las usuarias:  http://$hostName`:$Port/"
Write-Host " Acceso local:              http://127.0.0.1:$Port/"
Write-Host ""
Write-Host " SIGUIENTES PASOS:"
Write-Host "  1. Edita la configuracion:   notepad `"$EnvFile`""
Write-Host "     -> pon RHP_MSSQL_CONNECTION_STRING con el usuario creado por"
Write-Host "        sql\create_app_user.sql"
Write-Host "  2. Comprueba la conexion:    .\.venv\Scripts\python.exe manage.py check-db"
Write-Host "  3. Reinicia la aplicacion:   Restart-ScheduledTask -TaskName $TaskName"
Write-Host "  4. Crea los usuarios reales:"
Write-Host "     .\.venv\Scripts\python.exe manage.py create-user --username nombre.apellido --role cadena"
Write-Host ""
Write-Host " GESTION:"
Write-Host "  Parar:      Stop-ScheduledTask -TaskName $TaskName"
Write-Host "  Arrancar:   Start-ScheduledTask -TaskName $TaskName"
Write-Host "  Estado:     Get-ScheduledTask -TaskName $TaskName"
Write-Host "  Actualizar: git pull; then Restart-ScheduledTask -TaskName $TaskName"
Write-Host ""
