#!/usr/bin/env bash
# a) Dos intentos simultaneos de la MISMA operacion atendidos por replicas distintas -> un solo envio.
# b) Dos envios nuevos intencionales con el mismo destinatario y direccion -> dos envios.
source "$(dirname "$0")/_comun.sh"
evidencia "04-concurrencia.txt"

titulo "a) Dos solicitudes simultaneas con la misma Idempotency-Key"
for n in 1 2 3 4 5; do
  CLAVE=$(nueva_clave simultaneo)
  echo "Prueba $n - clave: $CLAVE"
  post_envio "$CLAVE" "$BODY_ANA" > /tmp/rutaexpress-c1.txt & P1=$!
  post_envio "$CLAVE" "$BODY_ANA" > /tmp/rutaexpress-c2.txt & P2=$!
  wait "$P1" "$P2"
  cat /tmp/rutaexpress-c1.txt /tmp/rutaexpress-c2.txt
  R1=$(grep -o 'replica=app[0-9]' /tmp/rutaexpress-c1.txt)
  R2=$(grep -o 'replica=app[0-9]' /tmp/rutaexpress-c2.txt)
  [ "$R1" != "$R2" ] && break
  echo "Ambas cayeron en la misma replica; se repite con otra clave."
  sleep 1.5
done

titulo "Servidor: envios con esa clave (debe ser 1)"
sql "SELECT id, instancia_creadora, creado_en FROM envios WHERE idempotency_key = '$CLAVE';"
titulo "Servidor: intentos de esa clave"
sql "SELECT recibido_en, instancia, resultado, envio_id, http_status FROM intentos
     WHERE idempotency_key = '$CLAVE' ORDER BY recibido_en;"

sleep 1.5
titulo "b) Dos envios nuevos intencionales: mismos datos, claves distintas"
CLAVE_A=$(nueva_clave intencional-a)
CLAVE_B=$(nueva_clave intencional-b)
post_envio "$CLAVE_A" "$BODY_ANA"
sleep 0.6
post_envio "$CLAVE_B" "$BODY_ANA"

titulo "Servidor: deben existir dos envios distintos"
sql "SELECT id, idempotency_key, destinatario, direccion, creado_en FROM envios
     WHERE idempotency_key IN ('$CLAVE_A', '$CLAVE_B') ORDER BY id;"
