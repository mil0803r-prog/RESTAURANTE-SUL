# Cómo se publican las actualizaciones (automático)

**Ya no hay que entrar a Supabase a pegar SQL.** Cada actualización se publica sola:

1. Se sube el cambio a GitHub (rama `main`).
2. Vercel arranca una publicación y, **antes de sacar la versión nueva al aire**, ejecuta `scripts/migrar.js`.
3. Ese script aplica a Supabase las migraciones nuevas de la carpeta `migraciones/` (una sola vez cada una, en orden, dentro de una transacción) y lo anota en la tabla `public.migraciones`.
4. Si todo salió bien, la versión nueva se publica. **Si una migración falla, no se aplica nada de ese archivo, la publicación se detiene y la versión anterior sigue funcionando.**

Las novedades de la app (código) siguen llegando primero como **Beta** al administrador, que las habilita para todos desde Ajustes → Novedades en prueba.

## Reglas
- Un cambio de base de datos = un archivo nuevo `migraciones/NNN_nombre.sql` (número siguiente). **Nunca se edita uno ya aplicado** (el script avisa y no lo vuelve a ejecutar).
- Las migraciones deben poder repetirse sin error (`if not exists`, `create or replace`, `drop policy if exists`…).
- Solo corre en **producción**: las vistas previas de otras ramas no tocan la base de datos real.

## Configuración (una sola vez)
El script necesita la cadena de conexión de la base de datos en la variable `DATABASE_URL` de Vercel:

1. **Supabase** → botón **Connect** (arriba) → pestaña **Connection string** → método **Session pooler** → copia el URI (`postgresql://postgres.xxxx:[YOUR-PASSWORD]@aws-…pooler.supabase.com:5432/postgres`).
   Cambia `[YOUR-PASSWORD]` por la contraseña de la base de datos (si no la recuerdas: Project Settings → Database → Reset database password).
2. **Vercel** → tu proyecto → **Settings → Environment Variables** → nombre `DATABASE_URL`, valor = ese URI, entorno **Production** únicamente → Save. Marca **Sensitive** si te lo ofrece.
3. **Vercel → Deployments** → en el último despliegue de producción: ⋯ → **Redeploy**. En el registro del build debe aparecer `[migraciones] …`.

Si `DATABASE_URL` no está configurada, el script lo avisa en el registro del build y la publicación sigue, pero **no se aplican migraciones**.

## Revisar qué migraciones están aplicadas
En Supabase → SQL Editor: `select * from public.migraciones order by nombre;`
