#!/bin/bash
set -e

[ -z "$3" ] && echo "Usage: $0 <num_pgbouncers> <poison|sleep> <peers|nopeers>" && exit 1
NUM_PGBOUNCERS=$1
MODE="$2"
PEERS_MODE="$3"

POSTGRES_USER="testuser"
POSTGRES_PASSWORD="test"
POSTGRES_DB="testdb"

# Log files
POSTGRES_LOG="postgres.log"
CLIENT_LOG="client.log"
CONSOLE_LOG="test_poisoned_connpool_exhaustion.log"

# Tee console output to log file
exec > >(tee "$CONSOLE_LOG") 2>&1

cleanup() {
    docker stop conn_exhaustion_client 2>/dev/null || true
    docker rm conn_exhaustion_client 2>/dev/null || true
    docker compose -f docker-compose.yml -f docker-compose.pgbouncers.yml down 2>/dev/null || true
    rm -f poison_connpool_linux docker-compose.pgbouncers.yml
    rm -rf pgbouncer_configs
}
trap cleanup EXIT INT TERM

echo "======================================"
echo "PgBouncer Connection Exhaustion Test"
echo "PgBouncer instances: $NUM_PGBOUNCERS, mode: $MODE, peers: $PEERS_MODE"
echo "======================================"

# Generate pgbouncer configs and docker-compose override
rm -rf pgbouncer_configs && mkdir -p pgbouncer_configs
for i in $(seq 1 $NUM_PGBOUNCERS); do
    cat > pgbouncer_configs/pgbouncer_${i}.ini << PGBCFG
[databases]
testdb = host=postgres port=5432 dbname=testdb
[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 5432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
admin_users = postgres
pool_mode = transaction
max_client_conn = 200
default_pool_size = 10
max_db_connections = 10
max_user_connections = 195
log_connections = 1
log_disconnections = 1
stats_period = 1
PGBCFG
    # Only add peer config in peers mode
    if [ "$PEERS_MODE" = "peers" ]; then
        echo "peer_id = ${i}" >> pgbouncer_configs/pgbouncer_${i}.ini
        echo "[peers]" >> pgbouncer_configs/pgbouncer_${i}.ini
        for j in $(seq 1 $NUM_PGBOUNCERS); do
            echo "${j} = host=pgb${j} port=5432" >> pgbouncer_configs/pgbouncer_${i}.ini
        done
    fi
done

# Generate docker-compose file for pgbouncer services
echo "services:" > docker-compose.pgbouncers.yml
for i in $(seq 1 $NUM_PGBOUNCERS); do
    cat >> docker-compose.pgbouncers.yml << DCCFG
  pgb${i}:
    image: edoburu/pgbouncer:v1.25.1-p0
    entrypoint: [pgbouncer, /etc/pgbouncer/pgbouncer.ini]
    volumes: [./pgbouncer_configs/pgbouncer_${i}.ini:/etc/pgbouncer/pgbouncer.ini:ro, ./userlist.txt:/etc/pgbouncer/userlist.txt:ro]
    depends_on: [postgres]
    networks:
      backend:
        aliases: [pgbouncer]
DCCFG
done

# Build and start services
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o poison_connpool_linux poison_connpool.go
docker compose -f docker-compose.yml -f docker-compose.pgbouncers.yml down 2>/dev/null || true
docker rm -f conn_exhaustion_client 2>/dev/null || true
docker compose -f docker-compose.yml -f docker-compose.pgbouncers.yml up -d

# Wait for PostgreSQL
echo "Waiting for PostgreSQL..."
for i in {1..30}; do
    docker compose exec -T postgres pg_isready -U postgres > /dev/null 2>&1 && break
    sleep 1
done
# Few more seconds for services to start up fully
sleep 5

# Setup
docker compose exec -T postgres sh -c "apt-get update -qq && apt-get install -y -qq iproute2" > /dev/null 2>&1 || true
docker compose exec -T postgres psql -U postgres -d testdb -c "
    CREATE USER testuser WITH PASSWORD 'test';
    GRANT ALL ON SCHEMA public TO testuser;
" > /dev/null 2>&1 || true

POSTGRES_CONTAINER=$(docker compose ps -q postgres)
HAPROXY_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(docker compose ps -q haproxy))

# Run client
docker run -d --name conn_exhaustion_client \
    --network conn_exhaustion_backend \
    -v "$(pwd)/poison_connpool_linux:/usr/local/bin/poison_connpool:ro" \
    alpine:latest sleep infinity

docker exec -e "DATABASE_URL=postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@$HAPROXY_IP:6432/$POSTGRES_DB" \
    conn_exhaustion_client sh -c '/usr/local/bin/poison_connpool '"$MODE"' 2> /tmp/client_stderr.log' &

# Monitor
echo ""
echo "=== Monitoring ==="
prev_xact_commit=""
start_time=$(date +%s)
while [ $(($(date +%s) - start_time)) -lt 95 ]; do
    sleep 1
    
    timestamp=$(date +%M:%S)
    
    stats=$(docker exec $POSTGRES_CONTAINER psql -U postgres -d testdb -t -c "
        SELECT count(*) || ',' || count(*) FILTER (WHERE state='active') || ',' ||
               count(*) FILTER (WHERE state='idle') || ',' || count(*) FILTER (WHERE wait_event_type='Lock') || ',' ||
               COALESCE(EXTRACT(EPOCH FROM (now() - min(xact_start)))::int, 0)
        FROM pg_stat_activity WHERE datname='testdb'" 2>/dev/null | tr -d ' ')
    
    xact_commit=$(docker exec $POSTGRES_CONTAINER psql -U postgres -d testdb -t -c "
        SELECT xact_commit FROM pg_stat_database WHERE datname='testdb'" 2>/dev/null | tr -d ' ')
    
    if [ -n "$prev_xact_commit" ]; then
        tps=$((xact_commit - prev_xact_commit))
    else
        tps=0
    fi
    prev_xact_commit=$xact_commit
    
    pgb_sv_active=""
    pgb_cl_active=""
    pgb_cl_waiting=""
    containers=$(for n in $(seq 1 $NUM_PGBOUNCERS); do docker compose -f docker-compose.yml -f docker-compose.pgbouncers.yml ps -q pgb${n}; done)
    bouncer_num=1
    for container in $containers; do
        sums=$(docker exec $container sh -c 'PGPASSWORD=test psql -h 127.0.0.1 -p 5432 -U postgres -d pgbouncer -t -c "SHOW POOLS"' 2>/dev/null | awk 'NF > 0 {cl_act += $5; sv_act += $13; cl_wait += $7} END {print cl_act+0 "," sv_act+0 "," cl_wait+0}')
        if [ -z "$sums" ] || [[ ! "$sums" =~ , ]]; then
            cl_active="ERR"; sv_active="ERR"; cl_waiting="ERR"
        else
            IFS=',' read -r cl_active sv_active cl_waiting <<< "$sums"
        fi
        if [ $bouncer_num -eq 1 ]; then
            pgb_cl_active="${cl_active:-ERR}"; pgb_cl_waiting="${cl_waiting:-ERR}"; pgb_sv_active="${sv_active:-ERR}"
        else
            pgb_cl_active="${pgb_cl_active}:${cl_active:-ERR}"; pgb_cl_waiting="${pgb_cl_waiting}:${cl_waiting:-ERR}"; pgb_sv_active="${pgb_sv_active}:${sv_active:-ERR}"
        fi
        bouncer_num=$((bouncer_num + 1))
    done
    
    tcp_states=$(docker exec $POSTGRES_CONTAINER sh -c "ss -tan | awk '/ESTAB|CLOSE-WAIT|FIN-WAIT/ {print \$1}' | sort | uniq -c" 2>/dev/null | \
        awk 'BEGIN {e=0;c=0;f=0} /ESTAB/ {e=$1} /CLOSE-WAIT/ {c=$1} /FIN-WAIT/ {f=$1} END {printf "%d,%d,%d", e, c, f}')
    
    IFS=',' read -r total active idle waiting xact_age <<< "$stats"
    IFS=',' read -r estab closewait finwait <<< "$tcp_states"
    
    printf "[%s] pgb: cl_act=%s cl_wait=%s sv_act=%s | pg: tot=%s act=%s idl=%s wait=%s | tcp: est=%s cw=%s | xact=%ss tps=%s\n" \
        "$timestamp" "${pgb_cl_active}" "${pgb_cl_waiting}" "${pgb_sv_active}" "${total:-0}" "${active:-0}" "${idle:-0}" "${waiting:-0}" "${estab:-0}" "${closewait:-0}" "${xact_age:-0}" "${tps:-0}"
done

# Capture logs
echo ""
echo "=== Capturing logs ==="
docker logs $POSTGRES_CONTAINER > "$POSTGRES_LOG" 2>&1
docker exec conn_exhaustion_client cat /tmp/client_stderr.log > "$CLIENT_LOG" 2>/dev/null || true

for idx in $(seq 1 $NUM_PGBOUNCERS); do
    container=$(docker compose -f docker-compose.yml -f docker-compose.pgbouncers.yml ps -q pgb${idx})
    docker logs $container > "pgbouncer_${idx}.log" 2>&1
done

grep POOL_STATS "$CLIENT_LOG"

# Results
echo ""
echo "=== Results & Log Files ==="
canceling=$(grep -c 'canceling statement' "$POSTGRES_LOG" || echo 0)
idle_timeout=$(grep -c 'terminating connection due to idle-in-transaction timeout' "$POSTGRES_LOG" | tr -d '\n' || echo 0)
transaction_timeout=$(grep -c 'terminating connection due to transaction timeout' "$POSTGRES_LOG" | tr -d '\n' || echo 0)
client_deadline=$(grep -c 'context deadline exceeded' "$CLIENT_LOG" | tr -d '\n' || echo 0)
client_superuser=$(grep -c 'reserved for roles with the SUPERUSER' "$CLIENT_LOG" | tr -d '\n' || echo 0)
client_max_conn=$(grep -c 'no more connections allowed (max_client_conn)' "$CLIENT_LOG" | tr -d '\n' || echo 0)
client_open_txn=$(grep -c 'Connection returned to pool with open transaction' "$CLIENT_LOG" | tr -d '\n' || echo 0)

failed_cancel=0
not_ready=0
pgb_logs=""
for i in $(seq 1 $NUM_PGBOUNCERS); do
    if [ -f "pgbouncer_${i}.log" ]; then
        fc=$(grep -c "failed cancel request" "pgbouncer_${i}.log" | tr -d '\n' || echo 0)
        failed_cancel=$((failed_cancel + fc))
        nr=$(grep -c "disconnect.*not ready" "pgbouncer_${i}.log" | tr -d '\n' || echo 0)
        not_ready=$((not_ready + nr))
        [ -n "$pgb_logs" ] && pgb_logs="$pgb_logs, "
        pgb_logs="${pgb_logs}pgbouncer_${i}.log"
    fi
done

printf "%-45s %6s   %s\n" "Metric" "Count" "Log File(s)"
printf "%-45s %6s   %s\n" "─────────────────────────────────────────────" "-─────" "─────────────────────────────────"
printf "%-45s %6s   %s\n" "PostgreSQL canceling statement" "$canceling" "$POSTGRES_LOG"
printf "%-45s %6s   %s\n" "Idle-in-transaction timeouts" "$idle_timeout" "$POSTGRES_LOG"
printf "%-45s %6s   %s\n" "Transaction timeouts" "$transaction_timeout" "$POSTGRES_LOG"
printf "%-45s %6s   %s\n" "PgBouncer failed cancel requests" "$failed_cancel" "$pgb_logs"
printf "%-45s %6s   %s\n" "PgBouncer disconnect while not ready" "$not_ready" "$pgb_logs"
printf "%-45s %6s   %s\n" "Client context deadline exceeded" "$client_deadline" "$CLIENT_LOG"
printf "%-45s %6s   %s\n" "Client superuser reserved connections" "$client_superuser" "$CLIENT_LOG"
printf "%-45s %6s   %s\n" "Client PgBouncer max_client_conn" "$client_max_conn" "$CLIENT_LOG"
printf "%-45s %6s   %s\n" "Client open transaction in pool" "$client_open_txn" "$CLIENT_LOG"

echo ""
echo "======================================"
echo "Expected results:"
echo "  - 2 PgB + poison + nopeers: TPS drop, cl_waiting spikes, backends max out near 95, system outage"
echo "  - 1 PgB + poison + nopeers: TPS drops, but connections stay healthy, system available"
echo "  - 2 PgB + poison + peers: TPS drops, cl_waiting stays low, backends stay low, system available"
echo "  - 2 PgB + sleep + nopeers: TPS drops briefly, then full recovery"
echo "  - 2 PgB + sleep + peers: TPS drops briefly, then full recovery, no connection spike"
echo "======================================"
