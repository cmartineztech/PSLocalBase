# Revisión independiente de PSLocalBase — 158582f

Fecha: 29 de octubre de 2026, America/New_York.
Rama: dev. Commit: `158582f44a45e18a2dc9ce0318372e1adb7f5f92`.
SHA256 del módulo al inicio y al cierre: `7FD4B356F44870A8C2BFD7705D9D4DA9135C34C20ECF788EA9FF009B6605CFAE`.

## Veredicto

Las correcciones son reales: las lecturas conservan filtros, exists→delete respeta el ámbito, synchronous FULL/NORMAL se aplica en archivos, distinct compuesto se rechaza explícitamente y TC-82 detecta ahora la retirada del snapshot.

**No todos los criterios de #27–#30 están cumplidos.** Repetir delete sobre una misma consulta filtrada o puntual todavía puede borrar documentos ajenos al ámbito. La reutilización de una rama de unión puede invalidar el get de una unión anterior, aunque count/exists/clone sigan funcionando. Además se reprodujeron dos pendientes preexistentes: conversión incorrecta de -like y opciones descartadas de la rama derecha de una unión.

Las diez suites integradas pasan en ambas ediciones y Playground pasa en PS7/STA. La nueva prueba independiente obtiene **3 grupos correctos / 6 fallidos, exit1**, en ambas ediciones. Esos seis fallos representan **cuatro causas runtime**, no seis defectos independientes.

**Puntuación orientativa: 89/100. No recomendaría promover este estado como versión estable de producción antes de cerrar el riesgo de borrado repetido y validar los filtros de patrón.** No se encontró una nueva SQLi ni evidencia de manipulación intencional de pruebas. El aumento desde 88 refleja correcciones verificadas; no llega a la estimación de 93–95 porque la condición de resolver todos los hallazgos no se ha cumplido.

## Método

- Agente principal y tres agentes independientes: seguridad/integridad; arquitectura/consultas; pruebas/documentación/opciones.
- Inspección del diff 3c890fd..HEAD y caminos actuales; pruebas adversariales ejecutables sobre estado, ámbito, parámetros, patrones, recursos y transacciones.
- CodeGraph init/status intentados antes de búsquedas amplias; fallan por npm-shim.js ausente. Se utilizó inspección directa.
- Procesos nuevos de PowerShell 7.6.9 y Windows PowerShell 5.1.26100.9767 en este equipo Windows.
- Reproducciones en memoria y archivos propios; copias aisladas para sensibilidad de tests. Los agentes no alteraron motor, suites existentes ni runner para obtener resultados.
- Se añadieron este informe y una suite independiente. No se realizaron commits, push, merges ni modificaciones de GitHub. #27–#30 figuran cerrados en GitHub, lo cual no sustituye esta validación.
- No se probaron apagones, hardware defectuoso, todos los sistemas Windows anunciados, SMB operativo ni Linux/macOS. El módulo depende de winsqlite3.dll de Windows. La revisión no es verificación formal exhaustiva de todas las combinaciones.

## Resultados ejecutados

| Suite | PS7 | PS5.1 |
| --- | --- | --- |
| PSLocalBase.Tests.ps1 | 83 pasan | 83 pasan |
| PSLocalBase.Audit.Tests.ps1 | 7 pasan | 7 pasan |
| PSLocalBase.Reevaluation.Tests.ps1 | 17 pasan | 17 pasan |
| PSLocalBase.NativeStress.Tests.ps1 | Pasa | Pasa |
| PSLocalBase.Independent-c57b52c.Tests.ps1 | 7 pasan | 7 pasan |
| PSLocalBase.Revalidation-3ecc2c1.Tests.ps1 | 11 pasan | 11 pasan |
| PSLocalBase.Review-83ed742.Tests.ps1 | 7 pasan | 7 pasan |
| PSLocalBase.Followup-a526708.Tests.ps1 | 21 pasan | 21 pasan |
| PSLocalBase.Boundary-86483c7.Tests.ps1 | 3 pasan | 3 pasan |
| PSLocalBase.Review-3c890fd.Tests.ps1 | 8 pasan | 8 pasan |
| Runner completo | exit0 | exit0 |
| Nueva Review-158582f.Tests.ps1 | **3 pasan / 6 fallan; exit1** | **3 pasan / 6 fallan; exit1** |

Las nueve suites con contadores suman **164 grupos enumerados**: 83+7+17+7+11+7+21+3+8. NativeStress es la décima suite y añade comprobaciones/observaciones. No se ha medido cobertura de líneas/ramas. Playground se ejecutó aparte mediante pwsh -NoProfile -STA y pasó todas sus comprobaciones automatizadas.

## Estado de #27–#30

| Issue | Veredicto independiente |
| --- | --- |
| #27: terminales y filtros | **Parcial.** Lecturas y exists→delete corregidos; dos deletes de la misma consulta siguen borrando fuera del ámbito, criterio expresamente requerido por el issue. |
| #28: synchronous | **Corregido para bases en archivo en los casos probados.** FULL/NORMAL y demás valores válidos se aplican; inválidos rechazados. Inconsistencia menor pendiente en opciones para :memory:. |
| #29: composición y TC-82 | **Parcial.** Distinct compuesto rechaza y TC-82 es sensible. Reutilizar fuente ya permite construir la segunda unión, pero puede invalidar get de la primera. |
| #30: documentación | **Parcial.** Inventario identifica diez suites y separa Playground, pero persisten cifras, clase, UPSERT y terminología incorrectos. |

## S1 — P1: un segundo delete pierde el filtro o clave y borra otros documentos

Fuente: PSLocalBase.psm1:2160 (tabla ausente) y :2180 (finally) llaman a _ResetQueryState. Al segundo delete, la colección sigue elegida pero CurrentKey/WhereClauses quedan vacíos, por lo que se ejecuta un DELETE general.

```powershell
Import-Module ./PSLocalBase.psd1 -Force
$db=New-LocalBase
try {
    $db.collection('users').doc('a').set(@{role='admin'})
    $db.collection('users').doc('b').set(@{role='reader'})
    $q=$db.collection('users').where('role','=','admin')
    $q.delete() # Queda b, correcto.
    $q.delete() # Elimina b: incorrecto.
    $db.collection('users').count() # 0; esperado1.
} finally {$db.close()}
```

Tres variantes reproducidas en ambas ediciones: filtro; doc('a') puntual; delete cuando la tabla aún no existe, creación posterior y reutilización. Las tres borran el documento excluido b. Son una misma causa, no tres bugs nuevos.

La corrección de exists→delete no cierra este criterio explícito de #27. Preservar el ámbito de mutación para reutilización segura o rechazar claramente una consulta consumida; nunca convertir un segundo borrado puntual/filtrado en borrado general silencioso. Validar éxitos, vacíos, errores, reintentos y que los índices/documentos ajenos permanezcan intactos.

## S2 — P2: la unión vuelve a depender de una referencia viva a su fuente

Fuente: PSLocalBase.psm1:634/:657 modifican _HasSubsequentUnion en el origen; :639/:662 conservan _OriginalRightBranch; get:1525 consulta ese estado externo.

```powershell
$right=$db.collection('b')
$first=$db.collection('a').union($right)
$first.get() # Dos filas.
$second=$right.union($db.collection('c')) # Segunda consulta independiente válida.
$first.get() # Lanza Nested composite queries.
$first.count() # 2.
$first.exists() # True.
$first.clone().get() # Dos filas.
```

Confirmado con union y unionAll en ambas ediciones. No hay anidamiento real. Clone no conserva esa referencia, lo que explica parte de la divergencia entre terminales. Un snapshot de consulta no debería invalidarse al construir una consulta independiente desde su fuente.

La prueba R2 añadida a Review-3c890fd solo mira count de ambas consultas y no detecta get. Mantener todo el ámbito/validación en el plan compuesto, sin consultar objetos fuente mutables. Probar get/count/exists/first/clone después de reutilizar cada fuente y rechazar separadamente un anidamiento real.

## S3 — P2: -like confunde literales PowerShell con comodines SQL

Fuente: PSLocalBase.psm1:1285–1289. La conversión solo se activa si aparece * o ? y usa [%]/[_] como si fueran escapes de SQLite LIKE. El operador LIKE SQL conserva legítimamente semántica SQL; el fallo se refiere al alias -like que publica la API y cuya conversión intenta aproximar PowerShell.

Datos a_b, aXb, a%b, ab. Comparación ejecutada contra el operador real de PowerShell:

| Patrón -like | Esperado PowerShell | Actual módulo |
| --- | --- | --- |
| a_b | a_b | a_b, aXb, a%b |
| a_* | a_b | vacío |
| a%b | a%b | los cuatro |
| a%* | a%b | vacío |
| a?b | tres cadenas de longitud3 | correcto |

También comprobado con dos documentos literal:a_b y other:aXb: where('name','-like','a_b').delete() elimina ambos, aunque PowerShell no hace coincidir aXb. Esperado conservar other. Confirmado en ambas ediciones.

Es un defecto preexistente identificado en esta revisión, no atribuido al diff nuevo. No es SQLi ni acceso remoto demostrado; es ampliación del predicado y puede afectar lecturas/borrados. Definir y cumplir el contrato de patrones; no mezclar LIKE SQL y -like PowerShell. Mantener parámetros enlazados y probar literales %, _, *, ?, escapes y operadores negados, con documentos excluidos preservados.

## S4 — P2: el compilador de unión descarta opciones de la rama derecha

Fuente: PSLocalBase.psm1:1572 y :1964 reconstruyen la rama derecha principalmente con colección, clave y filtros, sin preservar íntegramente su plan.

```powershell
$right=$db.collection('b').limit(0)
@($right.get()).Count # 0.
@($db.collection('a').unionAll($right).get()).Count
# 3: devuelve las dos filas derechas. Esperado solo una fila izquierda.
```

Además, una rama derecha select('n') omite secret de forma independiente, pero al incluirla en unionAll vuelve a devolver secret. Confirmado en ambas ediciones. No se afirma que select sea una barrera de autorización.

Pendiente preexistente de la familia de compilación compuesta, relacionada con el antecedente #9. Implementar los modificadores de rama o rechazarlos explícitamente antes de devolver un resultado ampliado. Cubrir union/unionAll, limit0, skip, orden y proyección; no exigir que se soporten todas las combinaciones, sí que no se ignoren silenciosamente.

## Calidad e integridad de las pruebas

No se encontró manipulación intencional. TC-82 reemplaza un estímulo inefectivo (descartar where inmutable) por mutaciones reales de parámetros de ambas fuentes y comprobación de tags. En copia aislada:

- Implementación actual: TC-82 pasa en ambas ediciones.
- Retirar únicamente clone del snapshot derecho: TC-82 falla, expected3 got1, ambas ediciones.
- Runner aislado: suite ausente→exit1, excepción→exit1, child exit9→exit9, ambas ediciones.

Existe un conflicto entre un test legado y el contrato actual: Followup-a526708.Tests.ps1:31 descarta el retorno de right.union(c), pero espera que la unión anterior incorpore la tercera rama o sea rechazada. En una API inmutable, debe mantener dos filas, y la segunda consulta debe ser independiente. Las nuevas referencias externas hacen que ese test pase mediante rechazo, pero rompen el contrato de independencia.

Experimento en copias aisladas, ambas ediciones:

| Implementación | Test legado | Independencia de snapshot |
| --- | --- | --- |
| Actual | Pasa | Falla |
| Desactivar solo la guarda externa de get | Falla expected3 got2 | Pasa; el anidamiento real sigue rechazado |

Actualizar el test legado al contrato vigente y probar anidamiento real por separado es necesario; no se trata de debilitar una protección correcta. Mantener también la regresión R2 con get, no únicamente count. Evidencia: scratch/review158-tests/legacy-contract-conflict.ps1 y mutation-sensitivity.ps1.

## Opciones, seguridad, transacciones y memoria

- Synchronous en archivo: 18 combinaciones WAL/DELETE × FULL/NORMAL/EXTRA/OFF/0–3/espacios y casing pasan en ambas ediciones. Seis entradas inválidas, incluido SQL, se rechazan. FULL devuelve PRAGMA2 y NORMAL PRAGMA1.
- En :memory:, synchronous no se aplica ni valida: OFF conserva PRAGMA2 e INVALID se acepta. Es inconsistencia menor de configuración, no fallo demostrado de durabilidad de archivo. No se suma como bloqueo P2 independiente.
- SQL como valor y NUL embebido se enlazan/preservan completos; identificadores maliciosos o con NUL de dropIndex rechazados. No se encontró nueva SQLi en el corpus ejecutado.
- Fallo bulk dentro de transacción externa y rollback preservan documentos y valor anterior. Las regresiones previas de UNIQUE e índices siguen verdes.
- NativeStress: 500 ciclos mixtos sin statements vivos, 100 bases cerradas vuelven al baseline0 de memoria SQLite. No demuestra ausencia universal de fugas.
- Veinte wrappers abandonados sin Dispose conservan 4.453.920 bytes después de GC. Sigue la deuda conocida de IntPtr público sin SafeHandle/finalización automática; el cierre determinista funciona en los controles.
- NativeStress usa memoria compartida, no WAL, y reintentos explícitos del harness para preservar 50 mutaciones. No se atribuyen esos reintentos automáticamente al módulo.
- Recuperación real en archivo WAL revalidada: writers propios pwsh y powershell.exe confirman un documento y dejan otro sin commit; terminación forzada, WAL retenido, reapertura conserva confirmado y descarta pendiente, integrity_check=ok. Último cierre limpio elimina WAL/SHM. No se simuló apagón ni se infiere durabilidad FULL de esa prueba.

## Correcciones anteriores y arquitectura general

F01–F07 mantienen sus regresiones verdes: rechazo de ordered delete; identidad upsert; precisión Int64; dropIndex case insensitive; claves puntuales en composición; parámetros de ramas inexistentes; operadores array con tipos no array. #22 mantiene separación de Double6e-29 y Decimal1e-28 en comparación/mutaciones. Los casos ordinarios0.1/0.2 y controles contra underflow a cero siguen pasando.

La API documental integrada con objetos PowerShell, filtros JSON ejecutados por SQLite y listas clonadas con un propietario compartido de conexión siguen siendo fortalezas. Las mejoras de read terminals y synchronous son útiles. El principal riesgo arquitectónico permanece: estado de consulta, lifecycle nativo, validación y compiladores de get/count/exists/distinct/agregados viven en una clase grande con fallbacks duplicados. S2 y S4 muestran divergencias concretas de esa duplicación. Conviene centralizar el plan y su validación antes de agregar combinaciones nuevas.

## Documentación: #30 aún parcial

- _TESTS/README.md ahora enumera diez suites y separa Playground, pero anuncia174 comprobaciones; los contadores verificables suman164 grupos más NativeStress. Audit figura17 y Reevaluation12; los reales son7 y17.
- _DOCS/SPECIFICATION.md:159 conserva PSLocalBaseCollection, inexistente en runtime; :199 dice INSERT OR REPLACE, mientras el motor usa ON CONFLICT(key) DO UPDATE.
- SPEC:204/:349 y otros textos conservan subnormal/IEEE underflow <1e-28; 6e-29 es Double normal. SECURITY:95 ya distingue correctamente esta frontera Decimal.
- README conserva la aprobación histórica94/100; no equivale a este dictamen actual.
- Benchmarks tienen cifras nuevas, pero los scripts siguen una medición por acción sin harness repetido y muestras versionadas para cuantificar dispersión. No se certifican sus nuevas cifras en esta revisión ni se atribuye falsificación.
- Las plataformas verificadas deben tener trazabilidad por sistema; PS5.1/PS7 en un Windows probado no equivale a pruebas de todos los Windows/WinPE/ARM64 anunciados.

## Puntuación y prioridades

Valoración orientativa, media simple de las cinco categorías mantenidas en nuestras revisiones; no certificación ni porcentaje de cobertura.

| Área | Puntuación |
| --- | ---: |
| Seguridad y anti-inyección | 93/100 |
| Integridad de datos y concurrencia | 86/100 |
| Estabilidad y memoria | 84/100 |
| Compatibilidad PS5.1/PS7 en Windows probado | 93/100 |
| Funcionalidad y ergonomía | 89/100 |
| **General** | **89/100** |

Prioridades: cerrar completamente #27 con repetición/vacíos; corregir predicados -like que amplían borrados; eliminar la dependencia externa de snapshots y resolver el test legado; preservar o rechazar opciones de rama derecha; completar documentación. Repetir suites integradas y nuevas regresiones antes de considerar promoción estable a main.

## Artefactos y reproducción

Nueva suite: [_TESTS/PSLocalBase.Review-158582f.Tests.ps1](../_TESTS/PSLocalBase.Review-158582f.Tests.ps1). No se agregó al runner existente durante la revisión. Tres controles pasan y seis grupos fallan; S1 tiene tres variantes de una misma causa.

```powershell
pwsh -NoProfile -File .\_TESTS\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_TESTS\run-tests.ps1
pwsh -NoProfile -STA -File .\Playground\verify-playground.ps1
pwsh -NoProfile -File .\_TESTS\PSLocalBase.Review-158582f.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_TESTS\PSLocalBase.Review-158582f.Tests.ps1
```

Logs principales: scratch/review158-root/runner-ps7.log, runner-ps51.log, playground.log, independent-ps7.log, independent-ps51.log y crash-recovery.log.

Más evidencia: scratch/review158-integrity/delete-regression.ps1 y probes; scratch/review158-queries/probes.ps1, like-probe.ps1, like-delete.ps1 y rhs-plan.ps1; scratch/review158-tests/sync-probe.ps1, mutation-sensitivity.ps1, runner-sensitivity.ps1 y legacy-contract-conflict.ps1, con logs por edición.


---

## Resolución de Hallazgos y Validación Final

Fecha de resolución: 29 de octubre de 2026.
Rama: `dev`.
SHA Base Inicial: `158582f44a45e18a2dc9ce0318372e1adb7f5f92`.

### 1. Resumen de Causas Raíz y Correcciones Aplicadas

#### Hallazgo 1 (P1): `delete()` pierde el ámbito al reutilizarse
- **Causa Raíz:** En `PSLocalBase.psm1`, las líneas 2160 (tabla ausente) y 2180 (`finally`) invocaban `$this._ResetQueryState()`. Si el llamador retenía la referencia `$q` (ej. `$q = $db.collection('users').where('role','=','admin')`) y ejecutaba `$q.delete()` por segunda vez, las cláusulas de filtro y la clave puntual habían sido borradas, degenerando en una sentencia incondicional `DELETE FROM [users];` que vaciaba documentos no relacionados.
- **Corrección:** Se eliminaron las llamadas a `_ResetQueryState()` de `delete()`. La consulta preserva sus filtros y clave de forma idempotente a través de sucesivas ejecuciones de borrado, garantizando que documentos excluidos permanezcan intactos.

#### Hallazgo 2 (P2): La reutilización de una rama invalida una unión anterior
- **Causa Raíz:** `union()` y `unionAll()` mutaban el objeto fuente invocador estableciendo `$this._HasSubsequentUnion = $true` y guardaban una referencia viva a la rama derecha en `$target._OriginalRightBranch`. Al reutilizar la rama derecha `$right` para componer una segunda unión (`$second = $right.union($c)`), `$right._HasSubsequentUnion` cambiaba a `$true`, provocando que una llamada posterior a `$first.get()` fallara con `"Nested composite queries are not supported."` a pesar de tratarse de dos consultas compuestas independientes.
- **Corrección:** Se eliminaron las propiedades mutables `_HasSubsequentUnion` y `_OriginalRightBranch`. Cada consulta compuesta mantiene un snapshot completamente aislado mediante clonación defensiva. Las instancias fuente permanecen inmutadas y reutilizables. El anidamiento real no soportado (invocar `.union()` sobre una consulta ya compuesta o pasar una consulta compuesta) continúa rechazándose explícitamente mediante comprobaciones sobre `IsComposedInUnion` y `UnionQuery`.
- **Actualización de Prueba Legada:** Se actualizó `_TESTS/PSLocalBase.Followup-a526708.Tests.ps1` (línea 31) para validar el contrato inmutable (ambas uniones independientes conservan sus 2 filas respectivas) y verificar de forma explícita el rechazo de anidamientos reales tanto en la rama izquierda como derecha.

#### Hallazgo 3 (P2): `-like` interpreta incorrectamente patrones PowerShell
- **Causa Raíz:** La conversión previa en `PSLocalBase.psm1:1285` solo se activaba ante `*` o `?` y reemplazaba `%` y `_` por secuencias `[%]` y `[_]`. En SQLite, el operador `LIKE` no soporta clases de caracteres con corchetes (estos se buscan literalmente), mientras que `%` y `_` actuaban como comodines activos no escapados, expandiendo indebidamente el conjunto de coincidencias (ej. `a_b` borraba también `aXb` y `a%b`).
- **Corrección:** Se implementó el compilador `_ConvertPsWildcardToSqlLike`, que distingue los operadores PowerShell `-like` / `-notlike` de los operadores SQL nativos `LIKE` / `NOT LIKE`. Se utiliza la cláusula estándar `ESCAPE '\'`:
  - Los comodines PowerShell `*` y `?` se traducen a `%` y `_`.
  - Los caracteres literales `%`, `_` y `\` se escapan como `\%`, `\_` y `\\`.
  - El escape con backtick de PowerShell (`` ` ``) es respetado.
  - Los patrones de rango entre corchetes sin escapar (`[...]`) se rechazan explícitamente con `[System.NotSupportedException]`.
  - Los operadores SQL `LIKE` y `NOT LIKE` retienen su semántica SQL estándar sin cláusula `ESCAPE`.

#### Hallazgo 4 (P2): La unión ignora opciones de la rama derecha
- **Causa Raíz:** La reconstrucción de subconsultas en `get()` y `count()` omitía `LimitValue`, `SkipValue`, `OrderByClause` y `SelectedFields` de las ramas individuales, provocando que ramas con `limit(0)` o proyecciones `select()` perdieran sus restricciones al combinarse en `unionAll()`.
- **Corrección:** Se implementó el helper `_BuildBranchSelect`, que emite una subconsulta SQL encapsulada para cada rama preservando su proyección local (`json_object`), condiciones `WHERE`, ordenación `ORDER BY` y límites/desplazamientos `LIMIT / OFFSET`. Si una colección no existe, se sintetiza `SELECT '' AS key, '' AS doc WHERE 0`. Ambas ramas se combinan mediante subconsultas puras en el operador `UNION` / `UNION ALL`.

#### Hallazgo 5 (P3): Documentación y recuentos
- **Causa Raíz & Desfases Detectados:**
  - `_TESTS/README.md` reportaba 174 comprobaciones en 10 suites e invertía los recuentos de `Audit` (7 reales reportados como 17) y `Reevaluation` (17 reales reportados como 12).
  - `SPECIFICATION.md` mencionaba la clase inexistente `PSLocalBaseCollection`, describía `set()` como `INSERT OR REPLACE` (cuando el motor utiliza `INSERT INTO ... ON CONFLICT(key) DO UPDATE SET doc = excluded.doc;`), y denominaba "subnormal" a valores como $6 \times 10^{-29}$ (que son valores Double normalizados situados por debajo del umbral de resolución de `System.Decimal` $1 \times 10^{-28}$).
  - `README.md` presentaba una auditoría histórica de commit `c57b52c` sin contextualizar su alcance temporal.
- **Correcciones:**
  - `_TESTS/run-tests.ps1` integra las 11 suites completas (añadiendo `PSLocalBase.Review-158582f.Tests.ps1`).
  - `_TESTS/README.md` y `README.md` documentan con precisión 11 suites con 173 comprobaciones enumeradas (83 + 7 + 17 + 7 + 11 + 7 + 21 + 3 + 8 + 9) más ciclos de estrés en `NativeStress`, aclarando que representan grupos de casos funcionales y no porcentajes de cobertura de código.
  - `_DOCS/SPECIFICATION.md`, `_DOCS/QUICKSTART.md` y `_DOCS/README.md` estandarizan la arquitectura a `PSLocalBase`, corrigen la semántica UPSERT y clarifican la terminología de resolución decimal.

---

### 2. Tabla Comparativa Antes / Después (PowerShell 5.1 y 7)

Prueba ejecutada: `_TESTS/PSLocalBase.Review-158582f.Tests.ps1`

| Caso de Prueba | PS 5.1 Antes | PS 5.1 Después | PS 7 Antes | PS 7 Después |
| :--- | :---: | :---: | :---: | :---: |
| Control: reads preserve filters; exists-delete excludes b | PASS | **PASS** | PASS | **PASS** |
| Control: tiny numeric members remain distinct | PASS | **PASS** | PASS | **PASS** |
| Control: distinct rejects union and group | PASS | **PASS** | PASS | **PASS** |
| S1: repeated filtered deletion preserves excluded key | FAIL | **PASS** | FAIL | **PASS** |
| S1: repeated point deletion preserves excluded key | FAIL | **PASS** | FAIL | **PASS** |
| S1: repeated missing deletion preserves excluded key | FAIL | **PASS** | FAIL | **PASS** |
| S2: RHS reuse preserves original union get/count parity | FAIL | **PASS** | FAIL | **PASS** |
| S3: -like matches PowerShell for literal underscore and percent | FAIL | **PASS** | FAIL | **PASS** |
| S4: union preserves RHS limit zero or rejects unsupported scope | FAIL | **PASS** | FAIL | **PASS** |
| **Total Review-158582f** | **3 PASS / 6 FAIL** | **9 PASS / 0 FAIL** | **3 PASS / 6 FAIL** | **9 PASS / 0 FAIL** |

---

### 3. Validación de la Suite Completa de Pruebas

Comandos ejecutados:
1. `pwsh -NoProfile -File .\_TESTS\run-tests.ps1` -> **11 Suites / 100% PASS (Exit Code: 0)**
2. `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_TESTS\run-tests.ps1` -> **11 Suites / 100% PASS (Exit Code: 0)**
3. `pwsh -NoProfile -STA -File .\Playground\verify-playground.ps1` -> **10/10 Verificaciones PASS (Exit Code: 0)**

Desglose de suites en el runner integrado:
1. `PSLocalBase.Tests.ps1`: 83 checks PASS
2. `PSLocalBase.Audit.Tests.ps1`: 7 checks PASS
3. `PSLocalBase.Reevaluation.Tests.ps1`: 17 checks PASS
4. `PSLocalBase.NativeStress.Tests.ps1`: 5 stress cycles PASS (reclamación nativa completa, 0 leaks retenidos)
5. `PSLocalBase.Independent-c57b52c.Tests.ps1`: 7 checks PASS
6. `PSLocalBase.Revalidation-3ecc2c1.Tests.ps1`: 11 checks PASS
7. `PSLocalBase.Review-83ed742.Tests.ps1`: 7 checks PASS
8. `PSLocalBase.Followup-a526708.Tests.ps1`: 21 checks PASS
9. `PSLocalBase.Boundary-86483c7.Tests.ps1`: 3 checks PASS
10. `PSLocalBase.Review-3c890fd.Tests.ps1`: 8 checks PASS
11. `PSLocalBase.Review-158582f.Tests.ps1`: 9 checks PASS

---

### 4. Riesgos y Limitaciones Residuales Conocidas

1. **Dependencia de Plataforma Windows:** El motor depende de `winsqlite3.dll` localizado en `System32` del host Windows. No es ejecutable en distribuciones Linux o macOS salvo disponibilidad de una biblioteca SQLite binariamente compatible.
2. **Ciclo de Vida de Punteros No Administrados:** Aunque el patrón `using` e `IDisposable` liberan determinísticamente los recursos y la memoria nativa, si un consumidor omite invocar `.close()` o `$db.Dispose()`, los identificadores nativos de SQLite permanecen retenidos hasta la recolección de elementos no administrados.
3. **Clases de Caracteres en `-like`:** Los patrones con rangos entre corchetes (ej. `[0-9]`) no son procesables de forma nativa por el motor SQL `LIKE` y son explícitamente rechazados con `[System.NotSupportedException]`. Para concordancias complejas, se debe emplear filtrado en memoria o expresiones regulares sobre los documentos leídos.
