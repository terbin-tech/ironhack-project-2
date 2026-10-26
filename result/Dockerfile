FROM node:26-slim

# add curl for healthcheck
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl tini && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/local/app

# have nodemon available for local dev use (file watching)
RUN npm install -g nodemon

COPY package*.json ./

RUN npm ci && \
    npm cache clean --force && \
    mv /usr/local/app/node_modules /node_modules

COPY . .

# RDS CA bundle for TLS to Postgres (PG_SSL_CA). --chmod because ADD from a URL
# writes mode 600; the file sits directly in /usr/local/share because a
# directory BuildKit creates would get the same mode and the non-root user
# could not enter it.
ADD --chmod=644 https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /usr/local/share/rds-global-bundle.pem

# Set default environment variables for both the application and PostgreSQL connection
ENV PORT=80 \
    PG_HOST=db \
    PG_PORT=5432 \
    PG_USER=postgres \
    PG_DATABASE=postgres

EXPOSE 80

# node, the unprivileged user the Node image ships
USER 1000

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "server.js"]
