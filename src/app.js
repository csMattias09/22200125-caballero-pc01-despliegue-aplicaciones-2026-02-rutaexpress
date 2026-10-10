const express = require('express');
const pool = require('./db');

const INSTANCE_ID = process.env.INSTANCE_ID || 'desconocida';

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '10kb' }));

// Toda respuesta identifica la replica que la emitio.
app.use((req, res, next) => {
  res.set('X-Instance-ID', INSTANCE_ID);
  next();
});

// Health check con una consulta real a PostgreSQL.
app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ok', database: 'conectada', instance: INSTANCE_ID });
  } catch (err) {
    res.status(503).json({ status: 'error', database: 'desconectada', instance: INSTANCE_ID, detalle: err.message });
  }
});

module.exports = app;
