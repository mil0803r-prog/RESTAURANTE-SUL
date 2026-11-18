// Servidor MCP (Model Context Protocol) del restaurante, por HTTP sin estado.
// Se conecta iniciando sesión (OAuth: ChatGPT, Claude…) o con una clave: Authorization: Bearer rsk_...
const { ApiError, ops, cors, claveDe, cuerpo, exigirLogin } = require('./_lib/core');

const VERSION = '1.0.0';
const fechaProp = d => ({ type: 'string', description: d + ' (AAAA-MM-DD)' });

const TOOLS = [
  { name: 'resumen_mes', escribe: false, description: 'Resumen financiero de un mes: ventas, gastos por categoría, costo de ventas, utilidad operativa, margen y punto de equilibrio.',
    inputSchema: { type: 'object', properties: { mes: { type: 'string', description: 'Mes AAAA-MM. Por defecto el mes actual.' } } } },
  { name: 'listar_ventas', escribe: false, description: 'Lista las ventas registradas (más recientes primero).',
    inputSchema: { type: 'object', properties: { desde: fechaProp('Desde'), hasta: fechaProp('Hasta'), limite: { type: 'integer', minimum: 1, maximum: 1000, description: 'Por defecto 200' } } } },
  { name: 'listar_gastos', escribe: false, description: 'Lista los gastos y compras registrados (incluye los pendientes de pago).',
    inputSchema: { type: 'object', properties: { desde: fechaProp('Desde'), hasta: fechaProp('Hasta'), limite: { type: 'integer', minimum: 1, maximum: 1000 } } } },
  { name: 'listar_platos', escribe: false, description: 'Platos del restaurante con su precio y sus ingredientes.', inputSchema: { type: 'object', properties: {} } },
  { name: 'listar_insumos', escribe: false, description: 'Insumos con su unidad y costo.', inputSchema: { type: 'object', properties: {} } },
  { name: 'registrar_venta', escribe: true, description: 'Registra las ventas de un día. Indica al menos un valor entre efectivo, tarjeta, transf o apps.',
    inputSchema: { type: 'object', properties: { fecha: fechaProp('Día de la venta; por defecto hoy'), efectivo: { type: 'number' }, tarjeta: { type: 'number' }, transf: { type: 'number', description: 'Transferencias' }, apps: { type: 'number', description: 'Apps de domicilio' }, propinas: { type: 'number' }, tickets: { type: 'integer', description: 'Número de cuentas o clientes' }, contado: { type: 'number', description: 'Efectivo contado en caja' }, nota: { type: 'string' } } } },
  { name: 'registrar_gasto', escribe: true, description: 'Registra un gasto o compra.',
    inputSchema: { type: 'object', required: ['monto'], properties: { fecha: fechaProp('Fecha del gasto; por defecto hoy'), monto: { type: 'number' }, cat: { type: 'string', enum: ['insumos', 'bebidas', 'empaques', 'gas', 'comisiones', 'nomina', 'arriendo', 'servicios', 'marketing', 'mant', 'impuestos', 'financiero', 'otros'], description: 'Categoría (por defecto otros)' }, tipo: { type: 'string', enum: ['fijo', 'var'] }, proveedor: { type: 'string' }, desc: { type: 'string', description: 'Detalle' }, estado: { type: 'string', enum: ['pagado', 'pendiente'] }, vence: fechaProp('Vencimiento si está pendiente'), metodo: { type: 'string', enum: ['Efectivo', 'Transferencia', 'Tarjeta', 'Crédito con proveedor', 'Otro'] } } } }
];

const RUN = {
  resumen_mes: (k, a) => ops.resumen(k, a),
  listar_ventas: (k, a) => ops.listar(k, 'ventas', a),
  listar_gastos: (k, a) => ops.listar(k, 'gastos', a),
  listar_platos: k => ops.catalogo(k, 'platos'),
  listar_insumos: k => ops.catalogo(k, 'insumos'),
  registrar_venta: (k, a) => ops.registrar(k, 'ventas', a),
  registrar_gasto: (k, a) => ops.registrar(k, 'gastos', a)
};

const ok = (id, result) => ({ jsonrpc: '2.0', id, result });
const fail = (id, code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });

async function atender(msg, key) {
  if (!msg || msg.jsonrpc !== '2.0' || typeof msg.method !== 'string') return fail(msg && msg.id != null ? msg.id : null, -32600, 'Solicitud inválida');
  const { id, method } = msg, params = msg.params || {};
  if (id === undefined) return null; // notificación: sin respuesta
  try {
    if (method === 'initialize') {
      const info = await ops.info(key); // valida la clave desde el primer paso
      return ok(id, {
        protocolVersion: typeof params.protocolVersion === 'string' ? params.protocolVersion : '2025-03-26',
        capabilities: { tools: {} },
        serverInfo: { name: 'restaurante', version: VERSION },
        instructions: `Datos de ${info.nombre} (${info.moneda}). Clave con permiso de ${info.permiso}. Los montos están en ${info.moneda}.`
      });
    }
    if (method === 'ping') return ok(id, {});
    if (method === 'tools/list') {
      const info = await ops.info(key);
      return ok(id, { tools: TOOLS.filter(t => !t.escribe || info.permiso === 'escritura').map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) });
    }
    if (method === 'tools/call') {
      const run = RUN[params.name];
      if (!run) return fail(id, -32602, 'Herramienta desconocida: ' + params.name);
      try {
        const data = await run(key, params.arguments || {});
        return ok(id, { content: [{ type: 'text', text: JSON.stringify(data, null, 2) }], isError: false });
      } catch (e) {
        if (e instanceof ApiError && e.status === 401) throw e;
        return ok(id, { content: [{ type: 'text', text: e instanceof ApiError ? e.message : 'Error interno.' }], isError: true });
      }
    }
    return fail(id, -32601, 'Método no encontrado: ' + method);
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) throw e;
    return fail(id, -32603, e instanceof ApiError ? e.message : 'Error interno');
  }
}

module.exports = async (req, res) => {
  cors(res);
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') {
    // Sin credenciales, cualquier método responde 401 con la ubicación del inicio de sesión (así los clientes
    // como ChatGPT descubren el OAuth aunque sondeen primero con GET). Con credenciales: solo se admite POST.
    if (!claveDe(req)) { exigirLogin(req, res); return res.status(401).json({ jsonrpc: '2.0', id: null, error: { code: -32001, message: 'Inicia sesión (OAuth) o envía una clave de API (Authorization: Bearer ...)' } }); }
    res.setHeader('Allow', 'POST, OPTIONS'); return res.status(405).json({ error: 'Usa POST (MCP por HTTP).' });
  }
  try {
    const key = claveDe(req);
    if (!key) { exigirLogin(req, res); return res.status(401).json({ jsonrpc: '2.0', id: null, error: { code: -32001, message: 'Falta la clave de API (Authorization: Bearer rsk_...)' } }); }
    let body;
    try { body = cuerpo(req); } catch (e) { return res.status(400).json(fail(null, -32700, 'JSON inválido')); }
    if (Array.isArray(body)) {
      const out = (await Promise.all(body.map(m => atender(m, key)))).filter(x => x !== null);
      return out.length ? res.status(200).json(out) : res.status(202).end();
    }
    const out = await atender(body, key);
    return out === null ? res.status(202).end() : res.status(200).json(out);
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) { exigirLogin(req, res); return res.status(401).json({ jsonrpc: '2.0', id: null, error: { code: -32001, message: 'Clave de API inválida o revocada.' } }); }
    return res.status(500).json({ jsonrpc: '2.0', id: null, error: { code: -32603, message: 'Error interno' } });
  }
};
