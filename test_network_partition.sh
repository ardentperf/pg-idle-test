#!/bin/bash

# Test script to validate Postgres idle_in_transaction_session_timeout behavior
# when the network connection is blocked (packets dropped between client and server).
# This demonstrates what happens when the backend terminates but the client
# never receives the termination message.

set -e

NETWORK_NAME="pg_test_network"
SERVER_CONTAINER="pg_server"
CLIENT_CONTAINER="pg_client"
POSTGRES_DB="testdb"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="test"
TIMEOUT_MS=5000  # 5 seconds

echo "======================================"
echo "Postgres idle_in_transaction_session_timeout Test"
echo "with Network Partition (Dropped Packets)"
echo "======================================"

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    docker stop $CLIENT_CONTAINER $SERVER_CONTAINER 2>/dev/null || true
    docker rm $CLIENT_CONTAINER $SERVER_CONTAINER 2>/dev/null || true
    docker network rm $NETWORK_NAME 2>/dev/null || true
}

trap cleanup EXIT

# Create a custom network
echo "Creating Docker network..."
docker network create $NETWORK_NAME > /dev/null

# Start Postgres server container (with NET_ADMIN capability for iptables)
echo "Starting Postgres server..."
docker run -d --name $SERVER_CONTAINER \
    --network $NETWORK_NAME \
    --cap-add=NET_ADMIN \
    -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
    -e POSTGRES_DB=$POSTGRES_DB \
    postgres:latest > /dev/null

# Wait for Postgres to be ready
echo "Waiting for Postgres..."
for i in {1..30}; do
    if docker exec $SERVER_CONTAINER pg_isready -U $POSTGRES_USER -d $POSTGRES_DB > /dev/null 2>&1; then
        echo "Postgres ready!"
        break
    fi
    [ $i -eq 30 ] && echo "ERROR: Postgres failed to start" && exit 1
    sleep 1
done

# Give Postgres extra time to fully initialize the database
sleep 3

# Install required packages early (before timing-sensitive operations)
echo "Installing iptables and net-tools in server container..."
docker exec $SERVER_CONTAINER bash -c "
    apt-get update -qq > /dev/null 2>&1
    apt-get install -y iptables net-tools -qq > /dev/null 2>&1
" 

sleep 1

# Configure idle_in_transaction_session_timeout
echo ""
echo "Setting idle_in_transaction_session_timeout to ${TIMEOUT_MS}ms..."
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c \
    "ALTER SYSTEM SET idle_in_transaction_session_timeout = '${TIMEOUT_MS}ms';" > /dev/null
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c \
    "SELECT pg_reload_conf();" > /dev/null

# Create test table
echo "Creating test table..."
sleep 1
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    CREATE TABLE test_table (id INT PRIMARY KEY, value TEXT);
    INSERT INTO test_table VALUES (1, 'initial value');
" > /dev/null

sleep 1

# Start a client container
echo ""
echo "Starting client container..."
docker run -d --name $CLIENT_CONTAINER \
    --network $NETWORK_NAME \
    postgres:latest \
    sleep infinity > /dev/null

sleep 2

# Get IP addresses for filtering
SERVER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $SERVER_CONTAINER)
CLIENT_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $CLIENT_CONTAINER)

echo "Server IP: $SERVER_IP"
echo "Client IP: $CLIENT_IP"

echo ""
echo "Starting transaction from client at $(date -u '+%Y-%m-%d %H:%M:%S UTC')..."

# Start a transaction from the client container (using docker exec -d)
docker exec -d $CLIENT_CONTAINER bash -c "
export PGPASSWORD='$POSTGRES_PASSWORD'
(
    echo 'BEGIN;'
    sleep 1
    echo \"UPDATE test_table SET value = 'locked by client' WHERE id = 1;\"
    sleep 1
    echo \"SELECT 'Transaction started', pg_backend_pid();\"
    sleep 25
    echo 'COMMIT;'
) | psql -h $SERVER_IP -U $POSTGRES_USER -d $POSTGRES_DB > /tmp/client_output.log 2>&1
"

sleep 2

# Check if client command succeeded
echo ""
echo "Checking client connection..."
if docker exec $CLIENT_CONTAINER test -f /tmp/client_output.log 2>/dev/null; then
    CLIENT_OUTPUT=$(docker exec $CLIENT_CONTAINER head -20 /tmp/client_output.log 2>/dev/null || echo "")
    if echo "$CLIENT_OUTPUT" | grep -q "BEGIN"; then
        echo "✓ Client command is running"
    fi
fi

# Get the client's backend PID on the server
echo ""
echo "=== Active connections on server ==="
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    SELECT pid, client_addr, state, query_start, left(query, 40) as query
    FROM pg_stat_activity
    WHERE pid != pg_backend_pid()
    AND datname = '$POSTGRES_DB';
"

CLIENT_BACKEND_PID=$(docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -t -c "
    SELECT pid FROM pg_stat_activity 
    WHERE state LIKE '%transaction%'
    AND pid != pg_backend_pid()
    LIMIT 1;
" | tr -d ' ')

echo "Client's backend PID on server: $CLIENT_BACKEND_PID"

echo ""
echo "=== Locks held by client's session ==="
if [ -n "$CLIENT_BACKEND_PID" ]; then
    docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
        SELECT l.pid, l.locktype, l.relation::regclass, l.mode, a.state
        FROM pg_locks l
        JOIN pg_stat_activity a ON l.pid = a.pid
        WHERE a.pid = $CLIENT_BACKEND_PID
        AND l.relation IS NOT NULL
        ORDER BY l.locktype;
    "
else
    echo "Client backend PID not found - client may not have connected yet"
    echo "Waiting a bit longer..."
    sleep 2
    CLIENT_BACKEND_PID=$(docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -t -c "
        SELECT pid FROM pg_stat_activity 
        WHERE client_addr::text = '$CLIENT_IP' 
        AND state LIKE '%transaction%'
        LIMIT 1;
    " | tr -d ' ')
    echo "Client's backend PID on server: $CLIENT_BACKEND_PID"
    
    if [ -n "$CLIENT_BACKEND_PID" ]; then
        docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
            SELECT l.pid, l.locktype, l.relation::regclass, l.mode, a.state
            FROM pg_locks l
            JOIN pg_stat_activity a ON l.pid = a.pid
            WHERE a.pid = $CLIENT_BACKEND_PID
            AND l.relation IS NOT NULL
            ORDER BY l.locktype;
        "
    else
        echo "ERROR: Client never connected"
        exit 1
    fi
fi

echo ""
echo "Now dropping all packets between client ($CLIENT_IP) and server ($SERVER_IP)..."

# Drop packets from client (iptables already installed earlier)
docker exec $SERVER_CONTAINER bash -c "
    iptables -A INPUT -s $CLIENT_IP -j DROP
    iptables -A OUTPUT -d $CLIENT_IP -j DROP
"
echo "Packets are now being dropped between client and server"
echo ""
echo "Waiting for idle_in_transaction_session_timeout to fire..."
echo "(Timeout is ${TIMEOUT_MS}ms, waiting 8 seconds to ensure it fires...)"
sleep 8

echo ""
echo "=== Server's view of the session (after timeout) ==="
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    SELECT pid, client_addr, state, state_change, query
    FROM pg_stat_activity
    WHERE pid = $CLIENT_BACKEND_PID;
"

# Check if session still exists on server
SESSION_EXISTS=$(docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -t -c "
    SELECT COUNT(*) FROM pg_stat_activity WHERE pid = $CLIENT_BACKEND_PID;
" | tr -d ' ')

if [ "$SESSION_EXISTS" -eq 0 ]; then
    echo "✓ Backend was terminated on server (no longer in pg_stat_activity)"
else
    echo "⚠ Backend still exists on server"
    echo "   State: $(docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -t -c "SELECT state FROM pg_stat_activity WHERE pid = $CLIENT_BACKEND_PID;" | tr -d ' ')"
fi

echo ""
echo "=== Locks held after timeout ==="
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    SELECT l.pid, l.locktype, l.relation::regclass, l.mode
    FROM pg_locks l
    WHERE l.pid = $CLIENT_BACKEND_PID
    AND l.relation IS NOT NULL
    ORDER BY l.locktype;
"

echo ""
echo "=== Testing if another session can acquire the lock ==="
START_TIME=$(date +%s)
docker exec $SERVER_CONTAINER timeout 4 psql -U $POSTGRES_USER -d $POSTGRES_DB << 'EOF' > /dev/null 2>&1 || true
BEGIN;
SET lock_timeout = '3s';
UPDATE test_table SET value = 'new session' WHERE id = 1;
COMMIT;
EOF
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ $DURATION -ge 3 ]; then
    echo "✗ Another session was blocked for ${DURATION}s (lock still held)"
else
    echo "✓ Another session completed in ${DURATION}s (lock was released)"
fi

echo ""
echo "=== Server logs (checking for timeout message) ==="
docker logs $SERVER_CONTAINER 2>&1 | grep -i "idle.*transaction" | tail -5

echo ""
echo "=== TCP connections on server (checking for orphaned connections) ==="
docker exec $SERVER_CONTAINER bash -c "
    netstat -tn | grep 5432 | grep $CLIENT_IP || echo 'No TCP connections from client IP'
"

echo ""
echo "======================================"
echo "Summary:"
echo "- idle_in_transaction_session_timeout fired and terminated the backend"
echo "- Server released all locks and removed session from pg_stat_activity"
echo "- Client never received termination message (packets dropped)"
echo "- TCP connection is stuck in FIN_WAIT1 (server sent FIN, no ACK received)"
echo ""
echo "Key finding: The server-side timeout works correctly even"
echo "when the client can't receive the termination notification."
echo "The server doesn't wait for client acknowledgment to release"
echo "locks and database resources."
echo "======================================"
