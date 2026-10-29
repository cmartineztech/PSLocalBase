# Auditoría Independiente y Completa de PSLocalBase (Opus 5.5 Parallel Review)

**Fecha:** 29 de octubre de 2026 (America/New_York)  
**Evaluador:** Antigravity / Claude Opus 5.5 Parallel Audit Team  
**Rama:** `dev`  
**Commit Base Evaluado:** `a526708a742f38d63ad9c45eb4899457810081dd`  
**Entorno de Pruebas:**  
- PowerShell 7.6.9 (Core, .NET 10.0.1) x64  
- Windows PowerShell 5.1.26100.9767 (Desktop, .NET Framework 4.8) x64  
- Windows 11 Enterprise x64  

---

## 1. Identificación y Verificación Criptográfica de Artefactos

Para garantizar que la evaluación se realizó sobre una versión estable e inmutable sin interferir con revisores concurrentes:

### Hashes SHA256 Registrados:

| Archivo | SHA256 Evaluado | Coincidencia Codex |
| :--- | :--- | :---: |
| `PSLocalBase.psm1` | `A3F50BC38282283B9740DF056A19B4F345DF5F8FB73C1B13949C052408A55C95` | **EXACTA (100%)** |
| `_TESTS/run-tests.ps1` | `FDABC805335923CE60E0DAA9FCC8DD59751B2A0B7576581428B58A96CADADBFF` | N/A (Modificado localmente) |
| `_TESTS/PSLocalBase.Followup-a526708.Tests.ps1` | `AE418E8872B432700883C938D0237FD1A61150D0FCB729E01011295C10800DE2` | N/A (Untracked) |
| `_TESTS/PSLocalBase.Review-83ed742.Tests.ps1` | `333222ED81F76809A4500F956007E587E47887DABF61F15E9BE59182F9EA1F11` | Intacto |
| `_TESTS/PSLocalBase.Tests.ps1` | `AA1D7A5A83DA375110A25AC00DEC6F6D7454B4D3C027D21A239389C7D8CAF6C9` | Intacto |

*Verificación al finalizar:* Los hashes se comprobaron al inicio y al término de la evaluación, confirmando que el árbol de trabajo no sufrió alteraciones accidentales.

---

## 2. Hallazgos de la Revisión (Ordenados por Severidad)

---

### Hallazgo H01 (Severidad Media — Defecto Reproducido)
**Falsa igualdad en underflow de comas flotantes subnormales contra Decimal Cero**

- **Archivo y Líneas:** `PSLocalBase.psm1`, Líneas 2447–2462 (`_JsonValuesEqual`).
- **Condiciones Necesarias:** Comparar un valor `[double]` no nulo extremadamente pequeño ($< 1 \times 10^{-28}$, por ejemplo `[double]1e-35` o `[double]::Epsilon` = $4.94 \times 10^{-324}$) contra `[decimal]0` (o `0.0m`).
- **Reproducción Mínima:**
  ```powershell
  [PSLocalBase]::_JsonValuesEqual([double]1e-35, [decimal]0)       # Devuelve $true
  [PSLocalBase]::_JsonValuesEqual([double]::Epsilon, [decimal]0)  # Devuelve $true
  [PSLocalBase]::_JsonValuesEqual([double]-1e-35, [decimal]0)     # Devuelve $true
  ```
- **Resultado Esperado:** `$false` (un número estrictamente mayor que cero no debe igualar a cero).
- **Resultado Observado:** `$true`.
- **Causa Raíz:**
  El tipo `System.Decimal` de .NET tiene una resolución mínima de $1 \times 10^{-28}$. Al parsear `"1E-35"` con `NumberStyles.Float`, `[decimal]::Parse()` no lanza excepción de overflow, sino que realiza underflow silencioso hacia `0m`. Por lo tanto, `$dVal -eq $fDecR` (`0m -eq 0m`) evalúa `$true`.
- **Impacto:** Falso positivo en deduplicación de arrays o sentinelas si se almacenan valores subnormales de física/científicos.
- **Solución Propuesta:**
  En la evaluación del parse decimal, verificar que si `$fDecR` resulta `0m`, `$fVal` también sea exactamente `0.0`:
  ```powershell
  if ($dVal -eq $fDecR -and ($fDecR -ne 0m -or $fVal -eq 0.0)) { return $true }
  ```

---

### Hallazgo H02 (Severidad Baja/Funcional — Defecto Reproducido)
**Descriptores de mutación `$arrayUnion` y `$arrayRemove` en `PSCustomObject` no se aplican en `.update()`**

- **Archivo y Líneas:** `PSLocalBase.psm1`, Líneas 2552–2565 (`_DeepMerge`).
- **Condiciones Necesarias:** Enviar un payload de actualización generado por `ConvertFrom-Json` (o construido como `[PSCustomObject]`) que contenga sentinelas en formato objeto JSON: `{"$arrayUnion": [...]}` o `{"$arrayRemove": [...]}`.
- **Reproducción Mínima:**
  ```powershell
  $db.collection('c').doc('d').set(@{ arr = @(1, 2) })
  # Payload deserializado de JSON:
  $payload = ConvertFrom-Json '{"arr": {"$arrayUnion": [3]}}'
  $db.collection('c').doc('d').update($payload)
  $result = $db.collection('c').doc('d').get()
  # Resultado: $result.arr se convierte en el objeto literal @{$arrayUnion=@(3)} en lugar de @(1, 2, 3)
  ```
- **Resultado Esperado:** Reconocer el descriptor y mutar el array existente a `[1, 2, 3]`.
- **Resultado Observado:** El array es sobrescrito por el objeto literal descriptor.
- **Causa Raíz:**
  La línea 2552 comprueba exclusivamente `if ($srcVal -is [System.Collections.IDictionary])`. Los objetos deserializados con `ConvertFrom-Json` son `[PSCustomObject]`, por lo que `$isArrayOp` permanece `$false` y se ejecuta la rama de reemplazo directo de propiedad.
- **Impacto:** Si un cliente REST/CLI pasa payloads JSON puros a `.update()`, los descriptores Firestore-style no se procesan a menos que el llamador use Hashtables explícitos o los métodos estáticos `[PSLocalBase]::ArrayUnion()`.
- **Solución Propuesta:**
  Extender la guarda a `[System.Management.Automation.PSCustomObject]` inspeccionando `$srcVal.PSObject.Properties['$arrayUnion']`.

---

### Hallazgo H03 (Severidad Baja / Latente — Demostrado por Inspección)
**Divergencia de sanitización regex en fallbacks dinámicos de `Update-TypeData`**

- **Archivo y Líneas:** `PSLocalBase.psm1`, Líneas 2785–2812 (`Update-TypeData -MemberName populate`).
- **Condiciones Necesarias:** Fallo de reflexión de métodos compilados o ejecución en entornos donde los scriptmethods dinámicos reemplacen las clases nativas de PowerShell.
- **Reproducción / Inspección:**
  En el método compilado de clase `populate` (Líneas 548, 552, 561), los parámetros `$foreignField`, `$fromCollection` y `$asProperty` están rigurosamente filtrados con regex:
  `$cleanFField -notmatch '^[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)*$'`
  En cambio, en el bloque fallback de `Update-TypeData` (Línea 2785), estas comprobaciones regex fueron omitidas.
- **Resultado Esperado:** Idénticas guardas de seguridad entre la clase nativa y el scriptmethod de fallback.
- **Impacto:** Latente / Nulo en ejecución normal (la clase compilada tiene prioridad y bloquea la entrada antes de los fallbacks).

---

### Hallazgo H04 (Severidad Informativa — Limitación de Diseño / Demostrado por Inspección)
**Ausencia de comprobación `IsCollectionGroup` en `.drop()`**

- **Archivo y Líneas:** `PSLocalBase.psm1`, Líneas 2085–2095 (`drop()`).
- **Condiciones Necesarias:** Invocar `$db.collectionGroup('orders').drop()` sobre un grupo que coincida exactamente con el nombre de una tabla real (sin comodines `*` o `?`).
- **Reproducción / Inspección:**
  Mientras que `create()`, `set()`, `add()`, `update()`, `delete()`, `upsert()`, `createIndex()` y `dropIndex()` comprueban `if ($this.IsCollectionGroup) { throw ... }`, el método `.drop()` no valida `$this.IsCollectionGroup`. Si el patrón fue `collectionGroup('users_*')`, `_CollectionExists('users_*')` da `$false` y no hace nada. Pero si el patrón no contenía comodines, podría intentar ejecutar `DROP TABLE IF EXISTS [orders]`.
- **Solución Propuesta:** Añadir `if ($this.IsCollectionGroup) { throw [System.InvalidOperationException]::new("Cannot drop collection from a collectionGroup. Collection groups are read-only.") }` en `drop()`.

---

## 3. Estado de los Problemas Históricos y Previamente Reportados

| Código | Descripción | Estado Comprobado | Evidencia |
| :--- | :--- | :--- | :--- |
| **N01** | Eliminación de índice legacy por colisión de hash8 | **CORREGIDO** | Expresiones `json_extract` en otros campos no coinciden con `$jsonExtractRegex` ni con `$anyJsonExtractPattern`, preservando el índice ajeno. |
| **N02** | Pérdida de rama en uniones mutadas posteriormente | **CORREGIDO** | Todas las terminales (`get`, `count`, `exists`, `first`) rechazan `$this.UnionQuery.UnionQuery` con `InvalidOperationException`. |
| **N03** | `collectionGroup.create()` creaba tabla literal | **CORREGIDO** | Rechazado con excepción antes de mutar esquema. |
| **N04** | Idempotencia numérica roundtrip (0.1, 0.2, etc.) | **CORREGIDO** | 16/16 pruebas pasando en PS5.1 y PS7. Uso de `"R"` y `"G17"` en invariante cultural. Cero deriva tras múltiples `.update()`. |
| **Sec-1** | SQLi en identificadores, operadores y parámetros | **CORREGIDO** | 100% parametrizado con `sqlite3_bind_*16`, whitelist rígido en operadores y nombres de tabla. |
| **Sec-2** | Fuga de credenciales en logs de diagnóstico | **CORREGIDO** | Redacción total en debug (`Params count: N`). Errores SQL muestran placeholders `?` sin datos sensibles. |
| **Sec-3** | Inyección de NUL bytes (`\0`) | **CORREGIDO** | Rechazados en identificadores; preservados fielmente en payloads sin truncado por terminador C. |

---

## 4. Validación de Integridad de Pruebas y Experimentos de Defectos Deliberados

Para confirmar que las suites de prueba son sensibles a fallos reales y no arrojan falsos positivos:
Se ejecutó un harness aislado en `scratch/opus-parallel/run_defect_experiment.py` sobre una copia idéntica del módulo:

1. **Defecto Deliberado 1 (Desactivar formato `"R"` en igualdad numérica):**
   - *Resultado:* La suite `Followup-a526708` **FALLA** inmediatamente con `Exit Code: 1` (`stored=Double expected=0 actual=1`).
2. **Defecto Deliberado 2 (Omitir rechazo de uniones anidadas en `get()`):**
   - *Resultado:* La suite `Followup-a526708` **FALLA** inmediatamente con `Exit Code: 1` (`returned 2 instead of 3 without explicit rejection`).
3. **Defecto Deliberado 3 (Restringir índices a `doc` sin comillas):**
   - *Resultado:* La suite `Followup-a526708` **FALLA** inmediatamente con `Exit Code: 1` (`Expected original imported index; remaining=0`).

---

## 5. Matriz de Comandos Ejecutados y Resultados Reales

```powershell
# 1. Runner completo en PowerShell 7
pwsh -NoProfile -File .\_TESTS\run-tests.ps1
# Resultado: 8 suites pasaron (147 de 147 comprobaciones en verde) | Exit Code: 0

# 2. Runner completo en Windows PowerShell 5.1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_TESTS\run-tests.ps1
# Resultado: 8 suites pasaron (147 de 147 comprobaciones en verde) | Exit Code: 0

# 3. Playground STA Verification
pwsh -NoProfile -STA -File .\Playground\verify-playground.ps1
# Resultado: 10 de 10 comprobaciones pasaron | Exit Code: 0

# 4. Suite Followup en PowerShell 7
pwsh -NoProfile -File .\_TESTS\PSLocalBase.Followup-a526708.Tests.ps1
# Resultado: 18 de 18 pruebas pasaron | Exit Code: 0

# 5. Suite Followup en Windows PowerShell 5.1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_TESTS\PSLocalBase.Followup-a526708.Tests.ps1
# Resultado: 18 de 18 pruebas pasaron | Exit Code: 0

# 6. Verificación de sintaxis y espacios git
git diff --check
# Resultado: 0 advertencias, 0 errores | Exit Code: 0
```

---

## 6. Puntuación por Categoría y Veredicto Final

| Área Evaluada | Puntuación | Justificación |
| :--- | :---: | :--- |
| **Seguridad y Anti-Inyección** | **96 / 100** | Whitelist estricto en identificadores, 100% de consultas parametrizadas, redacción de credenciales en debug y error handlers, defensa ante NUL bytes. |
| **Integridad de Datos y Concurrencia** | **94 / 100** | Idempotencia numérica sólida para el rango normal de IEEE 754 y Decimal, persistencia sin drift, locking WAL y busyTimeout de 5000 ms. (Deducido por underflow subnormal H01 y H02). |
| **Estabilidad y Gestión de Memoria** | **94 / 100** | Cero leaks de `sqlite3_stmt` en P/Invoke (finalización garantizada en `finally`), detección inmediata de padres cerrados. SafeHandle pendiente como mejora arquitectónica futura. |
| **Compatibilidad Multiplataforma (PS5.1 / PS7)** | **95 / 100** | Comportamiento conmutativo y paridad demostrada en 147 tests sobre .NET 10 y .NET Framework 4.8. |
| **Funcionalidad y Ergonomía** | **93 / 100** | Soporte robusto de API fluent, transacciones ACID, uniones compuestas y sharding. (Deducido por H02 descriptores en `PSCustomObject`). |
| **Calidad de Pruebas y Cobertura de Regresión** | **96 / 100** | 8 suites automatizadas con 147 grupos de pruebas, pruebas negativas deliberadas demostradas con Exit Code 1. |
| **PUNTUACIÓN GLOBAL PONDERADA** | **94.7 / 100** | **Aprobado para Producción con Recomendaciones Menores** |

### Veredicto de Preparación para Producción:
El motor en su estado evaluado (`SHA256: A3F50BC38282283B9740DF056A19B4F345DF5F8FB73C1B13949C052408A55C95`) es **completamente apto y seguro para producción** en entornos Windows con PowerShell 5.1 y 7.x. Los hallazgos H01 y H02 son casos de borde especializados (flotantes subnormales y descriptores JSON puros) que no comprometen la seguridad ni la integridad de los flujos de datos operativos convencionales.
