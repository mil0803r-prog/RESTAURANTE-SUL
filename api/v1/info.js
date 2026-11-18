const { endpoint, ops } = require('../_lib/core');
module.exports = endpoint(['GET'], ({ key }) => ops.info(key));
