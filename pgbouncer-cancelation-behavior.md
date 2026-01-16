*Written with Claude 👋 - code references have been spot checked, but haven't fully verified everything with tests*

# PgBouncer Cancellation Request Behavior

This document explains how PgBouncer handles query cancellation requests, client disconnections during queries, the related connection states visible in `SHOW POOLS`, and disconnection log messages.

> **Source Code Reference:** This document references the [PgBouncer source code on GitHub](https://github.com/pgbouncer/pgbouncer). All source links point to the [`pgbouncer_1_25_1`](https://github.com/pgbouncer/pgbouncer/tree/pgbouncer_1_25_1) tag for stability.

## Table of Contents

- [Overview](#overview)
- [Client Disconnection During a Query](#client-disconnection-during-a-query)
- [Explicit Cancel Requests](#explicit-cancel-requests)
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
| `failed cancel request` | No client found with matching cancel key | [`src/objects.c:2196`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L2196) |
| `cancel_wait_timeout` | Cancel request waited too long for a server connection | [`src/janitor.c:462`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/janitor.c#L462) |
| `client gave up on cancel request...` | Cancel client disconnected before cancel could be sent; server connection also closed | [`src/objects.c:1540`](https://github.com/pgbouncer/pgbouncer/blob/pgbouncer_1_25_1/src/objects.c#L1540) |

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

| Version | Client Cancel States | Server Cancel States | SHOW POOLS Cancel Columns |
|---------|---------------------|---------------------|--------------------------|
| ≤1.15 | `CL_CANCEL` | none | none |
| 1.16-1.17 | `CL_CANCEL` | none | `cl_cancel_req` |
| 1.18.0 | `CL_WAITING_CANCEL`, `CL_ACTIVE_CANCEL` | `SV_WAIT_CANCELS`, `SV_ACTIVE_CANCEL` | Split columns |
| 1.19.0+ | `CL_WAITING_CANCEL`, `CL_ACTIVE_CANCEL` | `SV_BEING_CANCELED`, `SV_ACTIVE_CANCEL` | Current format |

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

- Renamed `sv_wait_cancels` → `sv_being_canceled` for clarity ([commit `193ea03`](https://github.com/pgbouncer/pgbouncer/commit/193ea0300a9f0a4d1cbd568a2f3085ca9afc4e3a))

From the commit message ([#788](https://github.com/pgbouncer/pgbouncer/pull/788)):

> "The `wait_cancels` name was quite confusing. `being_canceled` makes it more clear that this is not a server that is canceling itself, but instead it's the target of a cancellation request."

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

- [#717](https://github.com/pgbouncer/pgbouncer/pull/717) - Handle race condition between cancel requests and server reuse
- [#788](https://github.com/pgbouncer/pgbouncer/pull/788) - Rename wait_cancels state to being_canceled
- [#544](https://github.com/pgbouncer/pgbouncer/issues/544) - Original race condition issue
- [#833](https://github.com/pgbouncer/pgbouncer/pull/833) - Add dedicated cancel_wait_timeout
- [#815](https://github.com/pgbouncer/pgbouncer/pull/815) - Fix disconnect_server on BEING_CANCELED state
- [#927](https://github.com/pgbouncer/pgbouncer/pull/927) - Fix server_proto bad state error
- [#928](https://github.com/pgbouncer/pgbouncer/pull/928) - Fix client_proto bad state error
