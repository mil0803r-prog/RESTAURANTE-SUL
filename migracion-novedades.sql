-- ============================================================================
-- NOVEDADES EN PRUEBA: cada actualización llega primero SOLO al administrador
-- (milstoreonline38@gmail.com) como "Beta". Cuando la pruebe, pulsa
-- "Habilitar para todos" en Ajustes → Novedades y la ven todos los correos.
-- Se ejecuta UNA vez (se puede repetir sin problema).
-- ============================================================================

-- ¿Quién es el administrador? Se mira el correo REAL de la cuenta (auth.users),
-- nunca un dato que el usuario pueda editar.
create or replace function public.es_admin() returns boolean
language sql security definer stable set search_path = public, auth as
$$ select exists(select 1 from auth.users where id = auth.uid() and lower(email) = 'milstoreonline38@gmail.com') $$;
grant execute on function public.es_admin() to authenticated;

-- Lista de novedades (la misma para todo el sistema)
create table if not exists public.funciones (
  clave text primary key,
  titulo text not null,
  descripcion text,
  estado text not null default 'beta' check (estado in ('beta','publicada')),
  creado timestamptz not null default now(),
  publicado timestamptz
);
alter table public.funciones enable row level security;

do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'funciones' loop
    execute format('drop policy %I on public.funciones', p.policyname);
  end loop;
end $$;

-- Todos ven solo lo publicado; el administrador ve también lo que está en Beta y es el único que puede cambiarlo
create policy funciones_ver on public.funciones for select to authenticated
  using (estado = 'publicada' or public.es_admin());
create policy funciones_admin on public.funciones for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- Registro de lo que ya está activo para todos
insert into public.funciones(clave, titulo, descripcion, estado, publicado) values
  ('ideas',     'Buzón de ideas',        'Botón flotante para enviar sugerencias.',                    'publicada', now()),
  ('secciones', 'Acceso por secciones',  'El dueño elige a qué secciones entra cada cajero.',          'publicada', now()),
  ('equipo',    'Equipo e invitaciones', 'Cada correo tiene su negocio privado e invita a su equipo.', 'publicada', now())
on conflict (clave) do nothing;

-- Seguridad extra: nadie puede cambiar su propio correo ni su negocio en "perfiles"
-- (solo el rol y las secciones, que es lo que usa la pantalla "Tu equipo").
revoke update on public.perfiles from authenticated;
grant update (rol, secciones) on public.perfiles to authenticated;
