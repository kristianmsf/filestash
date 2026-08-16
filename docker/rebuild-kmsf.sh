#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${FILESTASH_REPO_DIR:-/dados/apps/filestash-src}"
APP_DIR="${FILESTASH_APP_DIR:-/dados/apps/filestash}"
REPO_URL="${FILESTASH_REPO_URL:-https://github.com/kristianmsf/filestash}"
BRANCH="${FILESTASH_BRANCH:-kmsf}"
IMAGE="${FILESTASH_IMAGE:-kmsf-filestash}"
SERVICE="${FILESTASH_SERVICE:-filestash}"

cd "$REPO_DIR"

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERRO: existem alteracoes locais rastreadas em $REPO_DIR."
    echo "Revise com: git status"
    exit 1
fi

echo "== Atualizando branch $BRANCH =="
git fetch origin "$BRANCH"
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH"

COMMIT="$(git rev-parse --short=8 HEAD)"
echo "Commit: $COMMIT"

if docker image inspect "${IMAGE}:latest" >/dev/null 2>&1; then
    echo "== Salvando imagem atual como ${IMAGE}:rollback =="
    docker tag "${IMAGE}:latest" "${IMAGE}:rollback"
fi

echo "== Construindo ${IMAGE}:${COMMIT} =="
docker build \
    -t "${IMAGE}:${COMMIT}" \
    -t "${IMAGE}:latest" \
    --build-arg "GIT_REPO=${REPO_URL}" \
    --build-arg "GIT_BRANCH=${BRANCH}" \
    -f docker/Dockerfile.kmsf .

echo "== Validando UID/GID da imagem =="
IDENTITY="$(docker run --rm --entrypoint id "${IMAGE}:latest")"
echo "$IDENTITY"
if [[ "$IDENTITY" != *"uid=1000(filestash) gid=1000(filestash)"* ]]; then
    echo "ERRO: UID/GID inesperado. Deploy cancelado."
    exit 1
fi

echo "== Validando Compose =="
cd "$APP_DIR"
docker compose config >/dev/null

echo "== Recriando $SERVICE =="
if ! docker compose up -d --force-recreate "$SERVICE"; then
    echo "ERRO durante o deploy."
    if docker image inspect "${IMAGE}:rollback" >/dev/null 2>&1; then
        echo "Restaurando imagem anterior..."
        docker tag "${IMAGE}:rollback" "${IMAGE}:latest"
        docker compose up -d --force-recreate "$SERVICE"
    fi
    exit 1
fi

sleep 2
RUNNING="$(docker inspect -f '{{.State.Running}}' "$SERVICE" 2>/dev/null || true)"
if [[ "$RUNNING" != "true" ]]; then
    echo "ERRO: container nao permaneceu em execucao."
    docker logs --tail 50 "$SERVICE" || true
    if docker image inspect "${IMAGE}:rollback" >/dev/null 2>&1; then
        echo "Restaurando imagem anterior..."
        docker tag "${IMAGE}:rollback" "${IMAGE}:latest"
        docker compose up -d --force-recreate "$SERVICE"
    fi
    exit 1
fi

echo "== Deploy concluido =="
docker ps --filter "name=^/${SERVICE}$"
echo
echo "Imagem ativa no Compose:"
docker inspect -f '{{.Config.Image}}' "$SERVICE"
echo
echo "Logs recentes:"
docker logs --tail 20 "$SERVICE"
echo
echo "Versao construida: ${IMAGE}:${COMMIT}"
echo "Rollback disponivel: ${IMAGE}:rollback"
