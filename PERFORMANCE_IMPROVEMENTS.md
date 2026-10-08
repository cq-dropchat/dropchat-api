# Mejoras de rendimiento — 8 de octubre de 2026

Implementación de los gaps G01–G15 de
`../auditoria/AUDITORIA_PERFORMANCE_2026-10-08.md`. Incluye cambios en los
repositorios `api` y `ui`. Las validaciones y mediciones descritas se realizaron
contra Supabase local y el build de producción de UI; no son mediciones de
producción ni implican un despliegue.

## Cambios por gap

| Gap                                          | Implementación                                                                                                                                                                                                             | Límite o seguimiento                                                                                                                                                                       |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| G01: carga inicial proporcional al historial | `init_data` consulta primero un prefijo indexado acotado; si no alcanza, usa búsquedas laterales por conversación con límite. Conserva RLS, filtros temporales y desempate por ID.                                         | La alternativa lateral sigue dependiendo del número de conversaciones visibles, pero no recorre todo su historial. Límite RPC: 1.000 mensajes y 50 por conversación; UI solicita 300 y 10. |
| G02: atención con candidatos no elegibles    | Los barridos de asignación humana y espera filtran TTL, actividad, horario y acción antes de aplicar el límite. Mantienen `SKIP LOCKED`.                                                                                   | Pruebas con 501 filas no elegibles delante de una elegible.                                                                                                                                |
| G03: contexto del agente                     | Queries explícitamente acotadas por organización, cursores `(created_at, id)` e índice correspondiente.                                                                                                                    | Se conserva la precisión del timestamp del servidor.                                                                                                                                       |
| G04: recuperación tras desconexión           | Índices `(organization_id, updated_at, id)`, cursores estables, cancelación al cambiar de usuario/tenant u ocultar la pestaña y presupuesto de 10 páginas por tabla.                                                       | Al agotar el presupuesto se recarga la vista inicial y se refrescan los mensajes retenidos del chat abierto.                                                                               |
| G05: crecimiento de colas terminadas         | Purga opcional por organización, con retención separada para éxito y fallo, rangos indexados y lotes acotados.                                                                                                             | Desactivada por defecto. Nunca purga trabajo pendiente o en ejecución.                                                                                                                     |
| G06: ranking de todo el backlog              | El scheduler obtiene candidatos acotados por organización antes del reparto; nuevos índices para pendientes, registros activos y salud de colas.                                                                           | Mantiene reparto por organización. La carga sigue dependiendo del número de organizaciones con trabajo.                                                                                    |
| G07: barrido de media                        | Índice parcial que coincide con archivos pendientes de preprocesamiento, con desempate por ID.                                                                                                                             | Conserva el procesamiento y sus reintentos existentes.                                                                                                                                     |
| G08: agenda completa en cada consumidor      | Contactos visibles se consultan por clave compuesta exacta en lotes de hasta 50; directorio paginado de 100 filas con búsqueda en servidor.                                                                                | El directorio busca coincidencias parciales; la ordenación por nombre se aplica a las filas cargadas. Las consultas individuales mantienen aislamiento por usuario y organización.         |
| G09: historial y recomputación del inbox     | Se separan previews de 10 mensajes por chat y una ventana activa de 20 páginas de 50 mensajes. Navegación en ambas direcciones y conservación del ancla visual. Versiones del preview y metadatos reducen recomputaciones. | Se puede recorrer todo el historial; solo 1.000 mensajes permanecen en la ventana activa. Caché de hasta cinco historiales recientes, con GC de 60 segundos.                               |
| G10: búsqueda síncrona                       | Fuse se ejecuta en un worker a partir de 1.000 conversaciones, con debounce de 150 ms y descarte de respuestas antiguas.                                                                                                   | El worker se crea al buscar. Prueba de navegador con 50.000 conversaciones.                                                                                                                |
| G11: hidratación de avisos realtime          | Deduplicación frente a filas ya recibidas, una petición en vuelo, lotes de 100 IDs por tabla y reintentos con backoff.                                                                                                     | El modo predeterminado sigue siendo `postgres_changes`. La activación de Broadcast requiere validar lag, consumo y reconexión en el entorno desplegado.                                    |
| G12: descargas de media sin límite           | Hasta cuatro descargas simultáneas por lote de webhook; estados y contactos se guardan antes. Los fallos individuales conservan el mensaje y su referencia.                                                                | Se preserva el orden de persistencia de mensajes, ediciones y revocaciones.                                                                                                                |
| G13: exportaciones acumuladas en memoria     | ZIP generado por streaming con backpressure, compresión de una página por adelantado, cancelación y carga directa a Storage. Índice de exportación de mensajes `(organization_id, id)`.                                    | Persisten límites de tamaño de Storage y duración del runtime. La exportación no es un snapshot transaccional; tablas sin ID mantienen paginación por rango.                               |
| G14: contadores de facturación               | Una sola sentencia actualiza los tres períodos en lugar de tres sentencias, con el mismo orden y transacción síncrona.                                                                                                     | Mejora el overhead; las filas compartidas siguen pudiendo generar contención. No se relajan cuotas ni consistencia.                                                                        |
| G15: presupuesto de frontend                 | Hooks de datos privados se cargan desde el layout autenticado y helpers compartidos se extraen de rutas. Nuevos presupuestos para abrir un chat y pruebas de performance en CI.                                            | Presupuestos gzip: inicial 165 KiB, primera pantalla 340 KiB, chat 472 KiB JS y 13,6 KiB CSS.                                                                                              |

## Retención de colas

La configuración opcional vive en `organizations.extra.queue_retention`:

```json
{
  "queue_retention": {
    "success_days": 30,
    "failure_days": 90
  }
}
```

Este ejemplo no se aplica automáticamente. Cada campo acepta días enteros
positivos de hasta cuatro dígitos. Ausencia, cero o valores inválidos conservan
las filas de ese estado. La antigüedad se calcula con `updated_at`: éxito
significa `edge_calls.done` o `webhook_deliveries.delivered`; fallo significa
`failed`. El job de retención existente procesa lotes limitados y omite filas
bloqueadas.

## Validación

- API: 268 pruebas Deno y seis pasos adicionales; cobertura y gates existentes
  aprobados. Incluye tenant/cursores del agente, concurrencia de media,
  backpressure/cancelación del ZIP, errores y carga real del stream a Storage
  local.
- Base de datos: 850 aserciones pgTAP en 41 archivos. Las nuevas pruebas cubren
  índices, elegibilidad antes de limitar, retención opt-in, aislamiento,
  mensajes con timestamp idéntico y exactitud de los tres contadores.
- UI: 421 pruebas en 56 archivos. Incluye recuperación/cancelación por tenant,
  historial de 1.600 mensajes con ventana de 1.000, retry bidireccional,
  contactos por clave compuesta y avisos realtime en vuelo.
- Navegador: dos pruebas Playwright aprobadas; login y envío de mensaje, y
  búsqueda real mediante el worker del build con 50.000 conversaciones.
- Formato, lint, tipos, traducciones y presupuesto de bundle aprobados en ambos
  repositorios según sus comandos correspondientes.
- Migraciones generadas desde schemas. Índices de mensajes/conversaciones
  separados con `CREATE INDEX CONCURRENTLY` como primera sentencia. Validación
  de reset local y aplicación de las migraciones posteriores aprobada.

## Mediciones locales

| Medición                                                        | Resultado                                                                                                                              |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `init_data`, 200.000 mensajes concentrados en un chat           | Service: 14,061 ms / 1.626 buffers; usuario autenticado: 3,447 ms / 1.706 buffers.                                                     |
| `init_data`, 2.000 chats con 100 mensajes cada uno              | Service: 4,628 ms / 1.433 buffers; usuario autenticado: 8,035 ms / 1.299 buffers.                                                      |
| Facturación, cuatro clientes y 4.000 transacciones por variante | Media: 0,396 → 0,306 ms; p95: 0,827 → 0,621 ms (aproximadamente 25% menos). Transacciones con rollback, misma organización y producto. |
| JavaScript inicial gzip                                         | 164,2 → 162,6 KiB.                                                                                                                     |
| Primera pantalla gzip                                           | 331,3 → 334,8 KiB, dentro del presupuesto de 340 KiB.                                                                                  |
| Chat abierto                                                    | 449,3 → 452,9 KiB JS gzip y 12,93 KiB CSS; dentro de sus presupuestos.                                                                 |

El perfil SQL usa datos sintéticos y rollback; valida los roles de servicio y
usuario autenticado. CI limita buffers a 5.000 para historial concentrado y
20.000 para historial uniforme, evitando gates temporales sensibles al hardware.
Los tiempos anteriores varían con caché y carga local. La comparación de
facturación mide overhead en ese escenario, no demuestra ausencia de contención
en producción.

## Reproducción

En `api`, iniciar Supabase local sin `edge-runtime`: los tests ejecutan handlers
en proceso y los requests generados por triggers no deben llegar a servicios
externos. Usar las mismas instrucciones y variables de la suite existente.

```sh
deno fmt --check
cd supabase/functions
deno lint
deno check .
deno task test:coverage
```

Desde la raíz de `api`, `supabase/tests/run.sh` recarga fixtures y ejecuta
pgTAP. Para el gate SQL:

```sh
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
  -v ON_ERROR_STOP=1 -q -f supabase/tests/performance/init_window.sql
```

Desde `ui`:

```sh
npm run check
npm run bundle:check
npm run translations:check
API_REPO_DIR=../api npm run types:sync-check
npm run e2e
```

Antes de activar retención o Broadcast, registrar políticas por organización y
comparar en el entorno desplegado latencia p95, buffers, lag realtime, duración
de exportaciones y esperas de locks de facturación. Estas decisiones operativas
no se activaron como parte de la implementación local.
