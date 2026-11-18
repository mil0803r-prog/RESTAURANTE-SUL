const { endpoint, ops, cuerpo } = require('../_lib/core');
module.exports = endpoint(['GET', 'POST'], async ({ key, req }) =>
  req.method === 'POST' ? { creada: await ops.registrar(key, 'ventas', cuerpo(req)) } : ops.listar(key, 'ventas', req.query || {}));
