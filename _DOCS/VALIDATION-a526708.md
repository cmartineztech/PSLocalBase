# Validación independiente de PSLocalBase — a526708

Fecha: 29 de octubre de 2026 (America/New_York).
Commit: `a526708a742f38d63ad9c45eb4899457810081dd`. Rama: `dev`.
El checkout estaba limpio al comenzar; el SHA se volvió a comprobar al terminar.

## Veredicto

Hay correcciones reales y verificadas. Las siete suites integradas y Playground pasan en PowerShell 7 y Windows PowerShell 5.1. Las siete comprobaciones originales de N01–N04 también pasan sin debilitar sus assertions.

No es correcto afirmar que toda la familia de integridad esté cerrada: N04 todavía falla con los valores comunes 0.1 y 0.2 después de guardar/leer entre Double y Decimal. Además, mutar una rama después de componer una unión puede saltarse la validación de anidamiento. Existe un caso condicionado a esquemas SQLite externos en el que dropIndex elimina un índice legacy de otra ruta si su definición utiliza la columna entre comillas.

Las correcciones de los ejemplos anteriores no se presentan como falsas: se distinguen de estas variantes adicionales. No recomiendo aún una aprobación de producción general sin reservas, principalmente por la idempotencia numérica pendiente.

## Método y alcance

- Tres agentes independientes revisaron integridad N01–N04, tests/runner y contratos/documentación. El agente principal ejecutó la matriz completa y contrastó resultados adicionales.
- CodeGraph se intentó inicializar y consultar antes de explorar el código; falló por npm-shim.js ausente. Se utilizó inspección directa.
- Se inspeccionó el diff completo desde 83ed742 y se ejecutaron procesos nuevos de PS7.6.9 y Windows PowerShell 5.1.26100.9767.
- Las nuevas reproducciones usan bases en memoria. El test de modos de archivo creó y limpió únicamente sus propios archivos temporales.
- No se modificaron motor ni pruebas existentes. Las pruebas de errores deliberados se hicieron en copias aisladas bajo scratch.
- No había issues ni PR abiertos al consultar GitHub. No se publicaron mensajes ni se alteraron estados.

## Matriz de pruebas ejecutada

| Suite/comprobación | PS7 | PS5.1 |
| --- | --- | --- |
| PSLocalBase.Tests.ps1 | 80 pasan | 80 pasan |
| PSLocalBase.Audit.Tests.ps1 | 7 pasan | 7 pasan |
| PSLocalBase.Reevaluation.Tests.ps1 | 17 pasan | 17 pasan |
| PSLocalBase.NativeStress.Tests.ps1 | Pasa | Pasa |
| PSLocalBase.Independent-c57b52c.Tests.ps1 | 7 pasan | 7 pasan |
| PSLocalBase.Revalidation-3ecc2c1.Tests.ps1 | 11 pasan | 11 pasan |
| PSLocalBase.Review-83ed742.Tests.ps1 | 7 pasan | 7 pasan |
| Runner completo | Exit 0 | Exit 0 |
| Nuevo Followup-a526708.Tests.ps1 | **12 pasan / 6 fallan**, exit 1 | **12 pasan / 6 fallan**, exit 1 |

Playground en PS7/STA: pasan todas las comprobaciones automatizadas.

Las seis suites con casos enumerados suman **129 grupos de comprobaciones** (80+7+17+7+11+7). NativeStress es la séptima suite y añade comprobaciones y observaciones. Esto no es una medición de cobertura de líneas/ramas. Los seis fallos del nuevo follow-up corresponden a tres familias: cuatro operaciones numéricas fallidas, una unión mutable y un índice importado.

## Estado de N01–N04

| Hallazgo anterior | Resultado del caso original | Alcance restante |
| --- | --- | --- |
| N01: drop del índice migrado elimina UNIQUE antiguo de otra ruta | Corregido para la expresión legacy habitual sin comillas; se conserva el índice original | Caso externo con columna quoted descrito abajo |
| N02: unión ya anidada pierde una rama | Corregido por rechazo al construir la unión | Mutación posterior de la rama derecha aún elude esa comprobación |
| N03: collectionGroup.create crea tabla literal | Corregido: rechazo antes de cambiar esquema | No se reprodujo un fallo en el caso examinado |
| N04: mismo 1.0000000000000002 tras roundtrip no coincide | Corregido: las cuatro combinaciones originales pasan en ambas ediciones | Mismos tipos y operaciones con 0.1/0.2 aún fallan |

Los casos V01–V09 de la revisión anterior permanecen verdes, incluidos casing de campos, rechazo de agregados compuestos/paginados, mutadores compuestos, populate de ambos lados, truncado con delete, rollback UNIQUE externo y rechazo BLOB.

## Integridad del runner y de las pruebas

No se encontró evidencia de manipulación intencional ni debilitamiento injustificado de assertions para obtener resultados verdes.

- El diff no cambia assertions de las suites existentes; añade la suite Review83 con sus siete comprobaciones originales y la integra como séptima suite del runner.
- El runner requiere cada archivo y propaga fallos.
- En copias aisladas, faltar las suites devuelve exit 1 en ambas ediciones.
- Un child que lanza una excepción no controlada devuelve exit 1 en ambas ediciones.
- Omitir únicamente la excepción de unión anidada en una copia hace fallar N02: 6 pasan/1 falla, exit 1, en ambas ediciones. El checkout no fue alterado.
- La cardinalidad de arrays que comprueba N04 es útil, pero conviene reforzarla con valores sobrevivientes y más valores de entrada. Los resultados no equivalen a garantía de cobertura universal.

Evidencia auxiliar: scratch/a526-tests.

## Hallazgo principal pendiente: N04 con decimales comunes

Ubicación: `PSLocalBase.psm1:2433`, comparación mixta Double/Decimal.

La conversión G17 representa Double 0.1 como 0.10000000000000001 y Double 0.2 como 0.20000000000000001. Compararlos con Decimal 0.1/0.2 produce una falsa desigualdad para el valor que el propio consumidor acaba de guardar y volver a usar.

Reproducción mínima en PS7:

```powershell
$value = [decimal]0.1
$db.collection('items').doc('one').set(@{ values = @($value) })
$db.collection('items').doc('one').update(@{
    values = [PSLocalBase]::ArrayUnion($value)
})
# Se esperan 1 elemento; se obtienen 2.
```

Resultados de la matriz:

| Edición | Entrada | Tipo después de leer | ArrayRemove del mismo valor | ArrayUnion del mismo valor |
| --- | --- | --- | --- | --- |
| PS7 | Decimal 0.1 y 0.2 | Double | Conserva 1 en vez de 0 | Deja 2 en vez de 1 |
| PS5.1 | Double 0.1 y 0.2 | Decimal | Conserva 1 en vez de 0 | Deja 2 en vez de 1 |

Los mismos controles con 0.01 y 1.0000000000000002 pasan, así como los casos que mantienen el mismo tipo al deserializar. De 16 controles numéricos, pasan 12 y fallan 4 en cada edición.

**Prioridad P2.** La familia de idempotencia numérica sigue parcialmente resuelta. Hace falta un contrato de normalización/igualdad compatible con la serialización JSON y ambas ediciones, cubriendo números comunes, valores adyacentes y ambos órdenes de comparación. Cambiar solo la cadena de formato para un ejemplo no cierra el problema general.

## Unión mutable: validación válida al construir, incompleta al ejecutar

Ubicación: guardas de union/unionAll en `PSLocalBase.psm1:579` y `:594`; compilación de la segunda rama en `:1495`.

```powershell
$right = $db.collection('b')
$query = $db.collection('a').union($right)
[void]$right.union($db.collection('c'))
$query.get()
```

Con un documento en cada colección, devuelve dos documentos en vez de tres, sin rechazo. Ambas ediciones lo reproducen. Las guardas se aplicaron antes de que la rama derecha se modificara; la ejecución sigue leyendo solo CurrentCollection de esa rama.

**Prioridad P2.** Acción: revalidar las capacidades al ejecutar o capturar un origen de consulta inmutable. Si el anidamiento no se soporta, rechazarlo claramente; no omitir la fuente de manera silenciosa.

## Compatibilidad condicionada: índice SQLite externo con columna quoted

Ubicación: `PSLocalBase.psm1:449`, detección de json_extract que habilita el fallback por hash.

Un índice histórico de la colisión hash8 con expresión `json_extract("doc", '$.ruta')` es SQLite válido. El detector espera doc sin comillas, por lo que interpreta esta definición como no reconocida y permite el fallback por nombre/hash. Crear el índice de la segunda ruta y después eliminarlo termina eliminando ambos; quedan cero índices. Se reproduce en ambas ediciones.

**Precondición importante:** definición creada/importada externamente o por SQL personalizado. El helper histórico habitual de PSLocalBase produce doc sin comillas; su caso original ya pasa. No se presenta este hallazgo como SQLi ni como el mismo defecto original sin corregir.

Acción: no destruir una restricción de otro campo por coincidencia de nombre cuando la definición es desconocida; inspeccionar de forma robusta o rechazar/omitir explícitamente la migración ambigua.

## Contratos, seguridad y documentación

- Populate compuesto se rechaza antes/después/en la rama derecha con union y unionAll.
- Delete sin criterios deja cero documentos conservando tabla e índices; drop elimina el esquema.
- Parámetros enlazados y filtros numéricos no aparecen en debug; SQL literal sigue visible como advierte SECURITY.
- BLOB y BLOB vacío se rechazan con NotSupportedException y la conexión sigue usable.
- JournalMode y config.effectiveJournalMode coinciden: RAM=memory, archivo con WAL=wal y wal=false=delete; hijos heredan el modo.
- Se retiraron referencias de guardas a la propiedad no declarada CompoundOperations.

La documentación mejoró: el informe Opus se marca histórico y corrige la fecha; Server/WinPE se separan como soporte por diseño y ARM64 como no verificado; desaparece la cifra ±3%.

Pendientes documentales:

1. Benchmarks todavía afirma warm-ups y distribuciones estadísticas documentadas por separado. No se encontró harness repetido ni datos/tablas brutos versionados que sustenten esas afirmaciones; los scripts siguen midiendo una ejecución. No se atribuye falsificación intencional.
2. Windows10/11 figura como Verified in CI & Local Suites, sin evidencia trazable de ambos sistemas. El workflow solo declara windows-latest. No se afirma incompatibilidad con los sistemas no probados.
3. Badges 94/100 y approved without reservations permanecen visibles en README/SECURITY vinculados al informe histórico; deben distinguirse claramente de la evaluación vigente.

## Recursos, arquitectura y límites

NativeStress pasa en ambas ediciones: 500 ciclos sin statements vivos, 100 bases cerradas con asignaciones de SQLite devueltas al nivel inicial y 50 mutaciones concurrentes conservadas mediante reintentos explícitos del harness. La prueba usa journal_mode=memory, no WAL. Las conexiones abandonadas sin Dispose siguen reteniendo memoria nativa; el cierre explícito continúa siendo necesario.

SafeHandle no está implementado. Es una mejora futura de gestión de recursos; no se inventó una fuga en el uso correctamente cerrado ni se incluyó esa implementación en el alcance de esta validación.

Los compiladores y guardas siguen repartidos entre varios métodos y fallbacks. El caso de la rama mutable muestra la utilidad de un origen común e inmutable y validación central de capacidades. No se han probado cortes eléctricos, todas las plataformas anunciadas ni un despliegue SMB completo.

## Artefactos y reproducción

Las pruebas nuevas están en [PSLocalBase.Followup-a526708.Tests.ps1](../_TESTS/PSLocalBase.Followup-a526708.Tests.ps1). Son una entrega de esta revisión, no parte del commit evaluado ni una omisión atribuida retrospectivamente a su runner.

```powershell
pwsh -NoProfile -File .\_TESTS\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_TESTS\run-tests.ps1
pwsh -NoProfile -STA -File .\Playground\verify-playground.ps1
pwsh -NoProfile -File .\_TESTS\PSLocalBase.Followup-a526708.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_TESTS\PSLocalBase.Followup-a526708.Tests.ps1
```

Logs y controles auxiliares: scratch/a526-root, scratch/a526-integrity, scratch/a526-tests y scratch/a526-contracts.

## Puntuación final

Valoración orientativa, no certificación ni porcentaje de cobertura. Media simple de las mismas cinco categorías:

| Área | Puntuación |
| --- | ---: |
| Seguridad y anti-inyección | 92/100 |
| Integridad de datos y concurrencia | 82/100 |
| Estabilidad y memoria | 82/100 |
| Compatibilidad PS5.1/PS7 en Windows probado | 89/100 |
| Funcionalidad y ergonomía | 90/100 |
| **General** | **87/100** |

Mejora desde 85 por cierre de los ejemplos anteriores e integración sin debilitar pruebas. N04 con 0.1/0.2 y la validación de uniones mutables impiden declarar que toda la integridad esté resuelta. El caso de índices externos queda expresamente condicionado a su origen y sintaxis.
