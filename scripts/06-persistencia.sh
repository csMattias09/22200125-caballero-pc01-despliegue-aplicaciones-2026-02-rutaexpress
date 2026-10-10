#!/usr/bin/env bash
# Persistencia: tres envios distintos, recreacion de contenedores (sin borrar volumenes)
# y reintento de una operacion ya completada despues de la recreacion.
# La consulta desde DBeaver (localhost:15432) se hace aparte y se guarda como captura.
source "$(dirname "$0")/_comun.sh"
evidencia "06-persistencia.txt"

titulo "Registro de tres envios distintos"
CLAVES=()
i=0
for datos in '{"destinatario":"Luis Ramos","direccion":"Jr. Ucayali 456, Lima"}' \
             '{"destinatario":"Maria Quispe","direccion":"Calle Las Flores 789, Arequipa"}' \
             '{"destinatario":"Carlos Vega","direccion":"Av. Larco 1020, Trujillo"}'; do
  CLAVES[$i]=$(nueva_clave persistencia)
  post_envio "${CLAVES[$i]}" "$datos"
  i=$((i + 1))
  sleep 0.6
done
LISTA="'${CLAVES[0]}','${CLAVES[1]}','${CLAVES[2]}'"
CONSULTA="SELECT id, idempotency_key, destinatario, direccion, creado_en FROM envios WHERE idempotency_key IN ($LISTA) ORDER BY id;"

titulo "Antes de recrear"
sql "$CONSULTA" | tee /tmp/rutaexpress-antes.txt
sql "SELECT (SELECT count(*) FROM envios) AS total_envios, (SELECT count(*) FROM intentos) AS total_intentos;"

titulo "Recreando contenedores: docker compose down (SIN -v) y docker compose up -d"
docker compose down
docker compose up -d
esperar_servicio
docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.CreatedAt}}'

titulo "Despues de recrear"
sql "$CONSULTA" | tee /tmp/rutaexpress-despues.txt
sql "SELECT (SELECT count(*) FROM envios) AS total_envios, (SELECT count(*) FROM intentos) AS total_intentos;"
if diff -q /tmp/rutaexpress-antes.txt /tmp/rutaexpress-despues.txt > /dev/null; then
  echo "RESULTADO: mismos ids y datos antes y despues de recrear."
else
  echo "RESULTADO: hay diferencias."
fi

titulo "Reintento de una operacion ya completada (clave ${CLAVES[0]})"
post_envio "${CLAVES[0]}" '{"destinatario":"Luis Ramos","direccion":"Jr. Ucayali 456, Lima"}'
sql "SELECT count(*) AS envios_con_esa_clave FROM envios WHERE idempotency_key = '${CLAVES[0]}';"
sql "SELECT recibido_en, instancia, resultado, envio_id, http_status FROM intentos
     WHERE idempotency_key = '${CLAVES[0]}' ORDER BY recibido_en;"
