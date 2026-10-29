# Analisis de seguridad y funcionalidad

> [!NOTE]
> **DOCUMENTO HISTÓRICO / HISTORICAL AUDIT DOCUMENT**
>
> Este documento representa una auditoría preliminar realizada sobre la revisión base commit `a5de2d8` (2026-10-28).
>
> **Estado de los hallazgos:** Todos los hallazgos F01–F07 detallados en este informe han sido **completamente resueltos** en revisiones posteriores del motor PSLocalBase. Dicha resolución ha sido verificada exhaustivamente por la suite de pruebas automatizadas **TC-74 a TC-80** (`_TESTS/PSLocalBase.Audit.Tests.ps1`) y suites independientes de reevaluación (`_TESTS/PSLocalBase.Reevaluation.Tests.ps1`) tanto en Windows PowerShell 5.1 como en PowerShell 7.x.
>
> Para consultar el estado actual y vigente de auditoría y seguridad del proyecto, diríjase a:
> - [**Auditoría de Seguridad y Calidad - Claude Opus 5.5**](AUDIT-CLAUDE-OPUS-5.5.md) (`_DOCS/AUDIT-CLAUDE-OPUS-5.5.md`)
> - [**Informe de Revisión y Verificación 2026-10-29**](REVIEW-2026-10-29.md) (`_DOCS/REVIEW-2026-10-29.md`)

Fecha: 2026-10-28 (America/New_York). Rama: `dev`.
Revision base: `a5de2d8` (`fix: resolve Codex P2 issues #6, #7, #8, #9, #10, #11`).

## Resultado

La suite existente pasa 73/73 casos en cada una de las dos ediciones de PowerShell probadas. Sin embargo, siete comprobaciones adicionales reproducen fallos: dos de prioridad P1 por perdida de datos y cinco de prioridad P2 por integridad o resultados incorrectos. No conviene promover esta revision a produccion sin resolver al menos F01 y F02.

Esta entrega contiene el analisis y pruebas de regresion; no modifica el motor. Las siete pruebas nuevas fallan deliberadamente contra la revision examinada porque expresan el comportamiento correcto esperado. No forman parte automaticamente de `run-tests.ps1`.

## Alcance y metodo

- Inspeccion del modulo, manifiesto, interoperabilidad nativa, consultas y escrituras, cierre de conexiones, transacciones, Playground, documentacion de seguridad y workflow de CI.
- Ejecucion de la suite existente en procesos nuevos de PowerShell 7.6.9 y Windows PowerShell 5.1.26100.9767.
- Ejecucion de la verificacion automatizada de Playground con PowerShell 7 en STA.
- Reproducciones nuevas con bases exclusivamente en memoria, ejecutadas en ambas ediciones.
- Busqueda limitada de patrones de claves privadas y tokens habituales: no se detectaron coincidencias. Esto no equivale a una auditoria completa de secretos ni incluye el historial de Git.
- CodeGraph no pudo inicializarse: el ejecutable disponible referencia un `npm-shim.js` inexistente. Se utilizo inspeccion directa como alternativa, despues de intentar inicializacion y consulta de estado.

No se ejecutaron benchmarks de carga prolongada, pruebas de fallo electrico, una revision de vulnerabilidades del binario de Windows ni ataques sobre sistemas externos. Los resultados corresponden a esta revision y a este equipo.

## Hallazgos confirmados

### F01 - P1: orderBy().delete() elimina la coleccion completa

Ubicacion: [PSLocalBase.psm1:1919](../PSLocalBase.psm1#L1919), rama destructiva en la linea 1939.

`delete()` rechaza `limit` y `skip`, pero no comprueba `OrderByClause`. Sin clave ni filtros termina en `DROP TABLE`. La politica `SECURITY.md`, apartado 6, afirma que tambien se rechaza `orderBy()`.

Reproduccion minima:

```powershell
$db.collection('users').doc('u1').set(@{ name = 'Alice' })
$db.collection('users').orderBy('name').delete()
$db.collectionExists('users') # False; no se lanzo excepcion
```

Impacto: perdida de todos los documentos e indices de la coleccion ante un encadenamiento accidental. Es un fallo de proteccion de operaciones destructivas, sin necesidad de inyeccion SQL.

Accion: rechazar la ordenacion antes de cualquier mutacion, igual que la paginacion; mantener `.drop()` como la operacion explicita. Comprobar que la excepcion conserva documentos e indices y actualizar la politica para que coincida con la implementacion.

### F02 - P1: upsert sin identificador deriva la clave de un campo arbitrario

Ubicacion: [PSLocalBase.psm1:795](../PSLocalBase.psm1#L795) y [_ResolveKeyFromCriteria:553](../PSLocalBase.psm1#L553).

Si no hay `CurrentKey`, clave explicita, `key`, `id` ni `_key`, `upsert()` reutiliza `_ResolveKeyFromCriteria()`. Este helper devuelve el primer valor de cualquier objeto. La generacion de GUID solo ocurre si ese valor resulta vacio. La especificacion anuncia claves automaticas o explicitas.

Con dos objetos ordenados `{ role = 'reader'; name = 'Alice' }` y `{ role = 'reader'; name = 'Bob' }`, ambas llamadas devuelven la clave `reader`; queda un solo documento, el de Bob. El objeto ordenado hace determinista la reproduccion; una hashtable comun tampoco ofrece una identidad fiable basada en su primer campo.

Impacto: sobrescritura silenciosa de documentos que no comparten identidad. Si una aplicacion admite cargas externas y confia en la clave automatica, un valor del contenido puede decidir el documento sustituido.

Accion: separar resolucion de criterios de navegacion y resolucion de identidad para escritura. Para `upsert`, aceptar solo los identificadores expresamente soportados o generar un GUID. Conservar la precedencia documentada de las claves explicitas y probar objetos sin identificador.

### F03 - P2: ArrayRemove confunde enteros Int64 distintos

Ubicacion: [PSLocalBase.psm1:2195](../PSLocalBase.psm1#L2195).

`_JsonValuesEqual()` convierte ambos numeros a `double`. Los enteros `9007199254740992` y `9007199254740993` se comparan como iguales. Tras almacenar ambos en `ids`, `ArrayRemove` del primero deja `[]` en lugar de conservar el segundo.

Impacto: eliminacion del elemento equivocado o supresion de elementos nuevos en `ArrayUnion`; especialmente relevante para identificadores Int64. Los valores originales se almacenan correctamente: el fallo aparece en la comparacion de la mutacion.

Accion: comparar enteros sin conversion a coma flotante, definir las reglas entre tipos numericos y cubrir limites de Int64, decimales y valores adyacentes superiores a 2^53.

### F04 - P2: dropIndex depende de las mayusculas de la coleccion

Ubicacion: [PSLocalBase.psm1:362](../PSLocalBase.psm1#L362), tambien generacion de nombres en la linea 312.

SQLite resuelve `users` y `USERS` como la misma tabla, pero el hash del nombre del indice usa la cadena original. Crear un indice unico en `users.email` y eliminarlo desde `USERS` deja `idx_users__email_A62F55FE` presente, sin lanzar error.

Impacto: los cambios de indices no se aplican de forma consistente; pueden seguir rechazandose escrituras pese a un `dropIndex()` aparentemente satisfactorio.

Accion: resolver el nombre canonico de la coleccion antes de generar la identidad del indice. Preservar la distincion entre rutas JSON sensibles a mayusculas y planificar compatibilidad con los nombres existentes. Verificar altas, bajas y cambios de unicidad con distintas grafias de la coleccion.

### F05 - P2: get ignora union cuando la rama izquierda usa doc

Ubicacion: [PSLocalBase.psm1:1250](../PSLocalBase.psm1#L1250).

La lectura puntual se ejecuta antes de la rama compuesta. Con un documento en `a` y otro en `b`, `.collection('a').doc('a1').union($db.collection('b')).get()` devuelve solo el de `a`. Una consulta nueva equivalente con `.count()` devuelve 2.

Impacto: resultados incompletos y discrepancia entre lectura y conteo. El retorno anticipado tambien evita la validacion de conexion que reside dentro de la rama `union`; esta observacion es de flujo de codigo y no implica acceso a otra conexion.

Accion: compilar la consulta compuesta antes de resolver una lectura puntual, o limitar la rama puntual a consultas sin `union`. Probar `union`, `unionAll`, `first`, `get` y `count` con claves a ambos lados y validar las conexiones antes de ejecutar.

### F06 - P2: union falla si una rama inexistente aporta parametros

Ubicacion: [PSLocalBase.psm1:1323](../PSLocalBase.psm1#L1323); logica equivalente de conteo en la linea 1708.

El constructor agrega los parametros de filtros incluso cuando sustituye una tabla inexistente por `SELECT '' AS key, '' AS doc WHERE 0`, que no contiene placeholders.

Reproduccion: una rama `missing.where('name', '=', 'Alice')` unida a una coleccion existente con Bob lanza `Parameter count mismatch: query expects 0 parameters, but 1 were provided.` en lugar de devolver Bob.

Impacto: la existencia o eliminacion de una coleccion rompe consultas compuestas que pretenden tratar esa rama como vacia.

Accion: agregar SQL y parametros como una unidad por rama; las ramas vacias no deben aportar parametros. Aplicar la misma regla a `get` y `count` y probar ambos lados inexistentes con filtros parametrizados.

### F07 - P2: array-contains tambien selecciona escalares y objetos

Ubicacion: [PSLocalBase.psm1:957](../PSLocalBase.psm1#L957), logica similar en la linea 977 para `array-contains-any`.

Se utiliza `json_each` sin exigir que el campo sea un array. La consulta `where('tags', 'array-contains', 'admin')` devuelve los tres documentos con `tags = @('admin')`, `tags = 'admin'` y `tags = @{ role = 'admin' }`.

Impacto: filtros con coincidencias adicionales sobre esquemas heterogeneos. Al utilizar el mismo filtro en `.delete()`, tambien se borran documentos cuyos campos no son arrays. La reproduccion automatizada comprueba directamente `array-contains`; el operador `array-contains-any` requiere una regresion propia durante la correccion.

Accion: exigir `json_type(doc, ruta) = 'array'` antes de aplicar pertenencia, y fijar la semantica entre numeros, booleanos, strings y objetos. Verificar los resultados de lectura y borrado.

## Evaluacion de seguridad

Los casos existentes verifican defensas utiles: parametros de valores string, rechazo de identificadores maliciosos, claves con NUL, busqueda de DLL limitada a System32 y operaciones de colecciones tras cierre del padre. La inspeccion confirma uso de `try/finally` para liberar statements en las rutas principales. No se confirmo una inyeccion SQL mediante los argumentos validados de la API fluida en esta revision.

La superficie de mayor riesgo confirmada es la integridad de datos: F01 y F02 permiten destruccion o sobrescritura inesperada; F07 amplia el conjunto de documentos de un filtro. La aplicacion que consume el modulo debe tener en cuenta esos comportamientos hasta su correccion.

`.query()` permite SQL arbitrario del llamador y el Playground ejecuta PowerShell con sus permisos. Ambas capacidades son deliberadas; no se clasifican por si solas como vulnerabilidades. Los parametros protegen los valores enlazados, no una sentencia SQL construida con texto externo. La proteccion de los archivos depende de las ACL del sistema, conforme al modelo documentado; no se verificaron ACL de despliegues de usuarios.

La politica de seguridad tiene al menos una garantia falsa confirmada (rechazo de `orderBy().delete()`). Ademas, conviene precisar que los filtros numericos se insertan como literales en SQL y que el modo debug imprime la sentencia: no debe prometerse que todos los valores se enlazan o se ocultan siempre. Esta ultima observacion es de inspeccion, no un octavo caso reproducido.

## Validacion reproducible

Desde la raiz del repositorio, en procesos nuevos:

```powershell
pwsh -NoProfile -File .\_TESTS\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_TESTS\run-tests.ps1
pwsh -NoProfile -STA -File .\Playground\verify-playground.ps1
pwsh -NoProfile -File .\_TESTS\PSLocalBase.Audit.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\_TESTS\PSLocalBase.Audit.Tests.ps1
```

| Verificacion | Resultado observado |
| --- | --- |
| Suite original, PowerShell 7.6.9 | 73 pasan, 0 fallan |
| Suite original, Windows PowerShell 5.1 | 73 pasan, 0 fallan |
| Playground, verificacion STA | Todas las comprobaciones pasan |
| Regresiones nuevas, PowerShell 7.6.9 | 0 pasan, 7 fallan; confirman F01-F07 |
| Regresiones nuevas, Windows PowerShell 5.1 | 0 pasan, 7 fallan; mismos resultados |

Las pruebas nuevas devuelven codigo de salida 1 mientras persistan los fallos. No ejecutan cargas de ataque ni operaciones de disco; cada caso crea y cierra su propia base en memoria.

## Acciones priorizadas

1. **Antes de publicar:** corregir F01 y F02, incorporar sus regresiones al runner y exigir paso en ambas ediciones. Criterio: el borrado ordenado se rechaza conservando datos e indices; dos upserts sin identidad conservan dos documentos con claves distintas.
2. **Siguiente bloque:** corregir F03 y F07 para evitar perdida de elementos y borrados por coincidencias inesperadas. Criterio: igualdad numerica exacta y pertenencia exclusiva a arrays, con pruebas de lectura y borrado.
3. **Consistencia de consultas y esquema:** resolver F04-F06. Criterio: indices independientes de la grafia de la tabla y paridad entre `get` y `count`, incluidas ramas inexistentes y conexiones distintas.
4. **Cierre del trabajo:** integrar las siete regresiones corregidas en CI, actualizar `SECURITY.md` y el catalogo de pruebas (aun anuncia 64/64 y lista hasta TC-67, mientras el runner ejecuta 73), y repetir la matriz de validacion. No publicar cambios ni afirmar que los hallazgos estan resueltos hasta superar esas pruebas.
