const express = require('express');
const pool = require('./db');
const registroIntentos = require('./registro-intentos');
const enviosRouter = require('./envios');

const INSTANCE_ID = process.env.INSTANCE_ID || 'desconocida';

const app = express();
app.disable('x-powered-by');

// Toda respuesta identifica la replica que la emitio (incluidos los errores).
app.use((req, res, next) => {
  res.set('X-Instance-ID', INSTANCE_ID);
  next();
});

// Se registra antes de parsear el body para no perder los intentos con JSON invalido.
app.use(registroIntentos);
app.use(express.json({ limit: '10kb' }));

// Health check con una consulta real a PostgreSQL.
app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.locals.intento.resultado = 'OK';
    res.json({ status: 'ok', database: 'conectada', instance: INSTANCE_ID });
  } catch (err) {
    res.locals.intento.resultado = 'ERROR';
    res.locals.intento.detalle = err.message;
    res.status(503).json({ status: 'error', database: 'desconectada', instance: INSTANCE_ID });
  }
});

app.use(enviosRouter);

app.use((req, res) => {
  res.locals.intento.resultado = 'NO_ENCONTRADO';
  res.status(404).json({ error: 'Ruta no encontrada' });
});

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  const intento = res.locals.intento;
  if (err.type === 'entity.parse.failed' || err.type === 'entity.too.large') {
    intento.resultado = 'INVALIDO';
    intento.detalle = `body rechazado: ${err.type}`;
    return res.status(err.status || 400).json({ error: 'El body debe ser JSON valido.' });
  }
  intento.resultado = 'ERROR';
  intento.detalle = err.message;
  console.error(JSON.stringify({ evento: 'error', instancia: INSTANCE_ID, mensaje: err.message }));
  return res.status(500).json({ error: 'Error interno al procesar la solicitud' });
});

module.exports = app;
