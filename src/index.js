const app = require('./app');
const pool = require('./db');

const PORT = Number(process.env.PORT || 3000);
const INSTANCE_ID = process.env.INSTANCE_ID || 'desconocida';

const server = app.listen(PORT, () => {
  console.log(`[${INSTANCE_ID}] envios-app escuchando en el puerto ${PORT}`);
});

// Apagado ordenado: al detener el contenedor (docker stop) se terminan las
// solicitudes en curso antes de cerrar el pool de conexiones.
function apagar(senal) {
  console.log(`[${INSTANCE_ID}] ${senal} recibido, cerrando...`);
  server.close(() => pool.end().finally(() => process.exit(0)));
  setTimeout(() => process.exit(1), 10000).unref();
}
process.on('SIGTERM', apagar);
process.on('SIGINT', apagar);
