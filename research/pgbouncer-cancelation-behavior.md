# PgBouncer Cancellation Request Behavior

This document explains how PgBouncer handles query cancellation requests, client disconnections during queries, the related connection states visible in `SHOW POOLS`, and disconnection log messages.

> **Source Code Reference:** This document references the [PgBouncer source code on GitHub](https://github.com/pgbouncer/pgbouncer). All source links point to the [`pgbouncer_1_25_1`](https://github.com/pgbouncer/pgbouncer/tree/pgbouncer_1_25_1) tag for stability.

## Table of Contents

- [Overview](#overview)
- [Client Disconnection During a Query](#client-disconnection-during-a-query)
- [Explicit Cancel Requests](#explicit-cancel-requests)
- [Cancel Requests in Load-Balanced Setups (Peering)](#cancel-requests-in-load-balanced-setups-peering)
- [Server States in SHOW POOLS](#server-states-in-show-pools)
- [Version History](#version-history)
- [FAQ](#faq)

---

## Overview

There are two distinct scenarios to understand:

1. **Client disconnects during a query** - The client closes its connection while a query is still running on the server.
2. **Explicit cancel request** - The client sends a PostgreSQL `CancelRequest` message (e.g., via Ctrl+C in psql or `PQcancel()` in libpq).

These scenarios are handled very differently by PgBouncer.

### Log Message Format

PgBouncer logs disconnect messages when `log_disconnections=1` (the default). Messages use these prefixes:

- **`C-0x...`** — Client connection (from application to PgBouncer)
- **`S-0x...`** — Server connection (from PgBouncer to PostgreSQL)

```
LOG <prefix>: <db>/<user>@<address>:<port> closing because: <reason> (age=<duration>)
```

---

## Client Disconnection During a Query

### Key Behavior

**PgBouncer does NOT automatically cancel running queries when a client disconnects.**

When a client closes its connection while a query is in progress:

1. The server connection is **closed/terminated** entirely
2. The server connection is **NOT reclaimed** for use by other clients
3. PgBouncer does **NOT** send a cancel request to PostgreSQL
4. The query continues running on PostgreSQL until it completes (or PostgreSQL detects the broken connection)

### Code Reference

From [`src/objects.c`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c) in the [`disconnect_client_sqlstate()`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L1465) function:

```c
case CL_ACTIVE:
case CL_LOGIN:
    if (client->link) {
        PgSocket *server = client->link;
        if (!server->ready) {
            server->link = NULL;
            client->link = NULL;
            /*
             * This can happen if the client connection is normally
             * closed while the server has a transaction block open.
             * Then there is no way for us to reset the server other
             * than by closing it.
             */
            disconnect_server(server, true, 
                "client disconnect while server was not ready");
        } else if (statlist_count(&server->outstanding_requests) > 0) {
            server->link = NULL;
            client->link = NULL;
            disconnect_server(server, true, 
                "client disconnected with query in progress");
        } else if (!sbuf_is_empty(&server->sbuf)) {
            server->link = NULL;
            client->link = NULL;
            disconnect_server(server, true, 
                "client disconnect before everything was sent to server");
        } else {
            release_server(server);
        }
    }
```

See also:
- [`release_server()`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L1204) - Returns server to idle pool
- [`disconnect_server()`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L1344) - Closes server connection

### Implications

| Scenario | Outcome |
|----------|---------|
| Client disconnects during query | Server connection **closed** |
| Client disconnects in transaction | Server connection **closed** |
| Client disconnects while idle | Server connection **released** to pool |

**The server connection will NOT appear in `SHOW POOLS`** after the client disconnects during a query because the connection is terminated, not moved to another state.

### Log Messages

When a client disconnects during a query, PgBouncer logs two messages—one for the client and one for the server:

```
LOG C-0x1234: db/user@10.0.0.1:54321 closing because: client unexpected eof (age=30s)
LOG S-0x5678: db/user@10.0.0.1:5432 closing because: client disconnect while server was not ready (age=25s)
```

**Client disconnect message** (the `C-` log line):

| Message | Description | Source |
|---------|-------------|--------|
| `client unexpected eof` | Client closed TCP connection unexpectedly (e.g., application crashed, network dropped, user killed process) | [`src/client.c:1733`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/client.c#L1733) |

**Server disconnect messages** (the `S-` log line):

| Message | Description | Source |
|---------|-------------|--------|
| `client disconnect while server was not ready` | Server is linked to the client (the `ready` flag is `false` whenever a server is actively assigned to a client). This is the typical message for any mid-query or mid-transaction disconnect. | [`src/objects.c:1502`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L1502) |
| `client disconnected with query in progress` | Server's `ready` flag is `true` but has outstanding requests. In practice this is rare—`ready` is typically `false` while linked. | [`src/objects.c:1513`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L1513) |
| `client disconnect before everything was sent to the server` | Server is "ready" with no outstanding requests, but PgBouncer's send buffer still has data queued. Also rare in practice. | [`src/objects.c:1518`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L1518) |

> **Note:** The `ready` flag is set to `false` when a server is [linked to a client](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L2432) and only becomes `true` when [unlinked](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L2435). This means `client disconnect while server was not ready` is the message you'll see for virtually all mid-query disconnections.

---

## Explicit Cancel Requests

When a client sends an explicit cancel request (separate from the main connection), PgBouncer:

1. Opens a new connection to the PostgreSQL server
2. Sends the cancel request packet
3. Waits for confirmation
4. The server running the query moves to `SV_BEING_CANCELED` state until all cancel requests complete

See [`accept_cancel_request()`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L2140) and [`forward_cancel_request()`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L2264) in `src/objects.c`.

### Cancel Request Flow

PostgreSQL's cancel protocol requires the client to open a **second TCP connection** to send the cancel request. This is separate from the connection running the query.

```
Client                         PgBouncer                      PostgreSQL
  |                                |                               |
  |==== Query connection (C1) ====>|==== Server connection (S1) ==>|
  |         (query running)        |         (query running)       |
  |                                |                               |
  |---- New connection (C2) ------>|                               |
  |---- CancelRequest (on C2) ---->|                               |
  |                                |---- New connection (S2) ----->|
  |                                |---- CancelRequest (on S2) --->|
  |                                |<--- S2 closed ----------------|
  |<--- C2 closed -----------------|                               |
  |                                |                               |
  |                                | (S1 state: SV_ACTIVE -> SV_BEING_CANCELED)
  |                                |                               |
  |<--- Query cancelled (on C1) ---|<--- Error response (on S1) ---|
  |                                |                               |
  |                                | (S1 state: SV_BEING_CANCELED -> SV_IDLE)
```

- **C1/S1**: Original query connection pair (remains open)
- **C2/S2**: Temporary cancel connections (opened and closed just for the cancel)

### The `sv_being_canceled` State

This state is specifically for servers that:
- Had a query cancelled via an explicit cancel request
- Are waiting for all in-flight cancel requests to complete before being returned to the idle pool

This prevents a race condition where:
- Client A's query is cancelled
- Server is immediately reused by Client B
- The cancel request (still in flight) accidentally cancels Client B's query

The state is defined in [`include/bouncer.h`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/include/bouncer.h#L83) and managed in [`src/objects.c`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L1283-L1286).

### Log Messages

When a cancel request is processed, PgBouncer logs messages for the temporary cancel connections (C2/S2 in the diagram above). The `(nodb)/(nouser)` indicates this is the cancel connection, not the main query connection.

**Successful cancel:**

```
LOG S-0xABCD: db/user@10.0.0.1:5432 new connection to server    <-- cancel connection opened
LOG C-0x9999: (nodb)/(nouser)@10.0.0.1:54322 closing because: successfully sent cancel request (age=0s)
LOG S-0xABCD: db/user@10.0.0.1:5432 closing because: successfully sent cancel request (age=0s)
```

**Cancel request log messages:**

| Log Message | Description | Source |
|-------------|-------------|--------|
| `successfully sent cancel request` (C-) | Cancel request was forwarded to PostgreSQL; cancel client connection closed | [`src/objects.c:1331`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L1331) |
| `successfully sent cancel request` (S-) | Cancel server connection completed its job and closed | [`src/server.c:763`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/server.c#L763) |
| `cancel request for idle client` | Target client's query already finished; nothing to cancel | [`src/objects.c:2217`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L2217) |
| `cancel request for console client` | Target is an admin console session; handled internally | [`src/objects.c:2206`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L2206) |
| `failed cancel request` | No client found with matching cancel key (see causes below) | [`src/objects.c:2196`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L2196) |
| `cancel_wait_timeout` | Cancel request waited too long for a server connection | [`src/janitor.c:462`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/janitor.c#L462) |
| `client gave up on cancel request...` | Cancel client disconnected before cancel could be sent; server connection also closed | [`src/objects.c:1540`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L1540) |

**Causes of `failed cancel request`:**

PgBouncer [searches all clients](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L2175-L2191) to find one with a matching 8-byte cancel key. The cancel key is assigned when the client connects and remains constant for the connection's lifetime. The lookup fails when:

1. **Client already disconnected** — The original connection closed before the cancel request arrived
2. **Wrong PgBouncer instance** — In load-balanced setups, the cancel request may arrive at a different PgBouncer than the one handling the original connection (this is why [peering](#cancel-requests-in-load-balanced-setups-peering) exists)
3. **Invalid cancel key** — Corrupted or incorrect key in the cancel request

Note: If the client is found but is idle (query already finished), PgBouncer logs `cancel request for idle client` instead—see the log message table above.

---

## Cancel Requests in Load-Balanced Setups (Peering)

### The Problem

When running multiple PgBouncer instances behind a load balancer (including using `so_reuseport` to have multiple processes on the same port), cancel requests often fail. This is because PostgreSQL's cancel protocol requires the client to open a **new TCP connection** to send the cancel request, and that new connection may be routed to a different PgBouncer instance than the one handling the original query.

```
                                    Load Balancer
                                         |
                    +--------------------+--------------------+
                    |                                         |
              PgBouncer A                               PgBouncer B
                    |                                         |
              PostgreSQL A                              PostgreSQL B

1. Client connects through load balancer → routed to PgBouncer A
2. Client runs a long query on PgBouncer A
3. Client sends cancel request (new connection) → routed to PgBouncer B
4. PgBouncer B has no record of the cancel key → "failed cancel request"
```

This is the root cause of the `failed cancel request` log messages in load-balanced deployments.

### The Solution: PgBouncer Peering

Introduced in **PgBouncer 1.19.0** ([#666](https://github.com/pgbouncer/pgbouncer/pull/666)), the peering feature allows multiple PgBouncer instances to forward cancel requests to each other. When a PgBouncer receives a cancel request for an unknown session, it forwards the request to its peers until the correct instance is found.

### How Peering Works

Each PgBouncer in a peered group embeds its `peer_id` into the cancel keys it generates. When a cancel request arrives:

1. PgBouncer extracts the `peer_id` from the cancel key
2. If the `peer_id` matches its own, it processes the cancel locally
3. If the `peer_id` belongs to a peer, it forwards the cancel request to that peer
4. The peer then processes the cancel request as normal

```
                                    Load Balancer
                                         |
                    +--------------------+--------------------+
                    |                                         |
              PgBouncer A                               PgBouncer B
              (peer_id=1)  <-- peering connection -->   (peer_id=2)
                    |                                         |
              PostgreSQL A                              PostgreSQL B

1. Client connects through load balancer → routed to PgBouncer A (peer_id=1)
2. Client runs a long query on PgBouncer A
3. Client sends cancel request → routed to PgBouncer B
4. PgBouncer B sees peer_id=1 in cancel key → forwards to PgBouncer A
5. PgBouncer A receives forwarded cancel → processes successfully
```

### Configuration

To enable peering, configure each PgBouncer instance with:

1. A unique `peer_id` (1-16383)
2. A `[peers]` section listing all peers in the group

**Example configuration for a 2-node setup:**

PgBouncer instance 1 (`pgbouncer1.ini`):
```ini
[pgbouncer]
peer_id = 1
listen_addr = 0.0.0.0
listen_port = 6432
; ... other settings ...

[peers]
1 = host=/var/run/pgbouncer1
2 = host=pgbouncer2.example.com port=6432
```

PgBouncer instance 2 (`pgbouncer2.ini`):
```ini
[pgbouncer]
peer_id = 2
listen_addr = 0.0.0.0
listen_port = 6432
; ... other settings ...

[peers]
1 = host=pgbouncer1.example.com port=6432
2 = host=/var/run/pgbouncer2
```

**Key configuration notes:**

- The `peer_id` must be unique within the peered group (1-16383)
- Each peer's `[peers]` section should list **all** peers, including itself
- Including yourself in `[peers]` allows using identical configs with only `peer_id` differing
- Peer connections can use Unix sockets (recommended for same-host) or TCP

### Peer Pool Statistics

Peering creates a special pool type visible in admin commands:

**`SHOW PEER_POOLS`** — Shows statistics for peer connections:

| Column | Description |
|--------|-------------|
| `peer_id` | ID of the configured peer |
| `sv_active` | Connections actively forwarding cancel requests |
| `sv_idle` | Idle connections to the peer |
| `sv_used` | Connections recently used |
| `sv_tested` | Connections being tested |
| `sv_login` | Connections in login phase |

**`SHOW PEERS`** — Shows configured peer entries and their state.

### Related Configuration Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `peer_id` | 0 | Unique ID for this PgBouncer in the peered group. 0 disables peering. |
| `cancel_wait_timeout` | 10s | How long to wait for a server connection to forward a cancel request (including to peers) |

### Peering Log Messages

| Log Message | Description |
|-------------|-------------|
| `forwarding cancel request to peer N` | Cancel request being sent to peer with ID N |
| `successfully sent cancel request` (to peer) | Cancel forwarded to peer successfully |
| `failed cancel request` | No matching client found locally or on any peer |

### Cross-Version Peering

Peering is supported between different PgBouncer versions with one important caveat:

> **Warning:** The encoding of `peer_id` in cancel keys changed in version 1.21.0 ([#945](https://github.com/pgbouncer/pgbouncer/pull/945)). Peering will not work correctly if some peers are on 1.19.0-1.20.x and others are on 1.21.0+. All peers should be on the same side of the 1.21.0 version boundary.

### Source Code References

| File | Description |
|------|-------------|
| [`src/objects.c`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c) | `forward_cancel_to_peer()`, peer pool management |
| [`src/loader.c`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/loader.c) | `[peers]` section parsing |
| [`src/janitor.c`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/janitor.c) | Peer connection maintenance |

---

## Server States in SHOW POOLS

The `SHOW POOLS` command is implemented in [`src/admin.c`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/admin.c#L896). See also the [usage documentation](https://www.pgbouncer.org/usage.html#show-pools).

### Current Columns (v1.19.0+)

| Column | Description |
|--------|-------------|
| `sv_active` | Server connections linked to a client |
| `sv_active_cancel` | Server connections forwarding a cancel request |
| `sv_being_canceled` | Servers waiting for cancel requests to complete before returning to idle |
| `sv_idle` | Server connections available for use |
| `sv_used` | Servers needing `server_check_query` before reuse |
| `sv_tested` | Servers running `server_reset_query` or `server_check_query` |
| `sv_login` | Server connections in login phase |

### Client Cancel Columns

| Column | Description |
|--------|-------------|
| `cl_active_cancel_req` | Clients with cancel requests forwarded to server |
| `cl_waiting_cancel_req` | Clients with cancel requests waiting for a server connection |

### State Transitions

States are defined in the [`SocketState` enum](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/include/bouncer.h#L70-L89) in `include/bouncer.h`.

```
Normal query flow:
  sv_login -> sv_idle -> sv_active -> sv_idle

With cancel request:
  sv_active -> sv_being_canceled -> sv_idle
              (while cancel requests complete)

Cancel server connection:
  sv_login -> sv_active_cancel -> (closed)
```

The pool structure with all server lists is defined in [`struct PgPool`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/include/bouncer.h#L345-L470) in `include/bouncer.h`.

---

## Version History

See the full [NEWS.md](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/NEWS.md) for all release notes.

### Summary Table

| Version | Client Cancel States | Server Cancel States | Peering Support |
|---------|---------------------|---------------------|-----------------|
| ≤1.15 | `CL_CANCEL` | none | No |
| 1.16-1.17 | `CL_CANCEL` | none | No |
| 1.18.0 | `CL_WAITING_CANCEL`, `CL_ACTIVE_CANCEL` | `SV_WAIT_CANCELS`, `SV_ACTIVE_CANCEL` | No |
| 1.19.0-1.20.x | `CL_WAITING_CANCEL`, `CL_ACTIVE_CANCEL` | `SV_BEING_CANCELED`, `SV_ACTIVE_CANCEL` | Yes (v1 encoding) |
| 1.21.0+ | `CL_WAITING_CANCEL`, `CL_ACTIVE_CANCEL` | `SV_BEING_CANCELED`, `SV_ACTIVE_CANCEL` | Yes (v2 encoding) |

### Detailed Changes

#### Version 1.16.0 (May 2021)

- Added `cl_cancel_req` column to `SHOW POOLS`
- Cancel requests can now exceed pool size by 2x ([commit `b477fc1`](https://github.com/pgbouncer/pgbouncer/commit/b477fc1599f82abd80faef09ab4d782270c69e03))
- Fixed cancel requests getting stuck

#### Version 1.18.0 (December 2022)

Major cancellation handling overhaul ([commit `ea4fb5f`](https://github.com/pgbouncer/pgbouncer/commit/ea4fb5fe07c1f71ca3dc6157ff44a02de6265c45)):

- **Fixed race condition** where cancel for Client A could cancel Client B's query
- Split `cl_cancel_req` into `cl_waiting_cancel_req` + `cl_active_cancel_req`
- Added `sv_active_cancel` for servers forwarding cancel requests
- Added `sv_wait_cancels` for servers waiting for cancels to complete
- Cancel requests are now doubly-linked to their target server

From the commit message ([#717](https://github.com/pgbouncer/pgbouncer/pull/717)):

> "Without this patch there were two possibilities for a race condition where a cancel request for client A could cancel a query that was sent by client B."

#### Version 1.19.0

- **Added peering support** for cancel requests in load-balanced setups ([#666](https://github.com/pgbouncer/pgbouncer/pull/666))
  - New `peer_id` configuration parameter
  - New `[peers]` configuration section
  - New `SHOW PEERS` and `SHOW PEER_POOLS` admin commands
  - New `cancel_wait_timeout` setting ([#833](https://github.com/pgbouncer/pgbouncer/pull/833))
- Renamed `sv_wait_cancels` → `sv_being_canceled` for clarity ([commit `193ea03`](https://github.com/pgbouncer/pgbouncer/commit/193ea0300a9f0a4d1cbd568a2f3085ca9afc4e3a))

From the commit message ([#788](https://github.com/pgbouncer/pgbouncer/pull/788)):

> "The `wait_cancels` name was quite confusing. `being_canceled` makes it more clear that this is not a server that is canceling itself, but instead it's the target of a cancellation request."

#### Version 1.21.0

- **Changed `peer_id` encoding in cancel keys** ([#945](https://github.com/pgbouncer/pgbouncer/pull/945))
  - This is a breaking change for cross-version peering
  - Peers on 1.19.0-1.20.x cannot interoperate with peers on 1.21.0+

---

## FAQ

### Q: If a client closes its connection during a long-running query, will PgBouncer cancel the query?

**No.** PgBouncer will close the server connection entirely. The query may continue running on PostgreSQL until PostgreSQL detects the broken connection. See the [`disconnect_client_sqlstate()`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L1465) function in `src/objects.c`.

### Q: Can I reclaim server connections from disconnected clients?

**No.** If a client disconnects while a query is running or a transaction is open, the server connection must be closed. There is no safe way to reset the server state. The comment in the [source code](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L1493-L1501) explains this.

### Q: What is `sv_being_canceled`?

This state is for servers that had a query explicitly cancelled (via `CancelRequest`) and are waiting for all cancel requests to complete before returning to the idle pool. It has nothing to do with client disconnection. See the [state definition](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/include/bouncer.h#L83) and [state transition logic](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L1283-L1286).

### Q: How do I see servers that are stuck waiting for cancels?

Use `SHOW SERVERS` ([implementation](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/admin.c#L793)) and look for servers with state `being_canceled`, or check the `sv_being_canceled` column in `SHOW POOLS` ([implementation](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/admin.c#L896)).

### Q: Why do I see "failed cancel request" in my logs?

This typically occurs when:
1. The client that initiated the query has already disconnected
2. The query completed before the cancel request arrived
3. **You're running multiple PgBouncer instances** (load-balanced or with `so_reuseport`) without peering configured

For load-balanced setups, enable [peering](#cancel-requests-in-load-balanced-setups-peering) so cancel requests can be forwarded to the correct PgBouncer instance.

### Q: Do I need peering if I run a single PgBouncer instance?

**No.** Peering is only needed when you have multiple PgBouncer instances (processes) that might receive connections from the same clients. Common scenarios requiring peering:

- Multiple PgBouncer processes using `so_reuseport` on the same port
- Multiple PgBouncer instances behind a TCP load balancer (HAProxy, nginx, etc.)
- Active/passive PgBouncer setups where clients might connect to either

### Q: Can I mix PgBouncer versions in a peered group?

**Partially.** Cross-version peering works, but there's a compatibility boundary at version 1.21.0:

- All peers on 1.19.0-1.20.x: Works
- All peers on 1.21.0+: Works
- Mixed (some on 1.19.0-1.20.x, some on 1.21.0+): **Does not work**

This is because the encoding of `peer_id` in cancel keys changed in 1.21.0 ([#945](https://github.com/pgbouncer/pgbouncer/pull/945)).

### Q: What happens if a peer is down?

If a cancel request needs to be forwarded to a peer that is unreachable:
1. PgBouncer will attempt to connect to the peer
2. If connection fails or times out, the cancel request fails
3. The `cancel_wait_timeout` setting (default 10s) controls how long to wait

The original query continues running; the client just won't be able to cancel it.

---

## Key Source Files

| File | Description |
|------|-------------|
| [`src/objects.c`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c) | Core connection management, cancel request handling, disconnect logic |
| [`src/client.c`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/client.c) | Client protocol handling, receives cancel packets (see [line 1409](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/client.c#L1409)) |
| [`src/server.c`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/server.c) | Server protocol handling, cancel request forwarding |
| [`src/admin.c`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/admin.c) | Admin console commands (`SHOW POOLS`, `SHOW SERVERS`, etc.) |
| [`src/janitor.c`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/janitor.c) | Periodic maintenance, timeout enforcement |
| [`include/bouncer.h`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/include/bouncer.h) | Core data structures, state enums, pool structure |

---

## Related Issues and Pull Requests

### Cancel Request Handling
- [#717](https://github.com/pgbouncer/pgbouncer/pull/717) - Handle race condition between cancel requests and server reuse
- [#788](https://github.com/pgbouncer/pgbouncer/pull/788) - Rename wait_cancels state to being_canceled
- [#544](https://github.com/pgbouncer/pgbouncer/issues/544) - Original race condition issue
- [#833](https://github.com/pgbouncer/pgbouncer/pull/833) - Add dedicated cancel_wait_timeout
- [#815](https://github.com/pgbouncer/pgbouncer/pull/815) - Fix disconnect_server on BEING_CANCELED state
- [#927](https://github.com/pgbouncer/pgbouncer/pull/927) - Fix server_proto bad state error
- [#928](https://github.com/pgbouncer/pgbouncer/pull/928) - Fix client_proto bad state error

### Peering
- [#666](https://github.com/pgbouncer/pgbouncer/pull/666) - Add PgBouncer peering support (introduced in 1.19.0)
- [#945](https://github.com/pgbouncer/pgbouncer/pull/945) - Change peer_id encoding in cancel keys (1.21.0)
- [#922](https://github.com/pgbouncer/pgbouncer/pull/922) - Fix slog log prefix for peers
- [#864](https://github.com/pgbouncer/pgbouncer/pull/864) - Fix name of peer_cache slab storage
- [#832](https://github.com/pgbouncer/pgbouncer/pull/832) - Document maximum value for peer_id
