-- ============================================================================
-- INICIO DE SESIÓN (OAuth 2.1) PARA EL MCP: ChatGPT, Claude y otras apps se conectan
-- con "Permitir acceso" (sin copiar claves). Cada conexión queda ligada al negocio de
-- quien la autoriza (solo un DUEÑO puede autorizar) y se puede revocar desde la app.
-- Se aplica sola al publicar (ver docs/ACTUALIZACIONES.md).
-- Los códigos y tokens nunca se guardan en texto: solo su huella (SHA-256).
-- ============================================================================

create table if not exists public.oauth_clientes (
  client_id text primary key,
  nombre text not null check (char_length(nombre) between 1 and 80),
  redirect_uris text[] not null check (array_length(redirect_uris, 1) between 1 and 10),
  creado timestamptz not null default now()
);
create table if not exists public.oauth_codigos (
  hash text primary key,
  client_id text not null references public.oauth_clientes(client_id) on delete cascade,
  user_id uuid not null,
  negocio uuid not null,
  permiso text not null check (permiso in ('lectura','escritura')),
  redirect_uri text not null,
  code_challenge text not null,
  expira timestamptz not null,
  usado boolean not null default false
);
create table if not exists public.oauth_tokens (
  hash text primary key,
  tipo text not null check (tipo in ('access','refresh')),
  grupo uuid not null,
  client_id text not null references public.oauth_clientes(client_id) on delete cascade,
  user_id uuid not null,
  negocio uuid not null,
  permiso text not null check (permiso in ('lectura','escritura')),
  creado timestamptz not null default now(),
  expira timestamptz not null,
  ultimo_uso timestamptz,
  revocada boolean not null default false
);
create index if not exists oauth_tokens_negocio_idx on public.oauth_tokens(negocio);
create index if not exists oauth_tokens_grupo_idx on public.oauth_tokens(grupo);

-- Solo las funciones de abajo (security definer) tocan estas tablas
alter table public.oauth_clientes enable row level security;
alter table public.oauth_codigos enable row level security;
alter table public.oauth_tokens enable row level security;
revoke all on public.oauth_clientes, public.oauth_codigos, public.oauth_tokens from anon, authenticated;

-- ---------- Ayudas internas ----------
create or replace function public._sha(t text) returns text
language sql immutable set search_path = public as
$$ select encode(sha256(convert_to(t, 'UTF8')), 'hex') $$;
create or replace function public._oauth_rand(prefijo text) returns text
language sql volatile set search_path = public as
$$ select prefijo || replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') $$;
revoke all on function public._sha(text), public._oauth_rand(text) from public, anon, authenticated;

-- Crea un par access (1 hora) + refresh (30 días) para un "grupo" de autorización
create or replace function public._oauth_emitir(p_grupo uuid, p_client text, p_user uuid, p_negocio uuid, p_permiso text) returns jsonb
language plpgsql security definer set search_path = public as
$$
declare acc text := public._oauth_rand('rst_'); ref text := public._oauth_rand('rsr_');
begin
  insert into public.oauth_tokens(hash, tipo, grupo, client_id, user_id, negocio, permiso, expira)
  values (public._sha(acc), 'access', p_grupo, p_client, p_user, p_negocio, p_permiso, now() + interval '1 hour'),
         (public._sha(ref), 'refresh', p_grupo, p_client, p_user, p_negocio, p_permiso, now() + interval '30 days');
  return jsonb_build_object('access_token', acc, 'token_type', 'Bearer', 'expires_in', 3600,
                            'refresh_token', ref, 'scope', 'restaurante');
end
$$;
revoke all on function public._oauth_emitir(uuid, text, uuid, uuid, text) from public, anon, authenticated;

-- ---------- 1) Registro dinámico de la app que se conecta (ChatGPT, Claude…) ----------
create or replace function public.oauth_registrar(p_nombre text, p_redirect_uris text[]) returns jsonb
language plpgsql security definer set search_path = public as
$$
declare u text; cid text;
begin
  if p_nombre is null or char_length(btrim(p_nombre)) not between 1 and 80 then
    raise exception 'invalid_client_metadata: client_name requerido (máx. 80 caracteres)' using errcode = '22023';
  end if;
  if p_redirect_uris is null or coalesce(array_length(p_redirect_uris, 1), 0) not between 1 and 10 then
    raise exception 'invalid_redirect_uri: se requieren entre 1 y 10 redirect_uris' using errcode = '22023';
  end if;
  foreach u in array p_redirect_uris loop
    if char_length(u) > 500 or not (u ~ '^https://[^\s#]+$' or u ~ '^http://(localhost|127\.0\.0\.1)(:[0-9]+)?(/[^\s#]*)?$') then
      raise exception 'invalid_redirect_uri: solo https (o http://localhost)' using errcode = '22023';
    end if;
  end loop;
  -- limpieza y tope para que nadie pueda llenar la tabla
  delete from public.oauth_clientes c where c.creado < now() - interval '30 days'
    and not exists (select 1 from public.oauth_tokens t where t.client_id = c.client_id);
  if (select count(*) from public.oauth_clientes) >= 5000 then
    raise exception 'invalid_client_metadata: demasiados registros, intenta más tarde' using errcode = '22023';
  end if;
  cid := public._oauth_rand('rc_');
  insert into public.oauth_clientes(client_id, nombre, redirect_uris) values (cid, btrim(p_nombre), p_redirect_uris);
  return jsonb_build_object('client_id', cid, 'client_name', btrim(p_nombre), 'redirect_uris', to_jsonb(p_redirect_uris));
end
$$;

create or replace function public.oauth_cliente(p_client text) returns jsonb
language sql security definer stable set search_path = public as
$$ select jsonb_build_object('nombre', nombre, 'redirect_uris', to_jsonb(redirect_uris)) from public.oauth_clientes where client_id = p_client $$;

-- ---------- 2) El dueño pulsa "Permitir" (lo llama la página de autorización, con su sesión) ----------
create or replace function public.oauth_aprobar(p_client text, p_redirect text, p_challenge text, p_permiso text) returns text
language plpgsql security definer set search_path = public as
$$
declare c public.oauth_clientes%rowtype; neg uuid; code text;
begin
  if auth.uid() is null or not public.es_dueno() then
    raise exception 'Solo el dueño del negocio puede autorizar conexiones' using errcode = '42501';
  end if;
  -- Mientras "API y MCP" esté en Beta, solo el administrador puede conectar
  if not (public.es_admin() or exists(select 1 from public.funciones where clave = 'api' and estado = 'publicada')) then
    raise exception 'Esta función todavía no está habilitada para tu cuenta' using errcode = '42501';
  end if;
  select * into c from public.oauth_clientes where client_id = p_client;
  if not found then raise exception 'La aplicación no está registrada' using errcode = '22023'; end if;
  if not (p_redirect = any(c.redirect_uris)) then raise exception 'redirect_uri no coincide con el registrado' using errcode = '22023'; end if;
  if p_challenge is null or p_challenge !~ '^[A-Za-z0-9_-]{43,128}$' then raise exception 'code_challenge inválido (se requiere PKCE S256)' using errcode = '22023'; end if;
  if p_permiso not in ('lectura', 'escritura') then raise exception 'permiso inválido' using errcode = '22023'; end if;
  neg := public.mi_negocio();
  code := public._oauth_rand('rco_');
  insert into public.oauth_codigos(hash, client_id, user_id, negocio, permiso, redirect_uri, code_challenge, expira)
  values (public._sha(code), p_client, auth.uid(), neg, p_permiso, p_redirect, p_challenge, now() + interval '5 minutes');
  return code;
end
$$;

-- ---------- 3) La app cambia el código por tokens (PKCE) ----------
create or replace function public.oauth_canjear(p_client text, p_code text, p_redirect text, p_verifier text) returns jsonb
language plpgsql security definer set search_path = public as
$$
declare r public.oauth_codigos%rowtype; calc text;
begin
  if p_code is null or p_verifier is null or p_verifier !~ '^[A-Za-z0-9._~-]{43,128}$' then
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'solicitud inválida');
  end if;
  -- El código se quema en el primer intento (bueno o malo). Los fallos de aquí en adelante se
  -- DEVUELVEN como {"error":...} (no se lanzan) para que el cambio no se revierta.
  update public.oauth_codigos set usado = true where hash = public._sha(p_code) and not usado returning * into r;
  if not found then return jsonb_build_object('error', 'invalid_grant', 'error_description', 'código inválido o ya usado'); end if;
  if r.expira < now() or r.client_id <> p_client or r.redirect_uri <> p_redirect then
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'código vencido o no coincide');
  end if;
  calc := translate(rtrim(encode(sha256(convert_to(p_verifier, 'UTF8')), 'base64'), '='), '+/', '-_');
  if calc <> r.code_challenge then return jsonb_build_object('error', 'invalid_grant', 'error_description', 'verificación PKCE fallida'); end if;
  -- el dueño debe seguir siéndolo
  if not exists(select 1 from public.perfiles where id = r.user_id and negocio = r.negocio and rol = 'dueno') then
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'el usuario ya no es dueño del negocio');
  end if;
  return public._oauth_emitir(gen_random_uuid(), r.client_id, r.user_id, r.negocio, r.permiso);
end
$$;

-- ---------- 4) Renovar el acceso con el refresh token (se rota en cada uso) ----------
create or replace function public.oauth_renovar(p_client text, p_refresh text) returns jsonb
language plpgsql security definer set search_path = public as
$$
declare r public.oauth_tokens%rowtype;
begin
  if p_refresh is null or p_refresh !~ '^rsr_[a-f0-9]{64}$' then return jsonb_build_object('error', 'invalid_grant', 'error_description', 'token inválido'); end if;
  select * into r from public.oauth_tokens where hash = public._sha(p_refresh) and tipo = 'refresh';
  if not found or r.client_id <> p_client then return jsonb_build_object('error', 'invalid_grant', 'error_description', 'token inválido'); end if;
  if r.revocada then
    -- reutilización de un token ya rotado: se corta toda la autorización (el cambio SÍ se guarda)
    update public.oauth_tokens set revocada = true where grupo = r.grupo;
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'token ya usado: la autorización fue revocada por seguridad');
  end if;
  if r.expira < now() then return jsonb_build_object('error', 'invalid_grant', 'error_description', 'token vencido'); end if;
  if not exists(select 1 from public.perfiles where id = r.user_id and negocio = r.negocio and rol = 'dueno') then
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'el usuario ya no es dueño del negocio');
  end if;
  update public.oauth_tokens set revocada = true where hash = r.hash;
  update public.oauth_tokens set revocada = true where grupo = r.grupo and tipo = 'access';
  return public._oauth_emitir(r.grupo, r.client_id, r.user_id, r.negocio, r.permiso);
end
$$;

-- ---------- 5) Aplicaciones conectadas: ver y revocar (solo el dueño de ese negocio) ----------
create or replace function public.oauth_listar() returns jsonb
language plpgsql security definer set search_path = public as
$$
begin
  if auth.uid() is null or not public.es_dueno() then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(x order by x->>'creado' desc) from (
    select jsonb_build_object('grupo', t.grupo, 'cliente', c.nombre, 'permiso', t.permiso, 'creado', min(t.creado),
             'ultimo_uso', max(t.ultimo_uso)) as x
      from public.oauth_tokens t join public.oauth_clientes c on c.client_id = t.client_id
     where t.negocio = public.mi_negocio() and t.tipo = 'refresh' and not t.revocada and t.expira > now()
     group by t.grupo, c.nombre, t.permiso) s), '[]'::jsonb);
end
$$;
create or replace function public.oauth_revocar(p_grupo uuid) returns void
language plpgsql security definer set search_path = public as
$$
begin
  if auth.uid() is null or not public.es_dueno() then raise exception 'Solo el dueño puede revocar' using errcode = '42501'; end if;
  update public.oauth_tokens set revocada = true where grupo = p_grupo and negocio = public.mi_negocio();
end
$$;

-- ---------- 6) El MCP/API también acepta tokens de inicio de sesión (rst_...) ----------
create or replace function public._api_auth(k text) returns public.api_keys
language plpgsql security definer set search_path = public as
$$
declare r public.api_keys; t public.oauth_tokens%rowtype;
begin
  if k is not null and k ~ '^rst_[a-f0-9]{64}$' then
    select * into t from public.oauth_tokens
     where hash = public._sha(k) and tipo = 'access' and not revocada and expira > now();
    if not found or not exists(select 1 from public.perfiles where id = t.user_id and negocio = t.negocio and rol = 'dueno') then
      raise exception 'Clave de API inválida' using errcode = '28000';
    end if;
    if t.ultimo_uso is null or t.ultimo_uso < now() - interval '1 minute' then
      update public.oauth_tokens set ultimo_uso = now() where hash = t.hash;
    end if;
    r := (t.grupo, t.negocio, 'Inicio de sesión', left(k, 8), t.hash, t.permiso, t.creado, t.ultimo_uso, false)::public.api_keys;
    return r;
  end if;
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

grant execute on function public.oauth_registrar(text, text[]), public.oauth_cliente(text),
  public.oauth_canjear(text, text, text, text), public.oauth_renovar(text, text) to anon, authenticated;
grant execute on function public.oauth_aprobar(text, text, text, text), public.oauth_listar(),
  public.oauth_revocar(uuid) to authenticated;
