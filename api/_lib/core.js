// Utilidades compartidas de la API y del MCP (la carpeta _lib no se publica como ruta).
// La seguridad vive en la base de datos: cada clave solo ve los datos de su negocio (ver migracion-api.sql).

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://wgjehfpwhxmefhnabrts.supabase.co';
// La "anon key" es pública por diseño (también está en config.js). Sola no da acceso a nada.
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'sb_publishable_NqHh8ZYdhGR_Vmmveb1K_w_Dn4CP6rT';

class ApiError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

// Llama a una función de la base de datos (RPC) con la clave de API del cliente
async function rpc(fn, args) {
  const headers = { apikey: SUPABASE_ANON_KEY, 'Content-Type': 'application/json' };
  if (!SUPABASE_ANON_KEY.startsWith('sb_')) headers.Authorization = 'Bearer ' + SUPABASE_ANON_KEY;
  let r;
  try {
    r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers, body: JSON.stringify(args) });
  } catch (e) {
    throw new ApiError(502, 'No se pudo conectar con la base de datos.');
  }
  const txt = await r.text();
  let j = null;
  try { j = txt ? JSON.parse(txt) : null; } catch (e) { j = null; }
  if (r.ok) return j;
  const code = j && j.code, msg = (j && j.message) || '';
  if (code === '28000') throw new ApiError(401, 'Clave de API inválida o revocada.');
  if (code === '42501') throw new ApiError(403, msg || 'No tienes permiso para esta acción.');
  if (r.status >= 400 && r.status < 500 && code && /^(22|23|P0001)/.test(code)) throw new ApiError(400, msg);
  throw new ApiError(502, 'La base de datos no respondió como se esperaba.');
}

const reFecha = /^\d{4}-\d{2}-\d{2}$/;
const reMes = /^\d{4}-(0[1-9]|1[0-2])$/;
const hoyBogota = () => new Date(Date.now() - 5 * 3600e3).toISOString().slice(0, 10);
const mesActual = () => hoyBogota().slice(0, 7);
const addMes = (m, d) => { const [y, mo] = m.split('-').map(Number); const dt = new Date(Date.UTC(y, mo - 1 + d, 1)); return dt.getUTCFullYear() + '-' + String(dt.getUTCMonth() + 1).padStart(2, '0'); };
const diasMes = m => { const [y, mo] = m.split('-').map(Number); return new Date(Date.UTC(y, mo, 0)).getUTCDate(); };

function validarFecha(v, nombre) {
  if (v == null || v === '') return null;
  if (!reFecha.test(String(v))) throw new ApiError(400, `"${nombre}" debe tener formato AAAA-MM-DD.`);
  return String(v);
}
function validarLimite(v) {
  if (v == null || v === '') return 200;
  const n = Number(v);
  if (!Number.isInteger(n) || n < 1 || n > 1000) throw new ApiError(400, '"limite" debe ser un entero entre 1 y 1000.');
  return n;
}

// ---- Resumen del mes: misma fórmula que la pantalla Panel de la app ----
const CATS = { insumos: ['var', 1], bebidas: ['var', 1], empaques: ['var', 0], gas: ['var', 0], comisiones: ['var', 0], nomina: ['fijo', 0], arriendo: ['fijo', 0], servicios: ['fijo', 0], marketing: ['fijo', 0], mant: ['fijo', 0], impuestos: ['fijo', 0], financiero: ['fijo', 0], otros: ['var', 0] };
const num = v => Number(v) || 0;
const sum = (a, f) => a.reduce((s, x) => s + (Number(f(x)) || 0), 0);
const r0 = x => Math.round(x);

function resumen(mes, ventas, gastos, cfg, inv) {
  cfg = cfg || {}; inv = inv || {};
  const vs = ventas.filter(v => String(v.fecha).slice(0, 7) === mes), gs = gastos.filter(g => String(g.fecha).slice(0, 7) === mes);
  const efectivo = sum(vs, v => v.efectivo), tarjeta = sum(vs, v => v.tarjeta), transf = sum(vs, v => v.transf), apps = sum(vs, v => v.apps);
  const bruto = efectivo + tarjeta + transf + apps, propinas = sum(vs, v => v.propinas), tickets = sum(vs, v => v.tickets);
  const r = num(cfg.inc) / 100, k = cfg.incIncluido && r > 0 ? 1 / (1 + r) : 1;
  const neta = bruto * k, impuesto = bruto - neta;
  const esCogs = g => CATS[g.cat] && CATS[g.cat][1];
  const compras = sum(gs.filter(esCogs), g => g.monto);
  const ini = inv[addMes(mes, -1)], fin = inv[mes];
  const hasInv = ini !== undefined && fin !== undefined;
  const cogs = hasInv ? compras + num(ini) - num(fin) : compras;
  const opex = gs.filter(g => !esCogs(g));
  const fijos = sum(opex.filter(g => g.tipo === 'fijo'), g => g.monto), varOp = sum(opex.filter(g => g.tipo !== 'fijo'), g => g.monto);
  const comis = tarjeta * num(cfg.comTarjeta) / 100 + apps * num(cfg.comApps) / 100;
  const utilBruta = neta - cogs, utilOp = utilBruta - fijos - varOp - comis;
  const margen = neta > 0 ? utilOp / neta : 0, food = neta > 0 ? cogs / neta : 0;
  const vr = neta > 0 ? (cogs + varOp + comis) / neta : num(cfg.metaFood) / 100;
  const be = vr < 1 ? fijos / (1 - vr) : null;
  const porCat = {}; gs.forEach(g => { porCat[g.cat] = (porCat[g.cat] || 0) + num(g.monto); });
  Object.keys(porCat).forEach(c => porCat[c] = r0(porCat[c]));
  return {
    mes, moneda: cfg.moneda || 'COP',
    ventas: { brutas: r0(bruto), netas_sin_impuesto: r0(neta), impuesto: r0(impuesto), efectivo: r0(efectivo), tarjeta: r0(tarjeta), transferencias: r0(transf), apps: r0(apps), propinas_no_son_ingreso: r0(propinas), cuentas: r0(tickets), registros: vs.length },
    gastos: { total: r0(sum(gs, g => g.monto)), por_categoria: porCat, fijos: r0(fijos), variables: r0(varOp), compras_de_comida_y_bebida: r0(compras), registros: gs.length, pendientes_de_pago: r0(sum(gs.filter(g => g.estado === 'pendiente'), g => g.monto)) },
    costo_de_ventas: r0(cogs), costo_de_ventas_usa_inventario: hasInv, comisiones: r0(comis),
    utilidad_bruta: r0(utilBruta), utilidad_operativa: r0(utilOp),
    margen_porcentaje: Math.round(margen * 1000) / 10, costo_de_ventas_porcentaje: Math.round(food * 1000) / 10,
    punto_de_equilibrio: be === null ? null : r0(be)
  };
}

async function resumenMes(key, mes) {
  mes = mes || mesActual();
  if (!reMes.test(mes)) throw new ApiError(400, '"mes" debe tener formato AAAA-MM.');
  const desde = mes + '-01', hasta = mes + '-' + String(diasMes(mes)).padStart(2, '0');
  const [ventas, gastos, conf] = await Promise.all([
    rpc('api_listar', { k: key, tabla: 'ventas', desde, hasta, lim: 1000 }),
    rpc('api_listar', { k: key, tabla: 'gastos', desde, hasta, lim: 1000 }),
    rpc('api_config', { k: key })
  ]);
  const out = resumen(mes, ventas, gastos, conf.cfg, conf.inv);
  if (ventas.length >= 1000 || gastos.length >= 1000) out.aviso = 'Se alcanzó el límite de 1000 registros: el resumen puede estar incompleto.';
  return out;
}

// ---- Operaciones compartidas por la API REST y el MCP ----
const ops = {
  info: key => rpc('api_info', { k: key }),
  resumen: (key, a) => resumenMes(key, a && a.mes),
  listar: (key, tabla, a) => rpc('api_listar', { k: key, tabla, desde: validarFecha(a && a.desde, 'desde'), hasta: validarFecha(a && a.hasta, 'hasta'), lim: validarLimite(a && a.limite) }),
  catalogo: (key, tipo) => {
    if (tipo !== 'platos' && tipo !== 'insumos') throw new ApiError(400, '"tipo" debe ser platos o insumos.');
    return rpc('api_listar', { k: key, tabla: tipo, lim: 1000 });
  },
  registrar: (key, tabla, dato) => {
    if (!dato || typeof dato !== 'object' || Array.isArray(dato)) throw new ApiError(400, 'El cuerpo debe ser un objeto JSON.');
    return rpc('api_registrar', { k: key, tabla, dato });
  }
};

// ---- Envoltorio HTTP: CORS, método, clave y errores ----
function cors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type, X-API-Key, Mcp-Session-Id, Mcp-Protocol-Version');
  res.setHeader('Cache-Control', 'no-store');
}
function claveDe(req) {
  const h = req.headers || {};
  const a = String(h.authorization || '');
  if (/^bearer /i.test(a)) return a.slice(7).trim();
  return String(h['x-api-key'] || '').trim();
}
function cuerpo(req) {
  if (req.body == null || req.body === '') return {};
  if (typeof req.body === 'string') { try { return JSON.parse(req.body); } catch (e) { throw new ApiError(400, 'El cuerpo no es un JSON válido.'); } }
  return req.body;
}
function endpoint(metodos, fn, { publico = false } = {}) {
  return async (req, res) => {
    cors(res);
    if (req.method === 'OPTIONS') return res.status(204).end();
    if (!metodos.includes(req.method)) { res.setHeader('Allow', metodos.join(', ')); return res.status(405).json({ error: 'Método no permitido.' }); }
    try {
      const key = claveDe(req);
      if (!publico && !key) { res.setHeader('WWW-Authenticate', 'Bearer'); return res.status(401).json({ error: 'Falta la clave de API. Envíala como "Authorization: Bearer rsk_..."' }); }
      const data = await fn({ key, req });
      return res.status(200).json(data);
    } catch (e) {
      if (e instanceof ApiError) { if (e.status === 401) res.setHeader('WWW-Authenticate', 'Bearer'); return res.status(e.status).json({ error: e.message }); }
      return res.status(500).json({ error: 'Error interno.' });
    }
  };
}

module.exports = { ApiError, rpc, ops, endpoint, cors, claveDe, cuerpo, resumen, mesActual };
