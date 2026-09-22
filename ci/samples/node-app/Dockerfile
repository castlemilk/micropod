# Deps-first: source-only changes reuse the npm-ci layer and the npm cache.
FROM node:24-alpine
WORKDIR /app

COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci

COPY . .
RUN npm test
ENTRYPOINT ["node", "src/index.js"]
