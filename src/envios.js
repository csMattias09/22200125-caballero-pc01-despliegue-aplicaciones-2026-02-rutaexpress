const crypto = require('crypto');
const express = require('express');
const pool = require('./db');

const router = express.Router();

// Clave de idempotencia: la genera el cliente (ej. un UUID) una vez por operacion
// y la reutiliza en cada reintento de esa misma operacion.
const FORMATO_CLAVE = /^[A-Za-z0-9_-]{8,100}$/;
const DEMORA_MAXIMA_MS = 30000;

const esTextoValido = (valor) => typeof valor === 'string' && valor.trim().length > 0;

const aRespuesta = (fila) => ({
  id: Number(fila.id),
  destinatario: fila.destinatario,
  direccion: fila.direccion,
});

// Solo para la prueba de timeout: si PERMITIR_DEMORA=true y el cliente envia
// X-Simular-Demora-Ms, se espera DESPUES de confirmar el registro y ANTES de responder.
async function demoraSimulada(req, intento) {
  if (process.env.PERMITIR_DEMORA !== 'true') return;
  const ms = Number.parseInt(req.get('X-Simular-Demora-Ms'), 10);
  if (!Number.isFinite(ms) || ms <= 0) return;
  const espera = Math.min(ms, DEMORA_MAXIMA_MS);
  intento.detalle = `demora simulada de ${espera} ms despues de confirmar el registro`;
  await new Promise((resolve) => setTimeout(resolve, espera));
}

router.post('/envios', async (req, res, next) => {
  const intento = res.locals.intento;
  const clave = req.get('Idempotency-Key');
  intento.idempotencyKey = clave ? clave.slice(0, 100) : null;

  if (!clave || !FORMATO_CLAVE.test(clave)) {
    intento.resultado = 'INVALIDO';
    intento.detalle = 'cabecera Idempotency-Key ausente o con formato invalido';
    return res.status(400).json({
      error: 'Se requiere la cabecera Idempotency-Key (8 a 100 caracteres: letras, numeros, - o _).',
    });
  }

  const { destinatario, direccion } = req.body || {};
  if (!esTextoValido(destinatario) || !esTextoValido(direccion)) {
    intento.resultado = 'INVALIDO';
    intento.detalle = 'destinatario y direccion son obligatorios y deben ser texto';
    return res.status(400).json({ error: 'destinatario y direccion son obligatorios y deben ser de tipo string.' });
  }

  const huella = crypto.createHash('sha256').update(JSON.stringify([destinatario, direccion])).digest('hex');

  try {
    // La restriccion UNIQUE decide quien crea el envio: si la clave ya existe
    // (reintento o solicitud simultanea en otra replica) no se inserta nada.
    const insercion = await pool.query(
      `INSERT INTO envios (idempotency_key, destinatario, direccion, huella_solicitud, instancia_creadora)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (idempotency_key) DO NOTHING
       RETURNING id, destinatario, direccion`,
      [clave, destinatario, direccion, huella, process.env.INSTANCE_ID || 'desconocida'],
    );

    if (insercion.rowCount === 1) {
      const envio = insercion.rows[0];
      intento.resultado = 'CREADO';
      intento.envioId = envio.id;
      await demoraSimulada(req, intento); // el envio ya esta confirmado en PostgreSQL
      return res.status(201).json(aRespuesta(envio));
    }

    // La clave ya existia: devolver el envio original sin crear otro.
    const existente = await pool.query(
      'SELECT id, destinatario, direccion, huella_solicitud FROM envios WHERE idempotency_key = $1',
      [clave],
    );
    const envio = existente.rows[0];
    intento.envioId = envio.id;

    if (envio.huella_solicitud !== huella) {
      intento.resultado = 'CLAVE_REUTILIZADA';
      intento.detalle = 'la clave ya pertenece a un envio con datos diferentes';
      return res.status(422).json({
        error: 'La Idempotency-Key ya fue usada con otros datos. Use una clave nueva para un envio nuevo.',
        id: Number(envio.id),
      });
    }

    intento.resultado = 'REPETIDO';
    intento.detalle = 'reintento de una operacion ya registrada; no se creo otro envio';
    res.set('Idempotent-Replayed', 'true');
    return res.status(200).json(aRespuesta(envio));
  } catch (err) {
    return next(err);
  }
});

module.exports = router;
