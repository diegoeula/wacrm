# syntax=docker/dockerfile:1
# wacrm — build multi-stage non-root (convenciones de docs/desarrollo.md del repo de infraestructura).
#
# IMPORTANTE: Next.js hornea las variables NEXT_PUBLIC_* en el bundle del cliente en BUILD time.
# Por eso la URL y la anon key de Supabase entran como build-args (la anon key es publica por
# diseno — RLS protege los datos). Los secretos reales (SERVICE_ROLE_KEY, ENCRYPTION_KEY,
# META_APP_SECRET) NUNCA entran al build: van como variables de entorno en runtime.

FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM node:22-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# Valores reales del proyecto Supabase (por deploy). Los defaults dummy permiten un build sin creds.
ARG NEXT_PUBLIC_SUPABASE_URL=https://build-placeholder.supabase.co
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY=build-placeholder-anon-key
ARG NEXT_PUBLIC_SITE_URL=
ARG NEXT_PUBLIC_APP_LOCALE=es
ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=$NEXT_PUBLIC_SUPABASE_ANON_KEY \
    NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL \
    NEXT_PUBLIC_APP_LOCALE=$NEXT_PUBLIC_APP_LOCALE \
    NEXT_TELEMETRY_DISABLED=1
# Dummies SOLO para que `next build` no falle en los modulos que leen env al cargar
# (mismo truco que la CI upstream, .github/workflows/ci.yml). No quedan en la imagen final.
ENV ENCRYPTION_KEY=0000000000000000000000000000000000000000000000000000000000000000 \
    META_APP_SECRET=build-dummy-meta-secret
RUN npm run build

FROM node:22-alpine AS run
WORKDIR /app
ENV NODE_ENV=production \
    PORT=3000 \
    HOSTNAME=0.0.0.0 \
    NEXT_TELEMETRY_DISABLED=1
RUN addgroup -S app && adduser -S app -G app
# output: "standalone" (next.config.ts) genera un server.js autocontenido con solo las deps usadas.
COPY --from=build --chown=app:app /app/.next/standalone ./
COPY --from=build --chown=app:app /app/.next/static ./.next/static
COPY --from=build --chown=app:app /app/public ./public
USER app
EXPOSE 3000
CMD ["node", "server.js"]
