#!/usr/bin/env bash
# Funciones comunes de los scripts de prueba. Se ejecutan desde Git Bash (Windows), Linux o macOS.
# Cada script guarda su salida en evidencias/ ademas de mostrarla en pantalla.

set -u
cd "$(dirname "$0")/.." || exit 1

URL="${URL:-http://localhost:8080}"
EVID="evidencias"
mkdir -p "$EVID"

BODY_ANA='{"destinatario":"Ana Torres","direccion":"Av. Los Olivos 123, Lima"}'

# Envia toda la salida del script a pantalla y al archivo de evidencia indicado.
evidencia() {
  exec > >(tee "$EVID/$1") 2>&1
  echo "# Evidencia generada por scripts/$(basename "$0") el $(ts) (UTC)"
  echo "# Lado CLIENTE = lineas [cliente]. Lado SERVIDOR = consultas a PostgreSQL / logs de Nginx."
  echo
}

ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }

titulo() { echo; echo "==================== $* ===================="; }

nueva_clave() { echo "$1-$(date +%s%N | cut -c1-16)-$RANDOM"; }

# Consulta SQL dentro del contenedor db (usa las credenciales del propio contenedor).
sql() {
  echo "$1" | docker compose exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off'
}

# POST /envios. Uso: post_envio CLAVE BODY [opciones extra de curl]
# Imprime: [cliente] hora | HTTP | replica | body
post_envio() {
  local clave="$1" body="$2"; shift 2
  local inicio salida codigo
  inicio=$(ts)
  salida=$(curl -s -X POST "$URL/envios" \
    -H 'Content-Type: application/json' -H "Idempotency-Key: $clave" \
    -w '\n%{http_code} %header{x-instance-id} %header{idempotent-replayed}' "$@" -d "$body")
  codigo=$?
  if [ "$codigo" -eq 28 ]; then
    echo "[cliente] $inicio -> $(ts) | TIMEOUT del cliente (curl exit 28): no se recibio respuesta | clave=$clave"
    return 28
  elif [ "$codigo" -ne 0 ]; then
    echo "[cliente] $inicio -> $(ts) | ERROR de conexion (curl exit $codigo) | clave=$clave"
    return "$codigo"
  fi
  local meta respuesta
  meta=$(echo "$salida" | tail -n1)
  respuesta=$(echo "$salida" | sed '$d')
  echo "[cliente] $inicio -> $(ts) | HTTP $(echo "$meta" | cut -d' ' -f1) | replica=$(echo "$meta" | cut -d' ' -f2) | replay=$(echo "$meta" | cut -d' ' -f3) | clave=$clave | $respuesta"
}

# GET /health. Imprime: [cliente] hora | HTTP | tiempo de respuesta | body
get_health() {
  local salida meta
  salida=$(curl -s --max-time 5 -w '\n%{http_code} %{time_total}' "$URL/health") || { echo "[cliente] $(ts) | ERROR de conexion (curl exit $?)"; return 1; }
  meta=$(echo "$salida" | tail -n1)
  echo "[cliente] $(ts) | HTTP $(echo "$meta" | cut -d' ' -f1) | $(echo "$meta" | cut -d' ' -f2)s | $(echo "$salida" | sed '$d')"
}

esperar_servicio() {
  for _ in $(seq 1 30); do
    curl -s -o /dev/null --max-time 2 "$URL/health" && return 0
    sleep 1
  done
  echo "El servicio no respondio en $URL/health"; return 1
}
