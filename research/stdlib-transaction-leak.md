*Written with Claude 👋 - code references have been spot checked, but haven't fully verified everything with tests*

# Transaction State Leak in database/sql with pgx stdlib

## Summary

When using `database/sql` or `sqlx` with pgx's stdlib adapter, connections with open transactions can be silently returned to the connection pool and reused by other operations. This can lead to unexpected behavior where queries run inside an uncommitted transaction from a previous operation.

## The Problem

### How Connection Pooling Works

When you use `database/sql` (or `sqlx`, which wraps it), the standard library manages a connection pool. After each operation, connections are returned to the pool for reuse. Before reusing a connection, `database/sql` calls the driver's `ResetSession` method to verify the connection is in a good state.

### What pgx stdlib Checks

The stdlib adapter's `ResetSession` implementation checks:

- ✅ Whether the connection is closed (`IsClosed()`)
- ✅ Optionally pings the connection if it's been idle
- ❌ **Does NOT check transaction state (`TxStatus()`)**

### What Can Go Wrong

If application code starts a transaction but fails to commit or rollback:

```go
func leakyFunction(db *sql.DB) error {
    conn, _ := db.Conn(ctx)
    defer conn.Close()  // Returns to pool without commit/rollback
    
    conn.ExecContext(ctx, "BEGIN")
    conn.ExecContext(ctx, "INSERT INTO users (name) VALUES ('alice')")
    // Forgot to COMMIT or ROLLBACK!
    return nil
}
```

The connection is returned to the pool with `TxStatus = 'T'` (in transaction). When another goroutine acquires this connection:

```go
func innocentFunction(db *sql.DB) {
    // This runs INSIDE the leaked transaction!
    db.ExecContext(ctx, "INSERT INTO orders (...) VALUES (...)")
}
```

The second operation unknowingly executes inside the first operation's transaction. If the connection is eventually discarded (idle timeout, max lifetime, etc.), all uncommitted work from both operations is rolled back.

## Comparison: pgxpool vs database/sql

| Pool Type | Checks TxStatus on Release? | Behavior with Open Transaction |
|-----------|----------------------------|-------------------------------|
| **pgxpool** | ✅ Yes | Connection destroyed, not reused |
| **database/sql + stdlib** | ❌ No | Connection reused with open transaction |
| **sqlx + stdlib** | ❌ No | Same as database/sql (sqlx is a wrapper) |

### Why pgxpool Is Safe

pgxpool explicitly checks transaction state when releasing connections:

```go
// pgxpool/conn.go
func (c *Conn) Release() {
    // ...
    if conn.IsClosed() || conn.PgConn().IsBusy() || conn.PgConn().TxStatus() != 'I' {
        res.Destroy()  // Discard connection, don't reuse
        return
    }
    // ...
}
```

## How pgx Knows Transaction State

PostgreSQL reports transaction state in every `ReadyForQuery` message sent after each command:

| TxStatus | Meaning |
|----------|---------|
| `'I'` | Idle - not in a transaction block |
| `'T'` | In a transaction block |
| `'E'` | In a failed transaction block |

pgx tracks this automatically:

```go
// pgconn/pgconn.go
case *pgproto3.ReadyForQuery:
    pgConn.txStatus = msg.TxStatus
```

This works regardless of whether transactions are started via `conn.Begin()` or manual `EXEC "BEGIN"` statements.

## App-Layer Workaround

If you cannot upgrade pgx, you can add your own check via `OptionResetSession`:

```go
config, _ := pgx.ParseConfig(connectionString)

db := stdlib.OpenDB(*config, stdlib.OptionResetSession(func(ctx context.Context, conn *pgx.Conn) error {
    if txStatus := conn.PgConn().TxStatus(); txStatus != 'I' {
        log.Printf("WARNING: Connection returned with open transaction (TxStatus=%c)", txStatus)
        return driver.ErrBadConn  // Discard the connection
    }
    return nil
}))
```

Returning `driver.ErrBadConn` tells `database/sql` to discard the connection. The logging is optional but might be helpful for identifying application code with transaction leaks.

---

## pgx Fix

The fix adds a `TxStatus` check to stdlib's `ResetSession` method, making it consistent with pgxpool's behavior:

```go
// stdlib/sql.go
func (c *Conn) ResetSession(ctx context.Context) error {
    if c.conn.IsClosed() {
        return driver.ErrBadConn
    }

    // Discard connection if it has an open transaction. This can happen if the
    // application did not properly commit or rollback a transaction.
    if c.conn.PgConn().TxStatus() != 'I' {
        return driver.ErrBadConn
    }

    // ... rest of function unchanged
}
```

With this fix, connections with open transactions are automatically discarded when returned to the database/sql pool, preventing transaction state from leaking between operations.
