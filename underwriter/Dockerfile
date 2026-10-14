FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY server.mjs ./
RUN mkdir -p /app/data && chown node:node /app/data
USER node
ENV PORT=8080 DATA_DIR=/app/data
EXPOSE 8080
CMD ["node", "server.mjs"]
