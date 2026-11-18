// Aplica automáticamente las migraciones de la carpeta /migraciones a la base de datos (Supabase).
// Corre en cada publicación en Vercel (antes de que la nueva versión salga al aire).
//  - Cada archivo se ejecuta UNA sola vez, en orden (001, 002, ...), dentro de una transacción.
//  - Si uno falla, no se aplica nada de ese archivo, la publicación se detiene y la versión anterior sigue funcionando.
//  - Solo corre en PRODUCCIÓN (las vistas previas de ramas no tocan la base de datos real).
// Requiere la variable de entorno DATABASE_URL (cadena de conexión de Supabase). Nunca se imprime.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DIR = path.join(__dirname, '..', 'migraciones');
const log = (...a) => console.log('[migraciones]', ...a);

async function main() {
  const env = process.env.VERCEL_ENV; // 'production' | 'preview' | 'development' (solo existe en Vercel)
  if (env && env !== 'production') { log(`Entorno "${env}": no se toca la base de datos.`); return 0; }
  const url = process.env.DATABASE_URL;
  if (!url) {
    log('⚠️  Falta la variable DATABASE_URL: NO se aplicaron migraciones. Configúrala en Vercel → Settings → Environment Variables (ver docs/ACTUALIZACIONES.md).');
    return 0;
  }
  const { Client } = require('pg');
  const local = /@(localhost|127\.0\.0\.1)|host=\/|%2F/.test(url) || url.includes('host=/');
  const c = new Client({ connectionString: url, ssl: local ? false : { rejectUnauthorized: false }, connectionTimeoutMillis: 20000 });
  try { await c.connect(); } catch (e) { log('❌ No se pudo conectar a la base de datos:', e.code || e.message.split('\n')[0]); return 1; }

  const archivos = fs.readdirSync(DIR).filter(f => /^\d+_.+\.sql$/.test(f)).sort();
  try {
    await c.query('select pg_advisory_lock(727274)');
    await c.query(`create table if not exists public.migraciones (
      nombre text primary key, checksum text not null, aplicada timestamptz not null default now())`);
    await c.query('alter table public.migraciones enable row level security');
    await c.query('revoke all on public.migraciones from anon, authenticated');

    const hechas = new Map((await c.query('select nombre, checksum from public.migraciones')).rows.map(r => [r.nombre, r.checksum]));
    const sha = f => crypto.createHash('sha256').update(fs.readFileSync(path.join(DIR, f))).digest('hex');

    // Base de datos que ya existía antes de este sistema: la migración 001 ya está aplicada
    if (hechas.size === 0 && archivos.length) {
      const { rows } = await c.query("select to_regclass('public.perfiles') as t");
      if (rows[0].t) {
        await c.query('insert into public.migraciones(nombre, checksum) values ($1, $2)', [archivos[0], sha(archivos[0])]);
        hechas.set(archivos[0], sha(archivos[0]));
        log(`Base de datos existente: ${archivos[0]} se marca como ya aplicada.`);
      }
    }

    let n = 0;
    for (const f of archivos) {
      const huella = sha(f);
      if (hechas.has(f)) {
        if (hechas.get(f) !== huella) log(`⚠️  ${f} cambió después de aplicarse; no se vuelve a ejecutar. Crea una migración nueva para cambios.`);
        continue;
      }
      const sql = fs.readFileSync(path.join(DIR, f), 'utf8');
      log(`Aplicando ${f} …`);
      try {
        await c.query('begin');
        await c.query(sql);
        await c.query('insert into public.migraciones(nombre, checksum) values ($1, $2)', [f, huella]);
        await c.query('commit');
        n++; log(`✔ ${f}`);
      } catch (e) {
        await c.query('rollback').catch(() => {});
        log(`❌ Falló ${f}: ${String(e.message).split('\n')[0]}${e.position ? ' (posición ' + e.position + ')' : ''}`);
        log('No se aplicó nada de ese archivo. La publicación se detiene y la versión anterior sigue funcionando.');
        return 1;
      }
    }
    log(n ? `Listo: ${n} migración(es) aplicada(s).` : 'Base de datos al día: no hay migraciones nuevas.');
    return 0;
  } finally {
    await c.query('select pg_advisory_unlock(727274)').catch(() => {});
    await c.end().catch(() => {});
  }
}

main().then(code => process.exit(code)).catch(e => { console.error('[migraciones] Error inesperado:', String(e.message).split('\n')[0]); process.exit(1); });
