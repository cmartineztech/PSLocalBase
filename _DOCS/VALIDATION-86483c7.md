# Validación independiente de PSLocalBase — 86483c7

Fecha: 29 de octubre de 2026 (America/New_York).
Rama: `dev`. Commit: `86483c7d088713f4782b27e7cb6021b8f29d2ab1`.

Hash SHA256 del módulo, idéntico al inicio y al final:
`16F19129B3F7BC8E4C603CA76E92BD8A6E1825308271736BFE76E0B5CA2CA806`.

El código versionado estaba limpio al comenzar. Existían dos directorios de resultados de benchmarks sin seguimiento; no se modificaron ni eliminaron. No se alteraron motor, pruebas existentes ni estados de GitHub para obtener resultados verdes.

## Veredicto

Hay mejoras reales y verificadas: las ocho suites integradas y Playground pasan en ambas ediciones de PowerShell. Los tres problemas de la revisión anterior pasan sus reproducciones, incluidos 0.1/0.2, uniones mutadas posteriormente e índices importados quoted. Las correcciones concretas H01–H04 también están presentes y se contrastaron.

Queda **un defecto P2 de precisión en una frontera numérica específica**: la conversión de Double a Decimal puede redondear un valor pequeño distinto hacia un Decimal no cero y considerarlos iguales. Se reprodujo pérdida de un elemento y supresión de otro distinto en arrays. Afecta, por ejemplo, Double 6e-29 frente a Decimal 1e-28; no es el problema anterior de 0.1/0.2, que ahora pasa.

La validación completa de integridad queda condicionada a cerrar ese caso. No se presenta como vulnerabilidad remota ni como fallo crítico universal. Para documentos sin esas magnitudes, la matriz ejecutada es favorable, sin implicar garantía sobre todos los datos posibles.

## Método y alcance

- Tres agentes independientes revisaron integridad, runner/tests y contratos/documentación. El agente principal repitió la matriz y contrastó la reproducción operativa del límite numérico.
- CodeGraph se intentó inicializar y consultar antes de explorar el código. Falló por npm-shim.js ausente; se utilizó inspección directa.
- Ejecuciones en procesos nuevos de PowerShell 7.6.9 y Windows PowerShell 5.1.26100.9767 en este equipo Windows.
- Reproducciones nuevas en memoria; pruebas WAL/DELETE con archivos propios temporales, limpiados por su script.
- Copias aisladas para introducir un defecto controlado y comprobar sensibilidad de tests. El checkout productivo permaneció intacto.
- Consulta de GitHub: no había issues ni PR abiertos. No se creó, cerró ni reabrió ninguno.
- No se evaluó una reimplementación SafeHandle, no se hicieron benchmarks largos ni se probaron cortes eléctricos o todas las plataformas anunciadas.

## Resultados ejecutados

| Suite / comprobación | PS7 | PS5.1 |
| --- | --- | --- |
| PSLocalBase.Tests.ps1 | 80 pasan | 80 pasan |
| PSLocalBase.Audit.Tests.ps1 | 7 pasan | 7 pasan |
| PSLocalBase.Reevaluation.Tests.ps1 | 17 pasan | 17 pasan |
| PSLocalBase.NativeStress.Tests.ps1 | Pasa | Pasa |
| PSLocalBase.Independent-c57b52c.Tests.ps1 | 7 pasan | 7 pasan |
| PSLocalBase.Revalidation-3ecc2c1.Tests.ps1 | 11 pasan | 11 pasan |
| PSLocalBase.Review-83ed742.Tests.ps1 | 7 pasan | 7 pasan |
| PSLocalBase.Followup-a526708.Tests.ps1 | 21 pasan | 21 pasan |
| Runner completo | Exit 0 | Exit 0 |
| Nuevo Boundary-86483c7.Tests.ps1 | **1 pasa / 2 fallan**, exit 1 | **1 pasa / 2 fallan**, exit 1 |

Playground en PS7/STA: todas las comprobaciones automatizadas pasan.

Las siete suites con casos enumerados suman **150 grupos de comprobaciones**: 80+7+17+7+11+7+21. NativeStress es la octava suite y añade comprobaciones y observaciones. No es una medición de cobertura de líneas/ramas. Los dos fallos de Boundary son dos operaciones afectadas por una sola causa raíz.

## Hallazgos anteriores y correcciones H01–H04

| Área | Veredicto verificado |
| --- | --- |
| 0.1/0.2 y roundtrip Double/Decimal | Corregido en las dos ediciones; ArrayRemove/ArrayUnion del mismo valor cumplen cardinalidad esperada. |
| Unión cuya rama cambia después de componerla | Rechazo al ejecutar get/count/exists/first, incluyendo populate y comprobaciones de conexión. |
| Índice legacy importado con columna quoted | Se preserva la restricción ajena del caso anteriormente reportado. |
| H01: Double pequeño no cero frente a Decimal cero | Corregido en los casos probados, ambos órdenes y signos, incluyendo Epsilon. El redondeo hacia un Decimal no cero sigue pendiente. |
| H02: descriptor de array como PSCustomObject | Corregido; también se probaron descriptores anidados y operaciones vacías. |
| H03: validaciones del fallback populate | Añadidas y comprobadas por inspección y ejecución aislada del cuerpo extraído del AST. No se afirma haber reproducido una sesión histórica caliente completa. |
| H04: drop desde grupo/unión | Rechazo explícito antes de afectar esquema/datos, también para grupo con nombre exacto. |

Los casos V01–V09 y N01–N04 conservan sus regresiones verdes. No se desestiman las correcciones porque exista una frontera numérica adicional.

## Defecto pendiente — P2: cuantización Decimal no cero confunde valores distintos

Ubicación en el commit evaluado: `PSLocalBase.psm1:2456–2462`, rama de comparación mixta Double/Decimal.

```powershell
[PSLocalBase]::_JsonValuesEqual([double]6e-29, [decimal]1e-28)
# True: incorrecto para dos valores distintos.
```

También devuelve True invirtiendo los argumentos. Decimal.Parse redondea la representación de 6e-29 hacia 1e-28. La guarda nueva evita aceptar un redondeo hacia cero, pero no detecta un redondeo hacia otro Decimal.

Reproducción operativa:

1. Guardar un documento con values=@([double]6e-29).
2. Leerlo y comprobar que conserva exactamente ese Double antes de mutar.
3. Aplicar ArrayRemove([decimal]1e-28): el array queda vacío, aunque el valor pedido es distinto.
4. En una base nueva, aplicar ArrayUnion([decimal]1e-28): queda un elemento, cuando deben conservarse ambos valores distintos.

Ambas operaciones fallan en PS7 y PS5.1. El fixture verifica la lectura previa, por lo que la reproducción no confunde una pérdida previa de serialización con el fallo de comparación.

**Precondición y alcance:** números extremadamente pequeños al mezclar Double con Decimal, por debajo de la resolución Decimal. 6e-29 es un Double normal, no un subnormal IEEE754; el fallo no debe describirse como exclusivo de Double.Epsilon. No se reprodujo este problema con los valores ordinarios 0.1/0.2 en el estado actual.

**Acción requerida:** antes de aceptar igualdad, asegurar que la conversión usada no haya alterado el valor por cuantización, sea hacia cero o hacia un Decimal no cero. Mantener las regresiones de idempotencia y de valores adyacentes. No introducir una tolerancia arbitraria que confunda números distintos.

## Integridad de las pruebas

No se encontró evidencia de manipulación intencional ni debilitamiento injustificado de assertions.

- El diff de H01–H04 añade H01, H02 y H04 a Followup sin eliminar las assertions anteriores.
- El runner enumera ocho suites, exige archivos y propaga errores.
- Una copia del runner sin suites devuelve exit 1 en ambas ediciones.
- Un child con excepción no controlada devuelve exit 1 en ambas ediciones.
- En una copia aislada se retiraron únicamente las dos condiciones nuevas de la guarda de underflow. Followup detectó H01: **20 pasan / 1 falla, exit 1**, en ambas ediciones.
- H03 no tiene una regresión versionada específica del mecanismo de sesión caliente. Se probó su cuerpo exacto extraído del AST con tres identificadores inválidos, dos ámbitos compuestos y una llamada válida. Los seis casos pasan en ambas ediciones; eso no demuestra el ciclo completo de hot reload histórico.

El nuevo Boundary es una entrega de esta revisión, no parte del commit evaluado ni una omisión atribuida retrospectivamente a él.

## Seguridad, contratos y recursos

Comprobaciones propias de contratos: seis grupos pasan en ambas ediciones. Incluyen:

- Populate de la rama derecha modificada rechazado en union/unionAll al ejecutar los terminales examinados.
- Drop de grupos y uniones rechazado, preservando las fuentes.
- Delete sin criterios vacía registros conservando tabla e índice UNIQUE; la restricción sigue activa. Drop elimina el esquema.
- Parámetros enlazados y filtros numéricos no aparecen en debug; SQL literal es visible como advierte la documentación.
- BLOB y BLOB vacío se rechazan con NotSupportedException; la consulta posterior funciona.
- JournalMode informa memory en RAM, wal en archivo y delete con wal=false; configuración e hijos coinciden.

El puente nativo mantiene la búsqueda System32 y liberación de statements en finally. NativeStress comprueba 500 ciclos sin statements vivos, retorno de memoria al nivel inicial tras 100 bases cerradas y preservación de 50 mutaciones concurrentes con reintentos explícitos del harness.

La prueba concurrente usa journal_mode=memory, no WAL. Los reintentos pertenecen al harness, no garantizan reintentos automáticos del módulo. La retención de conexiones sin Dispose es una observación de uso sin cierre, no prueba de fuga en uso correctamente cerrado. DbHandle sigue siendo IntPtr público y SafeHandle/finalización automática no están implementados.

La arquitectura conserva una clase grande, compiladores de consulta separados y fallbacks duplicados. Es deuda de mantenimiento, no por sí sola un nuevo defecto runtime demostrado.

## Documentación y validación externa pendientes

1. **Benchmarks:** los scripts siguen midiendo cada acción una sola vez. El texto afirma warm-ups y distribuciones documentadas por separado; no se encontró harness repetido ni datos brutos/tablas versionados que lo sustenten. Los resúmenes JSON locales sin seguimiento no constituyen muestras repetidas ni evidencia versionada. No se atribuye falsificación.
2. **Plataformas:** Windows10/11 aparecen agrupados como Verified in CI & Local Suites; el workflow solo declara windows-latest. Falta trazabilidad por sistema. Server/WinPE como soporte por diseño y ARM64 no verificado están mejor separados. No se demuestra incompatibilidad.
3. **Auditorías:** el informe histórico ya tiene fecha y aviso corregidos, pero badges 94/100 y aprobación sin reservas siguen visibles en README/SECURITY. Deben distinguirse de la revisión vigente.

No se probaron cortes eléctricos, todos los sistemas anunciados ni un despliegue SMB completo. No se declara ausencia universal de vulnerabilidades o fugas.

## Artefactos y reproducción

Pruebas nuevas: [PSLocalBase.Boundary-86483c7.Tests.ps1](../_TESTS/PSLocalBase.Boundary-86483c7.Tests.ps1).

```powershell
pwsh -NoProfile -File .\_TESTS\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_TESTS\run-tests.ps1
pwsh -NoProfile -STA -File .\Playground\verify-playground.ps1
pwsh -NoProfile -File .\_TESTS\PSLocalBase.Boundary-86483c7.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_TESTS\PSLocalBase.Boundary-86483c7.Tests.ps1
```

Logs y experimentos auxiliares: scratch/review864-root, scratch/review864-integrity, scratch/review864-tests y scratch/review864-contracts. No se modificaron las ocho suites existentes ni su runner.

## Puntuación final

Valoración orientativa, no certificación ni porcentaje de cobertura. Media simple de las cinco categorías de nuestras revisiones:

| Área | Puntuación |
| --- | ---: |
| Seguridad y anti-inyección | 93/100 |
| Integridad de datos y concurrencia | 87/100 |
| Estabilidad y memoria | 84/100 |
| Compatibilidad PS5.1/PS7 en Windows probado | 93/100 |
| Funcionalidad y ergonomía | 93/100 |
| **General** | **90/100** |

La nota sube desde 87 por cierre de los problemas comunes anteriores y mejoras verificadas H01–H04. Para cerrar la validación de integridad completa falta la cuantización no cero descrita. Su impacto está limitado a ese escenario numérico; no se equipara a un fallo crítico general, pero no debe ocultarse detrás del runner verde.
