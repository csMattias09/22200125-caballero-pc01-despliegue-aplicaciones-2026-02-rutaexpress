#!/usr/bin/env bash
# Exporta los registros persistentes del servidor a evidencias/:
#  - tabla envios e intentos (PostgreSQL) en CSV
#  - resumen de intentos por resultado y replica
#  - copia del log de rechazos 429 de Nginx
source "$(dirname "$0")/_comun.sh"

csv() {
  echo "COPY ($1) TO STDOUT WITH CSV HEADER" |
    docker compose exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q'
}

csv "SELECT id, idempotency_key, destinatario, direccion, instancia_creadora, creado_en FROM envios ORDER BY id" \
  > "$EVID/08-envios.csv"
csv "SELECT * FROM intentos ORDER BY recibido_en, id" > "$EVID/08-intentos.csv"
cp logs/nginx/rechazos_429.log "$EVID/08-rechazos-429-nginx.log" 2>/dev/null

evidencia "08-resumen-registros.txt"
titulo "Intentos por resultado y codigo HTTP"
sql "SELECT resultado, http_status, respuesta_entregada, count(*) FROM intentos
     GROUP BY 1, 2, 3 ORDER BY 1, 2;"
titulo "Intentos por replica"
sql "SELECT instancia, count(*) FROM intentos GROUP BY 1 ORDER BY 1;"
titulo "Operaciones con mas de un intento (reintentos relacionados por Idempotency-Key)"
sql "SELECT idempotency_key, count(*) AS intentos, string_agg(resultado || '@' || instancia, ', ' ORDER BY recibido_en) AS secuencia
     FROM intentos WHERE idempotency_key IS NOT NULL GROUP BY 1 HAVING count(*) > 1 ORDER BY min(recibido_en);"

echo
echo "Archivos exportados: $EVID/08-envios.csv, $EVID/08-intentos.csv, $EVID/08-rechazos-429-nginx.log"
