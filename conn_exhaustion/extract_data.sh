#!/bin/bash
# Extract data from test logs for gnuplot
# Note: only extracts data for the first two PgBouncer instances

cd "$(dirname "$0")"
[ ! -d graphs ] && mkdir graphs

# Convert MM:SS timestamp to seconds, relative to first timestamp
# Manual parsing instead of `date` for portability (macOS vs GNU date syntax differs)
timestamp_to_seconds() {
    local ts="$1"
    local first_ts="$2"
    local mm=$(echo "$ts" | cut -d: -f1 | sed 's/^0*//' | sed 's/^$/0/')
    local ss=$(echo "$ts" | cut -d: -f2 | sed 's/^0*//' | sed 's/^$/0/')
    local first_mm=$(echo "$first_ts" | cut -d: -f1 | sed 's/^0*//' | sed 's/^$/0/')
    local first_ss=$(echo "$first_ts" | cut -d: -f2 | sed 's/^0*//' | sed 's/^$/0/')
    local total=$((mm * 60 + ss))
    local first_total=$((first_mm * 60 + first_ss))
    local diff=$((total - first_total))
    # Handle minute wraparound (if test crosses hour boundary)
    if [ $diff -lt 0 ]; then
        diff=$((diff + 3600))
    fi
    echo $diff
}

for dir in results/*/; do
    name=$(basename "$dir")
    log="$dir/test_poisoned_connpool_exhaustion.log"
    
    echo "Processing $name..."
    
    # Extract monitoring data - parse the monitoring lines
    # Format: [MM:SS] pgb: cl_act=X:Y cl_wait=X:Y sv_act=X:Y | pg: tot=X act=X idl=X wait=X | tcp: est=X cw=X | xact=Xs tps=X
    # Output: sample_num time_sec pg_tot pg_act pg_wait tcp_cw tps cl_wait1 cl_wait2 xact_age
    
    first_ts=""
    grep '^\[' "$log" | grep 'pgb:' | while read -r line; do
        # Extract timestamp [MM:SS]
        ts=$(echo "$line" | grep -o '^\[[0-9:]*\]' | tr -d '[]')
        if [ -z "$first_ts" ]; then
            first_ts="$ts"
            echo "$first_ts" > /tmp/first_ts_$$
        else
            first_ts=$(cat /tmp/first_ts_$$ 2>/dev/null)
        fi
        time_sec=$(timestamp_to_seconds "$ts" "$first_ts")
        
        # Extract pg: tot value
        pg_tot=$(echo "$line" | sed 's/.*pg: tot=\([0-9]*\).*/\1/')
        # Extract pg: act value (second occurrence after pg:)
        pg_act=$(echo "$line" | sed 's/.*pg:.*act=\([0-9]*\).*/\1/')
        # Extract pg: wait value
        pg_wait=$(echo "$line" | sed 's/.*wait=\([0-9]*\) |.*/\1/')
        # Extract tcp: cw value
        tcp_cw=$(echo "$line" | sed 's/.*cw=\([0-9]*\).*/\1/')
        # Extract tps value
        tps=$(echo "$line" | sed 's/.*tps=\([0-9]*\).*/\1/')
        # Extract cl_wait - keep both values separate
        cl_wait_raw=$(echo "$line" | grep -o 'cl_wait=[0-9:]*' | sed 's/cl_wait=//')
        cl_wait1=$(echo "$cl_wait_raw" | awk -F: '{print $1+0}')
        cl_wait2=$(echo "$cl_wait_raw" | awk -F: '{if (NF>1) print $2+0; else print 0}')
        # Extract xact age (oldest transaction age in seconds)
        xact_age=$(echo "$line" | grep -o 'xact=[0-9]*s' | sed 's/xact=//;s/s//')
        
        echo "$time_sec $pg_tot $pg_act $pg_wait $tcp_cw $tps $cl_wait1 $cl_wait2 ${xact_age:-0}"
    done | nl -v0 -nln | awk '{print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10}' > "graphs/${name}_metrics.dat"
    rm -f /tmp/first_ts_$$
    
    # Also extract POOL_STATS from client.log for AvgWait
    # Output: sample_num time_sec avgwait_ms
    first_ts=""
    grep 'POOL_STATS' "$dir/client.log" 2>/dev/null | while read -r line; do
        # Extract timestamp [MM:SS]
        ts=$(echo "$line" | grep -o '^\[[0-9:]*\]' | tr -d '[]')
        if [ -z "$first_ts" ]; then
            first_ts="$ts"
            echo "$first_ts" > /tmp/first_ts_avgwait_$$
        else
            first_ts=$(cat /tmp/first_ts_avgwait_$$ 2>/dev/null)
        fi
        time_sec=$(timestamp_to_seconds "$ts" "$first_ts")
        
        avgwait=$(echo "$line" | grep -o 'AvgWait=[0-9.]*ms' | sed 's/AvgWait=//;s/ms//')
        echo "$time_sec ${avgwait:-0}"
    done | nl -v0 -nln | awk '{print $1, $2, $3}' > "graphs/${name}_avgwait.dat"
    rm -f /tmp/first_ts_avgwait_$$
done

echo "Data extraction complete."
ls -la graphs/*.dat
