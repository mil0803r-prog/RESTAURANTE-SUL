const { endpoint } = require('../_lib/core');

const err = { description: 'Error', content: { 'application/json': { schema: { type: 'object', properties: { error: { type: 'string' } } } } } };
const seg = [{ ApiKey: [] }];
const fechaQ = n => ({ name: n, in: 'query', schema: { type: 'string', format: 'date' }, description: 'AAAA-MM-DD' });

const spec = (origen) => ({
  openapi: '3.0.3',
  info: { title: 'Restaurante · API', version: '1.0.0', description: 'Consulta y registra ventas y gastos de tu restaurante. Cada clave solo ve los datos de su negocio. Las claves se crean en la app: Ajustes → Conexiones.' },
  servers: [{ url: origen + '/api/v1' }],
  components: { securitySchemes: { ApiKey: { type: 'http', scheme: 'bearer', description: 'Clave que empieza con rsk_' } } },
  security: seg,
  paths: {
    '/info': { get: { summary: 'Datos de la clave y del negocio', responses: { 200: { description: 'OK' }, 401: err } } },
    '/resumen': { get: { summary: 'Resumen financiero de un mes', parameters: [{ name: 'mes', in: 'query', schema: { type: 'string', example: '2026-11' }, description: 'AAAA-MM (por defecto, el mes actual)' }], responses: { 200: { description: 'OK' }, 401: err } } },
    '/ventas': {
      get: { summary: 'Listar ventas', parameters: [fechaQ('desde'), fechaQ('hasta'), { name: 'limite', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 1000, default: 200 } }], responses: { 200: { description: 'OK' }, 401: err } },
      post: { summary: 'Registrar una venta del día (requiere clave con permiso de escritura)', requestBody: { required: true, content: { 'application/json': { schema: { type: 'object', properties: { fecha: { type: 'string', format: 'date' }, efectivo: { type: 'number' }, tarjeta: { type: 'number' }, transf: { type: 'number' }, apps: { type: 'number' }, propinas: { type: 'number' }, tickets: { type: 'integer' }, contado: { type: 'number' }, nota: { type: 'string' } } } } } }, responses: { 200: { description: 'Creada' }, 400: err, 401: err, 403: err } }
    },
    '/gastos': {
      get: { summary: 'Listar gastos', parameters: [fechaQ('desde'), fechaQ('hasta'), { name: 'limite', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 1000, default: 200 } }], responses: { 200: { description: 'OK' }, 401: err } },
      post: { summary: 'Registrar un gasto (requiere clave con permiso de escritura)', requestBody: { required: true, content: { 'application/json': { schema: { type: 'object', required: ['monto'], properties: { fecha: { type: 'string', format: 'date' }, cat: { type: 'string', enum: ['insumos', 'bebidas', 'empaques', 'gas', 'comisiones', 'nomina', 'arriendo', 'servicios', 'marketing', 'mant', 'impuestos', 'financiero', 'otros'] }, tipo: { type: 'string', enum: ['fijo', 'var'] }, proveedor: { type: 'string' }, desc: { type: 'string' }, monto: { type: 'number' }, estado: { type: 'string', enum: ['pagado', 'pendiente'] }, vence: { type: 'string', format: 'date' }, metodo: { type: 'string', enum: ['Efectivo', 'Transferencia', 'Tarjeta', 'Crédito con proveedor', 'Otro'] } } } } } }, responses: { 200: { description: 'Creado' }, 400: err, 401: err, 403: err } }
    },
    '/catalogo': { get: { summary: 'Platos o insumos', parameters: [{ name: 'tipo', in: 'query', schema: { type: 'string', enum: ['platos', 'insumos'], default: 'platos' } }], responses: { 200: { description: 'OK' }, 401: err } } }
  }
});

module.exports = endpoint(['GET'], ({ req }) => {
  const h = req.headers || {};
  const host = h['x-forwarded-host'] || h.host || 'localhost';
  const proto = h['x-forwarded-proto'] || 'https';
  return spec(`${proto}://${host}`);
}, { publico: true });
