FROM node:22-alpine

ENV NODE_ENV=production
WORKDIR /app

# Primero solo los archivos de dependencias para aprovechar la cache de capas.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY src ./src

# La imagen oficial de Node incluye el usuario sin privilegios "node".
USER node

EXPOSE 3000

CMD ["node", "src/index.js"]
