# Contraste técnico del review de Opus

Documento examinado: AUDIT-CLAUDE-OPUS-5.5.md.
Fecha del contraste: 29 de octubre de 2026.
El informe declara evaluar c57b52c; el checkout actual está en 3ecc2c1. Se contrastaron las afirmaciones históricas con git show/git ls-tree de c57b52c, para no atribuir al informe diferencias introducidas después.

## Veredicto

El informe identifica defensas reales, pero contiene errores factuales y garantías más amplias que su evidencia. No respalda una certificación de producción ni una cobertura medida del 96%. El 94/100 debe presentarse, como máximo, como opinión histórica del autor, no como aprobación técnica vigente sin reservas.

No se atribuye intención de engañar ni manipulación de resultados. El problema verificable es la falta de correspondencia entre varias afirmaciones y el código/revisión que el propio documento identifica.

## Hallazgos sobre el informe

| Prioridad | Línea del informe | Afirmación | Contraste y corrección necesaria |
| --- | ---: | --- | --- |
| P1 | 25, 39 | Production Ready y ausencia de riesgos de corrupción o defectos bloqueantes | La revisión independiente reprodujo fallos de UNIQUE, precisión numérica y composición. Algunos siguen en 3ecc2c1 y otros se corrigieron después de c57b52c. Sustituir la aprobación sin reservas por un veredicto acotado al alcance y resultados documentados. |
| P2 | 572–575 | Enumera Independent-c57b52c como suite automatizada | Ese archivo no existe en el árbol de c57b52c y el runner de dicho commit enumera cuatro suites. La inclusión efectiva de cinco suites llegó con 3ecc2c1. El informe mezcla revisiones. |
| P2 | 583–596 | CRUD, transacciones, arrays y seguridad al 100%; cobertura global estimada 96% | No acompaña un informe de cobertura de líneas/ramas ni un denominador de requisitos que permita reproducir esos porcentajes. Son estimaciones declaradas, no mediciones. Además, los casos reproducidos contradicen la idea de cobertura funcional completa. |
| P2 | 180 | drop explícito requerido para eliminar una colección | En c57b52c, delete sin clave ni filtro ya ejecuta DROP TABLE; ocurre también en 3ecc2c1. No es una diferencia causada por una revisión posterior. Corregir la descripción del contrato. |
| P2 | 182 | Eliminación atómica de .db, .db-wal y .db-shm | deleteDatabase recorre archivos y ejecuta File.Delete por separado, acumulando errores. Agregar errores no convierte la secuencia en una transacción atómica del sistema de archivos. |
| P2 | 347 | Reutilización de prepared statements | Los helpers preparan el statement por llamada y lo finalizan en finally. Separar preparación y ejecución no demuestra una caché ni reutilización entre llamadas. |
| P2 | 351, 497 | Mutaciones de arrays realizadas en SQL, evitando read-modify-write | update lee el JSON, usa ConvertFrom-Json, llama a _DeepMerge y persiste con set. BEGIN IMMEDIATE aporta protección transaccional cuando inicia la transacción, pero no transforma la operación en una mutación SQL del array. |
| P2 | 758–777 | Identidad de índices resistente a colisiones por usar SHA256 | El ejemplo del propio informe recorta el digest a ocho hexadecimales: 32 bits. Se encontró una colisión real con dos rutas que normalizan al mismo nombre. El hash más largo de 3ecc2c1 corrige las altas modernas, pero su compatibilidad hash8 aún requiere verificar la expresión real. |
| P2 | 155–170, 241 | Prevención de filtración de credenciales; debug no supone fuga | Se ocultan valores enlazados, pero SQL literal y filtros numéricos de c57b52c pueden aparecer en diagnósticos. 3ecc2c1 parametriza filtros numéricos y aclara el límite de SQL literal. La garantía original era excesiva. |
| P3 | 3 | Review Date: January 2025 | git show fecha el commit c57b52c en 2026-10-29. La fecha declarada es inconsistente con la revisión evaluada y necesita corrección. |

## Fortalezas correctamente identificadas

- Prepared statements y enlace de valores en las rutas correspondientes.
- Allowlist de identificadores, operadores y direcciones de ordenación.
- Búsqueda de DLL limitada a System32 en el puente nativo.
- Validación de NUL en claves y preservación de texto con longitud explícita.
- Liberación de statements y errores nativos en finally en las rutas examinadas.
- Guardas de colecciones hijas después del cierre de su propietario.
- Savepoints para bulk y recomendaciones útiles sobre la complejidad de get/where y los fallbacks duplicados.

Estas fortalezas no prueban por sí solas ausencia universal de vulnerabilidades, fugas o condiciones de carrera. Las mediciones de recursos fueron favorables con cierre correcto; las conexiones abandonadas sin Dispose retienen memoria nativa y la prueba concurrente de NativeStress usa journal_mode=memory, no WAL.

## Cómo corregir el review

1. Marcarlo como histórico de c57b52c y corregir su fecha.
2. Corregir las afirmaciones técnicas anteriores, conservando la distinción entre atomicidad transaccional y ejecución SQL nativa.
3. Sustituir porcentajes de cobertura no medidos por una matriz de pruebas ejecutadas, resultados, plataforma, commit y limitaciones.
4. Vincular cada conclusión de seguridad a una prueba o inspección concreta; evitar garantías universales.
5. Retirar o acotar el badge de aprobación sin reservas mientras existan fallos de integridad reproducibles.
6. Publicar una evaluación actual separada, sin hacer pasar correcciones posteriores por resultados del commit histórico.

## Evidencia reproducible

```powershell
git show -s --format='%h %aI %s' c57b52c
git ls-tree -r --name-only c57b52c -- _TESTS
git show c57b52c:_TESTS/run-tests.ps1
git show c57b52c:PSLocalBase.psm1
pwsh -NoProfile -File .\_TESTS\PSLocalBase.Revalidation-3ecc2c1.Tests.ps1
```

Los resultados actuales y sus reproducciones se detallan en [REVALIDATION-3ecc2c1.md](REVALIDATION-3ecc2c1.md). Este contraste no modifica el informe de Opus, el motor ni su puntuación anterior; documenta por qué la aprobación 94/100 no puede adoptarse como certificación técnica verificable.
