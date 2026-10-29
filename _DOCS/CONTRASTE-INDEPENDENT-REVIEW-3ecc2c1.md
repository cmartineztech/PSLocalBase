# Contraste del informe INDEPENDENT-REVIEW-3ecc2c1.md

Fecha: 29 de octubre de 2026.
Documento examinado: [INDEPENDENT-REVIEW-3ecc2c1.md](INDEPENDENT-REVIEW-3ecc2c1.md).
Commit declarado por el documento: `3ecc2c10a7f6ff30c79e10791affcacacfb2befe`.

## Veredicto

El informe mejora la presentación de limitaciones frente al review anterior, pero no es una validación reproducible del SHA que declara. Atribuye a 3ecc2c1 correcciones que no están en ese commit y que aparecen en el diff local sin commit. Reejecutar las reproducciones contra una copia extraída con git archive del SHA confirma los fallos anteriores: 9 comprobaciones fallan en PS7 y 8 en PS5.1.

Esto no determina que las correcciones locales sean incorrectas. Determina que el informe mezcla versiones y que su puntuación 91/100 no puede trasladarse al commit declarado. No se atribuye intención de engañar ni se afirma que todos los resultados de ejecución del autor sean inventados.

## Método

- Inspección completa del documento y diff del checkout frente a 3ecc2c1.
- Extracción con git archive de PSLocalBase.psm1, PSLocalBase.psd1 e InitWinSqlite3Native.ps1 de 3ecc2c1 a scratch/opus-report-check-3ecc2c1.
- Copia de la suite de reproducciones independiente al snapshot y ejecución en procesos nuevos de PowerShell 7.6.9 y Windows PowerShell 5.1.26100.9767.
- Comprobación de existencia de los cuatro scripts citados por el documento.
- No se modificaron motor, pruebas existentes ni informe examinado. El working tree ya tenía cambios antes de este contraste; se preservaron.

## Hallazgos sobre el informe

### P1 — Confunde commit con cambios locales

La tabla V01–V09 del documento, líneas 50–60, y las conclusiones de sus secciones H02 y veredicto final afirman correcciones en 3ecc2c1 que no existen en su árbol Git.

| Afirmación del informe | Evidencia del SHA declarado |
| --- | --- |
| V01 no reproducido; dropIndex usa -cmatch | En 3ecc2c1 usa -match. El cambio a -cmatch y comparaciones -ceq/-clike aparece en el diff local. V01 falla en ambas ediciones. |
| V02 verifica la expresión antes de reutilizar un índice | El filtro de candidatos con -cmatch se añadió en el working tree. El SHA aún acepta un índice antiguo por sufijo hash8 sin verificar su expresión. V02 falla en ambas ediciones. |
| V03 no reproducido | La nueva comprobación Double/Decimal aparece en el diff local; V03 reproduce pérdida del valor distinto en PS7 sobre el SHA exacto. |
| V04/V05 rechazan agregados compuestos/paginados | Las guardas se añadieron localmente. El SHA devuelve sum=10 para la unión de 10 y 20, y sum=30 para la página que contiene 10. |
| V06/V07 rechazan createIndex/upsert compuestos | Las guardas están en el diff local. El SHA modifica el esquema izquierdo o crea la tabla literal audit_*. |
| V08 rechaza populate en rama derecha | El chequeo de otherQuery.PopulateClauses se añadió localmente. El SHA descarta silenciosamente populate de la rama derecha. |
| V09 ya estaba corregido antes de 3ecc2c1 | El SHA ejecuta DROP TABLE. El cambio local sustituye esa sentencia por DELETE FROM. |

Corrección requerida: identificar un nuevo commit que contenga los cambios, o declarar expresamente que se evaluó un working tree modificado y registrar su diff/hashes. No atribuir esas mejoras al SHA antiguo ni desestimar por ello sus reproducciones.

### P2 — V02 prueba el caso moderno, no el caso de migración reportado

El análisis del documento, líneas 62–72, destaca que los hashes16 difieren y se crean dos índices modernos. Eso ya se había reconocido como corregido. El fallo reportado instala un índice histórico hash8 para una ruta y solicita UNIQUE para otra que comparte el antiguo hash8. Demostrar separación de índices nuevos no refuta la reutilización incorrecta del índice viejo. La reproducción V02 del snapshot falla.

### P2 — Artefactos citados no disponibles

En el momento de esta revisión no existen los cuatro archivos enumerados en las líneas 415–418:

- _TESTS/IndependentVerification.Tests.ps1
- _TESTS/AdditionalProbes.Tests.ps1
- _TESTS/RunnerIntegrity.Tests.ps1
- _TESTS/DeepInspection-V02.ps1

No se conoce la causa de su ausencia. Mientras no se entreguen, no es reproducible la afirmación de que todos los scripts citados están incluidos. Sus comandos tampoco pueden ejecutarse desde esas rutas.

### P2/P3 — H01 trata otro problema y contiene una explicación imprecisa

H01 compara valores test@example.com y TEST@EXAMPLE.COM. V01 trata rutas JSON email y Email, no la igualdad de esos valores. Son cuestiones distintas. Aceptar cadenas con distinta capitalización bajo UNIQUE con comparación binaria no refuta la eliminación de un índice ajeno.

El texto inicial de H01 dice «sin COLLATE BINARY», pero la propia explicación posterior reconoce el comportamiento case-sensitive por defecto. Debe aclarar el contrato de collation y clasificar una opción NOCASE como mejora si no existe requisito de unicidad case-insensitive, no como defecto demostrado.

### P3 — Fecha incorrecta

Las líneas 5 y 451 dicen 2024-10-29. El commit declarado es de 2026-10-29. Debe corregirse la fecha y vincularla con la versión realmente examinada.

## Resultados repetidos sobre el SHA exacto

| Casos | PS7 | PS5.1 |
| --- | --- | --- |
| V01, V02, V04, V05, V06, V07, V08, V09 | Fallan | Fallan |
| V03, Double/Decimal | Falla | Pasa |
| C01, rollback del upgrade UNIQUE y transacción externa | Pasa | Pasa |
| C02, rechazo BLOB y conexión posterior utilizable | Pasa | Pasa |
| Total | 2 pasan / 9 fallan, exit 1 | 3 pasan / 8 fallan, exit 1 |

Comandos ejecutados:

```powershell
pwsh -NoProfile -File scratch/opus-report-check-3ecc2c1/_TESTS/PSLocalBase.Revalidation-3ecc2c1.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scratch/opus-report-check-3ecc2c1/_TESTS/PSLocalBase.Revalidation-3ecc2c1.Tests.ps1
```

No se ejecutaron las reproducciones contra el motor local modificado para calificar el SHA histórico. Tampoco se ha validado aquí por completo ese working tree posterior.

## Lo que sí mejora el informe

- Reconoce que no hay cobertura de líneas/ramas medida.
- Distingue concurrencia en memoria de durabilidad WAL en disco.
- Limita las plataformas realmente probadas.
- Explica la dependencia de Dispose/close para recursos nativos.
- Presenta la puntuación como orientativa y la aprobación con condiciones, no como certificación.

Esas mejoras metodológicas son útiles, pero no subsanan la identificación incorrecta del código evaluado.

## Recomendación

No adoptar el 91/100 como puntuación validada de 3ecc2c1. Separar dos documentos: evidencia histórica del SHA y evaluación de las correcciones posteriores. Entregar los scripts citados, fijar la nueva versión y repetir las pruebas contra esa misma versión antes de actualizar el veredicto. No se modifica la puntuación anterior del SHA histórico a partir de cambios locales aún sin validar completamente.
