*Coded and written by Claude 👋*

# Postgres Transaction State Tests

This repository contains test scripts to validate different Postgres transaction and connection behaviors, including transaction states, timeouts, network partitions, and client disconnection handling.

**View sample output:** https://github.com/ardentperf/pg-idle-test/actions/workflows/test.yml

## Server-Side Session Termination Tests

These tests focus on scenarios where the database server terminates sessions.

## Test 1: Error-Induced Transaction Abort

**Script:** `test_idle_in_transaction_aborted.sh`

### What is "Idle in Transaction (Aborted)"?

When a Postgres session is in the "idle in transaction (aborted)" state, it means:
- A previous statement within the transaction caused an error
- The transaction has been marked for rollback
- The session will ignore all commands except for ROLLBACK or COMMIT
- COMMIT in this state also results in a rollback
- **Row locks from the failed statement are released**
- The transaction itself continues to exist

### What the Test Demonstrates

1. **Error-Triggered Aborted State**: Shows that when an error occurs within a transaction, the session enters "idle in transaction (aborted)" state
2. **Lock Behavior**: Displays locks BEFORE the error and AFTER the error, demonstrating that row locks are released
3. **Session Persistence**: Shows the session still exists in pg_stat_activity even after locks are released
4. **No Blocking**: Verifies another session can immediately modify the same row

## Test 2: idle_in_transaction_session_timeout - Connection Termination

**Script:** `test_idle_in_transaction_timeout.sh`

### What is idle_in_transaction_session_timeout?

`idle_in_transaction_session_timeout` is a Postgres setting that:
- Terminates sessions that are idle in a transaction for too long
- Completely closes the connection (not just aborts the transaction)
- Releases all locks immediately
- Rolls back the transaction automatically

### What the Test Demonstrates

1. **Timeout Configuration**: Sets `idle_in_transaction_session_timeout` to 2 seconds
2. **Lock Behavior**: Shows locks BEFORE timeout and verifies they're gone AFTER
3. **Connection Termination**: Proves the session is completely removed from pg_stat_activity (not in aborted state)
4. **No Blocking**: Verifies another session can immediately modify the same row

## Key Differences

| Behavior | Error in Transaction | idle_in_transaction_session_timeout |
|----------|---------------------|-------------------------------------|
| Trigger | SQL error (division by zero, etc.) | Timeout while idle in transaction |
| Session State | "idle in transaction (aborted)" | Connection terminated (gone) |
| Visible in pg_stat_activity? | Yes | No |
| Row locks released? | Yes | Yes |
| Connection still open? | Yes | No |
| Requires explicit ROLLBACK? | Yes | No (automatic) |

## Test 3: Network Partition Scenario

**Script:** `test_network_partition.sh`

### What This Tests

This test demonstrates what happens when `idle_in_transaction_session_timeout` fires but the client can't receive the termination message due to a network partition.

### What the Test Demonstrates

1. **Two-Container Setup**: Separate client and server containers on a Docker network
2. **Lock Acquisition**: Client starts a transaction and acquires row locks
3. **Network Partition**: Uses iptables to drop all packets between client and server
4. **Timeout Fires**: Server terminates the backend after timeout
5. **Lock Release**: Verifies locks are released even though client can't acknowledge
6. **TCP State**: Shows the TCP connection stuck in FIN_WAIT1

### Key Findings

- The server-side timeout works correctly even when packets are dropped
- Server doesn't wait for client acknowledgment to release resources
- Locks are released immediately upon backend termination
- TCP connection enters FIN_WAIT1 (server sent FIN, waiting for ACK that never comes)
- The FIN_WAIT1 state will eventually timeout at the OS level

## Test 4: Client Kill with Blocked Query

**Script:** `test_client_kill.sh`

### What This Tests

This test demonstrates what happens when a client is forcibly killed (SIGKILL) while its query is blocked waiting for a lock. Postgres does not immediately detect the broken connection.

This means that if a client in a retry loop opens new connections and then forcibly kills them when they timeout waiting for a lock, those queries will wait indefinitely until the database server runs out of available connections. (This is the default behavior of golang context deadlines.)

### What the Test Demonstrates

1. **TCP Keepalive Configuration**: Sets aggressive keepalive (idle=10s, interval=3s, count=3)
2. **Lock Blocking**: Session A holds a lock (idle in transaction), Session B blocks waiting for it
3. **Client Kill**: Session B's psql process is killed with SIGKILL while blocked
4. **TCP State Monitoring**: Shows connection goes to CLOSE-WAIT (OS knows client is dead)
5. **Backend Persistence**: Proves Session B's backend persists for 60+ seconds despite keepalive
6. **Cleanup on Unblock**: Backend only detects dead client when the lock is released and it tries to send data

### Key Findings

- TCP connection goes to CLOSE-WAIT immediately after client kill (OS detects the dead connection)
- But Session B's Postgres backend remains "active" and blocked on the lock for 60+ seconds
- TCP keepalive does not work for blocked backends
- Blocked backends don't check socket state until they try to read/write the socket
- When the lock is released, the backend discovers "unexpected EOF on client connection"

## Running the Tests

*Note: Uses Postgres latest version in Docker*

**Prerequisites:**

- Docker installed and available
- Bash shell

**View sample output:** https://github.com/ardentperf/pg-idle-test/actions/workflows/test.yml

```bash
# Test 1: Error-induced aborted state
./test_idle_in_transaction_aborted.sh

# Test 2: Timeout-induced termination
./test_idle_in_transaction_timeout.sh

# Test 3: Timeout with network partition
./test_network_partition.sh

# Test 4: Client kill with blocked query
./test_client_kill.sh
```
