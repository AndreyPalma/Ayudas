#Requires -Version 5.1
<#
.SYNOPSIS
    PostToolUse hook para VS Code Copilot.
    Auto-formato de fuentes RPGLE despues de edicion:
    - Keywords RPGLE a UPPERCASE
    - Tabs -> 2 espacios
    - Trailing whitespace eliminado
    - Escritura UTF-8 SIN BOM (importante para IBM i tooling)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Get-PropSafe {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $evt = $raw | ConvertFrom-Json
} catch { exit 0 }

$editTools = @('editFiles','createFile','writeFile','str_replace_editor','MultiEdit','Edit','Write')
if ((Get-PropSafe $evt 'tool_name') -notin $editTools) { exit 0 }

# Recolectar archivos
$toolInput = Get-PropSafe $evt 'tool_input'
$files = @()
foreach ($prop in @('files','file_path','path','filePath')) {
    $v = Get-PropSafe $toolInput $prop
    if ($v) { $files += @($v) }
}
$files = $files | Where-Object { $_ } | Select-Object -Unique
$rpgFiles = $files | Where-Object { $_ -match '\.(rpgle|sqlrpgle)$' -and (Test-Path -LiteralPath $_) }
if (-not $rpgFiles) { exit 0 }

# Keywords RPGLE/SQL a normalizar a UPPERCASE
$keywords = @(
    'CTL-OPT','DCL-PROC','END-PROC','DCL-PR','END-PR','DCL-PI','END-PI',
    'DCL-DS','END-DS','DCL-S','DCL-C','DCL-F','DCL-SUBF',
    'IF','ELSE','ELSEIF','ENDIF','FOR','ENDFOR','DOW','ENDDO','DOU',
    'SELECT','WHEN','OTHER','ENDSL','LEAVE','ITER','RETURN',
    'MONITOR','ON-ERROR','ENDMON','BEGSR','ENDSR','EXSR',
    'CHAIN','READ','READE','READP','SETLL','SETGT','UPDATE','WRITE','DELETE',
    'EXEC SQL','FETCH','OPEN','CLOSE','DECLARE','INTO','USING','VALUES',
    'SELECT','FROM','WHERE','ORDER BY','GROUP BY','HAVING','JOIN','INNER','LEFT','RIGHT',
    'INSERT','UPDATE','SET','COMMIT','ROLLBACK',
    'CONST','INZ','VALUE','LIKEDS','LIKEREC','TEMPLATE','EXTNAME','EXTPROC','OPDESC'
)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

foreach ($file in $rpgFiles) {
    try {
        $content = Get-Content -LiteralPath $file -Raw
        if (-not $content) { continue }
        $original = $content

        # Tabs -> 2 espacios
        $content = $content -replace "`t", '  '

        # Trailing whitespace
        $content = ($content -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n"

        # Keywords -> UPPERCASE (respetando strings y comentarios basicos)
        # Estrategia: split por strings/comentarios, transformar solo el codigo
        $lines = $content -split "`n"
        for ($i = 0; $i -lt $lines.Length; $i++) {
            $line = $lines[$i]
            # Ignorar lineas de comentario completas
            if ($line -match '^\s*//') { continue }

            # Separar string literals para no tocarlos
            $segments = [regex]::Split($line, "('(?:[^']|'')*')")
            for ($j = 0; $j -lt $segments.Length; $j++) {
                $seg = $segments[$j]
                if ($seg.StartsWith("'")) { continue }  # es un literal, no tocar
                foreach ($kw in $keywords) {
                    $pattern = '(?i)(?<![A-Z0-9_-])' + [regex]::Escape($kw) + '(?![A-Z0-9_-])'
                    $seg = [regex]::Replace($seg, $pattern, $kw.ToUpper())
                }
                $segments[$j] = $seg
            }
            $lines[$i] = [string]::Join('', $segments)
        }
        $content = [string]::Join("`n", $lines)

        # Escribir solo si cambio
        if ($content -ne $original) {
            $absPath = (Resolve-Path -LiteralPath $file).Path
            [System.IO.File]::WriteAllText($absPath, $content, $utf8NoBom)
        }
    } catch {
        [Console]::Error.WriteLine("auto-format error en $file : $($_.Exception.Message)")
    }
}

exit 0
