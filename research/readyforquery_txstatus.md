*Written with Claude 👋 - code references have been spot checked, but haven't fully verified everything with tests*

# ReadyForQuery and TxStatus in PostgreSQL

> **Version**: This document describes PostgreSQL **18.1** (`REL_18_1` tag).  
> All line numbers and GitHub links reference this specific version.

## Overview

`ReadyForQuery` is a message sent by the PostgreSQL backend to indicate that it has finished processing and is ready to accept a new command. It includes a single-byte **transaction status indicator** (`TxStatus`) that tells the client the current state of the transaction.

## The ReadyForQuery Message

The message is sent by the [`ReadyForQuery()`](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/tcop/dest.c#L255-L286) function in `src/backend/tcop/dest.c`:

```c
void
ReadyForQuery(CommandDest dest)
{
    switch (dest)
    {
        case DestRemote:
        case DestRemoteExecute:
        case DestRemoteSimple:
            {
                StringInfoData buf;

                pq_beginmessage(&buf, PqMsg_ReadyForQuery);
                pq_sendbyte(&buf, TransactionBlockStatusCode());
                pq_endmessage(&buf);
            }
            /* Flush output at end of cycle in any case. */
            pq_flush();
            break;
        // ...
    }
}
```

### Message Format

From the [PostgreSQL 18 Protocol Documentation](https://www.postgresql.org/docs/18/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-READYFORQUERY) and [protocol.h](https://github.com/postgres/postgres/blob/REL_18_1/src/include/libpq/protocol.h#L55):

| Field | Length | Description |
|-------|--------|-------------|
| Message Type | 1 byte | `'Z'` (0x5A) - defined as `PqMsg_ReadyForQuery` |
| Message Length | 4 bytes | Always 5 (int32, includes self) |
| TxStatus | 1 byte | Transaction status indicator: `'I'` (idle), `'T'` (in transaction), or `'E'` (failed transaction) |

## TxStatus Values

The transaction status byte is determined by [`TransactionBlockStatusCode()`](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/access/transam/xact.c#L5002-L5038) in `src/backend/access/transam/xact.c`:

| Value | Character | Meaning | Block States |
|-------|-----------|---------|--------------|
| `0x49` | `'I'` | **Idle** - not in a transaction block | `TBLOCK_DEFAULT`, `TBLOCK_STARTED` |
| `0x54` | `'T'` | **In Transaction** - inside a transaction block | `TBLOCK_BEGIN`, `TBLOCK_INPROGRESS`, `TBLOCK_IMPLICIT_INPROGRESS`, `TBLOCK_SUBINPROGRESS`, etc. |
| `0x45` | `'E'` | **Error** - in a failed transaction block | `TBLOCK_ABORT`, `TBLOCK_SUBABORT`, etc. |

### Detailed State Mappings

The [`TBlockState`](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/access/transam/xact.c#L157-L184) enum defines all possible transaction block states:

#### Returns `'I'` (Idle)
- `TBLOCK_DEFAULT` - No transaction active
- `TBLOCK_STARTED` - Running a single auto-commit statement

#### Returns `'T'` (In Transaction)
- `TBLOCK_BEGIN` - Just received BEGIN command
- `TBLOCK_INPROGRESS` - Inside an explicit transaction block
- `TBLOCK_IMPLICIT_INPROGRESS` - Inside an implicit transaction (pipeline mode)
- `TBLOCK_PARALLEL_INPROGRESS` - Inside a parallel worker transaction
- `TBLOCK_SUBINPROGRESS` - Inside a subtransaction (savepoint)
- `TBLOCK_END` - COMMIT received, pending execution
- `TBLOCK_SUBRELEASE` - RELEASE SAVEPOINT received
- `TBLOCK_SUBCOMMIT` - COMMIT received while in subtransaction
- `TBLOCK_PREPARE` - PREPARE TRANSACTION received

#### Returns `'E'` (Failed Transaction)
- `TBLOCK_ABORT` - Transaction failed, waiting for ROLLBACK
- `TBLOCK_SUBABORT` - Subtransaction failed, waiting for ROLLBACK
- `TBLOCK_ABORT_END` - Failed transaction, ROLLBACK received
- `TBLOCK_SUBABORT_END` - Failed subtransaction, ROLLBACK received
- `TBLOCK_ABORT_PENDING` - Live transaction, ROLLBACK received
- `TBLOCK_SUBABORT_PENDING` - Live subtransaction, ROLLBACK received
- `TBLOCK_SUBRESTART` - Live subtransaction, ROLLBACK TO received
- `TBLOCK_SUBABORT_RESTART` - Failed subtransaction, ROLLBACK TO received

## When is ReadyForQuery Sent?

The main message processing loop is in [`PostgresMain()`](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/tcop/postgres.c#L4184-L5022) in `src/backend/tcop/postgres.c`.

### Simple Query Protocol

After **every** query string sent via the simple query protocol ([`PqMsg_Query` handling](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/tcop/postgres.c#L4750-L4771)), PostgreSQL sends `ReadyForQuery`.

```
Client: Query("SELECT 1; SELECT 2")
Server: RowDescription, DataRow, CommandComplete  (for SELECT 1)
Server: RowDescription, DataRow, CommandComplete  (for SELECT 2)
Server: ReadyForQuery('I')
```

### Extended Query Protocol

`ReadyForQuery` is **only** sent after a **Sync** message ([`PqMsg_Sync` handling](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/tcop/postgres.c#L4960-L4972)), not after Parse/Bind/Execute:

```
Client: Parse("SELECT 1")
Server: ParseComplete
Client: Bind
Server: BindComplete
Client: Execute
Server: DataRow, CommandComplete
Client: Sync                          <-- Only now...
Server: ReadyForQuery('I')            <-- ...is RFQ sent
```

This is crucial for **pipeline mode** - you can send many Parse/Bind/Execute sequences before a single Sync.

### Error Handling in Extended Query Protocol

When an error occurs during extended query protocol processing, PostgreSQL sets [`ignore_till_sync = true`](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/tcop/postgres.c#L4483-L4485) and skips sending `ReadyForQuery`:

```c
/*
 * If we were handling an extended-query-protocol message, initiate
 * skip till next Sync.  This also causes us not to issue
 * ReadyForQuery (until we get Sync).
 */
if (doing_extended_query_message)
    ignore_till_sync = true;
```

The [`send_ready_for_query` flag](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/tcop/postgres.c#L4509-L4510) is only set to true when not in ignore mode:

```c
if (!ignore_till_sync)
    send_ready_for_query = true;   /* initially, or after error */
```

Example error flow:
```
Client: Parse("SELECT * FROM nonexistent")
Server: ErrorResponse
Client: Bind                          <-- Ignored
Client: Execute                       <-- Ignored  
Client: Sync
Server: ReadyForQuery('I')            <-- or 'E' if in transaction block
```

## Transaction State Transitions

### Starting a Transaction

```
State: TBLOCK_DEFAULT ('I')
  |
  v  [BEGIN command]
State: TBLOCK_BEGIN
  |
  v  [CommitTransactionCommand]
State: TBLOCK_INPROGRESS ('T')
```

### Successful Commit

```
State: TBLOCK_INPROGRESS ('T')
  |
  v  [COMMIT command]
State: TBLOCK_END ('T')              <-- Still 'T' here!
  |
  v  [CommitTransactionCommand]
State: TBLOCK_DEFAULT ('I')          <-- Now 'I'
```

### Error in Transaction

The transition to `TBLOCK_ABORT` happens in [`AbortCurrentTransactionInternal()`](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/access/transam/xact.c#L3469-L3621):

```
State: TBLOCK_INPROGRESS ('T')
  |
  v  [Query error occurs]
State: TBLOCK_ABORT ('E')            <-- Now 'E'
  |
  v  [ROLLBACK command]
State: TBLOCK_ABORT_END ('E')
  |
  v  [CommitTransactionCommand]
State: TBLOCK_DEFAULT ('I')          <-- Back to 'I'
```

### Implicit Transaction Blocks (Pipeline Mode)

When using pipeline mode without explicit BEGIN, [`BeginImplicitTransactionBlock()`](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/access/transam/xact.c#L4316-L4341) and [`EndImplicitTransactionBlock()`](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/access/transam/xact.c#L4343-L4366) manage the state:

```
State: TBLOCK_STARTED ('I')
  |
  v  [BeginImplicitTransactionBlock]
State: TBLOCK_IMPLICIT_INPROGRESS ('T')   <-- Shows as 'T'!
  |
  v  [Sync received, EndImplicitTransactionBlock]
State: TBLOCK_STARTED ('I')
  |
  v  [CommitTransactionCommand]
State: TBLOCK_DEFAULT ('I')
```

## Important Considerations

### 1. TxStatus is Accurate at ReadyForQuery Time

The transaction status reflects the state **at the moment ReadyForQuery is sent**, not at any earlier point during command execution.

### 2. Extended Query Protocol Delays

In pipeline mode, you won't see updated TxStatus until the next Sync. Multiple state changes can occur between ReadyForQuery messages.

### 3. Asynchronous Commit

With `synchronous_commit = off`, you may receive `ReadyForQuery('I')` before the transaction is durably committed to disk. A crash could lose the transaction even though the client saw acknowledgment. See the [async commit handling](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/access/transam/xact.c#L1473-L1532) in `RecordTransactionCommit()`.

### 4. The Flush Message

`PqMsg_Flush` forces PostgreSQL to [flush its output buffer](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/tcop/postgres.c#L4955-L4958) but does **not** send `ReadyForQuery`. Use this in pipeline mode if you need to read results without ending the pipeline.

## Client Library Behavior (e.g., pgx)

Client libraries typically track `TxStatus` by parsing the `ReadyForQuery` message:

```go
// Pseudocode
func (c *Conn) handleReadyForQuery(msg *ReadyForQuery) {
    c.txStatus = msg.TxStatus  // 'I', 'T', or 'E'
}
```

This allows the client to:
- Know if it's safe to start a new transaction
- Detect if the current transaction has failed
- Implement proper error recovery in pipeline mode

## Source Code References

All links point to the `REL_18_1` tag on GitHub:

| Component | File | Lines | GitHub Link |
|-----------|------|-------|-------------|
| Protocol Documentation (message format) | PostgreSQL 18 Docs | — | [View](https://www.postgresql.org/docs/18/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-READYFORQUERY) |
| `PqMsg_ReadyForQuery` constant | `src/include/libpq/protocol.h` | 55 | [View](https://github.com/postgres/postgres/blob/REL_18_1/src/include/libpq/protocol.h#L55) |
| `ReadyForQuery()` | `src/backend/tcop/dest.c` | 255-286 | [View](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/tcop/dest.c#L255-L286) |
| `TransactionBlockStatusCode()` | `src/backend/access/transam/xact.c` | 5002-5038 | [View](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/access/transam/xact.c#L5002-L5038) |
| `TBlockState` enum | `src/backend/access/transam/xact.c` | 157-184 | [View](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/access/transam/xact.c#L157-L184) |
| `PostgresMain()` (message loop) | `src/backend/tcop/postgres.c` | 4184-5022 | [View](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/tcop/postgres.c#L4184-L5022) |
| Simple Query handling | `src/backend/tcop/postgres.c` | 4750-4771 | [View](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/tcop/postgres.c#L4750-L4771) |
| Sync message handling | `src/backend/tcop/postgres.c` | 4960-4972 | [View](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/tcop/postgres.c#L4960-L4972) |
| `ignore_till_sync` error handling | `src/backend/tcop/postgres.c` | 4479-4485 | [View](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/tcop/postgres.c#L4479-L4485) |
| `BeginImplicitTransactionBlock()` | `src/backend/access/transam/xact.c` | 4316-4341 | [View](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/access/transam/xact.c#L4316-L4341) |
| `EndImplicitTransactionBlock()` | `src/backend/access/transam/xact.c` | 4343-4366 | [View](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/access/transam/xact.c#L4343-L4366) |
| `AbortCurrentTransactionInternal()` | `src/backend/access/transam/xact.c` | 3469-3621 | [View](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/access/transam/xact.c#L3469-L3621) |
| Async commit handling | `src/backend/access/transam/xact.c` | 1473-1532 | [View](https://github.com/postgres/postgres/blob/REL_18_1/src/backend/access/transam/xact.c#L1473-L1532) |
