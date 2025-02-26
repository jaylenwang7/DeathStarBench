FROM mongo:5.0

# Install necessary tools
RUN apt-get update && apt-get install -y curl jq && \
    rm -rf /var/lib/apt/lists/*

# Copy initialization scripts
COPY scripts/init-db.sh /docker-entrypoint-initdb.d/

# Make scripts executable
RUN chmod +x /docker-entrypoint-initdb.d/init-db.sh

# Default command
CMD ["mongod"]