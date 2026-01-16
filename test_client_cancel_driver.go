package main

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

func main() {
	connStr := os.Getenv("DATABASE_URL")

	db, err := sql.Open("pgx", connStr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Unable to connect with DATABASE_URL='%s': %v\n", connStr, err)
		os.Exit(1)
	}
	defer db.Close()

	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(10)

	// Create context with 5 second timeout
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Execute blocking query
	_, err = db.ExecContext(ctx, "UPDATE test_table SET value = 'locked by B' WHERE id = 1")
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		// Sleep briefly to allow cancel request to be sent
		time.Sleep(100 * time.Millisecond)
		os.Exit(1)
	}
}
