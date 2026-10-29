# Revalidación independiente de PSLocalBase — 3ecc2c1

Fecha de la revisión: 29 de octubre de 2026 (America/New_York).
Commit evaluado: `3ecc2c10a7f6ff30c79e10791affcacacfb2befe`, rama `dev`.

Este archivo se ha restaurado a partir de los resultados obtenidos durante la revisión y registrados en la conversación. Sus conclusiones corresponden al commit indicado; no son una nueva validación de cambios posteriores. No se conoce la causa de la desaparición de la entrega local anterior.

## Veredicto

Hay mejoras reales frente a d6f0bda: las cinco suites existentes pasan en ambas ediciones de PowerShell, el runner incluye la suite antes omitida y falla si falta una suite. Las correcciones no cierran todos los problemas de integridad y composición. No se recomendó producción general sin reservas.

La revisión utilizó agentes independientes para código/datos y funcionalidad/issues, con contraste del agente principal. CodeGraph falló al inicializar y consultar por un npm-shim.js ausente; se utilizó inspección directa. No se modificó el motor para obtener los resultados.

## Resultados de ejecución registrados

| Comprobación | PowerShell 7.6.9 | Windows PowerShell 5.1.26100.9767 |
| --- | --- | --- |
| PSLocalBase.Tests.ps1 | 80 pasan | 80 pasan |
| PSLocalBase.Audit.Tests.ps1 | 7 pasan | 7 pasan |
| PSLocalBase.Reevaluation.Tests.ps1 | 17 pasan | 17 pasan |
| PSLocalBase.NativeStress.Tests.ps1 | Pasa | Pasa |
| PSLocalBase.Independent-c57b52c.Tests.ps1 | 7 pasan | 7 pasan |
| Runner completo del commit | Exit 0 | Exit 0 |
| Pruebas adicionales de esta revisión | 2 pasan / **9 fallan** | 3 pasan / **8 fallan** |

Playground pasó todas sus comprobaciones automatizadas en PS7 con STA.

Las pruebas adicionales son nuevos casos de revisión, no cambios a las assertions originales ni una omisión atribuida retrospectivamente al commit. Algunas son variantes de una misma causa raíz.

## Integridad de las pruebas

- El diff frente a d6f0bda no modifica las 80 pruebas originales, Reevaluation ni NativeStress. Independent solo cambia su marca de codificación.
- El runner enumera cinco suites. Una copia aislada sin suites devolvió exit 1 con Required test suite file not found.
- En una copia aislada del módulo se introdujo un comparador deliberadamente incorrecto. Independent detectó la pérdida del Double adyacente en A01 y devolvió exit 1. El motor original no fue alterado.
- R03 aislado conserva un fixture débil, pero el control C01 de Independent sí comprueba la selección y eliminación segura del índice extraño, y ahora forma parte del runner.
- No se encontró evidencia de manipulación intencional de pruebas para obtener resultados verdes. Quedaban variantes sin cubrir.

## Correcciones verificadas

1. Filtros numéricos enlazados como parámetros; el valor de prueba ya no aparecía en debug.
2. Double/Double distingue 1.0 de 1.0000000000000002; Int64/Double iguales en 2^53 coinciden.
3. El caso legacy profile.code frente a profile_code conserva la restricción ajena previamente perdida.
4. Las dos rutas modernas con colisión del antiguo hash32 crean índices separados con nombres más largos.
5. Un upgrade fallido a UNIQUE conserva el índice anterior mediante savepoint. Se comprobó también una transacción externa y su rollback.
6. collectionGroup().add() se rechaza antes de crear una tabla literal con comodines.
7. Varias combinaciones de populate con union/collectionGroup se rechazan claramente.
8. query rechaza BLOB y BLOB vacío con NotSupportedException; la conexión sigue utilizable.
9. JournalMode y config.effectiveJournalMode exponen el modo efectivo. Se probaron memory en RAM, wal en archivo y delete con wal=false en ambas ediciones.

## Hallazgos pendientes reproducidos

| Caso | Prioridad y ubicación en 3ecc2c1 | Resultado observado |
| --- | --- | --- |
| V01 | P2 — PSLocalBase.psm1:415–425 | dropIndex('email') elimina también el UNIQUE de Email. El regex se aplica con -match, insensible a mayúsculas, aunque las rutas JSON son distintas. Después acepta duplicados. Ambas ediciones. |
| V02 | P2 — PSLocalBase.psm1:348–353 | La compatibilidad con sufijos hash8 reutiliza un índice antiguo de otra ruta sin verificar su expresión. La segunda restricción UNIQUE no se crea y acepta duplicados. Ambas ediciones. |
| V03 | P2 — PSLocalBase.psm1:2385–2389 | Guardar Double 1.0000000000000002 y ejecutar ArrayRemove([decimal]1) elimina el valor distinto en PS7. En PS5.1 pasa por diferencias de deserialización. |
| V04 | P2 — _ExecuteAggregate, PSLocalBase.psm1:1695 y :1730 | Unión de valores 10 y 20: sum devuelve 10 en vez de 30. Ambas ediciones. |
| V05 | P2 — mismo compilador de agregados | orderBy().limit(1).sum() devuelve 30 cuando la fuente paginada contiene 10. Ambas ediciones. |
| V06 | P2 — createIndex desde :312 | union().createIndex() modifica únicamente la rama izquierda, sin rechazar la combinación. |
| V07 | P2 — upsert desde :887 | collectionGroup('audit_*').upsert() crea y escribe una tabla literal audit_*. Ambas ediciones. |
| V08 | P2 — guardas de union/unionAll | a.union(b.populate(...)).get() acepta e ignora populate en la rama derecha. También unionAll. Ambas ediciones. |
| V09 | Contrato documental — SECURITY.md:72 y motor :2065–2066 | SECURITY promete truncado conservando tabla e índices, pero bare delete sigue ejecutando DROP TABLE. Ambas ediciones. |

V02 utiliza la colisión histórica 43CEB4E2 en la colección users entre estas rutas:

```text
a.a_a_a_a_a_a_a_a.a.a.a.a.a_a.a_a_a.a
a_a.a.a.a_a.a_a.a.a.a_a_a.a.a.a_a.a_a
```

Acciones necesarias: comprobar expresiones reales y mayúsculas de rutas al resolver índices; completar la comparación numérica entre tipos sin redondeo silencioso; compartir la compilación del origen de consulta o rechazar combinaciones no soportadas; aplicar guardas comunes a todos los mutadores; alinear el contrato de delete.

## Issues revisados

GitHub mostraba #13–#21 cerrados y ningún PR abierto. El cierre no se utilizó como evidencia de resolución y no se modificaron estados en esta revalidación.

| Issue | Veredicto |
| --- | --- |
| #13 | Parcial: queda populate en la rama derecha, V08. |
| #14 | Observabilidad resuelta; prueba de fallback controlado pendiente. No se reprodujo una discrepancia WAL silenciosa. |
| #15 | No resuelto: documentación de truncate frente a implementación DROP. |
| #16 | Corregido en lo esencial: parámetros numéricos protegidos y advertencia expresa sobre SQL literal en logs/errores. |
| #17 | Runtime resuelto mediante rechazo explícito de BLOB; falta completar documentación pública de tipos. |
| #18 | Seguía cerrado sin reproducción exitosa por requerir privilegios para crear el enlace. No se declaró imposible. |
| #19 | Parcial: informe inicial marcado histórico, pero badge/aprobación sin reservas no refleja esta revisión. |
| #20 | Pendiente: scripts sin nueva metodología; afirmaciones de warm-up y medianas ±3% sin harness/resultados brutos versionados para verificarlas. No se atribuye falsificación intencional. |
| #21 | Pendiente: README afirma CI para Windows10/11 y Server2019/2022, pero workflow conserva un solo windows-latest. No demuestra incompatibilidad con esas plataformas. |

## Arquitectura, recursos y límites

Fortalezas: puente nativo pequeño, DLL de System32, parámetros preparados, propiedad raíz/hijos, savepoints y liberación explícita. La clase todavía mezcla conexión, esquema, serialización y varios compiladores divergentes. Faltan guardas uniformes de capacidades; Update-TypeData duplica lógica y no hay SafeHandle/finalización automática.

En las cargas ejecutadas, 500 ciclos no dejaron statements abiertos y 100 bases cerradas devolvieron las asignaciones SQLite al nivel inicial. Dos escritores preservaron 50 mutaciones con reintentos explícitos del harness en memoria compartida. Esta prueba usa journal_mode=memory, no demuestra durabilidad WAL.

Veinte conexiones abandonadas sin Dispose retuvieron aproximadamente 4,45 MB nativos tras GC. El cierre explícito sigue siendo parte del contrato; esto no se presenta como fuga en uso correctamente cerrado. No se probaron cortes eléctricos, todas las plataformas anunciadas ni un despliegue SMB completo.

## Reproducción

Las nuevas comprobaciones están en [PSLocalBase.Revalidation-3ecc2c1.Tests.ps1](../_TESTS/PSLocalBase.Revalidation-3ecc2c1.Tests.ps1). Usan bases en memoria y devuelven exit 1 mientras persistan los fallos.

```powershell
pwsh -NoProfile -File .\_TESTS\PSLocalBase.Revalidation-3ecc2c1.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_TESTS\PSLocalBase.Revalidation-3ecc2c1.Tests.ps1
```

Experimentos auxiliares conservados localmente: scratch/recheck-engine, scratch/recheck-issues y scratch/recheck-numeric-guard. No forman parte del commit evaluado.

## Puntuación final

Valoración orientativa, no certificación ni porcentaje de cobertura. Media simple de las cinco categorías usadas en la revisión anterior:

| Área | Puntuación |
| --- | ---: |
| Seguridad y anti-inyección | 88/100 |
| Integridad de datos y concurrencia | 72/100 |
| Estabilidad y memoria | 82/100 |
| Compatibilidad PS5.1/PS7 en Windows probado | 86/100 |
| Funcionalidad y ergonomía NoSQL | 77/100 |
| **General** | **81/100** |

La nota aumentó desde 76 por mejoras verificadas y un runner más estricto. Los fallos de integridad pendientes impidieron recomendar producción general sin reservas.
