#!/bin/bash

# Cleanup script for all Postgres test containers and networks

echo "Cleaning up test containers and networks..."

# Stop and remove all test containers
docker stop pg_idle_test pg_idle_timeout_test pg_server pg_client 2>/dev/null || true
docker rm pg_idle_test pg_idle_timeout_test pg_server pg_client 2>/dev/null || true

# Remove test networks
docker network rm pg_test_network 2>/dev/null || true

echo "Cleanup complete!"
