*Written with Claude 👋 - code references have been spot checked, but haven't fully verified everything with tests*

# pgx Cancellation with DNS Round Robin

## Summary

**Yes, pgx is smart enough to ensure cancellation messages always go to the same IP as the connection being canceled, even when PostgreSQL is behind DNS round robin.**

pgx achieves this by using `conn.RemoteAddr()` to get the actual connected IP address from the established TCP connection, rather than re-resolving the DNS hostname. This ensures the cancel request goes to the exact same server that is processing the query.

## How It Works

### The Key Implementation

When pgx needs to send a cancel request, it extracts the remote address from the active connection rather than using the original connection configuration:

```1005:1019:pgconn/pgconn.go
func (pgConn *PgConn) CancelRequest(ctx context.Context) error {
	// Open a cancellation request to the same server. The address is taken from the net.Conn directly instead of reusing
	// the connection config. This is important in high availability configurations where fallback connections may be
	// specified or DNS may be used to load balance.
	serverAddr := pgConn.conn.RemoteAddr()
	var serverNetwork string
	var serverAddress string
	if serverAddr.Network() == "unix" {
		// for unix sockets, RemoteAddr() calls getpeername() which returns the name the
		// server passed to bind(). For Postgres, this is always a relative path "./.s.PGSQL.5432"
		// so connecting to it will fail. Fall back to the config's value
		serverNetwork, serverAddress = NetworkAddress(pgConn.config.Host, pgConn.config.Port)
	} else {
		serverNetwork, serverAddress = serverAddr.Network(), serverAddr.String()
	}
```

[View on GitHub](https://github.com/jackc/pgx/blob/v5.8.0/pgconn/pgconn.go#L1005-L1019)

### Why This Matters

The comment in the code explicitly states the intention:

> "The address is taken from the net.Conn directly instead of reusing the connection config. This is important in high availability configurations where fallback connections may be specified or DNS may be used to load balance."

This design handles several scenarios:

1. **DNS Round Robin**: When multiple IPs are returned for a hostname, each connection establishes to one specific IP. The cancel request uses that exact IP.

2. **High Availability Configurations**: When multiple fallback servers are configured, the cancel goes to whichever server actually accepted the connection.

3. **Load Balancers**: Even if DNS or configuration changes between query start and cancellation, the cancel uses the actual connected endpoint.

### Connection State Storage

The `PgConn` struct stores the necessary information to cancel a specific backend connection:

```76:79:pgconn/pgconn.go
type PgConn struct {
	conn              net.Conn
	pid               uint32            // backend pid
	secretKey         uint32            // key to use to send a cancel query message to the server
```

[View on GitHub](https://github.com/jackc/pgx/blob/v5.8.0/pgconn/pgconn.go#L76-L79)

- `conn`: The actual TCP connection with the resolved IP address
- `pid`: The PostgreSQL backend process ID
- `secretKey`: The secret key for this specific backend session

### The Cancel Protocol

The cancel request:

1. Retrieves the remote address from `pgConn.conn.RemoteAddr()`
2. Opens a new connection to that exact address
3. Sends a cancel message with the `pid` and `secretKey` from the original connection

```1041:1055:pgconn/pgconn.go
	buf := make([]byte, 16)
	binary.BigEndian.PutUint32(buf[0:4], 16)
	binary.BigEndian.PutUint32(buf[4:8], 80877102)
	binary.BigEndian.PutUint32(buf[8:12], pgConn.pid)
	binary.BigEndian.PutUint32(buf[12:16], pgConn.secretKey)

	if _, err := cancelConn.Write(buf); err != nil {
		return fmt.Errorf("write to connection for cancellation: %w", err)
	}

	// Wait for the cancel request to be acknowledged by the server.
	// It copies the behavior of the libpq: https://github.com/postgres/postgres/blob/REL_16_0/src/interfaces/libpq/fe-connect.c#L4946-L4960
	_, _ = cancelConn.Read(buf)

	return nil
```

[View on GitHub](https://github.com/jackc/pgx/blob/v5.8.0/pgconn/pgconn.go#L1041-L1055)

## DNS Round Robin Scenario

### Example Setup

```
db.example.com resolves to:
- 10.0.1.100
- 10.0.1.101
- 10.0.1.102
```

### What Happens

1. **Initial Connection**:
   - Client resolves `db.example.com` → gets [10.0.1.100, 10.0.1.101, 10.0.1.102]
   - Client connects to 10.0.1.100 (or whichever is tried first/succeeds)
   - PostgreSQL backend on 10.0.1.100 returns `pid=12345` and `secretKey=67890`
   - `pgConn.conn` stores the TCP connection to 10.0.1.100

2. **Context Cancellation**:
   - Query timeout occurs or context is canceled
   - pgx calls `CancelRequest()`
   - `conn.RemoteAddr()` returns "10.0.1.100:5432" (the actual connected IP)
   - pgx opens a NEW connection to 10.0.1.100:5432 (NOT re-resolving DNS)
   - Sends cancel message with pid=12345, secretKey=67890

3. **Result**:
   - Cancel arrives at the correct backend on 10.0.1.100
   - The query running in process 12345 is canceled
   - Even if DNS round robin would return 10.0.1.101 next, the cancel still goes to 10.0.1.100

## Edge Cases

### Unix Domain Sockets

For Unix domain sockets, `RemoteAddr()` returns a relative path that won't work for reconnection. In this case, pgx falls back to using the original configuration:

```1012:1016:pgconn/pgconn.go
	if serverAddr.Network() == "unix" {
		// for unix sockets, RemoteAddr() calls getpeername() which returns the name the
		// server passed to bind(). For Postgres, this is always a relative path "./.s.PGSQL.5432"
		// so connecting to it will fail. Fall back to the config's value
		serverNetwork, serverAddress = NetworkAddress(pgConn.config.Host, pgConn.config.Port)
```

[View on GitHub](https://github.com/jackc/pgx/blob/v5.8.0/pgconn/pgconn.go#L1012-L1016)

This is safe because Unix sockets don't have the DNS round robin problem—there's only one endpoint.

### Cancel Request Failure

If the cancel request connection fails (e.g., server is at `max_connections`), pgx returns an error but the original connection state is already closed. The PostgreSQL backend will eventually notice the connection drop.

## When Cancellation Happens

For context on when pgx sends cancel requests, see:
- [`cancellation-behavior.md`](./cancellation-behavior.md) - Details on default cancellation behavior
- [`correction.md`](./correction.md) - Clarification that pgx DOES send cancel requests by default

## Conclusion

pgx's implementation is robust for DNS round robin scenarios. By using `conn.RemoteAddr()` to retrieve the actual connected IP address instead of re-resolving the hostname, pgx ensures that:

1. Cancel requests always reach the correct backend server
2. DNS changes between connection and cancellation don't affect correctness
3. Load balancing and high availability configurations work correctly
4. The PostgreSQL protocol's backend process identification (pid + secret key) is properly respected

This design follows the PostgreSQL wire protocol correctly and mirrors the behavior of libpq, PostgreSQL's reference client library.
