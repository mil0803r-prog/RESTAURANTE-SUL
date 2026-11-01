# OmniRoute (herramienta local, no parte de la app)

Guía basada en "OmniRoute Paso a Paso" (CENTEIA Education, oct. 2026).

OmniRoute es un router gratuito y de código abierto (licencia MIT) que corre en **tu computador**
en `http://localhost:20128`. Conecta Claude Code, Cursor, Copilot, Codex, Cline u OpenCode a muchos
proveedores de modelos: cuando uno agota su cuota salta al siguiente, y además comprime los prompts.

> Esto NO se despliega con la app del restaurante ni se instala en Vercel/Supabase.
> Se ejecuta en tu máquina de desarrollo. Los scripts de esta carpeta son solo una ayuda.

## Advertencias
- Los modelos gratuitos tienen límites y su calidad varía; no rinden igual que Claude en tareas largas.
- Tu código y prompts pasan por proveedores externos: **no lo uses con datos confidenciales**
  (claves de Supabase privadas, datos de clientes del restaurante, etc.).
- Úsalo como complemento cuando se acabe el límite, no como sustituto total.
- La cifra de ahorro de ~89 % de tokens es del propio proyecto, no verificada de forma independiente.

## Requisitos
Node.js 22 o 24 LTS (`node -v`).

## Instalación
```bash
./install.sh          # instala con npm global
./start.sh            # arranca; panel en http://localhost:20128
# alternativa con Docker:
./start-docker.sh
```

## Configuración (panel web)
1. Funciona sin configurar: trae proveedores gratuitos conectados al modo `auto`.
2. Providers: conecta más proveedores con tu cuenta o clave.
3. Endpoints: copia tu clave de OmniRoute (la necesitan Cursor y otros).
4. Modelo: `auto`, o `auto/coding`, `auto/fast`, `auto/cheap`.

## Conectar herramientas
| Herramienta | Cómo |
|---|---|
| Claude Code | `omniroute run claude --model auto` |
| Cursor y compatibles, Codex, Cline, OpenCode | Base URL `http://localhost:20128/v1`, clave de Endpoints, modelo `auto` |
| GitHub Copilot | Extensión OmniCopilot en VS Code > Copilot Chat > selector de modelos > Manage Models… > OmniRoute |

## Compresión de prompts
Perfiles: Lite, Standard, Aggressive, Ultra, RTK. Empieza con el perfil por defecto; si bajan las
respuestas en tareas delicadas, usa Lite.

## Problemas típicos
- `command not found`: reabre la terminal y verifica Node 22/24.
- No conecta: confirma que OmniRoute sigue abierto y entra a `localhost:20128`.
- Respuestas flojas: conecta más proveedores o usa `auto/coding`.
- Error de clave: vuelve a copiarla desde Endpoints.

Fuentes: https://github.com/diegosouzapw/OmniRoute
