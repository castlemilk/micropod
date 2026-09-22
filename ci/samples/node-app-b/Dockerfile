# Deps-first: shares the npm cache mount (and base image) with node-app.
FROM node:24-alpine
WORKDIR /app

COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci

COPY . .
RUN npm test
ENTRYPOINT ["node", "src/index.js"]
