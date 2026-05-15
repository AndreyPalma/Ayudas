# RPGLE Hooks para VS Code Copilot

Guardrails deterministas para desarrollo RPGLE / IBM i 7.4 vía hooks de VS Code Copilot. Todos los scripts son compatibles con **PowerShell 5.1** (default en Windows).

## Estructura

```
tu-proyecto/
├── .github/
│   └── hooks/
│       └── rpgle-guardrails.json     # Config que VS Code descubre automaticamente
├── scripts/
│   ├── validate-rpgle.ps1            # PreToolUse: 12 reglas RPGLE
│   ├── block-dangerous-cl.ps1        # PreToolUse: bloqueo CL destructivo
│   ├── auto-format-rpgle.ps1         # PostToolUse: normalizacion
│   └── load-context.ps1              # SessionStart: contexto proyecto
└── .ibmi-project.json                # (opcional) configuracion proyecto
```

## Instalacion

1. Copia ambas carpetas (`.github/hooks/` y `scripts/`) a la raiz de tu workspace de VS Code.
2. Habilita ejecucion de scripts en PowerShell (una vez por maquina):
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
   ```
3. Reinicia VS Code. Los hooks se cargan al iniciar la siguiente sesion del agente.
4. Verifica en VS Code: `Output` panel → canal `GitHub Copilot Chat Hooks`.

## Configuracion opcional del proyecto

Crea `.ibmi-project.json` en la raiz del workspace para que `load-context.ps1` inyecte contexto al agente:

```json
{
  "name": "FacturacionERP",
  "rpgleVersion": "7.4",
  "libraries": ["FACTLIB", "COMLIB", "DATALIB"],
  "schema": "PRODDATA"
}
```

## Reglas activas en validate-rpgle.ps1

| # | Regla | Severidad |
|---|---|---|
| 1 | Nombre de objeto ≤ 10 chars, UPPERCASE | Deny |
| 2 | Sin fixed-form (C/D/F/H/I/O specs) | Deny |
| 3 | Sin indicadores numerados `*INxx` | Deny |
| 4 | Sin `GOTO` | Deny |
| 5 | Sin `SELECT *` en EXEC SQL | Deny |
| 6 | EXEC SQL con manejo de SQLCODE/SQLSTATE | Deny |
| 7 | DECLARE CURSOR con CLOSE matching | Deny |
| 8 | Sin schema hardcoded en EXEC SQL | Deny |
| 9 | Sin credenciales hardcoded (PWD/PASSWORD/QSECOFR/*ALLOBJ) | Deny |
| 10 | Sin `QCMDEXC` (preferir `QCAPCMD`) | Deny |
| 11 | Lineas ≤ 100 columnas | Deny |
| 12 | DCL-PROC con docblock `///` previo | Deny |
| 13 | DCL-PR/END-PR balanceados | Deny |

## Comandos bloqueados en block-dangerous-cl.ps1

**Deny absoluto:** `rm -rf /`, `format X:`, `DROP TABLE/SCHEMA/DATABASE`, `TRUNCATE`, `DELETE FROM ... ;` sin WHERE, `DLTLIB`, `DLTF`, `CLRPFM`, `CLRLIB`, `RCLSTG`, `ENDSBS`, `PWRDWNSYS`, `DLTUSRPRF`, `ENDSYS`.

**Ask (requiere confirmacion):** `SAVLIB`, `RSTLIB`, `CHGUSRPRF`, `SBMJOB`, `GRTOBJAUT *ALLOBJ`, `SET CURRENT SCHEMA = QSYS*`, `CRTUSRPRF`.

## Testing local de los scripts

Antes de integrar, prueba cada script con un payload simulado:

```powershell
# Test: validar archivo con SELECT *
$payload = @{
    tool_name = 'editFiles'
    tool_input = @{
        files = @('src/PGM001.sqlrpgle')
        content = "DCL-PROC main;`nEXEC SQL SELECT * FROM CLIENTES;`nEND-PROC;"
    }
} | ConvertTo-Json -Depth 10

$payload | powershell.exe -NoProfile -File .\scripts\validate-rpgle.ps1
# Esperado: JSON con permissionDecision: deny
```

```powershell
# Test: bloqueo de DLTLIB
$payload = @{
    tool_name = 'runTerminalCommand'
    tool_input = @{ command = 'system "DLTLIB LIB(MYLIB)"' }
} | ConvertTo-Json

$payload | powershell.exe -NoProfile -File .\scripts\block-dangerous-cl.ps1
# Esperado: JSON con permissionDecision: deny
```

## Debug en VS Code

- Comando `/hooks` en Copilot Chat → UI guiada para ver hooks cargados.
- Output panel → canal **GitHub Copilot Chat Hooks** muestra ejecuciones en tiempo real.
- Logs locales en `.logs/sessions.log` (generados por `load-context.ps1`).

## Notas tecnicas

- Los `matcher` de los hooks **se ignoran en VS Code Copilot** (solo se parsean para compatibilidad con Claude Code). El filtrado por `tool_name` se hace dentro de cada script.
- Solo `type: "command"` esta soportado en VS Code (no hay hooks tipo `prompt`).
- Cuando varios hooks decidan sobre la misma invocacion, **gana la decision mas restrictiva**.
- Los scripts escriben UTF-8 **sin BOM** (importante para upload a IBM i con CCSID 1208).
- Los hooks se cargan al iniciar la sesion: cambios requieren reiniciar VS Code.

## Migrar a PowerShell 7 (opcional)

Si tienes `pwsh` (PowerShell 7+) en el PATH, cambia `powershell.exe` por `pwsh` en `rpgle-guardrails.json` para mejor performance y compatibilidad multi-OS. Los scripts ya son compatibles con ambas versiones.
