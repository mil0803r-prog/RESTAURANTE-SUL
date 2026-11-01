#!/usr/bin/env bash
set -euo pipefail
if ! command -v node >/dev/null; then echo "Instala Node.js 22 o 24 LTS desde nodejs.org"; exit 1; fi
major=$(node -v | sed 's/v\([0-9]*\).*/\1/')
if [ "$major" != "22" ] && [ "$major" != "24" ]; then
  echo "Node $(node -v) no es 22 ni 24 (requerido por la guía)."; exit 1
fi
npm install -g omniroute
echo "Listo. Ejecuta ./start.sh"
