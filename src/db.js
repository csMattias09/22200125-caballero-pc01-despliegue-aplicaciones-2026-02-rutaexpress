const { Pool } = require('pg');

// Las credenciales llegan solo por variables de entorno (nunca dentro de la imagen).
const pool = new Pool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  max: 10,
  connectionTimeoutMillis: 3000,
});

pool.on('error', (err) => {
  console.error(JSON.stringify({ evento: 'pool_error', mensaje: err.message }));
});

module.exports = pool;
