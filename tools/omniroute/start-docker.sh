#!/usr/bin/env bash
set -euo pipefail
docker run -d --name omniroute --restart unless-stopped \
  -p 127.0.0.1:20128:20128 -v omniroute-data:/app/data \
  diegosouzapw/omniroute:latest
echo "Panel en http://localhost:20128"
