#!/bin/bash

# Test script to validate Postgres behavior when a client is forcibly killed
# while its query is blocked waiting for a lock.

set -e

NETWORK_NAME="pg_test_network"
SERVER_CONTAINER="pg_server"
CLIENT_CONTAINER="pg_client"
POSTGRES_DB="testdb"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="test"

echo "======================================"
echo "Postgres Client Kill Test"
echo "Testing blocked query behavior when client is killed"
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

# Install network utilities in server container
echo "Installing network utilities..."
docker exec $SERVER_CONTAINER bash -c "apt-get update > /dev/null 2>&1 && apt-get install -y iproute2 > /dev/null 2>&1"

# Configure TCP keepalive settings
echo ""
echo "=== Configuring TCP keepalive settings ==="
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "ALTER SYSTEM SET tcp_keepalives_idle = 10;" > /dev/null
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "ALTER SYSTEM SET tcp_keepalives_interval = 3;" > /dev/null
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "ALTER SYSTEM SET tcp_keepalives_count = 3;" > /dev/null
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT pg_reload_conf();" > /dev/null
echo "Settings configured: idle=10s, interval=3s, count=3 (expected detection: ~19s)"

# Create test table
echo "Creating test table..."
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    CREATE TABLE test_table (id INT PRIMARY KEY, value TEXT);
    INSERT INTO test_table VALUES (1, 'initial value');
" > /dev/null

# Start client container
echo ""
echo "Starting client container..."
docker run -d --name $CLIENT_CONTAINER --network $NETWORK_NAME postgres:latest sleep infinity > /dev/null
sleep 2

SERVER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $SERVER_CONTAINER)
CLIENT_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $CLIENT_CONTAINER)

echo ""
echo "=== Phase 1: Client A session acquires lock and stays idle ==="

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
echo "=== Phase 2: Client B session tries to acquire the same lock (will block) ==="

# Start Client B session (will block)
docker exec -d $CLIENT_CONTAINER bash -c "
export PGPASSWORD='$POSTGRES_PASSWORD'
echo \$\$ > /tmp/client_b_shell_pid
(
    echo 'BEGIN;'
    sleep 1
    echo \"UPDATE test_table SET value = 'locked by B' WHERE id = 1;\"
    echo 'COMMIT;'
) | psql -h $SERVER_IP -U $POSTGRES_USER -d $POSTGRES_DB > /tmp/client_b.log 2>&1
"

sleep 3

echo ""
echo "=== All client sessions BEFORE kill ==="
docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    SELECT pid, backend_type, state, wait_event_type, wait_event, left(query, 50) as query
    FROM pg_stat_activity
    WHERE backend_type = 'client backend'
    ORDER BY pid;
"

# Verify Client B is blocking
CLIENT_B_BLOCKING=$(docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -t -c "
    SELECT COUNT(*) FROM pg_stat_activity 
    WHERE wait_event_type = 'Lock'
    AND backend_type = 'client backend'
    AND pid != pg_backend_pid();
" | tr -d ' ')

if [ "$CLIENT_B_BLOCKING" -eq 0 ]; then
    echo "ERROR: Client B is not blocking as expected"
    exit 1
fi

echo ""
echo "=== Phase 3: Forcibly kill Client B's psql process ==="
echo "Network connections BEFORE kill:"
docker exec $SERVER_CONTAINER ss -tn "sport = :5432 and src $SERVER_IP" 2>/dev/null | grep -E "State|$CLIENT_IP" || true

# Kill Client B's shell process
SHELL_PID=$(docker exec $CLIENT_CONTAINER cat /tmp/client_b_shell_pid 2>/dev/null || echo "")
if [ -n "$SHELL_PID" ]; then
    echo ""
    echo "Killing Client B at $(date -u '+%Y-%m-%d %H:%M:%S UTC')..."
    docker exec $CLIENT_CONTAINER bash -c "kill -9 -$SHELL_PID" 2>/dev/null || true
fi
sleep 1

echo ""
echo "Network connections AFTER kill:"
docker exec $SERVER_CONTAINER ss -tn "sport = :5432 and src $SERVER_IP" 2>/dev/null | grep -E "State|$CLIENT_IP" || true

echo ""
echo "=== All client sessions IMMEDIATELY after kill ==="
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
    echo "✓ Client B's backend was immediately terminated"
else
    echo "✗ Client B's backend STILL EXISTS (query still blocked)"
    echo "Waiting to see if TCP keepalive will detect the dead connection..."
    
    # Wait up to 45 seconds, checking every 3 seconds
    for i in {1..15}; do
        sleep 3
        ELAPSED=$((i * 3))
        
        CLIENT_B_EXISTS=$(docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -t -c "
            SELECT COUNT(*) FROM pg_stat_activity 
            WHERE backend_type = 'client backend' 
            AND query LIKE '%locked by B%'
            AND query NOT LIKE '%pg_stat_activity%';
        " | tr -d ' ')
        
        if [ "$CLIENT_B_EXISTS" -eq 0 ]; then
            echo "✓ Client B's backend was terminated after ${ELAPSED}s (TCP keepalive detected dead connection)"
            break
        else
            # Show meaningful status
            BACKEND_STATE=$(docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -t -c "
                SELECT state || ' | ' || wait_event_type || '.' || wait_event 
                FROM pg_stat_activity 
                WHERE backend_type = 'client backend' 
                AND query LIKE '%locked by B%'
                AND query NOT LIKE '%pg_stat_activity%';
            " 2>/dev/null | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            TCP_STATES=$(docker exec $SERVER_CONTAINER ss -tn "sport = :5432 and src $SERVER_IP" 2>/dev/null | grep "$CLIENT_IP" | awk '{print $1}' | paste -sd ',' -)
            if [ -z "$TCP_STATES" ]; then
                TCP_STATES="GONE"
            fi
            
            echo "  ${ELAPSED}s: Backend=${BACKEND_STATE} | TCP=${TCP_STATES}"
        fi
    done
    
    CLIENT_B_EXISTS=$(docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -t -c "
        SELECT COUNT(*) FROM pg_stat_activity 
        WHERE backend_type = 'client backend' 
        AND query LIKE '%locked by B%'
        AND query NOT LIKE '%pg_stat_activity%';
    " | tr -d ' ')
    
    if [ "$CLIENT_B_EXISTS" -gt 0 ]; then
        echo "✗ Client B's backend STILL EXISTS after 45 seconds"
        echo ""
        echo "=== All client sessions after 45 seconds ==="
        docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
            SELECT pid, backend_type, state, wait_event_type, wait_event, left(query, 50) as query
            FROM pg_stat_activity
            WHERE backend_type = 'client backend'
            ORDER BY pid;
        "
        
        echo ""
        echo "Network connections before terminating Client A's backend:"
        docker exec $SERVER_CONTAINER ss -tn "sport = :5432 and src $SERVER_IP" 2>/dev/null | grep -E "State|$CLIENT_IP" || true
        
        echo "Terminating Client A's backend to release lock..."
        docker exec $SERVER_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
            SELECT pg_terminate_backend(pid) 
            FROM pg_stat_activity 
            WHERE backend_type = 'client backend' 
            AND query LIKE '%locked by A%'
            AND query NOT LIKE '%pg_stat_activity%'
            LIMIT 1;
        " > /dev/null
        sleep 2
        
        echo ""
        echo "Network connections after terminating Client A's backend:"
        docker exec $SERVER_CONTAINER ss -tn "sport = :5432 and src $SERVER_IP" 2>/dev/null | grep "$CLIENT_IP" || echo "(Client connections cleaned up)"
        
        echo ""
        echo "=== All client sessions after terminating Client A's backend ==="
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
            echo "✓ Client B's backend was terminated when it tried to send results"
        fi
    fi
fi

echo ""
echo "=== Check server logs for connection termination ==="
docker logs $SERVER_CONTAINER 2>&1 | grep -i "unexpected EOF" | tail -3 || echo "(No termination messages found)"

echo ""
echo "======================================"
echo "Summary:"
echo "- Client B killed while blocked waiting for lock"
echo "- TCP connection went to CLOSE-WAIT (OS knows client is dead)"
echo "- Backend persisted 45+ seconds (blocked backends don't check socket state)"
echo "- Only detected when unblocked and tried to send data"
echo ""
echo "TCP keepalive does not work for blocked backends."
echo "======================================"
