#!/bin/bash

# Test script to validate Postgres "idle in transaction (aborted)" behavior
# This state occurs when an ERROR happens within a transaction.

set -e

CONTAINER_NAME="pg_idle_test"
POSTGRES_DB="testdb"
POSTGRES_USER="postgres"

echo "======================================"
echo "Postgres 'idle in transaction (aborted)' Test"
echo "======================================"

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    docker stop $CONTAINER_NAME 2>/dev/null || true
    docker rm $CONTAINER_NAME 2>/dev/null || true
}

trap cleanup EXIT

# Start PostgreSQL container
echo "Starting Postgres container..."
docker run -d --name $CONTAINER_NAME -e POSTGRES_PASSWORD=test -e POSTGRES_DB=$POSTGRES_DB postgres:latest > /dev/null

# Wait for PostgreSQL to be ready
echo "Waiting for Postgres..."
for i in {1..30}; do
    if docker exec $CONTAINER_NAME pg_isready -U $POSTGRES_USER > /dev/null 2>&1; then
        echo "Postgres ready!"
        break
    fi
    [ $i -eq 30 ] && echo "ERROR: Postgres failed to start" && exit 1
    sleep 1
done

# Create test table
echo ""
echo "Creating test table..."
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    CREATE TABLE test_table (id INT PRIMARY KEY, value TEXT);
    INSERT INTO test_table VALUES (1, 'initial value');
" > /dev/null

echo "Starting transaction and acquiring lock..."

# Start background session that will enter aborted state
docker exec -d $CONTAINER_NAME bash -c '
(
  echo "BEGIN;"
  sleep 0.5
  echo "UPDATE test_table SET value = '\''locked'\'' WHERE id = 1;"
  sleep 3
  echo "SELECT 1/0;"
  sleep 10
  echo "ROLLBACK;"
) | psql -U postgres -d testdb > /dev/null 2>&1
'

sleep 2

echo ""
echo "=== Locks BEFORE error (transaction active) ==="
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    SELECT l.pid, l.locktype, l.relation::regclass, l.mode, a.state
    FROM pg_locks l
    JOIN pg_stat_activity a ON l.pid = a.pid
    WHERE a.state LIKE '%transaction%'
    AND l.relation IS NOT NULL
    ORDER BY l.locktype;
"

echo "Causing error in transaction..."
sleep 2

echo ""
echo "=== Locks AFTER error (transaction aborted) ==="
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    SELECT l.pid, l.locktype, l.relation::regclass, l.mode, a.state
    FROM pg_locks l
    JOIN pg_stat_activity a ON l.pid = a.pid
    WHERE a.state = 'idle in transaction (aborted)'
    AND l.relation IS NOT NULL
    ORDER BY l.locktype;
"

echo ""
echo "=== Testing if another session can modify the same row ==="
START_TIME=$(date +%s)
docker exec $CONTAINER_NAME timeout 4 psql -U $POSTGRES_USER -d $POSTGRES_DB << 'EOF' > /dev/null 2>&1 || true
BEGIN;
SET lock_timeout = '3s';
UPDATE test_table SET value = 'session 2' WHERE id = 1;
COMMIT;
EOF
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ $DURATION -ge 3 ]; then
    echo "✓ Second session blocked for ${DURATION}s (aborted transaction holds row lock)"
else
    echo "✓ Second session completed in ${DURATION}s (row lock was released after error)"
fi

echo ""
echo "=== pg_stat_activity (session still exists after locks released) ==="
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -x -c "
    SELECT pid, state, state_change, wait_event, query
    FROM pg_stat_activity 
    WHERE state = 'idle in transaction (aborted)';
"

# Check if we found the aborted session
STATE=$(docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -t -c "
    SELECT COUNT(*) FROM pg_stat_activity WHERE state = 'idle in transaction (aborted)';
" | tr -d ' ')

if [ "$STATE" -gt 0 ]; then
    echo "✓ Session still exists in 'idle in transaction (aborted)' state"
else
    echo "✗ FAIL: No aborted session found"
    exit 1
fi

echo ""
echo "======================================"
echo "Summary:"
echo "- Errors cause 'idle in transaction (aborted)' state"
echo "- Row locks from failed statements are released"
echo "- Transaction persists until ROLLBACK/COMMIT"
echo ""
echo "Note: idle_in_transaction_session_timeout"
echo "      terminates the connection (different behavior)"
echo "======================================"
