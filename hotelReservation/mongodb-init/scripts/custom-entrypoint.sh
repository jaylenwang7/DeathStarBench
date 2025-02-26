#!/bin/bash
set -e

# Handle specific DB type initialization
DB_TYPE=${DB_TYPE:-"reservation-db"}

# Start MongoDB with original entrypoint
echo "Starting MongoDB server..."
/usr/local/bin/docker-entrypoint.sh mongod --fork --logpath /var/log/mongodb.log

# Wait for MongoDB to be ready
until mongo --eval "db.adminCommand('ping')" > /dev/null 2>&1; do
  echo "Waiting for MongoDB to be ready..."
  sleep 2
done
echo "MongoDB is ready!"

# Check if database already has data
echo "Checking if database $DB_TYPE already has data..."
HAS_DATA=false

case "$DB_TYPE" in
    "reservation-db")
        # Check if the number collection has data
        COUNT=$(mongo $DB_TYPE --quiet --eval "db.number.count()" || echo "0")
        if [ "$COUNT" -gt "0" ]; then
            HAS_DATA=true
        fi
        ;;
    "profile-db")
        # Check if the hotels collection has data
        COUNT=$(mongo $DB_TYPE --quiet --eval "db.hotels.count()" || echo "0")
        if [ "$COUNT" -gt "0" ]; then
            HAS_DATA=true
        fi
        ;;
    "geo-db")
        # Check if the geo collection has data
        COUNT=$(mongo $DB_TYPE --quiet --eval "db.geo.count()" || echo "0")
        if [ "$COUNT" -gt "0" ]; then
            HAS_DATA=true
        fi
        ;;
    "rate-db")
        # Check if the inventory collection has data
        COUNT=$(mongo $DB_TYPE --quiet --eval "db.inventory.count()" || echo "0")
        if [ "$COUNT" -gt "0" ]; then
            HAS_DATA=true
        fi
        ;;
    "recommendation-db")
        # Check if the recommendation collection has data
        COUNT=$(mongo $DB_TYPE --quiet --eval "db.recommendation.count()" || echo "0")
        if [ "$COUNT" -gt "0" ]; then
            HAS_DATA=true
        fi
        ;;
    "user-db")
        # Check if the user collection has data
        COUNT=$(mongo $DB_TYPE --quiet --eval "db.user.count()" || echo "0")
        if [ "$COUNT" -gt "0" ]; then
            HAS_DATA=true
        fi
        ;;
    *)
        echo "Unknown database type: $DB_TYPE"
        exit 1
        ;;
esac

if [ "$HAS_DATA" = true ]; then
    echo "Database $DB_TYPE already has data, skipping initialization."
else
    echo "Initializing database $DB_TYPE..."
    /docker-entrypoint-initdb.d/init-db.sh
    echo "Database $DB_TYPE initialization completed."
fi

# Stop the forked MongoDB process
mongo admin --eval "db.shutdownServer()"
wait # Wait for MongoDB to stop

# Start MongoDB in foreground with normal parameters
echo "Starting MongoDB with regular parameters..."
exec /usr/local/bin/docker-entrypoint.sh "$@"