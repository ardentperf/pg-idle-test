// Simulates connection pool exhaustion by holding a row lock while workers timeout.
package main

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5/stdlib"
)

var startTime = time.Now()
var prevWaitCount int64
var prevWaitDuration time.Duration
var prevMaxIdleClosed int64
var prevMaxLifetimeClosed int64
var prevMaxIdleTimeClosed int64

// monitorPoolStats prints pool stats every second continuously
func monitorPoolStats(db *sql.DB) {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		stats := db.Stats()

		// Calculate rates
		waitCountDelta := stats.WaitCount - prevWaitCount
		waitDurationDelta := stats.WaitDuration - prevWaitDuration
		maxIdleClosedDelta := stats.MaxIdleClosed - prevMaxIdleClosed
		maxLifetimeClosedDelta := stats.MaxLifetimeClosed - prevMaxLifetimeClosed
		maxIdleTimeClosedDelta := stats.MaxIdleTimeClosed - prevMaxIdleTimeClosed

		// Calculate average wait time per wait (if any waits occurred)
		var avgWaitMs float64
		if waitCountDelta > 0 {
			avgWaitMs = float64(waitDurationDelta.Milliseconds()) / float64(waitCountDelta)
		}

		timestamp := time.Now().Format("04:05")
		fmt.Fprintf(os.Stderr, "[%s] POOL_STATS: Open=%d InUse=%d Idle=%d Waits/s=%d AvgWait=%.2fms MaxIdleClosed/s=%d MaxLifetimeClosed/s=%d MaxIdleTimeClosed/s=%d\n",
			timestamp, stats.OpenConnections, stats.InUse, stats.Idle, waitCountDelta, avgWaitMs,
			maxIdleClosedDelta, maxLifetimeClosedDelta, maxIdleTimeClosedDelta)

		// Update previous values
		prevWaitCount = stats.WaitCount
		prevWaitDuration = stats.WaitDuration
		prevMaxIdleClosed = stats.MaxIdleClosed
		prevMaxLifetimeClosed = stats.MaxLifetimeClosed
		prevMaxIdleTimeClosed = stats.MaxIdleTimeClosed

		// Sample a connection to check transaction status
		conn, err := db.Conn(context.Background())
		if err == nil {
			conn.Raw(func(driverConn interface{}) error {
				if pgxConn, ok := driverConn.(*stdlib.Conn); ok {
					txStatus := pgxConn.Conn().PgConn().TxStatus()
					if txStatus != 'I' {
						fmt.Fprintf(os.Stderr, "WARNING: Connection returned to pool with open transaction (TxStatus=%c)\n", txStatus)
					}
				}
				return nil
			})
			conn.Close()
		}
	}
}

func main() {
	if len(os.Args) < 2 || (os.Args[1] != "poison" && os.Args[1] != "sleep") {
		fmt.Fprintf(os.Stderr, "Usage: %s <poison|sleep>\n", os.Args[0])
		os.Exit(1)
	}

	connStr := os.Getenv("DATABASE_URL")
	db, err := sql.Open("pgx", connStr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Unable to connect with DATABASE_URL='%s': %v\n", connStr, err)
		os.Exit(1)
	}
	defer db.Close()
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(10)

	// Test connection
	if err := db.Ping(); err != nil {
		fmt.Fprintf(os.Stderr, "Unable to connect to database with DATABASE_URL='%s': %v\n", connStr, err)
		os.Exit(1)
	}

	// Setup table
	db.Exec("DROP TABLE IF EXISTS test_row")
	db.Exec("CREATE TABLE test_row (id INT PRIMARY KEY, val INT)")
	db.Exec("INSERT INTO test_row (id, val) VALUES (1, 0)")

	fmt.Println(">>> Starting workers")
	fmt.Println()

	// Start pool stats monitor
	go monitorPoolStats(db)

	// Start workers
	for i := 0; i < 20; i++ {
		go func() {
			for {
				ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
				if _, err := db.ExecContext(ctx, "UPDATE test_row SET val = val + 1 WHERE id = 1"); err != nil {
					fmt.Fprintf(os.Stderr, "ERROR: Worker failed: %v\n", err)
				}
				db.ExecContext(ctx, "SELECT pg_sleep(0.01)")
				cancel()
				time.Sleep(100 * time.Millisecond)
			}
		}()
	}

	// Wait, then poison
	time.Sleep(20 * time.Second)

	fmt.Println()
	fmt.Println(">>> START BLOCKING: Holding row lock in open transaction...")

	conn, _ := db.Conn(context.Background())
	var backendPID int
	conn.QueryRowContext(context.Background(), "SELECT pg_backend_pid()").Scan(&backendPID)
	conn.ExecContext(context.Background(), "BEGIN")
	conn.ExecContext(context.Background(), "UPDATE test_row SET val = val + 1 WHERE id = 1 -- POISON")

	if os.Args[1] == "poison" {
		// Return connection to pool immediately with open transaction (default "poison" behavior)
		conn.Close()
		fmt.Printf(">>> POISON: Lock acquired by PID %d, connection returned to pool with open transaction\n", backendPID)
		// Sleep so that workers continue to run; poison connection picked up and will not be idle
		time.Sleep(70 * time.Second)
	} else {
		// Sleep before completing test; workers blocked by idle transaction
		fmt.Printf(">>> SLEEP: Lock acquired by PID %d, sleeping with open transaction\n", backendPID)
		time.Sleep(70 * time.Second)
		conn.Close()
	}

	fmt.Println()
	fmt.Println(">>> TEST COMPLETE")
}
