#!/bin/bash

# Test script to validate Postgres idle_in_transaction_session_timeout behavior
# This setting terminates connections that are idle in transaction for too long.

set -e

CONTAINER_NAME="pg_idle_timeout_test"
POSTGRES_DB="testdb"
POSTGRES_USER="postgres"
TIMEOUT_MS=2000  # 2 seconds

echo "======================================"
echo "Postgres idle_in_transaction_session_timeout Test"
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

# Configure idle_in_transaction_session_timeout
echo ""
echo "Setting idle_in_transaction_session_timeout to ${TIMEOUT_MS}ms..."
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "ALTER SYSTEM SET idle_in_transaction_session_timeout = '${TIMEOUT_MS}ms';" > /dev/null
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT pg_reload_conf();" > /dev/null

# Create test table
echo "Creating test table..."
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    CREATE TABLE test_table (id INT PRIMARY KEY, value TEXT);
    INSERT INTO test_table VALUES (1, 'initial value');
" > /dev/null

echo ""
echo "Starting transaction and acquiring lock at $(date -u '+%Y-%m-%d %H:%M:%S UTC')..."

# Start background session that will be terminated by timeout
docker exec -d $CONTAINER_NAME bash -c '
(
  echo "BEGIN;"
  sleep 0.5
  echo "UPDATE test_table SET value = '\''locked'\'' WHERE id = 1;"
  sleep 10
  echo "SELECT '\''This should never execute'\'', pg_backend_pid();"
  sleep 0.5
  echo "COMMIT;"
) | psql -U postgres -d testdb > /tmp/psql_timeout_test.log 2>&1
'

sleep 1

echo ""
echo "=== Locks BEFORE timeout (transaction active) ==="
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    SELECT l.pid, l.locktype, l.relation::regclass, l.mode, a.state
    FROM pg_locks l
    JOIN pg_stat_activity a ON l.pid = a.pid
    WHERE a.state LIKE '%transaction%'
    AND l.relation IS NOT NULL
    ORDER BY l.locktype;
"

# Get the PID before timeout
PID_BEFORE=$(docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -t -c "
    SELECT pid FROM pg_stat_activity WHERE state = 'idle in transaction' LIMIT 1;
" | tr -d ' ')

echo "Transaction PID: $PID_BEFORE"

echo ""
echo "Waiting for idle_in_transaction_session_timeout to fire..."
sleep 3

echo ""
echo "=== pg_stat_activity AFTER timeout ==="
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    SELECT pid, state, query 
    FROM pg_stat_activity 
    WHERE pid = $PID_BEFORE;
"

# Check if session was terminated
SESSION_EXISTS=$(docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -t -c "
    SELECT COUNT(*) FROM pg_stat_activity WHERE pid = $PID_BEFORE;
" | tr -d ' ')

if [ "$SESSION_EXISTS" -eq 0 ]; then
    echo "✓ Session was terminated (no longer exists in pg_stat_activity)"
else
    echo "✗ FAIL: Session still exists (was not terminated)"
    exit 1
fi

echo ""
echo "=== Locks AFTER timeout ==="
docker exec $CONTAINER_NAME psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
    SELECT l.pid, l.locktype, l.relation::regclass, l.mode
    FROM pg_locks l
    WHERE l.pid = $PID_BEFORE
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
    echo "✗ FAIL: Second session blocked for ${DURATION}s (lock was not released)"
    exit 1
else
    echo "✓ Second session completed in ${DURATION}s (lock was released)"
fi

echo ""
echo "=== Postgres log (checking for timeout message) ==="
docker logs $CONTAINER_NAME 2>&1 | grep -i "idle.*transaction" | tail -5 || echo "(No timeout message found in logs)"

echo ""
echo "======================================"
echo "Summary:"
echo "- idle_in_transaction_session_timeout terminates the connection"
echo "- Session is completely removed from pg_stat_activity"
echo "- All locks are released immediately"
echo "- Transaction is rolled back"
echo ""
echo "Key difference: Unlike errors (which create 'idle in"
echo "transaction (aborted)' state), the timeout terminates"
echo "the connection entirely."
echo "======================================"
