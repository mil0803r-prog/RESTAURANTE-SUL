-- Control financiero · Restaurante Sul
-- Pega TODO este archivo en Supabase → SQL Editor → Run. Se puede ejecutar una sola vez.

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
