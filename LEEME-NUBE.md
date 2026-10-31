# Puesta en marcha en la nube (Supabase + Vercel)

## 1. Crear la base de datos (una sola vez, ~5 min)
1. Entra a https://supabase.com y crea una cuenta gratis → **New project** (nombre: `restaurante-sul`, región cercana, guarda la contraseña de base de datos).
2. Menú **SQL Editor** → **New query** → pega TODO el contenido de `schema.sql` → **Run**. Debe decir "Success".
3. Menú **Authentication → Providers → Email**: déjalo activo. Recomendado para empezar: desactiva *Confirm email* (así no dependen de un correo de confirmación).
4. Menú **Project Settings → API**: copia **Project URL** y la clave **anon public**.
5. Abre `config.js` y pega esos dos valores entre las comillas.

## 2. Probar en tu computador
Abre `index.html` con doble clic. Verás la pantalla de entrada → **Crear cuenta**. **La primera cuenta que se crea queda como Dueño**, así que créala tú primero.

## 3. Publicar para usarla desde el celular
Opción Vercel: sube la carpeta `nube` como proyecto estático (index.html + config.js) y obtendrás un enlace público tipo `https://restaurante-sul.vercel.app`. Ábrelo en el celular y usa "Agregar a pantalla de inicio".

## 4. Dar acceso al cajero
1. El cajero abre el enlace → **Crear cuenta** con su correo.
2. Queda en "Esperando aprobación".
3. Tú (Dueño) entras a **Ajustes → Quién puede entrar** y lo cambias a **Cajero**.

## Qué ve cada rol
| | Dueño | Cajero |
|---|---|---|
| Panel, reportes, costeo, nómina, ajustes | Sí | No |
| Registrar ventas y gastos | Sí | Sí |
| Ver lo registrado | Todo el historial | Solo los últimos 2 días |
| Editar o borrar registros | Sí | No (se lo pide al dueño) |

Las reglas las aplica la base de datos (no solo la pantalla): aunque alguien abra las herramientas del navegador, un cajero no puede leer ni modificar lo que no le corresponde.

## Notas
- Se necesita internet para usarla (los datos viven en la nube). Si se cae la conexión, el cambio no se guarda y la app avisa.
- Si cambias el correo del dueño o pierdes la clave: Supabase → Authentication → Users.
- Mantén descargando respaldos desde Ajustes como copia extra.
