// Inicio de sesión OAuth 2.1 para el MCP (ChatGPT, Claude y otras apps).
// Una sola función con varias rutas (ver vercel.json):
//   /.well-known/oauth-protected-resource  -> a=recurso   (dónde está el servidor de autorización)
//   /.well-known/oauth-authorization-server -> a=metadata (endpoints)
//   POST /oauth/register                    -> a=register (registro dinámico del cliente)
//   POST /oauth/token                       -> a=token    (código/refresh -> tokens, con PKCE)
// La pantalla "Permitir acceso" es /oauth/authorize (public/oauth/authorize.html).
// Toda la lógica de seguridad vive en la base de datos (migraciones/005_oauth.sql).

const { ApiError, rpc, cors, origen } = require('./_lib/core');

const jsonOAuth = (res, status, obj) => { res.setHeader('Cache-Control', 'no-store'); res.setHeader('Pragma', 'no-cache'); return res.status(status).json(obj); };
const errOAuth = (res, status, error, desc) => jsonOAuth(res, status, { error, error_description: desc });

function cuerpoForm(req) {
  const b = req.body;
  if (b == null || b === '') return {};
  if (typeof b === 'string') {
    try { return JSON.parse(b); } catch (e) { return Object.fromEntries(new URLSearchParams(b)); }
  }
  return b;
}

function metadataRecurso(req) {
  const o = origen(req);
  return { resource: `${o}/api/mcp`, authorization_servers: [o], bearer_methods_supported: ['header'], scopes_supported: ['restaurante'], resource_name: 'Restaurante' };
}
function metadataServidor(req) {
  const o = origen(req);
  return {
    issuer: o,
    authorization_endpoint: `${o}/oauth/authorize`,
    token_endpoint: `${o}/oauth/token`,
    registration_endpoint: `${o}/oauth/register`,
    response_types_supported: ['code'],
    grant_types_supported: ['authorization_code', 'refresh_token'],
    code_challenge_methods_supported: ['S256'],
    token_endpoint_auth_methods_supported: ['none'],
    scopes_supported: ['restaurante']
  };
}

async function registrar(req, res) {
  const b = cuerpoForm(req);
  const nombre = typeof b.client_name === 'string' ? b.client_name : '';
  const uris = Array.isArray(b.redirect_uris) ? b.redirect_uris.filter(u => typeof u === 'string') : [];
  try {
    const r = await rpc('oauth_registrar', { p_nombre: nombre, p_redirect_uris: uris });
    return jsonOAuth(res, 201, {
      client_id: r.client_id, client_name: r.client_name, redirect_uris: r.redirect_uris,
      token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'],
      client_id_issued_at: Math.floor(Date.now() / 1000)
    });
  } catch (e) {
    if (e instanceof ApiError && e.status === 400) {
      const m = String(e.message);
      return errOAuth(res, 400, /^invalid_redirect_uri/.test(m) ? 'invalid_redirect_uri' : 'invalid_client_metadata', m.replace(/^[a-z_]+:\s*/, ''));
    }
    throw e;
  }
}

async function token(req, res) {
  const b = cuerpoForm(req);
  let r;
  try {
    if (b.grant_type === 'authorization_code') {
      if (!b.client_id || !b.code || !b.redirect_uri || !b.code_verifier) return errOAuth(res, 400, 'invalid_request', 'Faltan parámetros: client_id, code, redirect_uri y code_verifier.');
      r = await rpc('oauth_canjear', { p_client: String(b.client_id), p_code: String(b.code), p_redirect: String(b.redirect_uri), p_verifier: String(b.code_verifier) });
    } else if (b.grant_type === 'refresh_token') {
      if (!b.client_id || !b.refresh_token) return errOAuth(res, 400, 'invalid_request', 'Faltan parámetros: client_id y refresh_token.');
      r = await rpc('oauth_renovar', { p_client: String(b.client_id), p_refresh: String(b.refresh_token) });
    } else {
      return errOAuth(res, 400, 'unsupported_grant_type', 'Usa authorization_code o refresh_token.');
    }
  } catch (e) {
    if (e instanceof ApiError && e.status === 400) return errOAuth(res, 400, 'invalid_request', e.message);
    throw e;
  }
  if (r && r.error) return errOAuth(res, 400, r.error, r.error_description || '');
  return jsonOAuth(res, 200, r);
}

module.exports = async (req, res) => {
  cors(res);
  res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type, Mcp-Protocol-Version');
  if (req.method === 'OPTIONS') return res.status(204).end();
  const a = String((req.query && req.query.a) || '');
  try {
    if (a === 'recurso' || a === 'metadata') {
      if (req.method !== 'GET') { res.setHeader('Allow', 'GET, OPTIONS'); return res.status(405).json({ error: 'Usa GET.' }); }
      res.setHeader('Cache-Control', 'public, max-age=300');
      return res.status(200).json(a === 'recurso' ? metadataRecurso(req) : metadataServidor(req));
    }
    if (a === 'register' || a === 'token') {
      if (req.method !== 'POST') { res.setHeader('Allow', 'POST, OPTIONS'); return res.status(405).json({ error: 'Usa POST.' }); }
      return a === 'register' ? await registrar(req, res) : await token(req, res);
    }
    return res.status(404).json({ error: 'No encontrado.' });
  } catch (e) {
    if (e instanceof ApiError) return errOAuth(res, e.status >= 500 ? 502 : e.status, 'server_error', e.message);
    return errOAuth(res, 500, 'server_error', 'Error interno.');
  }
};
