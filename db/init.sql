-- Esquema de envios-app (RutaExpress).
-- PostgreSQL lo ejecuta automaticamente solo la primera vez, cuando el volumen de datos esta vacio
-- (montado en /docker-entrypoint-initdb.d). Al recrear contenedores el volumen se conserva.

-- ---------------------------------------------------------------------------
-- envios: un registro por envio real.
-- La idempotencia se garantiza con la restriccion UNIQUE sobre idempotency_key:
-- el cliente genera una clave por operacion y la reutiliza en cada reintento.
-- PostgreSQL arbitra la concurrencia, aunque los intentos lleguen a replicas
-- distintas o al mismo tiempo, solo uno puede insertar esa clave.
-- Un envio nuevo intencional (mismo destinatario y direccion) usa otra clave.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS envios (
    id                  BIGSERIAL    PRIMARY KEY,
    idempotency_key     VARCHAR(100) NOT NULL,
    destinatario        TEXT         NOT NULL,
    direccion           TEXT         NOT NULL,
    -- Huella SHA-256 del body: detecta si se reusa una clave con datos diferentes.
    huella_solicitud    CHAR(64)     NOT NULL,
    instancia_creadora  VARCHAR(50)  NOT NULL,
    creado_en           TIMESTAMPTZ  NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_envios_idempotency_key UNIQUE (idempotency_key)
);

-- ---------------------------------------------------------------------------
-- intentos: registro de cada solicitud que llega al backend (aceptada, repetida,
-- invalida o fallida). Los rechazos previos al backend (HTTP 429) los registra
-- Nginx en su propio log, porque nunca llegan a la aplicacion.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS intentos (
    id                  BIGSERIAL    PRIMARY KEY,
    -- Identificador asignado por Nginx (X-Request-ID): enlaza con el log de Nginx.
    request_id          VARCHAR(64),
    -- Momento en que la replica recibio la solicitud (precision de microsegundos).
    recibido_en         TIMESTAMPTZ  NOT NULL,
    -- Momento en que termino el procesamiento / se cerro la conexion.
    finalizado_en       TIMESTAMPTZ  NOT NULL,
    duracion_ms         INTEGER      NOT NULL,
    metodo              VARCHAR(10)  NOT NULL,
    ruta                TEXT         NOT NULL,
    instancia           VARCHAR(50)  NOT NULL,
    ip_cliente          VARCHAR(64),
    -- Relaciona todos los intentos de una misma operacion.
    idempotency_key     VARCHAR(100),
    -- CREADO | REPETIDO | INVALIDO | CLAVE_REUTILIZADA | ERROR | OK (health) | NO_ENCONTRADO
    resultado           VARCHAR(30)  NOT NULL,
    envio_id            BIGINT       REFERENCES envios (id),
    -- Codigo HTTP emitido por el servidor.
    http_status         INTEGER,
    -- false = el cliente cerro la conexion antes de recibir la respuesta (ej. timeout).
    respuesta_entregada BOOLEAN      NOT NULL,
    detalle             TEXT
);

CREATE INDEX IF NOT EXISTS ix_intentos_idempotency_key ON intentos (idempotency_key);
CREATE INDEX IF NOT EXISTS ix_intentos_recibido_en     ON intentos (recibido_en);
CREATE INDEX IF NOT EXISTS ix_intentos_envio_id        ON intentos (envio_id);
