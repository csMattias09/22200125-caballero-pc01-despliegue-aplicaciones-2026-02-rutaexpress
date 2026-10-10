#!/usr/bin/env bash
# Limite en Nginx: 2 r/s por IP en POST /envios, rafaga de 4, exceso -> HTTP 429.
# Genera carga, cuenta codigos HTTP, verifica la recuperacion y la persistencia del log de rechazos.
source "$(dirname "$0")/_comun.sh"
evidencia "07-limite-429.txt"

TOTAL="${TOTAL:-30}"
LOG_RECHAZOS="logs/nginx/rechazos_429.log"
ANTES=$( [ -f "$LOG_RECHAZOS" ] && wc -l < "$LOG_RECHAZOS" || echo 0)

titulo "Carga: $TOTAL POST /envios simultaneos (claves distintas)"
INICIO_NS=$(date +%s%N)
PIDS=()
DIR_CARGA=$(mktemp -d)
for n in $(seq 1 "$TOTAL"); do
  # Un archivo por solicitud: escrituras paralelas al mismo archivo pueden perder lineas.
  curl -s -o /dev/null -w '%{http_code}\n' -X POST "$URL/envios" \
    -H 'Content-Type: application/json' -H "Idempotency-Key: carga-$INICIO_NS-$n" \
    -d '{"destinatario":"Prueba de carga","direccion":"Sin datos reales"}' > "$DIR_CARGA/$n.txt" &
  PIDS+=($!)
done
# Se espera solo a los curl (un "wait" sin argumentos tambien esperaria al tee de la evidencia).
wait "${PIDS[@]}"
FIN_NS=$(date +%s%N)

echo "Solicitudes enviadas: $TOTAL"
echo "Respuestas recibidas: $(cat "$DIR_CARGA"/*.txt | wc -l)"
echo "Duracion: $(( (FIN_NS - INICIO_NS) / 1000000 )) ms"
echo "Conteo de codigos HTTP:"
cat "$DIR_CARGA"/*.txt | sort | uniq -c
rm -rf "$DIR_CARGA"

titulo "Recuperacion: se reduce la frecuencia a 1 solicitud por segundo"
sleep 3
for _ in 1 2 3; do
  post_envio "$(nueva_clave recuperacion)" '{"destinatario":"Prueba de recuperacion","direccion":"Sin datos reales"}'
  sleep 1
done

titulo "Rechazos registrados por Nginx ($LOG_RECHAZOS)"
DESPUES=$(wc -l < "$LOG_RECHAZOS")
echo "Lineas antes de la prueba: $ANTES | despues: $DESPUES | nuevas: $((DESPUES - ANTES))"
tail -n 5 "$LOG_RECHAZOS"

titulo "Recreando el contenedor de Nginx (docker compose up -d --force-recreate nginx)"
docker compose up -d --force-recreate nginx
esperar_servicio
echo "Lineas en el log de rechazos tras recrear Nginx: $(wc -l < "$LOG_RECHAZOS")"

titulo "Consulta del log: rechazos por IP y por minuto"
grep -o '"fecha":"[^"]*:[0-9][0-9]' "$LOG_RECHAZOS" | cut -d'"' -f4 | cut -c1-16 | sort | uniq -c | tail -n 5
grep -o '"ip_cliente":"[^"]*"' "$LOG_RECHAZOS" | sort | uniq -c
