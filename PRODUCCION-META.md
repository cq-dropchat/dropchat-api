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
| Empresa constituida                                          | **no**, ni SpA ni inicio de actividades (2026-09-20)                                                                       |
| Verificación del negocio                                     | **no iniciada**, depende de lo anterior                                                                                    |
| Número real                                                  | **no registrado**                                                                                                          |
| Embedded Signup                                              | **implementado en el código, no habilitado en Meta**                                                                       |
| Plantillas en español                                        | escritas, sin enviar (`whatsapp-templates/`)                                                                               |

## 0. Todavía no hay empresa

DropChat no está constituido: no hay SpA ni inicio de actividades. Eso **no
bloquea el piloto**, pero sí pone techo a lo que se puede hacer.

**Lo que se puede hacer sin verificar el negocio:** conectar un número real y
escribirle a unos 250 clientes distintos cada 24 horas, con hasta dos números en
la cuenta. Para un piloto con uno o dos vendedores sobra. El límite se vuelve un
problema recién cuando el piloto crece o entra el segundo cliente grande — y la
verificación es obligatoria para App Review, o sea para Embedded Signup. Los
límites exactos cambian; confirmarlos en la documentación el día que se registre
el número.

**Lo que igual hay que resolver antes de cobrar:** estar formalizado ante el
SII, porque hay que emitir boleta o factura y porque Meta va a pedir un
documento tributario para verificar. Dos caminos:

|              | Persona natural con giro                       | SpA por Empresa en un Día                                                               |
| ------------ | ---------------------------------------------- | --------------------------------------------------------------------------------------- |
| Trámite      | inicio de actividades en el SII con ClaveÚnica | constitución en `registrodeempresasysociedades.cl`, después RUT e inicio de actividades |
| Plazo        | el mismo día                                   | un día con firma electrónica avanzada; más si se firma ante notario                     |
| Costo        | gratis                                         | constitución gratis; la FEA ronda los $30.000                                           |
| Nombre legal | el tuyo                                        | `DropChat SpA`                                                                          |
| Patrimonio   | respondes con el personal                      | separado                                                                                |

El nombre legal importa más de lo que parece: **es el que ve el cliente en la
ficha del negocio de WhatsApp**, no el nombre de fantasía. Como persona natural,
tus clientes verán tu nombre.

Para lo que DropChat quiere ser —cobrarle a otras empresas y llegar a proveedor
técnico de Meta— la SpA es el camino. La diferencia de tiempo entre las dos es
de días, y cambiar de persona natural a empresa después obliga a **rehacer la
verificación de Meta desde cero**, porque cambia el titular.

Esto tiene efectos tributarios; conviene consultarlo con un contador antes de
firmar. Nada de este documento es asesoría legal ni contable.

## 1. Verificación del negocio

Sin ella no hay revisión de la app, y sin revisión de la app no hay Embedded
Signup. No hace falta para el piloto, pero sí para vender a varios clientes, y
es lo único de esta lista que depende de terceros: una vez que exista la
empresa, iniciarla cuanto antes. Se hace en el portfolio DropChat, en
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

1. **Empresa constituida y verificación del negocio** aprobada (puntos 0 y 1).
   Es requisito previo de todo lo demás de esta lista, y lo único que el piloto
   no necesita.

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

El plan va **primero el piloto, después la verificación**. Al revés se esperan
semanas de trámite antes de saber si el producto sirve, y esa espera no enseña
nada: el límite de 250 clientes al día alcanza de sobra para descubrir si un
vendedor deja de perder plata con DropChat.

**Ahora, sin depender de nadie:**

1. Cerrar las
   [decisiones pendientes de las plantillas](whatsapp-templates/README.md):
   plazo de entrega, medio de pago y costo del reintento.
2. Dominio propio y correo corporativo. Después los piden para verificar, y el
   correo cierra el hueco de la política de privacidad
   (`PRIVACY_CONTACT_EMAIL`).
3. Datos públicos de la app: ícono y URL de términos, que hoy apunta a
   `facebook.com`.
4. Catálogo de facturación en CLP en la base de datos de producción: hoy está
   vacío, y por eso la organización no tiene suscripción ni cuotas.

**Formalizarse (punto 0):** SpA o persona natural. Define el nombre que verá el
cliente, así que va antes de registrar el número.

**El piloto, con negocio sin verificar:**

5. Registrar el número real y enviar las plantillas a aprobación.
6. Correr el piloto con uno o dos vendedores, sobre **nuestro** número, dentro
   del límite de 250 clientes cada 24 horas.

**Escalar:**

7. Verificación del negocio (punto 1), apenas exista la empresa: tarda, y sin
   ella no se sube del límite.
8. App Review y Embedded Signup (punto 3), que es lo que permite que cada
   cliente conecte su propio número.

El orden importa en las dos puntas: la verificación demora y conviene tenerla
corriendo temprano, y App Review revisa un flujo que tiene que funcionar de
verdad — la forma más rápida de que lo aprueben es mostrar el producto ya
operando con clientes reales.
