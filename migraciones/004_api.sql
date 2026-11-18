-- ============================================================================
-- API y MCP: claves por negocio. Cada clave solo ve y escribe los datos de SU negocio.
-- Se aplica sola al publicar (ver docs/ACTUALIZACIONES.md).
-- La clave real nunca se guarda: solo su huella (hash). Se muestra una sola vez al crearla.
-- ============================================================================

create table if not exists public.api_keys (
  id uuid primary key default gen_random_uuid(),
  negocio uuid not null default public.mi_negocio(),
  nombre text not null check (char_length(nombre) between 1 and 60),
  prefijo text not null,
  hash text not null unique,
  permiso text not null default 'escritura' check (permiso in ('lectura','escritura')),
  creado timestamptz not null default now(),
  ultimo_uso timestamptz,
  revocada boolean not null default false
);
alter table public.api_keys enable row level security;

do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'api_keys' loop
    execute format('drop policy %I on public.api_keys', p.policyname);
  end loop;
end $$;

-- Solo el dueño del negocio ve, crea, revoca y borra las claves de su negocio
create policy api_keys_dueno on public.api_keys for all to authenticated
  using (negocio = public.mi_negocio() and public.es_dueno())
  with check (negocio = public.mi_negocio() and public.es_dueno());
revoke update on public.api_keys from authenticated;
grant update (revocada) on public.api_keys to authenticated;

-- ---------- Validar una clave (interna: nadie puede llamarla directamente) ----------
create or replace function public._api_auth(k text) returns public.api_keys
language plpgsql security definer set search_path = public as
$$
declare r public.api_keys;
begin
  if k is null or k !~ '^rsk_[A-Za-z0-9_-]{20,100}$' then
    raise exception 'Clave de API inválida' using errcode = '28000';
  end if;
  select * into r from public.api_keys
   where hash = encode(sha256(convert_to(k, 'UTF8')), 'hex') and not revocada;
  if not found then raise exception 'Clave de API inválida' using errcode = '28000'; end if;
  if r.ultimo_uso is null or r.ultimo_uso < now() - interval '1 minute' then
    update public.api_keys set ultimo_uso = now() where id = r.id;
  end if;
  return r;
end
$$;
revoke all on function public._api_auth(text) from public, anon, authenticated;

-- Número validado de un campo del JSON (0 si no viene)
create or replace function public._api_num(d jsonb, campo text) returns numeric
language plpgsql immutable set search_path = public as
$$
declare v numeric;
begin
  if d->campo is null or d->>campo = '' then return 0; end if;
  begin v := (d->>campo)::numeric; exception when others then
    raise exception 'El campo "%" debe ser un número', campo using errcode = '22023';
  end;
  if v < 0 or v > 1000000000000 then
    raise exception 'El campo "%" está fuera de rango', campo using errcode = '22023';
  end if;
  return round(v, 2);
end
$$;
revoke all on function public._api_num(jsonb, text) from public, anon, authenticated;

-- ---------- Funciones públicas (se llaman con la clave) ----------
create or replace function public.api_info(k text) returns jsonb
language plpgsql security definer set search_path = public as
$$
declare r public.api_keys; cfg jsonb;
begin
  r := public._api_auth(k);
  select data into cfg from public.ajustes where negocio_id = r.negocio and key = 'cfg';
  return jsonb_build_object('permiso', r.permiso, 'clave', r.nombre,
    'nombre', coalesce(cfg->>'nombre', 'Restaurante'), 'moneda', coalesce(cfg->>'moneda', 'COP'));
end
$$;

create or replace function public.api_config(k text) returns jsonb
language plpgsql security definer set search_path = public as
$$
declare r public.api_keys; cfg jsonb; inv jsonb;
begin
  r := public._api_auth(k);
  select data into cfg from public.ajustes where negocio_id = r.negocio and key = 'cfg';
  select data into inv from public.ajustes where negocio_id = r.negocio and key = 'inv';
  return jsonb_build_object('cfg', coalesce(cfg, '{}'::jsonb), 'inv', coalesce(inv, '{}'::jsonb));
end
$$;

create or replace function public.api_listar(k text, tabla text, desde date default null, hasta date default null, lim int default 200)
returns jsonb
language plpgsql security definer set search_path = public as
$$
declare r public.api_keys; res jsonb; n int := least(greatest(coalesce(lim, 200), 1), 1000);
begin
  r := public._api_auth(k);
  if tabla = 'ventas' then
    select coalesce(jsonb_agg(x.data order by x.fecha desc, x.id), '[]'::jsonb) into res from (
      select data, fecha, id from public.ventas
       where negocio_id = r.negocio and (desde is null or fecha >= desde) and (hasta is null or fecha <= hasta)
       order by fecha desc, id limit n) x;
  elsif tabla = 'gastos' then
    select coalesce(jsonb_agg(x.data order by x.fecha desc, x.id), '[]'::jsonb) into res from (
      select data, fecha, id from public.gastos
       where negocio_id = r.negocio and (desde is null or fecha >= desde) and (hasta is null or fecha <= hasta)
       order by fecha desc, id limit n) x;
  elsif tabla = 'platos' then
    select coalesce(jsonb_agg(x.data order by x.id), '[]'::jsonb) into res from (
      select data, id from public.platos where negocio_id = r.negocio order by id limit n) x;
  elsif tabla = 'insumos' then
    select coalesce(jsonb_agg(x.data order by x.id), '[]'::jsonb) into res from (
      select data, id from public.insumos where negocio_id = r.negocio order by id limit n) x;
  else
    raise exception 'Tabla no permitida: use ventas, gastos, platos o insumos' using errcode = '22023';
  end if;
  return res;
end
$$;

create or replace function public.api_registrar(k text, tabla text, dato jsonb) returns jsonb
language plpgsql security definer set search_path = public as
$$
declare
  r public.api_keys; nid text; f date; fila jsonb;
  hoy date := (now() at time zone 'America/Bogota')::date;
  ef numeric; ta numeric; tr numeric; ap numeric; mo numeric;
  cat text; tipo text; est text; met text; vence text;
  cats text[] := array['insumos','bebidas','empaques','gas','comisiones','nomina','arriendo','servicios','marketing','mant','impuestos','financiero','otros'];
  fijas text[] := array['nomina','arriendo','servicios','marketing','mant','impuestos','financiero'];
  metodos text[] := array['Efectivo','Transferencia','Tarjeta','Crédito con proveedor','Otro'];
begin
  r := public._api_auth(k);
  if r.permiso <> 'escritura' then
    raise exception 'Esta clave es de solo lectura' using errcode = '42501';
  end if;
  if dato is null or jsonb_typeof(dato) <> 'object' then
    raise exception 'El cuerpo debe ser un objeto JSON' using errcode = '22023';
  end if;
  nid := substr(md5(gen_random_uuid()::text), 1, 11);
  begin f := coalesce(nullif(dato->>'fecha', '')::date, hoy);
  exception when others then raise exception 'La fecha debe tener formato AAAA-MM-DD' using errcode = '22023'; end;
  if f < hoy - 370 or f > hoy + 1 then
    raise exception 'La fecha está fuera de rango (máximo 1 año atrás)' using errcode = '22023';
  end if;

  if tabla = 'ventas' then
    ef := public._api_num(dato, 'efectivo'); ta := public._api_num(dato, 'tarjeta');
    tr := public._api_num(dato, 'transf');   ap := public._api_num(dato, 'apps');
    if ef + ta + tr + ap <= 0 then
      raise exception 'Ingresa al menos un valor de venta (efectivo, tarjeta, transf o apps)' using errcode = '22023';
    end if;
    fila := jsonb_build_object('id', nid, 'fecha', f::text, 'efectivo', ef, 'tarjeta', ta, 'transf', tr, 'apps', ap,
      'propinas', public._api_num(dato, 'propinas'), 'tickets', floor(public._api_num(dato, 'tickets')),
      'contado', '',
      'nota', left(coalesce(dato->>'nota', ''), 200));
    if nullif(dato->>'contado', '') is not null then
      fila := jsonb_set(fila, '{contado}', to_jsonb(public._api_num(dato, 'contado')));
    end if;
    insert into public.ventas(id, fecha, data, negocio_id) values (nid, f, fila, r.negocio);
  elsif tabla = 'gastos' then
    mo := public._api_num(dato, 'monto');
    if mo <= 0 then raise exception 'El monto debe ser mayor a 0' using errcode = '22023'; end if;
    cat := coalesce(nullif(dato->>'cat', ''), 'otros');
    if not (cat = any(cats)) then
      raise exception 'Categoría no válida. Use una de: %', array_to_string(cats, ', ') using errcode = '22023';
    end if;
    tipo := coalesce(nullif(dato->>'tipo', ''), case when cat = any(fijas) then 'fijo' else 'var' end);
    if tipo not in ('fijo', 'var') then raise exception 'tipo debe ser fijo o var' using errcode = '22023'; end if;
    est := coalesce(nullif(dato->>'estado', ''), 'pagado');
    if est not in ('pagado', 'pendiente') then raise exception 'estado debe ser pagado o pendiente' using errcode = '22023'; end if;
    met := coalesce(nullif(dato->>'metodo', ''), 'Efectivo');
    if not (met = any(metodos)) then raise exception 'Medio de pago no válido. Use: %', array_to_string(metodos, ', ') using errcode = '22023'; end if;
    if est = 'pendiente' then
      begin vence := coalesce(nullif(dato->>'vence', '')::date, f)::text;
      exception when others then raise exception 'vence debe tener formato AAAA-MM-DD' using errcode = '22023'; end;
    else vence := ''; end if;
    fila := jsonb_build_object('id', nid, 'fecha', f::text, 'cat', cat, 'tipo', tipo,
      'proveedor', left(coalesce(dato->>'proveedor', ''), 120), 'desc', left(coalesce(dato->>'desc', ''), 200),
      'monto', mo, 'estado', est, 'vence', vence, 'metodo', met);
    insert into public.gastos(id, fecha, data, negocio_id) values (nid, f, fila, r.negocio);
  else
    raise exception 'Solo se puede registrar en ventas o gastos' using errcode = '22023';
  end if;
  return fila;
end
$$;

grant execute on function public.api_info(text), public.api_config(text),
  public.api_listar(text, text, date, date, int), public.api_registrar(text, text, jsonb) to anon, authenticated;
