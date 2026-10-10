#!/usr/bin/env bash
# Al menos nueve GET /health exitosos, a menor frecuencia que el limite, atendidos por las tres replicas.
source "$(dirname "$0")/_comun.sh"
evidencia "02-balanceo-health.txt"

titulo "Servicios en ejecucion (solo nginx:8080 y db:15432 publicados)"
docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'

titulo "12 solicitudes GET /health (una cada 0.6 s)"
for _ in $(seq 1 12); do
  get_health
  sleep 0.6
done | tee /tmp/rutaexpress-health.txt

titulo "Respuestas por replica"
grep -o '"instance":"app[0-9]"' /tmp/rutaexpress-health.txt | sort | uniq -c
