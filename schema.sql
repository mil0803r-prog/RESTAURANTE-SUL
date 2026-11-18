-- Control financiero · Restaurante
-- Para una base NUEVA: pega TODO este archivo en Supabase → SQL Editor → Run (una sola vez).
-- Para una base que ya usas: ejecuta solo el archivo migracion-multiusuario.sql.
-- ========== Perfiles y roles ==========
-- rol: 'dueno' (ve y edita todo) | 'cajero' (registra ventas y gastos, ve solo los últimos 2 días) | 'pendiente' (sin acceso hasta que el dueño lo apruebe)
create table public.perfiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  rol text not null default 'pendiente' check (rol in ('dueno','cajero','pendiente')),
  creado timestamptz not null default now()
);

create function public.es_dueno() returns boolean
language sql security definer stable set search_path = public as
$$ select exists(select 1 from public.perfiles where id = auth.uid() and rol = 'dueno') $$;

create function public.es_cajero() returns boolean
language sql security definer stable set search_path = public as
$$ select exists(select 1 from public.perfiles where id = auth.uid() and rol = 'cajero') $$;

-- La primera persona que crea cuenta queda como DUEÑO. Las demás quedan "pendiente" hasta que el dueño las apruebe.
create function public.nuevo_usuario() returns trigger
language plpgsql security definer set search_path = public as
$$
begin
  insert into public.perfiles(id, email, rol)
  values (new.id, new.email,
    case when exists(select 1 from public.perfiles where rol = 'dueno') then 'pendiente' else 'dueno' end);
  return new;
end
$$;
create trigger al_crear_usuario after insert on auth.users
for each row execute function public.nuevo_usuario();

alter table public.perfiles enable row level security;
create policy perfiles_ver on public.perfiles for select to authenticated
  using (id = auth.uid() or public.es_dueno());
create policy perfiles_editar on public.perfiles for update to authenticated
  using (public.es_dueno()) with check (public.es_dueno());

-- ========== Datos del negocio ==========
-- Cada registro se guarda completo en la columna "data" (json). ventas y gastos llevan además "fecha" para las reglas del cajero.
create table public.ventas      (id text primary key, fecha date not null, data jsonb not null, actualizado timestamptz default now());
create table public.gastos      (id text primary key, fecha date not null, data jsonb not null, actualizado timestamptz default now());
create table public.insumos     (id text primary key, data jsonb not null, actualizado timestamptz default now());
create table public.platos      (id text primary key, data jsonb not null, actualizado timestamptz default now());
create table public.empleados   (id text primary key, data jsonb not null, actualizado timestamptz default now());
create table public.recurrentes (id text primary key, data jsonb not null, actualizado timestamptz default now());
create table public.ajustes     (key text primary key, data jsonb not null, actualizado timestamptz default now());

create index on public.ventas(fecha);
create index on public.gastos(fecha);

alter table public.ventas enable row level security;
alter table public.gastos enable row level security;
alter table public.insumos enable row level security;
alter table public.platos enable row level security;
alter table public.empleados enable row level security;
alter table public.recurrentes enable row level security;
alter table public.ajustes enable row level security;

-- Dueño: todo
create policy dueno_todo on public.ventas      for all to authenticated using (public.es_dueno()) with check (public.es_dueno());
create policy dueno_todo on public.gastos      for all to authenticated using (public.es_dueno()) with check (public.es_dueno());
create policy dueno_todo on public.insumos     for all to authenticated using (public.es_dueno()) with check (public.es_dueno());
create policy dueno_todo on public.platos      for all to authenticated using (public.es_dueno()) with check (public.es_dueno());
create policy dueno_todo on public.empleados   for all to authenticated using (public.es_dueno()) with check (public.es_dueno());
create policy dueno_todo on public.recurrentes for all to authenticated using (public.es_dueno()) with check (public.es_dueno());
create policy dueno_todo on public.ajustes     for all to authenticated using (public.es_dueno()) with check (public.es_dueno());

-- Cajero: ver y crear ventas/gastos de los últimos 2 días (no edita ni borra), y leer los ajustes generales (moneda, impuesto)
create policy cajero_ver on public.ventas for select to authenticated
  using (public.es_cajero() and fecha >= current_date - 2);
create policy cajero_crear on public.ventas for insert to authenticated
  with check (public.es_cajero() and fecha >= current_date - 2 and fecha <= current_date + 1);
create policy cajero_ver on public.gastos for select to authenticated
  using (public.es_cajero() and fecha >= current_date - 2);
create policy cajero_crear on public.gastos for insert to authenticated
  with check (public.es_cajero() and fecha >= current_date - 2 and fecha <= current_date + 1);
create policy cajero_ver on public.ajustes for select to authenticated
  using (public.es_cajero() and key = 'cfg');

-- ========== Eliminar usuarios (solo el dueño) ==========
-- Borra la cuenta completa (y su perfil). La persona tendrá que registrarse de nuevo.
create or replace function public.eliminar_usuario(uid uuid) returns void
language plpgsql security definer set search_path = public, auth as
$$
begin
  if not public.es_dueno() then raise exception 'Solo el dueño puede eliminar usuarios'; end if;
  if exists(select 1 from public.perfiles where id = uid and rol = 'dueno')
     and not exists(select 1 from public.perfiles where rol = 'dueno' and id <> uid) then
    raise exception 'Debe quedar al menos un dueño';
  end if;
  delete from auth.users where id = uid;
end
$$;
revoke all on function public.eliminar_usuario(uuid) from public, anon;
grant execute on function public.eliminar_usuario(uuid) to authenticated;

-- ========== Buzón de ideas ==========
-- Cualquier persona con acceso (dueño o cajero) puede enviar una idea; solo el dueño las ve, marca y borra.
create table if not exists public.ideas (
  id uuid primary key default gen_random_uuid(),
  autor text,
  texto text not null check (char_length(texto) between 1 and 1000),
  hecha boolean not null default false,
  creado timestamptz not null default now()
);
alter table public.ideas enable row level security;
create policy ideas_enviar on public.ideas for insert to authenticated
  with check (public.es_dueno() or public.es_cajero());
create policy ideas_dueno on public.ideas for all to authenticated
  using (public.es_dueno()) with check (public.es_dueno());

-- ========== Acceso por secciones (para cajeros) ==========
-- El dueño elige a qué secciones entra cada cajero. Sin elegir, solo Ventas y Gastos.
-- Ventas y Gastos: puede registrar. Panel, Por pagar, Reportes, Costeo y Nómina: solo lectura.
alter table public.perfiles add column if not exists secciones text[];

create or replace function public.tiene_seccion(s text) returns boolean
language sql security definer stable set search_path = public as
$$ select exists(select 1 from public.perfiles where id = auth.uid() and rol = 'cajero'
                 and s = any(coalesce(secciones, array['ventas','gastos']))) $$;

-- Registrar: solo con la sección Ventas / Gastos
drop policy if exists cajero_crear on public.ventas;
drop policy if exists cajero_crear on public.gastos;
create policy cajero_crear on public.ventas for insert to authenticated
  with check (public.tiene_seccion('ventas') and fecha >= current_date - 2 and fecha <= current_date + 1);
create policy cajero_crear on public.gastos for insert to authenticated
  with check (public.tiene_seccion('gastos') and fecha >= current_date - 2 and fecha <= current_date + 1);
drop policy if exists cajero_ver on public.ventas;
drop policy if exists cajero_ver on public.gastos;
create policy cajero_ver on public.ventas for select to authenticated
  using (public.tiene_seccion('ventas') and fecha >= current_date - 2);
create policy cajero_ver on public.gastos for select to authenticated
  using (public.tiene_seccion('gastos') and fecha >= current_date - 2);

-- Leer todo el historial: Panel, Por pagar y Reportes
create policy cajero_historial on public.ventas for select to authenticated
  using (public.tiene_seccion('panel') or public.tiene_seccion('reportes') or public.tiene_seccion('pagar'));
create policy cajero_historial on public.gastos for select to authenticated
  using (public.tiene_seccion('panel') or public.tiene_seccion('reportes') or public.tiene_seccion('pagar'));

-- Costeo y Nómina: solo lectura
create policy cajero_ver on public.insumos     for select to authenticated using (public.tiene_seccion('costeo'));
create policy cajero_ver on public.platos      for select to authenticated using (public.tiene_seccion('costeo'));
create policy cajero_ver on public.empleados   for select to authenticated using (public.tiene_seccion('equipo'));
create policy cajero_ver on public.recurrentes for select to authenticated using (public.tiene_seccion('equipo'));
drop policy if exists cajero_ver on public.ajustes;
create policy cajero_ver on public.ajustes for select to authenticated
  using (public.es_cajero() and (key = 'cfg' or (key = 'inv' and public.tiene_seccion('costeo'))));
-- ============================================================================
-- MULTIUSUARIO: cada correo tiene su propio negocio y no ve nada de los demás.
-- Se ejecuta UNA vez (sirve tanto para una base nueva como para la que ya usas).
-- Quien se registra queda como DUEÑO de su propio espacio vacío.
-- El dueño puede INVITAR correos (cajero o dueño) a su mismo negocio.
-- Los datos que ya existen quedan con el dueño principal (milstoreonline38@gmail.com).
-- ============================================================================

-- ---------- 1) A qué negocio pertenece cada persona ----------
alter table public.perfiles add column if not exists negocio uuid;
alter table public.perfiles add column if not exists secciones text[];

create or replace function public.mi_negocio() returns uuid
language sql security definer stable set search_path = public as
$$ select negocio from public.perfiles where id = auth.uid() $$;

create or replace function public.es_dueno() returns boolean
language sql security definer stable set search_path = public as
$$ select exists(select 1 from public.perfiles where id = auth.uid() and rol = 'dueno') $$;

create or replace function public.es_cajero() returns boolean
language sql security definer stable set search_path = public as
$$ select exists(select 1 from public.perfiles where id = auth.uid() and rol = 'cajero') $$;

create or replace function public.tiene_seccion(s text) returns boolean
language sql security definer stable set search_path = public as
$$ select exists(select 1 from public.perfiles where id = auth.uid() and rol = 'cajero'
                 and s = any(coalesce(secciones, array['ventas','gastos']))) $$;

-- ---------- 2) Columna "negocio_id" en todas las tablas de datos ----------
create table if not exists public.ideas (
  id uuid primary key default gen_random_uuid(),
  autor text,
  texto text not null check (char_length(texto) between 1 and 1000),
  hecha boolean not null default false,
  creado timestamptz not null default now()
);

do $$
declare t text; principal uuid;
begin
  -- dueño principal: el correo indicado o, si no existe, el dueño más antiguo
  select id into principal from public.perfiles where lower(email) = 'milstoreonline38@gmail.com';
  if principal is null then
    select id into principal from public.perfiles where rol = 'dueno' order by creado limit 1;
  end if;
  if principal is null then
    select id into principal from public.perfiles order by creado limit 1;
  end if;

  -- perfiles: los cajeros quedan en el negocio principal; todos los demás tienen el suyo propio
  update public.perfiles set rol = 'dueno' where rol = 'pendiente';
  update public.perfiles set negocio = case when rol = 'cajero' then principal else id end where negocio is null;

  foreach t in array array['ventas','gastos','insumos','platos','empleados','recurrentes','ajustes','ideas'] loop
    execute format('alter table public.%I add column if not exists negocio_id uuid', t);
    execute format('update public.%I set negocio_id = %L where negocio_id is null', t, principal);
    execute format('alter table public.%I alter column negocio_id set default public.mi_negocio()', t);
    execute format('alter table public.%I alter column negocio_id set not null', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('create index if not exists %I on public.%I(negocio_id)', t || '_negocio_idx', t);
  end loop;
end $$;

-- La llave primaria incluye el negocio (dos negocios pueden tener "cfg" o el mismo id)
do $$
declare t text; pk text;
begin
  foreach t in array array['ventas','gastos','insumos','platos','empleados','recurrentes'] loop
    select conname into pk from pg_constraint where conrelid = ('public.'||t)::regclass and contype = 'p';
    if pk is not null and (select count(*) from pg_constraint c, unnest(c.conkey) k where c.conname = pk and c.conrelid = ('public.'||t)::regclass) = 1 then
      execute format('alter table public.%I drop constraint %I', t, pk);
      execute format('alter table public.%I add primary key (negocio_id, id)', t);
    end if;
  end loop;
  select conname into pk from pg_constraint where conrelid = 'public.ajustes'::regclass and contype = 'p';
  if pk is not null and (select count(*) from pg_constraint c, unnest(c.conkey) k where c.conname = pk and c.conrelid = 'public.ajustes'::regclass) = 1 then
    alter table public.ajustes drop constraint ajustes_pkey;
    alter table public.ajustes add primary key (negocio_id, key);
  end if;
end $$;

-- ---------- 3) Invitaciones (el dueño invita correos a SU negocio) ----------
create table if not exists public.invitaciones (
  email text not null,
  negocio uuid not null default public.mi_negocio(),
  rol text not null default 'cajero' check (rol in ('cajero','dueno')),
  secciones text[],
  creado timestamptz not null default now(),
  primary key (negocio, email)
);
alter table public.invitaciones enable row level security;

-- ---------- 4) Cuenta nueva: dueña de su propio negocio, o entra por invitación ----------
create or replace function public.nuevo_usuario() returns trigger
language plpgsql security definer set search_path = public as
$$
declare inv public.invitaciones%rowtype;
begin
  select * into inv from public.invitaciones where lower(email) = lower(new.email) order by creado limit 1;
  if found then
    insert into public.perfiles(id, email, rol, secciones, negocio) values (new.id, new.email, inv.rol, inv.secciones, inv.negocio);
    delete from public.invitaciones where lower(email) = lower(new.email);
  else
    insert into public.perfiles(id, email, rol, negocio) values (new.id, new.email, 'dueno', new.id);
  end if;
  return new;
end
$$;
drop trigger if exists al_crear_usuario on auth.users;
create trigger al_crear_usuario after insert on auth.users
for each row execute function public.nuevo_usuario();

-- ---------- 5) Reglas: cada negocio solo ve lo suyo ----------
do $$
declare p record;
begin
  for p in select schemaname, tablename, policyname from pg_policies
           where schemaname = 'public'
             and tablename in ('perfiles','ventas','gastos','insumos','platos','empleados','recurrentes','ajustes','ideas','invitaciones')
  loop
    execute format('drop policy %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end $$;

-- Perfiles: cada uno ve el suyo; el dueño ve y edita los de su negocio
create policy perfiles_ver on public.perfiles for select to authenticated
  using (id = auth.uid() or (public.es_dueno() and negocio = public.mi_negocio()));
create policy perfiles_editar on public.perfiles for update to authenticated
  using (public.es_dueno() and negocio = public.mi_negocio())
  with check (public.es_dueno() and negocio = public.mi_negocio());

-- Dueño: todo lo de su negocio
create policy dueno_todo on public.ventas      for all to authenticated using (negocio_id = public.mi_negocio() and public.es_dueno()) with check (negocio_id = public.mi_negocio() and public.es_dueno());
create policy dueno_todo on public.gastos      for all to authenticated using (negocio_id = public.mi_negocio() and public.es_dueno()) with check (negocio_id = public.mi_negocio() and public.es_dueno());
create policy dueno_todo on public.insumos     for all to authenticated using (negocio_id = public.mi_negocio() and public.es_dueno()) with check (negocio_id = public.mi_negocio() and public.es_dueno());
create policy dueno_todo on public.platos      for all to authenticated using (negocio_id = public.mi_negocio() and public.es_dueno()) with check (negocio_id = public.mi_negocio() and public.es_dueno());
create policy dueno_todo on public.empleados   for all to authenticated using (negocio_id = public.mi_negocio() and public.es_dueno()) with check (negocio_id = public.mi_negocio() and public.es_dueno());
create policy dueno_todo on public.recurrentes for all to authenticated using (negocio_id = public.mi_negocio() and public.es_dueno()) with check (negocio_id = public.mi_negocio() and public.es_dueno());
create policy dueno_todo on public.ajustes     for all to authenticated using (negocio_id = public.mi_negocio() and public.es_dueno()) with check (negocio_id = public.mi_negocio() and public.es_dueno());
create policy dueno_todo on public.ideas       for all to authenticated using (negocio_id = public.mi_negocio() and public.es_dueno()) with check (negocio_id = public.mi_negocio() and public.es_dueno());
create policy dueno_todo on public.invitaciones for all to authenticated
  using (negocio = public.mi_negocio() and public.es_dueno()) with check (negocio = public.mi_negocio() and public.es_dueno());

-- Cajero: registrar ventas y gastos (si tiene esa sección), ver lo que su dueño le permitió
create policy cajero_crear on public.ventas for insert to authenticated
  with check (negocio_id = public.mi_negocio() and public.tiene_seccion('ventas') and fecha >= current_date - 2 and fecha <= current_date + 1);
create policy cajero_crear on public.gastos for insert to authenticated
  with check (negocio_id = public.mi_negocio() and public.tiene_seccion('gastos') and fecha >= current_date - 2 and fecha <= current_date + 1);
create policy cajero_ver on public.ventas for select to authenticated
  using (negocio_id = public.mi_negocio() and public.tiene_seccion('ventas') and fecha >= current_date - 2);
create policy cajero_ver on public.gastos for select to authenticated
  using (negocio_id = public.mi_negocio() and public.tiene_seccion('gastos') and fecha >= current_date - 2);
create policy cajero_historial on public.ventas for select to authenticated
  using (negocio_id = public.mi_negocio() and (public.tiene_seccion('panel') or public.tiene_seccion('reportes') or public.tiene_seccion('pagar')));
create policy cajero_historial on public.gastos for select to authenticated
  using (negocio_id = public.mi_negocio() and (public.tiene_seccion('panel') or public.tiene_seccion('reportes') or public.tiene_seccion('pagar')));
create policy cajero_ver on public.insumos     for select to authenticated using (negocio_id = public.mi_negocio() and public.tiene_seccion('costeo'));
create policy cajero_ver on public.platos      for select to authenticated using (negocio_id = public.mi_negocio() and public.tiene_seccion('costeo'));
create policy cajero_ver on public.empleados   for select to authenticated using (negocio_id = public.mi_negocio() and public.tiene_seccion('equipo'));
create policy cajero_ver on public.recurrentes for select to authenticated using (negocio_id = public.mi_negocio() and public.tiene_seccion('equipo'));
create policy cajero_ver on public.ajustes for select to authenticated
  using (negocio_id = public.mi_negocio() and public.es_cajero() and (key = 'cfg' or (key = 'inv' and public.tiene_seccion('costeo'))));
create policy ideas_enviar on public.ideas for insert to authenticated
  with check (negocio_id = public.mi_negocio() and (public.es_dueno() or public.es_cajero()));

-- ---------- 6) Eliminar personas de MI negocio (solo dueños) ----------
create or replace function public.eliminar_usuario(uid uuid) returns void
language plpgsql security definer set search_path = public, auth as
$$
declare destino public.perfiles%rowtype;
begin
  if not public.es_dueno() then raise exception 'Solo el dueño puede eliminar usuarios'; end if;
  select * into destino from public.perfiles where id = uid;
  if not found or destino.negocio <> public.mi_negocio() then raise exception 'Esa persona no pertenece a tu negocio'; end if;
  if destino.rol = 'dueno' and not exists(select 1 from public.perfiles where rol = 'dueno' and negocio = destino.negocio and id <> uid) then
    raise exception 'Debe quedar al menos un dueño';
  end if;
  delete from auth.users where id = uid;
end
$$;
revoke all on function public.eliminar_usuario(uuid) from public, anon;
grant execute on function public.eliminar_usuario(uuid) to authenticated;

alter table public.perfiles alter column negocio set not null;

-- Quién puede llamar a las funciones de ayuda
grant execute on function public.mi_negocio(), public.es_dueno(), public.es_cajero(), public.tiene_seccion(text) to authenticated;
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
