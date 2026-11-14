# Frontend (React + Vite). Tres etapas:
#   dev   -> servidor de desarrollo de Vite con recarga (lo usa compose.yaml)
#   build -> compila el sitio estático
#   prod  -> sirve la build con nginx
FROM node:26.13.1-slim AS base
RUN npm install -g pnpm@12.18.0
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

FROM base AS dev
COPY . .
EXPOSE 5173
CMD ["pnpm", "dev", "--host", "0.0.0.0"]

FROM base AS build
COPY . .
RUN pnpm build

FROM nginx:1.29-alpine AS prod
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
