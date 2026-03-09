FROM ghcr.io/gleam-lang/gleam:v1.9.0-erlang-alpine AS builder

RUN apk add --no-cache nodejs npm

WORKDIR /app

# Copy shared first (dependency of both client and server)
COPY shared/ shared/

# Build client JS bundle
COPY client/ client/
COPY package.json package-lock.json ./
RUN npm ci
RUN cd client && gleam build
RUN npx esbuild ./client/build/dev/javascript/client/app/app.mjs \
    --bundle --outfile=./server/priv/static/app.mjs --format=esm \
    --footer:js="main();"

# Build server
COPY server/ server/
RUN cd server && gleam export erlang-shipment

# --- Runtime stage ---
FROM erlang/otp:27-alpine

RUN apk add --no-cache python3 py3-pip bash

WORKDIR /app

# Install TTS server
COPY tts_server/ tts_server/
RUN pip3 install --no-cache-dir --break-system-packages -r tts_server/requirements.txt

# Copy compiled server
COPY --from=builder /app/server/build/erlang-shipment server/

# Copy static assets
COPY --from=builder /app/server/priv/static server/priv/static

# Start script: run TTS in background, then start Gleam server
COPY <<'EOF' /app/start.sh
#!/bin/bash
cd /app/tts_server && uvicorn server:app --host 0.0.0.0 --port 8766 &
cd /app/server && ./entrypoint.sh run
EOF
RUN chmod +x /app/start.sh

EXPOSE 8000

CMD ["/app/start.sh"]
