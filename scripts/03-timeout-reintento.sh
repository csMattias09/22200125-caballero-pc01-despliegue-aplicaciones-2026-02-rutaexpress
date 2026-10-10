#!/usr/bin/env bash
# Prueba de timeout y recuperacion:
#  1. Se activa la demora (PERMITIR_DEMORA=true) solo durante esta prueba.
#  2. Primer intento: el servidor registra el envio, espera 5 s y recien responde;
#     el cliente solo espera 2 s (timeout del cliente, no un codigo HTTP de error).
#  3. Reintento con la MISMA Idempotency-Key, sin demora, hasta que lo atienda otra replica.
#  4. Se verifica en PostgreSQL que existe un solo envio.
#  5. Se retira la demora (las replicas vuelven a PERMITIR_DEMORA=false del .env).
source "$(dirname "$0")/_comun.sh"
evidencia "03-timeout-reintento.txt"

titulo "Activando la demora solo para esta prueba (PERMITIR_DEMORA=true)"
PERMITIR_DEMORA=true docker compose up -d app1 app2 app3
esperar_servicio
docker compose exec -T app1 printenv PERMITIR_DEMORA | sed 's/^/app1 PERMITIR_DEMORA=/'

CLAVE=$(nueva_clave timeout)
echo "Idempotency-Key de la operacion: $CLAVE"

titulo "Intento 1: demora de 5 s en el servidor, el cliente espera solo 2 s"
post_envio "$CLAVE" "$BODY_ANA" --max-time 2 -H 'X-Simular-Demora-Ms: 5000'
HORA_TIMEOUT=$(ts)

titulo "Servidor: el envio YA existe aunque el cliente no recibio respuesta (consultado a las $(ts))"
sql "SELECT id, idempotency_key, instancia_creadora, creado_en FROM envios WHERE idempotency_key = '$CLAVE';"
echo "Hora del timeout observada por el cliente: $HORA_TIMEOUT -> creado_en es anterior."

sleep 4 # se deja terminar la demora del primer intento para que quede registrado
INSTANCIA_1=$(sql "SELECT instancia FROM intentos WHERE idempotency_key = '$CLAVE' ORDER BY recibido_en LIMIT 1;" | sed -n '3p' | tr -d ' ')
echo "Replica que atendio el intento 1: $INSTANCIA_1"

titulo "Reintento (misma clave, sin demora) hasta que responda una replica distinta de $INSTANCIA_1"
for n in 1 2 3 4; do
  linea=$(post_envio "$CLAVE" "$BODY_ANA")
  echo "Reintento $n: $linea"
  echo "$linea" | grep -q "replica=$INSTANCIA_1 " || break
  sleep 0.6
done

titulo "Servidor: cantidad de envios con esa clave (debe ser 1)"
sql "SELECT count(*) AS envios_registrados FROM envios WHERE idempotency_key = '$CLAVE';"

titulo "Servidor: todos los intentos de esta operacion"
sql "SELECT id, request_id, recibido_en, instancia, resultado, envio_id, http_status, respuesta_entregada, detalle
     FROM intentos WHERE idempotency_key = '$CLAVE' ORDER BY recibido_en;"

titulo "Retirando la demora (vuelve PERMITIR_DEMORA=false del .env)"
docker compose up -d app1 app2 app3
esperar_servicio
docker compose exec -T app1 printenv PERMITIR_DEMORA | sed 's/^/app1 PERMITIR_DEMORA=/'
