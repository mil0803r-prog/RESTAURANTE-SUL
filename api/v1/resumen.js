const { endpoint, ops } = require('../_lib/core');
module.exports = endpoint(['GET'], ({ key, req }) => ops.resumen(key, { mes: req.query && req.query.mes }));
