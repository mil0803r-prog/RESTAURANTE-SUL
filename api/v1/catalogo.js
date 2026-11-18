const { endpoint, ops } = require('../_lib/core');
module.exports = endpoint(['GET'], ({ key, req }) => ops.catalogo(key, (req.query && req.query.tipo) || 'platos'));
