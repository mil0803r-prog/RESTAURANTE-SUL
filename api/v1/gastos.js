const { endpoint, ops, cuerpo } = require('../_lib/core');
module.exports = endpoint(['GET', 'POST'], async ({ key, req }) =>
  req.method === 'POST' ? { creado: await ops.registrar(key, 'gastos', cuerpo(req)) } : ops.listar(key, 'gastos', req.query || {}));
