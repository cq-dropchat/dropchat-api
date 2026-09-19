# Plantillas de WhatsApp (español de Chile)

Las plantillas que Meta debe aprobar antes de que DropChat pueda escribirle
primero a un cliente. Cubren el flujo de la landing: confirmar el pedido contra
entrega, corregir la dirección, avisar el despacho y rescatar la entrega
fallida.

`pedidos-contra-entrega.es.json` es el arreglo de plantillas tal cual las recibe
la API de Meta (`POST /{waba_id}/message_templates`), que es lo mismo que envía
`whatsapp-management/templates.ts`.

## Las siete plantillas

| Nombre                               | Cuándo se envía                      | Botones                                           |
| ------------------------------------ | ------------------------------------ | ------------------------------------------------- |
| `confirmacion_pedido_contra_entrega` | apenas entra el pedido en Dropi      | Confirmar · Cambiar dirección · Cancelar          |
| `recordatorio_confirmacion_pedido`   | si no contestó la primera            | Confirmar · Cambiar dirección · Cancelar          |
| `direccion_incompleta`               | dirección sin número, block o comuna | — (se espera texto libre)                         |
| `pedido_en_camino`                   | el pedido sale de bodega             | Ahí estaré · Cambiar la fecha                     |
| `pedido_en_reparto_hoy`              | sale a reparto ese día               | —                                                 |
| `entrega_fallida_reintento`          | nadie abrió la puerta                | Reintentar mañana · Coordinar otro día · Cancelar |
| `pedido_entregado`                   | entrega confirmada                   | Todo bien · Tuve un problema                      |

Las siete son **UTILITY**: hablan de un pedido que el cliente ya hizo. Esa
categoría se aprueba más rápido, no necesita opt-in de marketing y a Meta le
cuesta menos por conversación. Cualquier plantilla que ofrezca algo que el
cliente no pidió —un descuento, un producto nuevo— es **MARKETING** y juega con
otras reglas; no hay ninguna en este archivo.

## Reglas de Meta que el archivo ya respeta

- El cuerpo no empieza ni termina en una variable, y no hay dos variables
  pegadas. Es el motivo de rechazo más común.
- Cada variable lleva su ejemplo en `example.body_text`. Sin ejemplos, Meta
  rechaza sin leer.
- Máximo 3 botones de respuesta rápida, de 25 caracteres cada uno.
- El nombre va en minúsculas con guion bajo.
- El idioma es `es`. Meta no tiene `es_CL`: el español neutro cubre Chile, y el
  tono chileno vive en el texto, no en el código de idioma.

## Cómo enviarlas a aprobación

Desde la app: Integraciones → WhatsApp → Plantillas → Nueva. La UI arma el mismo
JSON.

O directo a Meta, una por una, con un token de usuario del sistema que tenga
`whatsapp_business_management`:

```bash
# TOKEN y WABA_ID los exportas tú; no quedan en el repo
jq -c '.[]' whatsapp-templates/pedidos-contra-entrega.es.json | while read -r t; do
  curl -s -X POST "https://graph.facebook.com/v24.0/${WABA_ID}/message_templates" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$t" | jq '{name: (.id // .error.message)}'
done
```

La aprobación suele tardar minutos; puede llegar a 24 horas. El estado se ve en
la misma pantalla de plantillas de la app.

## Antes de enviarlas

Revisa que el texto calce con **tu** operación: el plazo de entrega que promete
`pedido_en_camino`, si el repartidor acepta solo efectivo, y si reintentas una
entrega sin cobrar (`entrega_fallida_reintento` lo promete).
