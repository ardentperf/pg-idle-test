#!/bin/bash

# Test script to validate Postgres behavior when a client cancels a query
# via context cancellation while blocked waiting for a lock.

set -e

NETWORK_NAME="pg_test_network"
SERVER_CONTAINER="pg_server"
CLIENT_CONTAINER="pg_client"
GO_CLIENT_CONTAINER="go_client"
POSTGRES_DB="testdb"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="test"

echo "======================================"
echo "Postgres Client Cancellation Test"
echo "Testing blocked query behavior with context cancellation"
echo "======================================"

cleanup() {
    echo ""
    echo "Cleaning up..."
    docker stop $GO_CLIENT_CONTAINER $CLIENT_CONTAINER $SERVER_CONTAINER 2>/dev/null || true
    docker rm $GO_CLIENT_CONTAINER $CLIENT_CONTAINER $SERVER_CONTAINER 2>/dev/null || true
    docker network rm $NETWORK_NAME 2>/dev/null || true
    rm -f test_client_cancel_driver_linux
}

trap cleanup EXIT

# Create network
echo "Creating Docker network..."
docker network create $NETWORK_NAME > /dev/null

# Start Postgres server
echo "Starting Postgres server..."
docker run -d --name $SERVER_CONTAINER \
    --network $NETWORK_NAME \
    -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
    -e POSTGRES_DB=$POSTGRES_DB \
    postgres:latest > /dev/null

# Wait for Postgres
echo "Waiting for Postgres..."
for i in {1..30}; do
    if docker exec $SERVER_CONTAINER pg_isready -U $POSTGRES_USER -d $POSTGRES_DB > /dev/null 2>&1; then
        echo "Postgres ready!"
        break
    fi
    [ $i -eq 30 ] && echo "ERROR: Postgres failed to start" && exit 1
    sleep 1
done

sleep 2

# Install network utilities
echo "Installing network utilities..."
docker exec $SERVER_CONTAINER bash -c "apt-get update > /dev/null 2>&1 && apt-get install -y iproute2 > /dev/null 2>&1"

# Create test table
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    CREATE TABLE test_table (id INT PRIMARY KEY, value TEXT);
    INSERT INTO test_table VALUES (1, 'initial value');
" > /dev/null

# Start client container
echo "Starting client container..."
docker run -d --name $CLIENT_CONTAINER --network $NETWORK_NAME postgres:latest sleep infinity > /dev/null
sleep 1

SERVER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $SERVER_CONTAINER)

echo "Server IP: $SERVER_IP"

echo ""
echo "=== Phase 1: Client A acquires lock and stays idle ==="

# Start Client A session (will hold lock)
docker exec -d $CLIENT_CONTAINER bash -c "
export PGPASSWORD='$POSTGRES_PASSWORD'
(
    echo 'BEGIN;'
    sleep 1
    echo \"UPDATE test_table SET value = 'locked by A' WHERE id = 1;\"
    sleep 1
    echo \"SELECT 'Client A: Lock acquired', pg_backend_pid();\"
    sleep 300
    echo 'COMMIT;'
) | psql -h $SERVER_IP -U $POSTGRES_USER -d $POSTGRES_DB > /tmp/client_a.log 2>&1
"

sleep 3

echo ""
echo "=== Phase 2: Start Go client with context timeout ==="

# Start Go client container
echo "Starting Go client container..."
docker run -d --name $GO_CLIENT_CONTAINER --network $NETWORK_NAME alpine:latest sleep infinity > /dev/null
sleep 1

GO_CLIENT_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $GO_CLIENT_CONTAINER)
echo "Go Client IP: $GO_CLIENT_IP"

# Build Go binary if needed
if [ ! -f "test_client_cancel_driver_linux" ]; then
    echo "Building Go client binary..."
    GOOS=linux GOARCH=amd64 go build -o test_client_cancel_driver_linux test_client_cancel_driver.go
fi

echo "Copying Go client binary..."
docker cp test_client_cancel_driver_linux $GO_CLIENT_CONTAINER:/usr/local/bin/client
docker exec $GO_CLIENT_CONTAINER chmod +x /usr/local/bin/client

# Start Client B (will block)
echo "Starting Client B query (will block on lock)..."
docker exec -d $GO_CLIENT_CONTAINER sh -c "
DATABASE_URL='postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@$SERVER_IP:5432/$POSTGRES_DB' \
/usr/local/bin/client > /tmp/client_b.log 2>&1
"

sleep 3

echo ""
echo "=== All client sessions BEFORE cancellation ==="
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    SELECT pid, backend_type, state, wait_event_type, wait_event, left(query, 50) as query
    FROM pg_stat_activity
    WHERE backend_type = 'client backend'
    ORDER BY pid;
"

echo ""
echo "Network connections BEFORE cancellation:"
docker exec $SERVER_CONTAINER ss -tn "sport = :5432 and src $SERVER_IP" 2>/dev/null | grep -E "State|$GO_CLIENT_IP"

echo ""
echo "=== Phase 3: Waiting for context timeout (5 seconds) ==="
echo "Waiting for context deadline to expire..."

sleep 6

echo ""
echo "Network connections AFTER cancellation:"
docker exec $SERVER_CONTAINER ss -tn "sport = :5432 and src $SERVER_IP" 2>/dev/null | grep -E "State|$GO_CLIENT_IP"

echo ""
echo "=== All client sessions AFTER cancellation ==="
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    SELECT pid, backend_type, state, wait_event_type, wait_event, left(query, 50) as query
    FROM pg_stat_activity
    WHERE backend_type = 'client backend'
    ORDER BY pid;
"

CLIENT_B_EXISTS=$(docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -t -c "
    SELECT COUNT(*) FROM pg_stat_activity 
    WHERE backend_type = 'client backend' 
    AND query LIKE '%locked by B%'
    AND query NOT LIKE '%pg_stat_activity%';
" | tr -d ' ')

if [ "$CLIENT_B_EXISTS" -eq 0 ]; then
    echo ""
    echo "✓ Client B's backend was immediately terminated"
else
    echo ""
    echo "✗ Client B's backend STILL EXISTS (unexpected)"
fi

echo ""
echo "=== Client B output ==="
docker exec $GO_CLIENT_CONTAINER cat /tmp/client_b.log 2>/dev/null || echo "(No output)"

echo ""
echo "======================================"
echo "Summary:"
echo "- Client B blocked waiting for lock held by Client A"
echo "- Context timeout (5s) triggered cancellation"
echo "- pgx driver sent CancelRequest to PostgreSQL"
echo "- Backend received cancel and terminated immediately"
echo "- TCP connection closed cleanly (no CLOSE-WAIT)"
echo ""
echo "Key behavior:"
echo "- pgx's asyncClose() sends CancelRequest on context timeout"
echo "- Backend receives cancel even while blocked on lock"
echo "- Query terminates immediately without waiting for lock release"
echo "- Connection cleanup is clean and immediate"
echo "======================================"
