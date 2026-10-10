const pool = require('./db');

const INSTANCE_ID = process.env.INSTANCE_ID || 'desconocida';

// Reloj con precision de microsegundos (Date solo llega a milisegundos), para
// poder ordenar intentos muy cercanos en el tiempo.
const BASE_US = BigInt(Date.now()) * 1000n - process.hrtime.bigint() / 1000n;
function ahoraIso() {
  const us = BASE_US + process.hrtime.bigint() / 1000n;
  const iso = new Date(Number(us / 1000n)).toISOString();
  return iso.replace('Z', String(us % 1000n).padStart(3, '0') + 'Z');
}

async function guardar(registro) {
  try {
    await pool.query(
      `INSERT INTO intentos (request_id, recibido_en, finalizado_en, duracion_ms, metodo, ruta, instancia,
         ip_cliente, idempotency_key, resultado, envio_id, http_status, respuesta_entregada, detalle)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)`,
      [
        registro.request_id, registro.recibido_en, registro.finalizado_en, registro.duracion_ms,
        registro.metodo, registro.ruta, registro.instancia, registro.ip_cliente, registro.idempotency_key,
        registro.resultado, registro.envio_id, registro.http_status, registro.respuesta_entregada,
        registro.detalle,
      ],
    );
  } catch (err) {
    // Si la base no esta disponible el intento no se pierde: queda en el log del contenedor.
    console.error(JSON.stringify({ evento: 'intento_no_guardado', error: err.message, registro }));
  }
}

// Middleware: registra cada solicitud que llega a esta replica, cuando termina
// (respuesta enviada) o cuando el cliente cierra la conexion antes (timeout).
function registroIntentos(req, res, next) {
  const recibidoEn = ahoraIso();
  const inicio = process.hrtime.bigint();

  // Los manejadores completan estos datos durante el procesamiento.
  res.locals.intento = { resultado: null, envioId: null, idempotencyKey: null, detalle: null };

  let registrado = false;
  const registrar = (respuestaEntregada) => {
    if (registrado) return;
    registrado = true;
    const intento = res.locals.intento;
    const detalles = [intento.detalle];
    if (!respuestaEntregada) detalles.push('el cliente cerro la conexion antes de recibir la respuesta');

    guardar({
      request_id: req.get('X-Request-ID') || null,
      recibido_en: recibidoEn,
      finalizado_en: ahoraIso(),
      duracion_ms: Number((process.hrtime.bigint() - inicio) / 1000000n),
      metodo: req.method,
      ruta: req.originalUrl.slice(0, 500),
      instancia: INSTANCE_ID,
      ip_cliente: req.get('X-Real-IP') || req.socket.remoteAddress || null,
      idempotency_key: intento.idempotencyKey,
      resultado: intento.resultado || (res.statusCode >= 500 ? 'ERROR' : 'SIN_RESULTADO'),
      envio_id: intento.envioId,
      // Solo hay codigo HTTP si la respuesta llego a emitirse.
      http_status: respuestaEntregada || res.headersSent ? res.statusCode : null,
      respuesta_entregada: respuestaEntregada,
      detalle: detalles.filter(Boolean).join('; ') || null,
    });
  };

  res.on('finish', () => registrar(true));
  res.on('close', () => registrar(res.writableFinished));
  next();
}

module.exports = registroIntentos;
