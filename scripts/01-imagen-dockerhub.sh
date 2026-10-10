#!/usr/bin/env bash
# Construye, publica y vuelve a descargar la imagen versionada en Docker Hub.
# Requiere haber ejecutado antes: docker login
# Uso: DOCKERHUB_USER=tu_usuario APP_VERSION=1.0.0 bash scripts/01-imagen-dockerhub.sh
source "$(dirname "$0")/_comun.sh"
evidencia "01-imagen-dockerhub.txt"

USUARIO="${DOCKERHUB_USER:-csmattias}"
VERSION="${APP_VERSION:-1.0.0}"
IMAGEN="$USUARIO/envios-app:$VERSION"

titulo "1. Build de la imagen $IMAGEN"
docker build -t "$IMAGEN" . || exit 1

titulo "2. Usuario con el que corre la imagen (no debe ser root)"
docker run --rm --entrypoint whoami "$IMAGEN"

titulo "3. Push a Docker Hub"
docker push "$IMAGEN" || exit 1

titulo "4. Se borra la imagen local y se descarga desde Docker Hub"
docker rmi "$IMAGEN"
docker pull "$IMAGEN" || exit 1
docker image ls "$USUARIO/envios-app"

echo
echo "Imagen publicada: https://hub.docker.com/r/$USUARIO/envios-app/tags"
