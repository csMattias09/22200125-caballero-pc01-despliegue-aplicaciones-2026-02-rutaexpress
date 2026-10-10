#!/usr/bin/env bash
# Continuidad: se detiene app2, app1 y app3 siguen atendiendo; se restablece app2 y vuelve a recibir solicitudes.
# Se registra cualquier error observado por el cliente durante la transicion.
source "$(dirname "$0")/_comun.sh"
evidencia "05-caida-app2.txt"

titulo "Antes: las tres replicas atienden"
for _ in $(seq 1 6); do get_health; sleep 0.5; done

titulo "Deteniendo app2 ($(ts))"
docker compose stop app2
docker compose ps --format 'table {{.Service}}\t{{.Status}}'

titulo "Con app2 detenida (12 solicitudes)"
for _ in $(seq 1 12); do get_health; sleep 0.5; done | tee /tmp/rutaexpress-caida.txt
echo "Respuestas no exitosas durante la caida: $(grep -vc 'HTTP 200' /tmp/rutaexpress-caida.txt)"

titulo "Errores registrados por Nginx durante la transicion"
docker compose logs --since 2m nginx 2>&1 | grep -E '\[(warn|error)\]' || echo "(sin errores en Nginx)"

titulo "Restableciendo app2 ($(ts))"
docker compose start app2

titulo "Despues: se espera hasta que app2 vuelva a responder"
for _ in $(seq 1 40); do
  linea=$(get_health); echo "$linea"
  echo "$linea" | grep -q '"instance":"app2"' && break
  sleep 0.5
done
for _ in $(seq 1 6); do get_health; sleep 0.5; done
