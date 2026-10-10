# Estabilidad operativa: implementación y evidencia

Actualizado: 9 de octubre de 2026. Fuente de criterios:
[SPEC_ESTABILIDAD_OPERATIVA.md](SPEC_ESTABILIDAD_OPERATIVA.md). Bases recibidas:
API `680a87f`, UI `2a60999`. Dos repositorios independientes. El spec estaba sin
seguimiento y pertenece al usuario; se conserva sin editar ni incluir en
commits. Los artefactos locales están bajo `api/artifacts/` y `ui/artifacts/`,
ignorados por Git. CI publica los planes y manifiestos SQL incluso al fallar.

## Estado por criterio y dependencia

“Local” significa implementación y prueba sintética; no completa validación de
producción. Los hitos dependientes permanecen abiertos aunque su código exista.

| Criterio          | Estado                          | Evidencia disponible                                                                                                      | Falta para cerrar                                                                                  |
| ----------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| A1 / H1           | Local; CI pendiente             | Reproducción SQL, corrección sin ampliar budgets, tres resets limpios; performance separado de Deno                       | Log original autenticado; tres runs de CI verdes del código publicado                              |
| A2 / H2           | Preparado; sin acceso operativo | Release exige SHA exacto y checks pareados; snapshot de migraciones/índices/cron                                          | Inventario real Supabase/Cloudflare/GitHub, propietario único de deploy, entorno, smoke y rollback |
| B1                | Local                           | 1.600 IDs, empates, 31 páginas antiguas y regreso; ventana ≤1.000; preview independiente                                  | CI del par final de SHAs                                                                           |
| B2                | Local; CI pendiente             | Retry antiguo y reciente, cursor y ancla aprobados diez veces                                                             | Diez ejecuciones aprobadas en ambas direcciones; falta CI                                          |
| B3                | Local                           | Offline HTTP/WS visible, otro escritor, convergencia real                                                                 | Dispositivo/red de referencia y evidencia del entorno                                              |
| B4                | Local                           | 11.001 actualizaciones con empate; fallback >10 páginas; cancelación y refresco retenido; seis horas cubiertas por unidad | Visibility es señal headless; repetir en dispositivo real                                          |
| B5                | Local                           | Request lento de A, B, logout/login, vuelta A; aislamiento                                                                | CI del par final de SHAs                                                                           |
| B6                | Local                           | Handlers reales; 20 medios + texto; slow/error; peak ≤4; imagen, audio y documento visibles                               | Cuenta externa de prueba para entrega real                                                         |
| B7                | Local; CI pendiente             | Toma/respuesta/liberación reales; IA no ejecuta LLM bajo toma humana; pgTAP de horario/TTL                                | Diez ejecuciones aprobadas de expiración/horario/timeout; falta CI                                 |
| B8                | Local                           | 429, lease expirada, retry con misma fila, delivered + eco sin duplicar                                                   | 5xx y ACL cubiertos por Deno/pgTAP; entrega externa incierta requiere inspección operacional       |
| C1 / H4           | Local                           | Eventos allowlist, correlación de job, intentos, release, duraciones; panel existente                                     | `ERROR_REPORTING` efectivo, acceso a logs, completar cadena con release real                       |
| C2                | Local; operación pendiente      | Quantiles/HTML; snapshots SQL; cinco alertas fire/dedupe/recovery simuladas                                               | Colector periódico, denominador completo de 10 min, responsable y canal; simulación atendida       |
| C3                | Local                           | Receipt durable antes de ACK, fallo post-ACK y replay idempotente, leases fenced, permisos                                | ACK staging antes/después; política de ledger/backup; rollback con backlog                         |
| D1 / H5           | Local                           | 200k concentrado + 200k uniforme + 200k ajeno, cuatro actores reales, ocho planes correctos                               | Runner CI comparable y evidencia del commit final                                                  |
| D2                | Local parcial                   | Selección 1k/100k/1m con fairness; rampa real 3/6/9/12 por segundo aprobada, 5.760/5.760 respuestas                       | Pico de tráfico real; workers/runtime comparable; separar proveedor                                |
| D3                | Preparado; pendiente            | Diagnóstico corto de 5k y 100 escrituras/s                                                                                | Ejecución 60 min/50k rechazada por permisos; memoria sostenida y comparación Broadcast pendientes  |
| D4                | Local                           | 1/4/16 escritores, 1/8 tenants; commit y rollback; cuotas exactas                                                         | Ventana sostenida y locks en entorno comparable                                                    |
| D5                | Local parcial                   | 100k/1m ×64/1024 B, ZIP/NDJSON íntegro, cancelación y escritor concurrente                                                | Límites reales Storage/runtime y error visible; export sigue best-effort                           |
| E                 | Local; operación pendiente      | Fairness de purga, agregados preservados, preview=delete, políticas inválidas conservan                                   | Backup/restauración, política por tenant, ingreso real y siete días representativos                |
| Salida sección 10 | Abierta                         | Código/gates/diagnóstico preparados                                                                                       | Ningún resultado sintético cierra criterios operativos; faltan responsables externos               |

## Diagnóstico del gate SQL

Antes de editar se comprobaron Git y CI. API en `main` alineada con remoto y UI
igual; único archivo ajeno: el spec sin seguimiento. El run observado
[37811215297/job/113428246509](https://github.com/cq-dropchat/dropchat-api/actions/runs/37811215297/job/113428246509)
seguía fallido: reset y pgTAP verdes, gate exit 3 y Deno omitido. El endpoint de
log devuelve 403; no hay sesión autenticada y el usuario no dispone del log. Por
tanto la causa **exacta de ese run** sigue sin confirmar.

Se reprodujo localmente reset → seed → 850 aserciones pgTAP → gate original:

```text
service history=200000 execution_ms=144.798 shared_buffers=407613
ERROR: init_data traversed too many buffers for one concentrated history
CONTEXT: PL/pgSQL function pg_temp.profile line 7 at RAISE
```

`auto_explain` mostró el lateral fallback recorriendo el índice global de
mensajes del tenant: 133.335 filas descartadas por loop, unos 403k buffers.
Correlacionar `m.organization_id = c.organization_id` habilita el índice de
tenant/conversación. El gate final tras pgTAP pasó con concentrado ≤2.829
buffers y uniforme ≤879, ejecución ≤12,868ms; esos valores se conservan junto a
los tres resets anteriores para mostrar variación por estadísticas/caché. No se
aumentan los presupuestos de 5.000 buffers concentrado / 20.000 uniforme.
`ANALYZE` posterior puede cambiar el plan y hacer pasar el cuerpo antiguo: la
secuencia fresca y las estadísticas forman parte de la reproducción.

Tres resets limpios (`artifacts/performance-reset-{1,2,3}`): ocho escenarios
correctos cada uno; concentrado ≤775 buffers, uniforme ≤655; ejecución ≤10,394
ms. El fixture registra rol efectivo (postgres, service_role, owner, member),
semilla fija, tenant ajeno y plan/buffers/temporales. El cálculo de referencia
completo se ejecuta fuera del tiempo medido. La suite funcional tiene runner
independiente del costo SQL, por lo que una regresión de performance ya no omite
Deno. Deno 2.9.6, Supabase 2.119.0, Ubuntu 24.04 y Node 24 están fijados en CI.

## Release verificable y procedimiento de promoción

El checkout de UI resuelve un SHA inmutable de API para types-sync y E2E y
publica el par ensayado. Release manual de API exige SHA UI de 40 caracteres,
último Check completado con éxito para ambos heads/repos, artefacto del par y
`DEPLOYMENT_OWNER=actions`. Un Check más nuevo fallido/en curso invalida un
verde viejo. Pruebas Node cubren estas condiciones. No se hizo push ni deploy.

Antes de habilitar promoción, el operador debe registrar por entorno:

- Project ref de Supabase y rama; Cloudflare project/branch/deployment; dueño y
  trigger efectivo de migraciones, funciones y UI. Desactivar deploy paralelo de
  integración GitHub si se elige Actions; no basta definir la variable.
- Secrets disponibles por **nombre**, `ERROR_REPORTING`, `API_RELEASE`, versión
  UI y modo Realtime del artefacto; nunca imprimir valores.
- Protección de rama con Check, test, performance, types-sync y E2E reales.
  Acceso cross-repo a evidencia mediante `RELEASE_EVIDENCE_TOKEN` cuando haga
  falta.
- Snapshot readonly `release_snapshot.sql`: migraciones aplicadas, índices
  válidos/definiciones, cron activo, fallos recientes y nuevas issues.
- Antes/después: IDs controlados, abrir historial reportado, recorrer
  ida/vuelta, reconectar visible, enviar desde cuenta de prueba y comprobar
  delivered del proveedor. Archivar SHAs, timestamps, request/job/message IDs
  restringidos.
- Ensayar rollback con artefactos previos de API/UI. El modo Realtime es de
  build; cambiar la variable no cambia una pestaña ya desplegada. DB requiere
  migración correctiva nueva, conservando filas/colas. No reescribir una
  migración aplicada.

No se asume staging existente. Falta autenticación Supabase y GitHub. Las
integraciones externas podrían desplegar antes de completar checks: el gate
local de Release no controla una integración externa hasta reconfigurarla.

## Recepción durable y privacidad

El receipt guarda el webhook validado **antes** del ACK; DB no disponible
devuelve 503 para retry. SHA-256 del cuerpo deduplica entrega, y el upsert de
mensajes por (organization_id, external_id) conserva triggers, cuotas e
identidad. Un webhook puede tener varios tenants: ledger de plataforma con RLS y
acceso service-only, sin acceso de usuarios. No se promete exactly-once del
proveedor.

Lease de diez minutos y token por intento; completion viejo no cierra claim
nuevo; máximo cinco intentos/backoff existente. Cron 30s envía IDs, worker
autenticado reclama y reutiliza procesador real. Payload se limpia al completar;
digest, intentos y fechas permanecen. Fallos finales conservan payload para
investigación. Falta política del ledger (dedupe window, tamaño, soporte, backup
y borrado): no se habilita TTL destructivo sin esa decisión. `queue_retention`
solo afecta las dos colas existentes, no el ledger nuevo.

El logger existente añade eventos allowlist sin texto, archivos ni tokens. IDs
solo en logs restringidos; etiquetas de métricas tienen cardinalidad limitada.
Muestreo configurable de éxitos; cap por isolate 600 éxitos/100 fallos por
minuto; counters de descarte marcan ventana incompleta. Los logs legacy no
tienen todos estos caps: presupuestar su volumen real por separado. Fallo del
colector no bloquea negocio. Se retiraron payload de webhook, contenido de
agente y detalles SQL de persistencia que podían incluir filas. Se reutiliza el
reporter y /errors.

El worker de anotación de medios emite inicio/fin con proveedor Google y
correlación de trabajo. Un rechazo permanente responde HTTP 200 según su
política terminal existente, pero cuenta como fallo de negocio; configuración,
cuota y respuesta inválida también se distinguen de skip. Claims, reservas,
consumo y reintentos no cambian. El nuevo test C1 ejecuta Storage/DB reales con
Gemini falso, verifica correlación y ausencia del detalle privado del proveedor.
La suite completa posterior pasó 283 tests con cobertura generada desde cero:
`artifacts/deno-fresh-coverage-final.log`. La medición de ACK anterior sigue
asociada al mismo código de webhook; este ajuste está en otro worker. Logs
legacy ajenos a los nuevos eventos aún requieren revisión de contenido/volumen
antes de configurar acceso y retención en producción.

La medición emparejada de 80 ACKs por brazo, éxitos 0 vs 1, dio p95 control
2,378 ms / instrumentado 2,440 ms: +2,595% (<5%). Hubo actividad E2E al final
del ensayo; es un resultado local, sin comparación pre-ledger ni prueba de ACK
en staging. `artifacts/telemetry/latency.json`. No extrapolar p99 ni duración a
producción.

`operations_report.ts` genera JSON y HTML desde eventos JSONL y snapshots de
salud JSONL. SQL real se normaliza sin confundir done del transporte con
procesamiento. Alerta de negocio solo usa denominador **completo, no
muestreado**, con ventana de 10 minutos y cancelaciones excluidas. Logs
muestreados no bastan. El diagnóstico cliente exportable incluye requests/bytes,
recursos y ring acotado; lag visible mide llegada→frame en el mismo reloj,
excluye red y proveedor.

## Runbooks de alertas

Responsable y destino siguen **sin asignar**: debe completarlos el operador
antes de activar notificaciones. Evaluación de referencia una vez por minuto,
deduplicación por key; aviso único de firing y recovery. Gaps reinician
evidencia sostenida y no anuncian recuperación falsa.
`artifacts/operations/dashboard.*` contiene duraciones del smoke real y cinco
incidentes **simulados**, cada uno con una activación y una recuperación. No
representa alerta atendida en producción.

### Alerta overdue

Más antiguo >60s durante tres muestras consecutivas. Leer `health_snapshot.sql`,
clasificar tenant/function y receipt versus edge_call. Revisar
`next_attempt_at`, lease, job/attempt, última ejecución cron y evento
queue.started. Comprobar runtime, Vault y permisos por presencia/validez, sin
exportar secretos. Resolver causa, replay selectivo conservando ID; recuperación
cuando atraso desaparece. No reencolar todo ni considerar timeout pg_net como
fallo definitivo de negocio.

### Alerta stalled

Backlog debido sin worker observado cinco minutos. Inspeccionar cron activo y
job_run_details, conectividad local del worker, firma/service auth, release y
estado de lease. Buscar por job_id, después message_id/request_id. Restablecer
el worker o cron; no marcar trabajo completado para vaciar backlog. Confirmar
nuevo inicio real y drenaje antes del aviso de recuperación.

### Alerta business

> 1% y ≥5 fallos en diez minutos completos. Distinguir configuración/permisos,
> 429/5xx proveedor, persistencia/media y cancelaciones esperadas. HTTP 200
> puede contener timeout de agente o trabajo diferido fallido. Abrir /errors
> existente, correlacionar issue y job/message. Para un receipt fallido,
> inspeccionar alcance, corregir causa y autorizar replay de esa identidad según
> sus límites; una entrega externa incierta se verifica con estado/eco antes de
> reintentar un envío.

### Alerta cron

Cualquier ejecución fallida en ventana. Mostrar jobid y última ejecución/avance,
no solo last_done_at. Leer job_run_details, distinguir SQL, permisos y endpoint;
corregir schema con migración generada si corresponde. Ensayar local, después
promover mediante gate. Confirmar ejecución siguiente exitosa y ausencia de
fallos en ventana antes de recovery.

### Alerta leases

Leases expiradas en dos muestras consecutivas. Separar transporte y receipt;
worker puede seguir vivo aunque pg_net haya dejado de esperar. Revisar intento,
claim token y progreso; no liberar ni completar claim a ciegas. Dejar el reclaim
fenced tras vencimiento y comprobar que completion antiguo es rechazado.
Investigar latencia/timeout/runtime antes de modificar límites.

## Capacidad y decisiones

Referencia local: host arm64 macOS 27.0.1, 12 CPU / 16 GiB; Colima 4 CPU / 8
GiB; Postgres 17.11.0.002. Caché/estadísticas de cada ensayo descritas por
fixture; Servicios de otros proyectos no se tocaron y comparten la VM: no es una
prueba de hardware exclusivo. El harness pg_net usa host.docker.internal probado
en macOS; un runner Linux requiere un host gateway equivalente verificado.
Excluir edge-runtime evita que otro worker sin mocks contacte Meta con fixtures.
Las escrituras medidas mantienen triggers/RLS/cuotas; generación bulk explícita
ocurre fuera de medición.

- D2 selección de cola 1k/100k/1m: dominante + diez pequeños; 110 elegidos,
  máximo diez por org, rollback. Mide scheduler SQL, no throughput de workers.
  La rampa `queue_workers.ts` usa ocho slots, pg_net real y fake LLM 50 ms: pico
  provisional 6/s, fases 3/6/9 por 120s y 12/s por 300s. Resultado final se
  registra abajo.
- D3 diagnóstico corto aprobado: 35s de escritura/3.500 cambios, store
  300→1.700, WS 1.663 conversaciones/1.650 mensajes, heap 21–65 MB, cero long
  tasks; búsquedas 23–1.318 ms. No valida 50k ni 60min. La ejecución larga fue
  rechazada por el usuario en permisos; no se repite por otra vía. Se preparó
  prueba CDC real para no confundir join ACK con suscripción lista.
- D4 commit transaction p95 1/4/16 escritores: un tenant 3,745/10,978/51,294 ms;
  ocho tenants 1,857/6,658/18,468 ms. Cuotas de tres intervalos exactas; cero
  deadlocks. Locks muestreados cada 50ms; WAL de cluster, incluye otra
  actividad. p95 incluye INSERT+triggers+commit, no timer aislado de commit.
  Escenario rollback separado. No justifica contadores distribuidos sin tráfico
  real.
- D5 100k×64/1024B: 1,171/2,208s; 1m×64/1024B: 11,676/21,120s. RSS pico
  213/262/217/227 MB; cuatro ZIP íntegros y aislamiento verificado. Cancelación
  0,019–0,195ms; diez escrituras concurrentes reales. Payload compresible, ZIP
  0,81–11,22MB; no demuestra límite Storage de un export pesado real.
  Best-effort: incluye parte de las escrituras concurrentes, sin snapshot
  transaccional.

Decisión: conservar `postgres_changes`. Broadcast queda sin activar hasta
comparar mismas sesiones/datos, bytes, requests, lag, errores y long tasks;
exige beneficio y sin regresión p95 >10%, más rollback con artefacto previo. No
introducir exports por partes ni contadores distribuidos con la evidencia
provisional actual. Objetivos iniciales del spec se conservan sin cambios; la
referencia local no es SLA ni dispositivo/red representativo.

## Retención y recuperación

30 días éxito / 90 fallo es propuesta **opt-in**, no política activada.
Ausencia, cero e inválido conservan. Pendiente/sending y processing no se
purgan. Resolver primero investigación/replay de failed, luego decidir
failure_days por tenant. `retention_snapshot.sql` es readonly: candidatos por
tabla/tenant/status, fecha y bytes de payload, estadísticas de tabla/índice/dead
rows/autovacuum y agregados preservados.
`retention_growth.py first.json second.json` compara dos muestras: contadores
son actividad (pueden incluir rollback), live/dead estimados y DELETE no reduce
necesariamente tamaño físico. No extrapolar un ensayo corto a ingreso real
diario.

La purga vieja seleccionaba globalmente lo más antiguo: con 20 filas del
dominante más viejas y una del pequeño, lote 2 dejó el pequeño pendiente. Nueva
selección round-robin por org, orden interno, SKIP LOCKED y lote 10.000 sin
aumentar. pgTAP comprueba progreso de pequeño y ausencia de acceso RLS a
agregados. Antes de borrar, `queue_retention_stats` conserva
count/bytes/intentos/fechas por tenant, tabla/status/día, sin payload. Solo
service_role administra esta tabla de plataforma.

`retention_control.py`: preview dos candidatos = dos borrados; seis filas
antiguas pendientes/en vuelo/tenant con política inválida protegidas;
transacción rollback. `artifacts/retention/fairness-before.json` demuestra el
comportamiento anterior. Capacidad teórica 240k/día por tabla; requiere
contrastar ingreso elegible real, locks/tick y margen antes de cambiar
frecuencia o lote. Desactivar política frena purga; filas borradas requieren
backup/archivo **restaurado en ensayo**. Falta verificar backup/PITR y medir
siete días reales antes del primer opt-in de producción.

## Comandos reproducibles y registros finales

Preparación local API:
`supabase start -x studio,imgproxy,mailpit,logflare,vector,edge-runtime`,
`supabase db reset`, `supabase/tests/run.sh`. Cambios SQL siguieron schemas →
`supabase db diff` → `supabase migration up --local` → tipos
public/storage/billing; UI conserva divergencias y pasa strict sync. No se editó
ninguna migración aplicada. La migración cron es excepción imperativa
documentada en CLAUDE.md.

```bash
# API: desde raíz y desde cada paquete según import map
DENO_BIN=/ruta/a/deno SQL_DOCKER_CONTAINER=supabase_db_open-bsp-api bash supabase/tests/performance/run.sh
deno fmt --check
cd supabase/functions && deno lint && deno check . && deno task test:coverage
cd plugin && deno lint && deno check .
# scripts especiales desde raíz API
node --test .github/scripts/verify-release.test.mjs
python3 supabase/tests/performance/capacity.py
python3 supabase/tests/performance/retention_control.py
deno run --config supabase/functions/deno.json --allow-all supabase/tests/performance/queue_workers.ts
deno run --config supabase/functions/deno.json --allow-all supabase/tests/performance/export_capacity.ts
deno run --config supabase/functions/deno.json --allow-all supabase/tests/performance/telemetry_latency.ts
# UI: desde raíz UI
npm run check
npm run translations:check
API_REPO_DIR=../api npm run types:sync-check
npm run bundle:check
npm run e2e -- --repeat-each=10
# D3 pendiente de autorización, sesión aparte
DROPCHAT_CAPACITY=1 npm run e2e -- e2e/capacity.spec.ts
```

Se verificaron nuevamente los endpoints públicos al finalizar: API sigue en run
37811215297, SHA 680a87f, completed/failure; logs HTTP 403. UI run 37811215875,
SHA 2a60999, completed/success. Ningún commit nuevo se publicó.

Incidentes de validación resueltos: la aserción DOM detectó un salto real de
ancla tras retry antiguo; se conserva la clave durante la medición de filas
virtuales. E2E ahora borra solo sus propios edge_calls antes de borrar mensajes:
los record_id no tenían cascade y la acumulación huérfana hacía que un trace
Deno no alcanzara su trabajo dentro del lote. Se conserva
`deno-orphan-queue-failure.log` y se repitió la suite en DB fresca: 282 tests
verdes. La primera repetición usó seis workers sobre los mismos
actores/políticas: logout de un test invalidaba otro y las conversaciones tenían
previews iguales. Se conserva `e2e-parallel-fixture-failure.log`; fixtures
compartidos ahora usan workers=1, selector por conversación y retries=0. No se
relaja el gate de performance.

Checks finales: pgTAP 43 archivos / 871 aserciones; Deno 283 tests + 6 steps;
cobertura limpia _shared 82,11% (mínimo 74), handlers 65,74% (58), total 68,90%
(60). Fmt 558 archivos, lint/check functions y plugin, tres tests de release
Node 24 y YAML de ambos workflows aprobados. UI 58 archivos / 425 tests, 31
warnings existentes sin errores; líneas 49,95%; traducciones 806 claves, strict
types-sync con API_REPO_DIR=../api y bundle aprobados. Node final 24.21.0, Deno
2.9.6, Supabase 2.119.0. Bundle gzip: inicial 162,6/165 KB; primera pantalla
336,0/340; chat abierto 454,0/472 KB JS y 12,93/13,6 KB CSS. No se cambiaron
thresholds.

Dos snapshots readonly locales están separados 5.356,125s; `growth-local.json`
registra deltas, actividad, filas muertas y autovacuum. Bajo actividad de
pruebas, messages creció 1.261.568 bytes de tabla y 884.736 de índice aunque
live estimado bajó 260; evidencia de que DELETE no equivale a reducción física.
Los contadores incluyen intentos/rollback y no sustituyen ingreso diario
comprometido. Ningún candidato bajo políticas por defecto. No valida siete días
representativos.

Los runners de capacidad tienen fixtures locales y restauran
Vault/cron/políticas; no ejecutarlos contra producción. El ejemplo de cd no es
un script completo: volver a la raíz correspondiente antes del comando
siguiente. D3 se salta por defecto en el gate funcional y nunca cuenta como
aprobado por estar skipped.

Commits locales API: `a21c335` (CI/historial/release), `2c001ee` (durable,
trazabilidad, permisos y retención), `02462ef` (capacidad y evidencia). UI:
`fa14f1f` (par inmutable de CI), `010b0d3` (recuperación, ancla, telemetría y
E2E). El SHA final y hashes de evidencia quedan en
`artifacts/final-manifest.json`.

E2E final: **100 passed / 10 skipped / cero retries**, diez ejecuciones de cada
prueba funcional, 8,7 minutos, Node 24.21.0 y workers=1.
`ui/artifacts/e2e-delivery-final-ten.log`. Los diez skips corresponden a D3 y no
se contabilizan como capacidad aprobada. `npm run check` pasó de nuevo después
de las últimas correcciones de fixtures. Typecheck de los cinco harnesses
aprobado desde functions/import map; quedó incorporado en Check de API.

Los resultados detallados viven en artefactos; tres resets SQL y el manifiesto
registran base, patch hash, plataforma y versiones. El spec ajeno sin
seguimiento puede marcar dirty tras commits, sin significar código nuestro sin
commit.

## Estado de los criterios finales de la sección 10

| Criterio                  | Estado                                            | Razón pendiente                                                                                             |
| ------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| A1                        | Abierto                                           | Falta log original y tres Checks remotos del código final; tres resets locales sí pasaron.                  |
| A2                        | Abierto                                           | Falta inventario efectivo, promoción, smoke y rollback observado.                                           |
| B                         | Validado local; CI pendiente                      | Diez repeticiones por prueba, sin retry; falta ejecutar sobre el par publicado.                             |
| C                         | Implementado y probado local; operación pendiente | Recepción/replay y eventos probados; falta cadena de release y alertas atendidas.                           |
| D                         | Parcial                                           | Capacidad provisional; D3 largo y comparación Broadcast pendientes; límites reales de export sin verificar. |
| E                         | Abierto                                           | Fairness/preview/agregados probados; falta política, restore y siete días representativos.                  |
| Incidentes y responsables | Abierto                                           | Fallos locales encontrados corregidos; falta asignar responsables externos reales.                          |

## Pendientes operativos, impacto y siguiente acción

| Pendiente                      | Impacto                                             | Responsable requerido / acción                                                                      |
| ------------------------------ | --------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| GitHub log y CI final          | A1/H1 no cerrados                                   | Mantenedor con sesión: descargar log original, publicar commits y ejecutar tres Checks limpios      |
| Entornos/integraciones         | Release no demostrado; riesgo doble deploy          | Administrador Supabase/Cloudflare/GitHub: inventario, owner único, acceso y branch checks           |
| Smoke/rollback                 | H2/H4/H5 no cerrados                                | Operador de release: ensayo con cuentas controladas y artefactos previos                            |
| Alertas/denominador            | Riesgo de incidentes sin atención o tasa parcial    | Operaciones: asignar persona, canal, colector y comprobar aviso/recovery atendidos                  |
| Ledger retention               | Digests/fallos crecen indefinidamente               | Producto/operaciones: dedupe window, soporte/replay, backup, política y nuevo gate antes de activar |
| D3 60min + Broadcast           | Memoria/lag sostenidos no medidos                   | Mantenedor: nueva autorización explícita para perfil largo; comparar mismo dispositivo y datos      |
| Storage/runtime                | Export grande puede fallar fuera de límites locales | Operador: límites reales y cuenta prueba; comprobar error visible/cancelación                       |
| Retención siete días + restore | Borrado irreversible sin recuperación verificada    | Operaciones: restore previo, opt-in controlado, dos snapshots diarios e ingreso/salida siete días   |

Ningún responsable externo se considera asignado por esta tabla. No se declaran
cerrados los criterios finales ni se habilita retomar features con estos
pendientes.
