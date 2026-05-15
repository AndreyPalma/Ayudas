#Requires -Version 5.1
<#
.SYNOPSIS
    PreToolUse hook para VS Code Copilot.
    Bloquea comandos destructivos en terminal (CL de IBM i y comandos
    peligrosos en shell). Comandos sensibles requieren confirmacion.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-HookOutput {
    param([Parameter(Mandatory)][hashtable]$Payload)
    $json = $Payload | ConvertTo-Json -Depth 10 -Compress
    [Console]::Out.WriteLine($json)
}
function Allow { Write-HookOutput @{ continue = $true }; exit 0 }
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
function AskUser {
    param([string]$Reason)
    Write-HookOutput @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'ask'
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

# Leer payload
try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { Allow }
    $evt = $raw | ConvertFrom-Json
} catch { Allow }

# Solo aplica a tools de terminal
$terminalTools = @('runTerminalCommand','runInTerminal','bash','Bash','executeCommand')
if ((Get-PropSafe $evt 'tool_name') -notin $terminalTools) { Allow }

# Extraer comando
$toolInput = Get-PropSafe $evt 'tool_input'
$cmd = ''
foreach ($prop in @('command','cmd','script','code')) {
    $v = Get-PropSafe $toolInput $prop
    if ($v) { $cmd = [string]$v; break }
}
if (-not $cmd) { Allow }

# ----------------------------------------------------------------------
# Lista DENY: bloqueo absoluto
# ----------------------------------------------------------------------
$denyPatterns = @(
    @{ Pattern = 'rm\s+-rf\s+/';                Desc = 'rm -rf en raiz del FS' },
    @{ Pattern = 'rm\s+-rf\s+\$HOME';           Desc = 'rm -rf $HOME' },
    @{ Pattern = 'rm\s+-rf\s+~';                Desc = 'rm -rf ~' },
    @{ Pattern = 'format\s+[A-Z]:';             Desc = 'format de disco Windows' },
    @{ Pattern = 'mkfs\.';                      Desc = 'formateo de filesystem' },
    @{ Pattern = ':\(\)\s*\{\s*:\|:&';          Desc = 'fork bomb' },
    @{ Pattern = '(?i)\bDROP\s+TABLE\b';        Desc = 'DROP TABLE' },
    @{ Pattern = '(?i)\bDROP\s+SCHEMA\b';       Desc = 'DROP SCHEMA' },
    @{ Pattern = '(?i)\bDROP\s+DATABASE\b';     Desc = 'DROP DATABASE' },
    @{ Pattern = '(?i)\bTRUNCATE\s+TABLE\b';    Desc = 'TRUNCATE TABLE' },
    @{ Pattern = '(?i)DELETE\s+FROM\s+\w+\s*;?\s*$'; Desc = 'DELETE sin WHERE' },
    # Comandos CL destructivos IBM i
    @{ Pattern = '(?i)\bDLTLIB\b';              Desc = 'DLTLIB (eliminar libreria)' },
    @{ Pattern = '(?i)\bDLTF\b';                Desc = 'DLTF (eliminar archivo)' },
    @{ Pattern = '(?i)\bCLRPFM\b';              Desc = 'CLRPFM (limpiar physical file member)' },
    @{ Pattern = '(?i)\bCLRLIB\b';              Desc = 'CLRLIB (limpiar libreria)' },
    @{ Pattern = '(?i)\bRCLSTG\b';              Desc = 'RCLSTG (reclaim storage)' },
    @{ Pattern = '(?i)\bENDSBS\b';              Desc = 'ENDSBS (end subsystem)' },
    @{ Pattern = '(?i)\bPWRDWNSYS\b';           Desc = 'PWRDWNSYS (power down)' },
    @{ Pattern = '(?i)\bDLTUSRPRF\b';           Desc = 'DLTUSRPRF (delete user profile)' },
    @{ Pattern = '(?i)\bENDSYS\b';              Desc = 'ENDSYS (end system)' }
)

foreach ($p in $denyPatterns) {
    if ($cmd -match $p.Pattern) {
        Deny "Comando destructivo bloqueado: $($p.Desc). Comando: $cmd"
    }
}

# ----------------------------------------------------------------------
# Lista ASK: requiere confirmacion explicita del usuario
# ----------------------------------------------------------------------
$askPatterns = @(
    @{ Pattern = '(?i)\bSAVLIB\b';                       Desc = 'SAVLIB (backup libreria)' },
    @{ Pattern = '(?i)\bRSTLIB\b';                       Desc = 'RSTLIB (restore libreria)' },
    @{ Pattern = '(?i)\bCHGUSRPRF\b';                    Desc = 'CHGUSRPRF (cambio perfil usuario)' },
    @{ Pattern = '(?i)\bSBMJOB\b';                       Desc = 'SBMJOB (submit batch job)' },
    @{ Pattern = '(?i)GRTOBJAUT.*\*ALLOBJ';              Desc = 'Otorgamiento de *ALLOBJ' },
    @{ Pattern = '(?i)SET\s+CURRENT\s+SCHEMA\s*=\s*[''"]?(QSYS|QSYS2|QGPL)'; Desc = 'Cambio a schema del sistema' },
    @{ Pattern = '(?i)\bSTRSQL\b\s+COMMIT\(\*NONE\)';    Desc = 'SQL sin commit control' },
    @{ Pattern = '(?i)\bCRTUSRPRF\b';                    Desc = 'Creacion de perfil de usuario' }
)

foreach ($p in $askPatterns) {
    if ($cmd -match $p.Pattern) {
        AskUser "Comando sensible requiere confirmacion: $($p.Desc)"
    }
}

Allow
