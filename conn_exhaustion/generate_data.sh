#!/bin/bash
# Run all five test scenarios and collect data for graph generation
set -e
cd "$(dirname "$0")"

echo "Running 5 test scenarios..."

./test_poisoned_connpool_exhaustion.sh 2 poison nopeers
mkdir -p results/2pgb_poison && mv *.log results/2pgb_poison/

./test_poisoned_connpool_exhaustion.sh 1 poison nopeers
mkdir -p results/1pgb_poison && mv *.log results/1pgb_poison/

./test_poisoned_connpool_exhaustion.sh 2 poison peers
mkdir -p results/2pgb_poison_pool && mv *.log results/2pgb_poison_pool/

./test_poisoned_connpool_exhaustion.sh 2 sleep nopeers
mkdir -p results/2pgb_sleep && mv *.log results/2pgb_sleep/

./test_poisoned_connpool_exhaustion.sh 2 sleep peers
mkdir -p results/2pgb_sleep_pool && mv *.log results/2pgb_sleep_pool/

echo "All tests complete. Run ./extract_data.sh and gnuplot generate_graphs.gp to generate graphs."
