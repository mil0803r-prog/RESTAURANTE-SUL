-- ============================================================================
-- MULTIUSUARIO: cada correo tiene su propio negocio y no ve nada de los demás.
-- Se aplica sola al publicar (ver docs/ACTUALIZACIONES.md). Sirve para una base nueva y para la que ya usas.
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
