# envios-app — RutaExpress

Práctica Calificada 01 — Despliegue de Aplicaciones (2026-02).

Servicio de registro de envíos con **Node.js, Express y PostgreSQL**, desplegado con **Docker Compose y Nginx**.
Evita envíos duplicados cuando una solicitud se reintenta tras un timeout, aunque el reintento llegue a otra
réplica o al mismo tiempo. Además conserva los datos al recrear contenedores, sigue atendiendo si una réplica
se detiene y limita las ráfagas de solicitudes con registro de rechazos.

- **Repositorio:** `https://github.com/csMattias09/22200125-caballero-pc01-despliegue-aplicaciones-2026-02-rutaexpress`
- **Imagen Docker Hub:** [`csmattias/envios-app:1.0.0`](https://hub.docker.com/r/csmattias/envios-app/tags)

## Arquitectura

```
Cliente (curl / Postman)
        │  http://localhost:8080
        ▼
┌───────────────┐   límite 2 r/s + ráfaga 4 en POST /envios → 429 (logs/nginx/rechazos_429.log)
│ nginx  :80    │   round-robin + failover, X-Request-ID
└──┬─────┬────┬─┘
   ▼     ▼    ▼        red interna de Docker (puerto 3000 no publicado)
 app1  app2  app3      misma imagen, INSTANCE_ID distinto, usuario no root
   └─────┼────┘
         ▼
┌───────────────┐
│ db PostgreSQL │   localhost:15432 → 5432 (DBeaver), volumen pg_data
└───────────────┘
```

| Servicio | Imagen | Puertos |
|---|---|---|
| `app1`, `app2`, `app3` | `csmattias/envios-app:1.0.0` | `3000` solo interno |
| `db` | `postgres:16-alpine` | `15432:5432` |
| `nginx` | `nginx:1.27-alpine` | `8080:80` |

## Ejecución

Requisitos: Docker Desktop (con Compose v2). Para los scripts de prueba: Git Bash, Linux o macOS con `curl`.

```bash
cp .env.example .env          # completar credenciales (no se suben al repositorio)
docker compose up -d          # descarga la imagen de Docker Hub y levanta los 5 servicios
docker compose ps
curl http://localhost:8080/health
```

Para construir la imagen localmente en lugar de descargarla: `docker compose up -d --build`.

**DBeaver:** PostgreSQL → host `localhost`, puerto `15432`, base/usuario/clave según `.env`.

## API

### `GET /health`
Ejecuta `SELECT 1` en PostgreSQL.
```json
{ "status": "ok", "database": "conectada", "instance": "app2" }
```
Si la base no responde, devuelve `503` con `"status": "error"`.

### `POST /envios`

| Cabecera | Obligatoria | Descripción |
|---|---|---|
| `Content-Type: application/json` | sí | |
| `Idempotency-Key` | sí | Identificador de la **operación** (8-100 caracteres: letras, números, `-`, `_`). Se recomienda un UUID. |

```bash
curl -i -X POST http://localhost:8080/envios \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: 3f2b8c1e-5d7a-4e9b-a1c2-9f8e7d6c5b4a' \
  -d '{"destinatario":"Ana Torres","direccion":"Av. Los Olivos 123, Lima"}'
```

| Caso | Respuesta |
|---|---|
| Envío nuevo | `201` `{ "id", "destinatario", "direccion" }` |
| Reintento (misma clave, mismos datos) | `200` con el **mismo** envío y cabecera `Idempotent-Replayed: true` |
| Misma clave con datos distintos | `422` (la clave ya pertenece a otro envío) |
| Falta la clave o datos inválidos | `400` |
| Exceso de solicitudes (Nginx) | `429` |

Toda respuesta de la aplicación incluye `X-Instance-ID` (réplica que atendió) y `X-Request-ID` (asignado por Nginx).

## Diseño de la solución

### Mecanismo contra duplicados: clave de idempotencia + restricción `UNIQUE`

1. El cliente (la oficina o el frontend) genera **una clave por operación** y la reutiliza en cada reintento de esa operación.
2. La aplicación ejecuta `INSERT ... ON CONFLICT (idempotency_key) DO NOTHING RETURNING ...`.
3. Si la fila se insertó, es un envío nuevo (`201`). Si no, la clave ya existía y se devuelve el envío original (`200`).

**Por qué en la base de datos y no en la aplicación:** las tres réplicas comparten PostgreSQL. La restricción
`UNIQUE` es atómica, así que aunque dos intentos lleguen al mismo tiempo a réplicas distintas solo uno puede insertar;
el otro espera a que el primero confirme y no inserta nada. Un enfoque de "consultar y luego insertar" en la aplicación
tendría una condición de carrera entre réplicas. Un bloqueo en memoria tampoco sirve, porque cada réplica tiene la suya.

**Reintento vs. envío nuevo intencional:** lo que distingue un caso del otro es la clave, no los datos. Un reintento
reutiliza la clave de la operación original. Un envío nuevo, aunque tenga el mismo destinatario y dirección, usa una
clave nueva y se registra como otro envío. Para detectar errores del cliente se guarda una huella SHA-256 del body:
si la misma clave llega con datos diferentes se responde `422`.

### Modelo de datos ([`db/init.sql`](db/init.sql))

PostgreSQL ejecuta el script automáticamente al crear el volumen por primera vez.

- **`envios`**: un registro por envío real. Contiene `id`, `idempotency_key` (UNIQUE), `destinatario`, `direccion`,
  `huella_solicitud`, `instancia_creadora` y `creado_en`.
- **`intentos`**: una fila por cada solicitud que llega al backend, con:
  - `request_id`, `recibido_en` y `finalizado_en` (microsegundos), `duracion_ms`
  - `metodo`, `ruta`, `instancia`, `ip_cliente`, `idempotency_key` (relaciona los intentos de una operación)
  - `resultado`, `envio_id`, `http_status`, `respuesta_entregada`, `detalle`

> Los `id` de `envios` pueden tener saltos. Es normal en PostgreSQL: un `INSERT ... ON CONFLICT` que no inserta
> igual consume un valor de la secuencia. El `id` sigue siendo único y estable.

### Registro de intentos: tres fuentes de evidencia

| Fuente | Qué registra | Dónde |
|---|---|---|
| **Servidor (aplicación)** | Cada solicitud que llega a una réplica: `CREADO`, `REPETIDO`, `INVALIDO`, `CLAVE_REUTILIZADA`, `ERROR`, `OK`, `NO_ENCONTRADO`. Si el cliente cerró la conexión antes de la respuesta (timeout), `respuesta_entregada = false` y `http_status` queda vacío. | Tabla `intentos` (volumen `pg_data`) |
| **Nginx** | Rechazos `429` que nunca llegan a la aplicación: fecha, IP, método, ruta, código y `request_id`. No guarda el body ni datos personales. | `logs/nginx/rechazos_429.log` (bind mount, sobrevive a la recreación) y `logs/nginx/access.log` |
| **Cliente** | Lo que observó el cliente: código recibido, réplica, timeouts (`curl exit 28`). | Archivos de `evidencias/` (líneas `[cliente]`) |

Las tres fuentes se cruzan por `request_id` y por `Idempotency-Key`. Si PostgreSQL no estuviera disponible, el intento
se escribe en el log del contenedor (`docker compose logs app1`) para no perderlo.

### Demora simulada (solo para la prueba de timeout)

La demora está **desactivada por defecto** (`PERMITIR_DEMORA=false` en `.env`). Cuando está activa, la réplica atiende
la cabecera `X-Simular-Demora-Ms`: confirma el registro en PostgreSQL, espera y **después** responde.

- **Activar:** `PERMITIR_DEMORA=true docker compose up -d app1 app2 app3`, y enviar el primer intento con `-H 'X-Simular-Demora-Ms: 5000' --max-time 2`.
- **Retirar:** no enviar la cabecera en el reintento y volver al valor del `.env` con `docker compose up -d app1 app2 app3`.

El script `scripts/03-timeout-reintento.sh` hace ambas cosas automáticamente.

### Nginx

- **Balanceo** round-robin entre las tres réplicas. Si una no acepta la conexión se prueba la siguiente
  (`proxy_next_upstream error timeout`) y queda fuera 10 s. Nginx no reenvía un POST que ya llegó a una réplica.
- **`resolve` + DNS de Docker:** una réplica detenida se reincorpora sola al volver, sin reiniciar Nginx.
- **Límite:** `limit_req` por IP solo para `POST /envios` con `rate=2r/s burst=4 nodelay`. Las 4 solicitudes de la
  ráfaga se procesan de inmediato y el exceso recibe `429`. `GET /health` no está limitado.

### Seguridad y configuración

- La imagen se ejecuta con el usuario `node` (no root).
- Las credenciales solo llegan por variables de entorno. `.env` está en `.gitignore` y `.dockerignore`, y `.env.example` no tiene secretos reales.
- Solo se publican los puertos `8080` (Nginx) y `15432` (PostgreSQL). Las réplicas no son accesibles desde el host.

## Pruebas y evidencias

Con el stack levantado (`docker compose up -d`), desde Git Bash:

| Script | Prueba | Evidencia |
|---|---|---|
| `scripts/01-imagen-dockerhub.sh` | build, usuario no root, push y pull de la imagen (requiere `docker login`) | `01-imagen-dockerhub.txt` |
| `scripts/02-balanceo-health.sh` | 12 `GET /health` repartidos entre app1, app2 y app3 | `02-balanceo-health.txt` |
| `scripts/03-timeout-reintento.sh` | timeout del cliente, registro previo, reintento desde otra réplica, un solo envío | `03-timeout-reintento.txt` |
| `scripts/04-concurrencia.sh` | dos intentos simultáneos en réplicas distintas y dos envíos intencionales iguales | `04-concurrencia.txt` |
| `scripts/05-caida-app2.sh` | detener y restablecer app2, registrando errores de transición | `05-caida-app2.txt` |
| `scripts/06-persistencia.sh` | 3 envíos, `down`/`up`, mismos ids, reintento sin duplicar | `06-persistencia.txt` |
| `scripts/07-limite-429.sh` | carga con 429, conteo de códigos, recuperación, log tras recrear Nginx | `07-limite-429.txt` |
| `scripts/08-exportar-registros.sh` | exporta `envios`, `intentos` y rechazos | `08-*.csv`, `08-*.log`, `08-resumen-registros.txt` |

Consultas útiles:

```bash
docker compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
#   SELECT * FROM envios ORDER BY id;
#   SELECT * FROM intentos WHERE idempotency_key = '<clave>' ORDER BY recibido_en;
cat logs/nginx/rechazos_429.log
```

## Estructura

```
├── src/                  app Express (index, app, db, envios, registro-intentos)
├── db/init.sql           esquema de la base
├── nginx/nginx.conf      balanceo, límite 429 y logs
├── docker-compose.yml
├── Dockerfile / .dockerignore / .env.example
├── scripts/              pruebas que generan evidencias
├── evidencias/           salidas de las pruebas y capturas
└── respuestas/           preguntas de análisis
```
