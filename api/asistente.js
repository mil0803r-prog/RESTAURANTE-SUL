// Asistente financiero (Vercel Serverless Function).
// Variables de entorno requeridas en Vercel: ANTHROPIC_API_KEY, SUPABASE_URL, SUPABASE_ANON_KEY.
// Solo responde a usuarios con sesión de Supabase y rol "dueno".

const SYSTEM = `Eres el asistente financiero de un restaurante. Hablas en español claro y cercano, sin jerga.
Respondes SOLO con los datos del contexto JSON que recibes (cifras del restaurante). Si algo no está en los datos, dilo y sugiere qué registrar para poder responder. No inventes cifras.
Sé concreto y accionable: da la cifra, explica en una frase qué significa y propone 1 a 3 acciones prácticas (precios, porciones, compras, horarios, pagos).
Usa la moneda indicada en el contexto, con separador de miles. Respuestas cortas (máximo ~150 palabras), con viñetas cuando ayude.
No des asesoría tributaria o legal definitiva: si preguntan por impuestos o prestaciones, orienta y recomienda confirmar con su contador.`;

module.exports = async (req, res) => {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Método no permitido.' });

  const { ANTHROPIC_API_KEY, SUPABASE_URL, SUPABASE_ANON_KEY } = process.env;
  if (!ANTHROPIC_API_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return res.status(503).json({ error: 'El asistente aún no está configurado en el servidor (faltan variables de entorno).' });
  }

  const auth = req.headers.authorization || '';
  if (!auth.startsWith('Bearer ')) return res.status(401).json({ error: 'Inicia sesión para usar el asistente.' });

  try {
    const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SUPABASE_ANON_KEY, Authorization: auth } });
    if (!u.ok) return res.status(401).json({ error: 'Tu sesión expiró. Vuelve a entrar.' });
    const user = await u.json();

    const p = await fetch(`${SUPABASE_URL}/rest/v1/perfiles?id=eq.${encodeURIComponent(user.id)}&select=rol`, {
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: auth }
    });
    const rows = await p.json();
    if (!Array.isArray(rows) || !rows[0] || rows[0].rol !== 'dueno') {
      return res.status(403).json({ error: 'El asistente es solo para el dueño.' });
    }

    const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
    const pregunta = String(body.pregunta || '').slice(0, 600).trim();
    if (!pregunta) return res.status(400).json({ error: 'Escribe una pregunta.' });
    const contexto = JSON.stringify(body.contexto || {}).slice(0, 14000);

    // Historial: alternar roles y empezar siempre con "user"
    const hist = [];
    for (const m of Array.isArray(body.historial) ? body.historial.slice(-8) : []) {
      const role = m && m.role === 'assistant' ? 'assistant' : 'user';
      const content = String((m && m.content) || '').slice(0, 1500);
      if (!content) continue;
      if (!hist.length && role === 'assistant') continue;
      if (hist.length && hist[hist.length - 1].role === role) hist[hist.length - 1].content += '\n' + content;
      else hist.push({ role, content });
    }
    const last = `Datos actuales del restaurante (JSON):\n${contexto}\n\nPregunta del dueño: ${pregunta}`;
    if (hist.length && hist[hist.length - 1].role === 'user') hist[hist.length - 1].content += '\n\n' + last;
    else hist.push({ role: 'user', content: last });

    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'claude-haiku-5-5', max_tokens: 700, system: SYSTEM, messages: hist })
    });
    const j = await r.json();
    if (!r.ok) return res.status(502).json({ error: 'El servicio de IA no respondió. Intenta de nuevo en un momento.' });
    const texto = (j.content || []).filter(b => b.type === 'text').map(b => b.text).join('\n').trim();
    return res.status(200).json({ respuesta: texto });
  } catch (e) {
    return res.status(500).json({ error: 'Ocurrió un error al consultar el asistente.' });
  }
};
