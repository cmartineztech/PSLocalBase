# Validación independiente de PSLocalBase — 83ed742

Fecha: 29 de octubre de 2026 (America/New_York).
Rama: `dev`. Commit: `83ed74235b6703753b6b9dbc733f5402fbb1d30e`.
El checkout estaba limpio al comenzar. Se verificó el SHA al finalizar; no se modificaron motor ni pruebas existentes para obtener resultados verdes.

## Veredicto

**V01–V09 están corregidos en las reproducciones concretas de nuestra revisión anterior.** Sus once comprobaciones pasan en ambas ediciones. Las seis suites del runner y Playground también pasan. Estas correcciones ahora están contenidas en el commit evaluado, sin mezclar resultados del working tree con un SHA anterior.

La evaluación más amplia todavía encuentra cuatro variantes pendientes: pérdida de un UNIQUE antiguo al borrar un índice migrado, una rama descartada en una unión anidada, creación de esquema desde collectionGroup y falta de idempotencia numérica tras guardar/leer ciertos Double/Decimal. No se recomienda aún una aprobación de producción general sin reservas.

La conclusión no reabre las reproducciones originales como si no hubieran sido corregidas: distingue esos cierres de los casos adicionales de las mismas áreas.

## Método

- Tres agentes independientes revisaron V01–V09/código, integridad de pruebas y contratos/documentación. El agente principal ejecutó la matriz y contrastó los casos adicionales.
- CodeGraph se intentó inicializar y consultar antes de explorar el código. Falló por npm-shim.js ausente; se utilizó inspección directa.
- Procesos nuevos de PowerShell 7.6.9 y Windows PowerShell 5.1.26100.9767, sobre este equipo Windows.
- Reproducciones adicionales con bases exclusivamente en memoria y copias aisladas para introducir errores controlados de prueba. El módulo productivo no fue alterado.
- Se consultaron GitHub issues y PR abiertos: no había ninguno. No se cambiaron estados ni se publicaron mensajes en esta revisión.

## Resultados de ejecución

| Suite/comprobación | PS7 | PS5.1 |
| --- | --- | --- |
| PSLocalBase.Tests.ps1 | 80 pasan | 80 pasan |
| PSLocalBase.Audit.Tests.ps1 | 7 pasan | 7 pasan |
| PSLocalBase.Reevaluation.Tests.ps1 | 17 pasan | 17 pasan |
| PSLocalBase.NativeStress.Tests.ps1 | Pasa | Pasa |
| PSLocalBase.Independent-c57b52c.Tests.ps1 | 7 pasan | 7 pasan |
| PSLocalBase.Revalidation-3ecc2c1.Tests.ps1 | 11 pasan | 11 pasan |
| Runner de seis suites | Exit 0 | Exit 0 |
| Nuevas variantes: PSLocalBase.Review-83ed742.Tests.ps1 | **2 pasan / 5 fallan**, exit 1 | **2 pasan / 5 fallan**, exit 1 |

Playground en PS7/STA: todas sus comprobaciones pasan. Las cinco suites con casos enumerados suman **122 grupos de comprobaciones** (80+7+17+7+11). NativeStress añade sus comprobaciones y observaciones; no debe seguir presentándose el total antiguo de 116 como el conteo vigente ni confundirse grupos de assertions con cobertura de líneas/ramas.

Las nuevas variantes corresponden a cuatro causas/familias, no cinco defectos independientes: el caso numérico tiene dos operaciones fallidas en cada edición.

## Cierre de V01–V09

| Hallazgo anterior | Veredicto comprobado en 83ed742 |
| --- | --- |
| V01: índices email/Email | Corregido en los casos modernos probados: eliminación sensible a mayúsculas. |
| V02: reutilización de índice antiguo al crear otro | Corregido: se comprueba la expresión candidata y se crea la segunda restricción. La variante de eliminación se describe abajo. |
| V03: Decimal1 elimina Double adyacente distinto | Corregido: el elemento distinto se conserva. La igualdad tras roundtrip tiene otra variante pendiente. |
| V04: agregado de unión ignora una rama | Corregido por rechazo explícito de agregados compuestos. |
| V05: agregado ignora paginación | Corregido por rechazo explícito de paginación en agregados. |
| V06: createIndex de unión modifica rama izquierda | Corregido por rechazo previo a efectos. |
| V07: upsert de grupo crea tabla literal | Corregido por rechazo previo a efectos. |
| V08: populate de rama derecha ignorado | Corregido por rechazo explícito en ambos lados de union/unionAll. |
| V09: delete contradice truncado documentado | Corregido: delete vacía documentos y conserva tabla e índices; drop elimina el esquema. |

Los controles adicionales de rollback de un upgrade UNIQUE dentro de transacción externa y de rechazo de BLOB también pasan.

## Integridad de las pruebas

No se encontró evidencia de manipulación intencional ni debilitamiento injustificado de assertions.

- El runner enumera seis suites y exige su existencia. Una copia sin suites devuelve exit 1 en ambas ediciones.
- Un child con una excepción no controlada también provoca exit 1; el runner no oculta ese error.
- Cambiar tres tests de delete a drop es coherente con el nuevo contrato de truncado. La suite core sigue comprobando que bare delete deja cero documentos y V09 verifica que preserve tabla e índices.
- En una copia aislada, un comparador float que siempre retorna true hace fallar A01 (Independent: 6 pasan/1 falla, exit 1).
- En otra copia, omitir la excepción de agregado compuesto hace fallar V04 (Revalidation: 10 pasan/1 falla, exit 1).
- R01a/R01b conservan algunas assertions permisivas y R03 aislado un fixture débil, pero los controles integrados Independent C01 y Revalidation comprueban efectos que aquellos no cubren. La detección de dos defectos controlados no demuestra cobertura universal.

Experimentos y resultados auxiliares: scratch/verify83-tests y scratch/verify83-root.

## Variantes pendientes reproducidas

### N01 — P2: dropIndex todavía elimina un UNIQUE antiguo de otra ruta

Ubicación: `PSLocalBase.psm1:441–443`.

Escenario:

1. Existe un índice UNIQUE antiguo con hash8 43CEB4E2 sobre la primera ruta de la colisión histórica.
2. Se crea correctamente el índice moderno de la segunda ruta.
3. dropIndex(segundaRuta) elimina ambos, aunque la definición del índice antiguo corresponde a la primera ruta.
4. Quedan cero índices y se aceptan duplicados de la primera ruta.

Se reproduce en PS7 y PS5.1. El fallback por nombre/hash se usa aunque la definición SQL presente no coincida. Esto es distinto de V02: la creación ya verifica la expresión, pero la eliminación mantiene una vía de compatibilidad que la contradice.

Acción: una definición SQL no coincidente no debe ser anulada por coincidencia de nombre; tratar explícitamente los índices históricos ambiguos.

### N02 — P2: unión anidada descarta una rama

Ubicación: `PSLocalBase.psm1:1481`, con lógica equivalente en count.

`a.union(b.union(c)).get()` devuelve dos documentos, no los tres esperados. El compilador usa CurrentCollection de la segunda rama y omite su propia unión. Se reproduce en ambas ediciones.

Acción: compilar recursivamente el origen compuesto o rechazar expresamente el anidamiento antes de ejecutar. No aceptar una cadena que pierde una fuente silenciosamente.

### N03 — P2: collectionGroup.create modifica esquema literal

Ubicación: `PSLocalBase.psm1:295`.

`collectionGroup('audit_*').create()` crea una tabla literal audit_*, sin rechazar la operación. Ocurre en ambas ediciones. Las guardas de add, upsert, set y otros métodos no cubren create.

Acción: centralizar la comprobación de capacidades de consultas compuestas/grupos antes de cualquier cambio de datos o esquema. Si un método se soporta para un grupo, definir expresamente su semántica; crear el nombre literal del patrón no satisface la expectativa de grupo solo lectura.

### N04 — P2: ArrayUnion/ArrayRemove no son idempotentes para el mismo valor tras roundtrip

Ubicación: comparación mixta Double/Decimal en `PSLocalBase.psm1:2412–2425`.

Se guarda el valor 1.0000000000000002 y se aplica una mutación con el mismo valor y tipo originales:

| Edición | Entrada | Tipo leído | Resultado incorrecto |
| --- | --- | --- | --- |
| PS7 | Decimal | Double | ArrayRemove deja un elemento; ArrayUnion deja dos |
| PS5.1 | Double | Decimal | ArrayRemove deja un elemento; ArrayUnion deja dos |

Double/Double en PS7 y Decimal/Decimal en PS5.1 pasan. En cada edición fallan dos de cuatro controles. El guard añadido corrige la eliminación del valor distinto de V03, pero sigue dando falsas desigualdades después de la serialización/deserialización.

Acción: definir la igualdad del modelo numérico JSON entre ediciones y preservar la identidad del valor almacenado. Si algún tipo no se admite, validarlo explícitamente; no duplicar o ignorar silenciosamente una mutación del mismo valor.

## Contratos e issues anteriores

| Tema | Resultado |
| --- | --- |
| #13 populate compuesto | Resuelto por rechazo explícito en los casos examinados, incluidos ambos lados y ambos operadores. |
| #14 modo SQLite efectivo | Observabilidad verificada: memory en RAM, wal/delete en archivos según opciones, heredado por hijos. No se simuló fallback controlado ni fallo eléctrico. |
| #15 delete/drop | Resuelto y documentación básica alineada. |
| #16 diagnósticos | Parámetros enlazados y valores numéricos ocultos; SQL literal visible como se advierte. No es redacción universal. |
| #17 BLOB | Rechazo explícito verificado para BLOB y vacío; conexión posterior usable. Conviene documentar públicamente tipos no soportados. |
| #19 auditorías | Pendiente documental: badges 94/100 y aprobación sin reservas siguen apuntando al informe histórico de c57b52c, cuya fecha continúa incorrecta. |
| #20 benchmarks | Pendiente: scripts de una medición y sin resultados brutos versionados que respalden warm-ups/medianas ±3% anunciados. No se afirma falsificación. |
| #21 plataformas | Pendiente: README y _DOCS/README anuncian CI de Windows10/11 y Server2019/2022; el workflow usa un solo windows-latest. No se demuestra incompatibilidad, sino falta de validación de esas afirmaciones. |

No había issues ni PR abiertos al consultar GitHub. Su ausencia no se utilizó como prueba de corrección; esta revisión no creó, reabrió ni cerró ninguno.

## Arquitectura, seguridad y memoria

Fortalezas verificadas: valores parametrizados, whitelist de entradas correspondientes, System32, validación de claves, propiedad raíz/hijos y liberación explícita. Las guardas de composición ahora son más completas y los contratos no soportados se rechazan en lugar de producir resultados falsos en los casos corregidos.

La debilidad estructural sigue siendo la representación fragmentada del origen de consulta y guardas repetidas por método. Las variantes N02/N03 muestran por qué conviene una política central de capacidades y un compilador común. Los fallbacks Update-TypeData duplican lógica; una propiedad CompoundOperations usada por guardas no aparece declarada en la clase revisada y merece limpieza, sin que se haya demostrado un fallo de las operaciones normales por ello.

NativeStress pasa en ambas ediciones: 500 ciclos sin statements vivos, 100 bases cerradas con retorno al nivel inicial de asignaciones y 50 mutaciones concurrentes conservadas con reintentos explícitos del harness. Usa journal_mode=memory, no WAL. La observación de conexiones abandonadas sin Dispose sigue mostrando retención nativa; no prueba fuga en uso cerrado correctamente. No hay SafeHandle/finalizador que sustituya el contrato de cierre manual.

No se certifican resistencia a fallos eléctricos, todos los sistemas Windows anunciados, ARM64/WinPE ni un despliegue SMB completo. No se ejecutaron benchmarks largos para inferir cifras ausentes de la evidencia versionada.

## Entrega y comandos

Las nuevas variantes están en [PSLocalBase.Review-83ed742.Tests.ps1](../_TESTS/PSLocalBase.Review-83ed742.Tests.ps1). Son nuevas pruebas de esta revisión, fuera del commit evaluado y de su runner; no una omisión retrospectiva atribuida a él.

```powershell
pwsh -NoProfile -File .\_TESTS\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_TESTS\run-tests.ps1
pwsh -NoProfile -STA -File .\Playground\verify-playground.ps1
pwsh -NoProfile -File .\_TESTS\PSLocalBase.Review-83ed742.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_TESTS\PSLocalBase.Review-83ed742.Tests.ps1
```

Logs y reproducciones auxiliares: scratch/verify83-root, scratch/verify83-engine, scratch/verify83-tests y scratch/verify83-contracts. El runner actual se dejó intacto.

## Prioridades finitas para la siguiente validación

1. No eliminar un índice cuya definición conocida corresponde a otra ruta, aunque coincida su nombre antiguo.
2. Preservar o rechazar unión anidada; rechazar create de grupos antes de cambiar esquema.
3. Hacer idempotentes las mutaciones del mismo valor numérico tras roundtrip en ambas ediciones.
4. Añadir estas variantes como regresiones y corregir las afirmaciones documentales no verificadas.

## Puntuación final

Valoración orientativa, no certificación ni medición de cobertura. Media simple de las cinco categorías mantenidas en nuestras revisiones:

| Área | Puntuación |
| --- | ---: |
| Seguridad y anti-inyección | 90/100 |
| Integridad y concurrencia | 80/100 |
| Estabilidad y memoria | 82/100 |
| Compatibilidad PS5.1/PS7 en Windows probado | 88/100 |
| Funcionalidad y ergonomía | 85/100 |
| **General** | **85/100** |

Mejora desde 81 por cierre verificado de V01–V09, integración de regresiones y mayor confianza en el runner. Los límites adicionales de integridad y composición impiden afirmar que todos los problemas estén resueltos o recomendar producción general sin reservas.
