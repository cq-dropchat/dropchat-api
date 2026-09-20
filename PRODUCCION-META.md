# Camino a producción en Meta

Qué falta para que DropChat deje de operar sobre el número de prueba y cada
cliente conecte el suyo desde la app. Escrito el 2026-09-20 con lo verificado en
este repositorio y en el proyecto de Supabase.

> Meta cambia requisitos, nombres de pantallas y precios seguido. Este documento
> dice **qué hay que conseguir y por qué**; los pasos exactos y las tarifas hay
> que confirmarlos en la documentación oficial el día que se ejecuten.

## Dónde estamos hoy

| Pieza                                                        | Estado                                                                                                                     |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| Portfolio comercial `DropChat` (`1749532886321694`)          | creado                                                                                                                     |
| App de Meta (`2168886197060394`), productos WhatsApp y Login | creada, publicada                                                                                                          |
| Usuario del sistema (`61594667275048`) con su token          | creado                                                                                                                     |
| Número de prueba `+1 555 172 8031`                           | registrado, suscrito, probado de ida y vuelta                                                                              |
| Webhook a `whatsapp-webhook`                                 | recibiendo y persistiendo                                                                                                  |
| Secretos del backend                                         | `META_APP_ID`, `META_APP_SECRET`, `META_SYSTEM_USER_ACCESS_TOKEN`, `META_SYSTEM_USER_ID`, `WHATSAPP_VERIFY_TOKEN` cargados |
| Verificación del negocio                                     | **no iniciada**                                                                                                            |
| Número real                                                  | **no registrado**                                                                                                          |
| Embedded Signup                                              | **implementado en el código, no habilitado en Meta**                                                                       |
| Plantillas en español                                        | escritas, sin enviar (`whatsapp-templates/`)                                                                               |

## 1. Verificación del negocio

Es el cuello de botella: sin ella no hay revisión de la app, y sin revisión de
la app no hay Embedded Signup. Conviene iniciarla antes que todo lo demás,
porque es lo único que depende de terceros. Se hace en el portfolio DropChat, en
**Configuración del negocio → Centro de seguridad → Iniciar verificación**.

Meta contrasta tres cosas: que la empresa existe, que la dirección es suya y que
el teléfono es suyo. Pide documentos oficiales, y el criterio es que **el nombre
legal, la dirección y el teléfono coincidan carácter por carácter** con lo que
escribas en el formulario. La causa de rechazo más común no es el documento: es
una diferencia entre "Ltda." y "Limitada", o una dirección abreviada distinto.

**Para acreditar que la empresa existe** (uno de estos):

- Certificado de RUT / e-RUT del SII.
- Certificado de inicio de actividades del SII.
- Escritura de constitución de la sociedad.
- Certificado de vigencia del Registro de Comercio.

**Para acreditar dirección y teléfono** (uno, a nombre de la empresa, con menos
de 90 días):

- Cuenta de servicios: luz, agua, gas o internet.
- Cartola o estado de cuenta bancario.
- Factura de telefonía.

**Además hace falta:**

- Un **sitio web** con el nombre del negocio visible. Sirve la landing, y
  conviene verificar el dominio en el portfolio.
- Un **correo corporativo del dominio** (`contacto@tudominio.cl`). Meta
  desconfía de Gmail para verificar negocios, y además resuelve el correo que
  falta en la política de privacidad.

Si operas como **persona natural con giro** en vez de sociedad, sirve el inicio
de actividades del SII junto con tu cédula; el nombre legal será el tuyo, y ese
es el que verá el cliente en la ficha del negocio, no "DropChat". Vale la pena
pensarlo antes de enviar.

**Cuánto demora:** de horas a semanas. Si rechazan, el mensaje no explica cuál
de los tres datos falló; hay que revisarlos uno por uno y reenviar.

## 2. El número real

Requisitos del número que uses para DropChat:

- **No puede tener WhatsApp activo**, ni el normal ni el Business. Si lo tiene,
  hay que borrar esa cuenta desde la aplicación y esperar — el número queda
  liberado, pero pierdes el historial de ese WhatsApp. Un número nuevo evita el
  problema.
- Tiene que poder **recibir SMS o llamada** para el código de verificación.
- Sirve un fijo, si contesta la llamada.

Después va el **nombre para mostrar**, que Meta revisa aparte: tiene que
relacionarse con el negocio verificado. "DropChat" pasa si el negocio se llama
así; un nombre genérico o una promesa comercial se rechaza.

Con el negocio verificado, el número se registra desde la app igual que el de
prueba: el código ya hace el `/register` con PIN y la suscripción de la WABA
(`whatsapp-management/embedded_signup.ts`).

## 3. Embedded Signup: cada cliente con su propio número

Esta es la pieza que convierte a DropChat en producto: el cliente entra a la
app, aprieta un botón, se autentica con su Facebook y queda conectado su propio
número, dentro de su propia WABA, sin que nosotros toquemos nada.

### Lo que ya está hecho

El flujo completo está implementado, no hay que programarlo:

- **Front** (`src/contexts/WhatsAppIntegrationContext.tsx`): levanta el SDK de
  Facebook y abre el diálogo con `appId` y `config_id`.
- **Back** (`supabase/functions/whatsapp-management/embedded_signup.ts`):
  intercambia el código por un token, suscribe la WABA a la app y registra el
  número.
- Los secretos del backend ya están cargados.

### Lo que falta, en orden

1. **Verificación del negocio** aprobada (punto 1). Es requisito previo de todo
   lo demás.

2. **Revisión de la app (App Review)** para los permisos
   `whatsapp_business_management` y `whatsapp_business_messaging` en modo
   avanzado. Mientras no estén aprobados, Embedded Signup solo funciona con
   cuentas que tengan un rol en la app — sirve para probar, no para vender. La
   revisión pide un video mostrando el flujo completo; en `app-review/` de este
   repositorio hay grabaciones de la versión original que sirven de guía.

3. **Datos públicos de la app**, que la revisión exige y hoy están incompletos:
   - ícono de la app (falta),
   - URL de términos del servicio (hoy apunta a `facebook.com`, hay que
     cambiarla),
   - URL de política de privacidad (ya existe: `/privacy`),
   - categoría y descripción.

4. **Configuración de Facebook Login for Business**: se crea en la app, con el
   tipo de configuración de onboarding de WhatsApp Business y los dos permisos
   de arriba. Entrega un **ID de configuración**, que es el `config_id` que
   consume el front.

5. **Dominios permitidos**: `dropchat-ui.pages.dev` (y el dominio propio cuando
   exista) tiene que estar en los dominios de la app y en la configuración de
   Login. Si falta, el diálogo abre y muere sin decir por qué.

6. **Variables del front en Cloudflare Pages**, que hoy no están puestas:
   - `VITE_META_APP_ID` = `2168886197060394`
   - `VITE_FB_LOGIN_CONFIG_ID` = el ID del paso 4

   Son públicas por diseño: viajan en el JavaScript del navegador. Después de
   cargarlas hay que volver a desplegar, porque Vite las mete en el bundle al
   compilar.

### Quién paga los mensajes

Con Embedded Signup, la WABA es **del cliente**: él es el dueño de su número y
de su historial, y conecta su propio método de pago. Meta le cobra a él
directamente, aparte de lo que le cobre DropChat por el servicio. Es lo que ya
dice la landing ("no incluye los mensajes que cobra Meta directo a tu cuenta") y
conviene que siga así: evita que DropChat quede de intermediario financiero.

La alternativa —compartir una línea de crédito y refacturar— existe, pero suma
responsabilidad contable y riesgo de impago. No la tomaría para el piloto.

### Cuánto cobra Meta

El modelo cambió: hoy se cobra **por mensaje de plantilla entregado**, con
precio distinto por categoría (utilidad, marketing, autenticación), y las
conversaciones que **inicia el cliente** no se cobran. Las plantillas de
utilidad enviadas **dentro de una ventana de atención abierta** tampoco. Eso
favorece al flujo contra entrega, donde el cliente suele responder el primer
mensaje y abrir la ventana.

**Confirmar las tarifas vigentes para Chile antes de fijar los precios del
plan**, tanto porque cambian como porque la calculadora de la landing depende de
ellas.

## Orden recomendado

1. Iniciar la verificación del negocio **hoy**: es lo que más demora y no
   depende de nosotros.
2. Mientras corre: completar los datos públicos de la app (ícono, términos),
   conseguir el correo del dominio y cerrar las
   [decisiones pendientes de las plantillas](whatsapp-templates/README.md).
3. Verificación aprobada → registrar el número real y enviar las plantillas a
   aprobación.
4. Con las plantillas aprobadas y el número andando, correr un piloto real con
   un cliente usando **nuestro** número.
5. Recién entonces App Review y Embedded Signup, que es lo que permite vender a
   varios clientes a la vez.

El orden importa: App Review revisa un flujo que tiene que funcionar de verdad,
y la forma más rápida de que lo aprueben es mostrar el producto ya operando.
