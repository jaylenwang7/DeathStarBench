FROM mongo:5.0

# Install necessary tools
RUN apt-get update && apt-get install -y curl jq && \
    rm -rf /var/lib/apt/lists/*

# Copy initialization scripts
COPY scripts/init-db.sh /docker-entrypoint-initdb.d/
COPY scripts/custom-entrypoint.sh /usr/local/bin/

# Make scripts executable
RUN chmod +x /docker-entrypoint-initdb.d/init-db.sh
RUN chmod +x /usr/local/bin/custom-entrypoint.sh

# Set custom entrypoint
ENTRYPOINT ["custom-entrypoint.sh"]

# Default command
CMD ["mongod"]