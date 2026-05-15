#Requires -Version 5.1
<#
.SYNOPSIS
    PreToolUse hook para VS Code Copilot.
    Bloquea ediciones a fuentes .rpgle/.sqlrpgle que violen reglas
    deterministicas de calidad y estilo IBM i (RPGLE 7.4+).

.NOTES
    - Solo type:"command" esta soportado en VS Code Copilot.
    - Los matchers no se aplican: se filtra por tool_name dentro del script.
    - Salida JSON por stdout. Exit 0 siempre (la decision va en el JSON).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------
function Write-HookOutput {
    param([Parameter(Mandatory)][hashtable]$Payload)
    # Depth 10: PS 5.1 trunca por defecto a 2
    $json = $Payload | ConvertTo-Json -Depth 10 -Compress
    [Console]::Out.WriteLine($json)
}

function Allow {
    Write-HookOutput @{ continue = $true }
    exit 0
}

function Deny {
    param([string]$Reason)
    Write-HookOutput @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'deny'
            permissionDecisionReason = $Reason
        }
    }
    exit 0
}

function Get-PropSafe {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

# ----------------------------------------------------------------------
# Lectura de payload del agente
# ----------------------------------------------------------------------
try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { Allow }
    $evt = $raw | ConvertFrom-Json
} catch {
    # Si no podemos parsear, no bloquear el flujo.
    Allow
}

# Filtrar manualmente (matchers son ignorados por VS Code)
$editTools = @('editFiles','createFile','writeFile','str_replace_editor','MultiEdit','Edit','Write')
if ((Get-PropSafe $evt 'tool_name') -notin $editTools) { Allow }

# ----------------------------------------------------------------------
# Extraer archivos afectados desde el payload
# ----------------------------------------------------------------------
$toolInput = Get-PropSafe $evt 'tool_input'
$files = @()
foreach ($prop in @('files','file_path','path','filePath')) {
    $v = Get-PropSafe $toolInput $prop
    if ($v) { $files += @($v) }
}
$files = $files | Where-Object { $_ } | Select-Object -Unique
$rpgFiles = $files | Where-Object { $_ -match '\.(rpgle|sqlrpgle)$' }
if (-not $rpgFiles) { Allow }

# Contenido propuesto por el agente (si viene en el payload)
$pendingContent = $null
foreach ($prop in @('content','new_str','file_text','text','newText')) {
    $v = Get-PropSafe $toolInput $prop
    if ($v) { $pendingContent = [string]$v; break }
}

# ----------------------------------------------------------------------
# Reglas deterministas RPGLE / IBM i
# ----------------------------------------------------------------------
$violations = New-Object System.Collections.Generic.List[string]

foreach ($file in $rpgFiles) {

    # --- Reglas sobre el NOMBRE del objeto -----------------------------
    $objName = [System.IO.Path]::GetFileNameWithoutExtension($file)
    if ($objName.Length -gt 10) {
        $violations.Add("$file : nombre de objeto excede 10 caracteres (system naming): '$objName'")
    }
    if ($objName -cnotmatch '^[A-Z][A-Z0-9_]*$') {
        $violations.Add("$file : nombre de objeto debe ser UPPERCASE alfanumerico: '$objName'")
    }

    # --- Obtener contenido a validar -----------------------------------
    $content = $null
    if ($pendingContent) {
        $content = $pendingContent
    } elseif (Test-Path -LiteralPath $file) {
        $content = Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue
    }
    if (-not $content) { continue }

    # 1) Fixed-form specs (C/D/F/H/I/O)
    if ($content -match '(?m)^\s{0,5}[CDFHIO]\s') {
        $violations.Add("$file : fixed-form spec detectada (C/D/F/H/I/O), usar free-form")
    }

    # 2) Indicadores numerados *INxx
    if ($content -match '\*IN\d{2}\b') {
        $violations.Add("$file : indicadores numerados (*INxx) prohibidos, usar indicadores nombrados")
    }

    # 3) GOTO
    if ($content -match '(?i)\bGOTO\b\s+\w') {
        $violations.Add("$file : uso de GOTO prohibido")
    }

    # 4) SELECT * en EXEC SQL
    if ($content -match '(?is)EXEC\s+SQL\b[^;]*\bSELECT\s+\*') {
        $violations.Add("$file : SELECT * en SQL embebido prohibido (listar columnas)")
    }

    # 5) EXEC SQL sin chequeo de SQLCODE/SQLSTATE en las siguientes lineas
    $sqlBlocks = [regex]::Matches($content, '(?is)EXEC\s+SQL\b[^;]*;')
    foreach ($m in $sqlBlocks) {
        $after = $content.Substring($m.Index + $m.Length)
        $next = ($after -split "`n" | Select-Object -First 6) -join "`n"
        if ($next -notmatch '(?i)SQLCODE|SQLSTATE') {
            $violations.Add("$file : EXEC SQL sin verificacion de SQLCODE/SQLSTATE en las 6 lineas siguientes")
            break
        }
    }

    # 6) DECLARE CURSOR sin CLOSE matching
    $declares = [regex]::Matches($content, '(?im)DECLARE\s+(\w+)\s+CURSOR')
    foreach ($d in $declares) {
        $cur = $d.Groups[1].Value
        if ($content -notmatch "(?im)CLOSE\s+$cur\b") {
            $violations.Add("$file : cursor '$cur' declarado sin CLOSE matching")
        }
    }

    # 7) Schema hardcoded en EXEC SQL
    if ($content -match '(?is)EXEC\s+SQL\b[^;]*\b[A-Z]{4,}\.[A-Z]{4,}\b') {
        $violations.Add("$file : posible schema hardcoded en EXEC SQL, preferir SET SCHEMA o variable")
    }

    # 8) Secrets / credenciales hardcoded
    if ($content -match "(?im)\b(PWD|PASSWORD)\s*\(?\s*[''""][^''""]+[''""]") {
        $violations.Add("$file : credencial hardcoded detectada (PWD/PASSWORD)")
    }
    if ($content -match '(?i)QSECOFR') {
        $violations.Add("$file : referencia explicita a perfil QSECOFR")
    }
    if ($content -match '(?i)USRPRF\s*\(\s*\*\s*ALLOBJ\s*\)') {
        $violations.Add("$file : referencia a autoridad *ALLOBJ")
    }

    # 9) QCMDEXC (preferir QCAPCMD)
    if ($content -match '(?i)\bQCMDEXC\b') {
        $violations.Add("$file : uso de QCMDEXC, preferir QCAPCMD para mejor manejo de errores")
    }

    # 10) Lineas que exceden 100 columnas
    $longLines = ($content -split "`n" | Where-Object { $_.Length -gt 100 }).Count
    if ($longLines -gt 0) {
        $violations.Add("$file : $longLines linea(s) exceden 100 columnas")
    }

    # 11) DCL-PROC sin docblock /// previo
    $procs = [regex]::Matches($content, '(?im)^\s*DCL-PROC\s+(\w+)')
    foreach ($p in $procs) {
        $procName = $p.Groups[1].Value
        $before = $content.Substring(0, $p.Index)
        $prevLines = ($before -split "`n" | Select-Object -Last 5) -join "`n"
        if ($prevLines -notmatch '(?m)^\s*///') {
            $violations.Add("$file : procedure '$procName' sin docblock /// previo")
        }
    }

    # 12) DCL-PR sin END-PR matching (conteo basico)
    $cntPR  = ([regex]::Matches($content, '(?im)^\s*DCL-PR\b')).Count
    $cntEnd = ([regex]::Matches($content, '(?im)^\s*END-PR\b')).Count
    if ($cntPR -ne $cntEnd) {
        $violations.Add("$file : DCL-PR/END-PR no balanceados ($cntPR vs $cntEnd)")
    }

    # 13) DCL-PROC EXPORT debe tener EXTPROC(*DCLCASE)
    # Captura la sentencia completa hasta ";" para tolerar declaraciones multi-linea
    $exportProcs = [regex]::Matches($content, '(?is)DCL-PROC\s+(\w+)\b([^;]*)\bEXPORT\b([^;]*);')
    foreach ($m in $exportProcs) {
        $procName = $m.Groups[1].Value
        $fullDecl = $m.Value
        if ($fullDecl -notmatch '(?i)EXTPROC\s*\(\s*\*DCLCASE\s*\)') {
            $violations.Add("$file : DCL-PROC '$procName' tiene EXPORT pero falta EXTPROC(*DCLCASE)")
        }
    }

    # 14) DCL-PR de procedimiento exportado debe tener EXTPROC(*DCLCASE)
    # Solo valida prototipos cuyos nombres coincidan con un EXPORT encontrado en este fuente
    $exportNames = $exportProcs | ForEach-Object { $_.Groups[1].Value }
    foreach ($procName in $exportNames) {
        # Captura el bloque DCL-PR nombre ... END-PR
        $prPattern = '(?is)DCL-PR\s+' + [regex]::Escape($procName) + '\b(.*?)END-PR\b'
        $prMatch = [regex]::Match($content, $prPattern)
        if ($prMatch.Success) {
            $prBlock = $prMatch.Value
            if ($prBlock -notmatch '(?i)EXTPROC\s*\(\s*\*DCLCASE\s*\)') {
                $violations.Add("$file : DCL-PR '$procName' no tiene EXTPROC(*DCLCASE) (requerido para exportado)")
            }
        }
        # Si no hay DCL-PR en este fuente, el prototipo puede estar en un copybook:
        # no se considera violacion porque no tenemos visibilidad del archivo externo.
    }
}

# ----------------------------------------------------------------------
# Decision final
# ----------------------------------------------------------------------
if ($violations.Count -eq 0) { Allow }

$reason = "Guardrails RPGLE/IBM i bloquearon la edicion:`n - " + ($violations -join "`n - ")
Deny -Reason $reason
