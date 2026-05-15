#Requires -Version 5.1
<#
.SYNOPSIS
    SessionStart hook para VS Code Copilot.
    Carga contexto del proyecto IBM i e inyecta al agente:
    - Libraries activas
    - Version RPGLE objetivo
    - Inventario rapido de fuentes
    - Estado de guardrails activos

.NOTES
    Lee opcionalmente .ibmi-project.json del workspace:
    {
      "name": "MiProyecto",
      "rpgleVersion": "7.4",
      "libraries": ["MYLIB","COMLIB"],
      "schema": "PRODDATA"
    }
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Get-PropSafe {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

# Drenar stdin aunque no lo usemos (evita pipe broken)
try { [Console]::In.ReadToEnd() | Out-Null } catch {}

$cwd = (Get-Location).Path
$timestamp = Get-Date -Format 's'

# Defaults
$info = [ordered]@{
    project      = (Split-Path -Leaf $cwd)
    rpgleVersion = '7.4'
    libraries    = @()
    schema       = ''
    sourceCount  = 0
}

# Leer configuracion del proyecto si existe
$configPath = Join-Path $cwd '.ibmi-project.json'
if (Test-Path -LiteralPath $configPath) {
    try {
        $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $name = Get-PropSafe $cfg 'name';         if ($name)    { $info.project = $name }
        $ver  = Get-PropSafe $cfg 'rpgleVersion'; if ($ver)     { $info.rpgleVersion = $ver }
        $libs = Get-PropSafe $cfg 'libraries';    if ($libs)    { $info.libraries = @($libs) }
        $sch  = Get-PropSafe $cfg 'schema';       if ($sch)     { $info.schema = $sch }
    } catch {
        [Console]::Error.WriteLine("load-context: error leyendo $configPath : $($_.Exception.Message)")
    }
}

# Inventario rapido de fuentes
try {
    $info.sourceCount = (Get-ChildItem -Path $cwd -Recurse -Include '*.rpgle','*.sqlrpgle' -ErrorAction SilentlyContinue).Count
} catch {}

# Log local
try {
    $logDir = Join-Path $cwd '.logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $logLine = "[$timestamp] session_start project=$($info.project) rpgle=$($info.rpgleVersion) libs=$($info.libraries -join ',') sources=$($info.sourceCount)"
    Add-Content -LiteralPath (Join-Path $logDir 'sessions.log') -Value $logLine
} catch {}

# Contexto a inyectar al agente
$libsStr = if ($info.libraries.Count -gt 0) { $info.libraries -join ', ' } else { '(no definidas)' }
$schStr  = if ($info.schema) { $info.schema } else { '(no definido)' }

$context = @"
=== Contexto proyecto IBM i ===
Proyecto: $($info.project)
Version RPGLE objetivo: $($info.rpgleVersion)
Libraries activas: $libsStr
Schema por defecto: $schStr
Fuentes RPGLE detectados: $($info.sourceCount)

=== Guardrails activos ===
- validate-rpgle.ps1 (PreToolUse): valida reglas deterministas en .rpgle/.sqlrpgle
- block-dangerous-cl.ps1 (PreToolUse): bloquea comandos CL destructivos
- auto-format-rpgle.ps1 (PostToolUse): normaliza keywords, tabs y EOL

=== Reglas activas (no es necesario reiterarlas) ===
- Nombres de objeto en MAYUSCULAS, max 10 chars (system naming)
- Solo free-form RPGLE (sin C/D/F/H/I/O specs)
- Sin indicadores numerados (*INxx), sin GOTO
- EXEC SQL: sin SELECT *, con manejo de SQLCODE/SQLSTATE
- DECLARE CURSOR debe tener CLOSE matching
- Sin schemas hardcoded ni credenciales en codigo
- DCL-PROC requiere docblock /// previo
- Lineas <= 100 columnas
"@

$payload = @{
    hookSpecificOutput = @{
        hookEventName     = 'SessionStart'
        additionalContext = $context
    }
}
$json = $payload | ConvertTo-Json -Depth 10 -Compress
[Console]::Out.WriteLine($json)
exit 0
