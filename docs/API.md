# API y MCP del restaurante

Cada clave ve **solo los datos de su propio negocio**. La seguridad la aplica la base de datos, no el servidor.

## 1. Crear una clave
En la app: **Ajustes → 🔌 Conexiones (API y MCP) → Crear clave**.
- *Leer y registrar*: consulta datos y registra ventas y gastos.
- *Solo leer*: únicamente consulta.

La clave (empieza con `rsk_`) se muestra **una sola vez**; en la base solo se guarda su huella (SHA-256). Puedes **revocarla** o borrarla cuando quieras, y crear una por cada uso.

## 2. API REST  (`https://TU-DOMINIO/api/v1`)
Envía la clave como `Authorization: Bearer rsk_...` (o `X-API-Key`).

| Método y ruta | Qué hace |
|---|---|
| `GET /info` | Nombre del negocio, moneda y permiso de la clave |
| `GET /resumen?mes=AAAA-MM` | Ventas, gastos por categoría, costo de ventas, utilidad operativa, margen, punto de equilibrio (misma fórmula que el Panel de la app) |
| `GET /ventas?desde=&hasta=&limite=` | Lista de ventas |
| `POST /ventas` | Registra ventas de un día: `efectivo`, `tarjeta`, `transf`, `apps` (al menos uno > 0), `fecha`, `propinas`, `tickets`, `contado`, `nota` |
| `GET /gastos?desde=&hasta=&limite=` | Lista de gastos |
| `POST /gastos` | Registra un gasto: `monto` (obligatorio), `cat`, `tipo`, `proveedor`, `desc`, `estado` (`pagado`/`pendiente`), `vence`, `metodo`, `fecha` |
| `GET /catalogo?tipo=platos\|insumos` | Platos o insumos |
| `GET /openapi` | Especificación OpenAPI (sin clave) |

Categorías de gasto: `insumos, bebidas, empaques, gas, comisiones, nomina, arriendo, servicios, marketing, mant, impuestos, financiero, otros`.
Medios de pago: `Efectivo, Transferencia, Tarjeta, Crédito con proveedor, Otro`.

```bash
curl -H "Authorization: Bearer rsk_..." https://TU-DOMINIO/api/v1/resumen

curl -X POST https://TU-DOMINIO/api/v1/ventas \
  -H "Authorization: Bearer rsk_..." -H "Content-Type: application/json" \
  -d '{"efectivo": 250000, "tarjeta": 120000, "tickets": 30}'
```

Errores: `401` clave inválida o ausente · `403` clave de solo lectura · `400` datos inválidos (el mensaje explica qué corregir).
Las fechas por defecto usan la zona horaria de Bogotá. No se pueden registrar fechas de más de 1 año atrás.

## 3a. Conectar con inicio de sesión (ChatGPT, Claude… — sin copiar claves)
1. En la app (ChatGPT → Ajustes → Conectores/Complementos → crear; Claude → Conectores personalizados) agrega un servidor MCP con la dirección `https://TU-DOMINIO/api/mcp` y autenticación **OAuth**.
2. La app se registra sola y abre la pantalla **Permitir acceso** de tu restaurante. Si no tienes sesión iniciada, primero te lleva al login normal (Google o correo) y luego vuelve.
3. Elige **Leer y registrar** o **Solo leer** y pulsa **Permitir acceso**. Solo el **dueño** del negocio puede autorizar.
4. Para quitar el acceso: **Ajustes → Conexiones → Quitar acceso** (deja de funcionar al instante).

Detalles técnicos: OAuth 2.1 con PKCE (S256), registro dinámico de clientes (`/oauth/register`), `/oauth/authorize`, `/oauth/token`, metadatos en `/.well-known/oauth-protected-resource` y `/.well-known/oauth-authorization-server`. Los tokens de acceso duran 1 hora y los de renovación 30 días (se rotan en cada uso; si se reutiliza uno ya usado, toda la autorización se revoca). Nada se guarda en texto: solo la huella (SHA-256).

## 3b. MCP  (`https://TU-DOMINIO/api/mcp`)
Servidor MCP por HTTP (sin estado). Herramientas: `resumen_mes`, `listar_ventas`, `listar_gastos`, `listar_platos`, `listar_insumos`, `registrar_venta`, `registrar_gasto` (las de registrar solo aparecen con una clave de escritura).

**Claude Code:**
```bash
claude mcp add --transport http restaurante https://TU-DOMINIO/api/mcp \
  --header "Authorization: Bearer rsk_..."
```
Sirve con cualquier cliente MCP que permita enviar un encabezado `Authorization`. Para ChatGPT y los conectores de claude.ai usa el inicio de sesión (sección 3a).

## 4. Instalación
Nada que instalar: la base de datos se actualiza sola al publicar (ver `ACTUALIZACIONES.md`).
La API usa por defecto la URL y la clave pública de Supabase de `config.js`; opcionalmente se pueden fijar con las variables de entorno de Vercel `SUPABASE_URL` y `SUPABASE_ANON_KEY`.
