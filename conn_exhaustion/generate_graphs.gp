# Gnuplot script for connection exhaustion test results
# Usage: gnuplot generate_graphs.gp

set terminal pngcairo enhanced font 'Helvetica,12' size 800,500
set datafile separator " "
set bmargin 7
set xrange [0:90]
set xlabel "Time (seconds)"
set key below box width 1 height 1 font ',11' samplen 2
set grid

# Graph: Oldest Transaction Age - All Cases
set output 'graphs/oldest_xact_age.png'
set title "Oldest Transaction Age: Poison vs Sleep Mode" font ',14'
set ylabel "Transaction Age (seconds)"
set yrange [0:45]
plot 'graphs/2pgb_poison_metrics.dat' using 2:10 with lines lw 2 lc rgb "#e41a1c" title "2 PgB Poison (nopeers)", \
     'graphs/1pgb_poison_metrics.dat' using 2:10 with lines lw 2 lc rgb "#984ea3" title "1 PgB Poison (nopeers)", \
     'graphs/2pgb_poison_pool_metrics.dat' using 2:10 with lines lw 2 lc rgb "#377eb8" title "2 PgB Poison (peers)", \
     'graphs/2pgb_sleep_metrics.dat' using 2:10 with lines lw 2 lc rgb "#ff7f00" title "2 PgB Sleep (nopeers)", \
     'graphs/2pgb_sleep_pool_metrics.dat' using 2:10 with lines lw 2 lc rgb "#4daf4a" title "2 PgB Sleep (peers)"

# Graph: Comparison of Total PostgreSQL Connections - All 4 cases
set output 'graphs/comparison_pg_connections.png'
set title "PostgreSQL Total Connections: All Test Cases" font ',14'
set ylabel "Connections"
set yrange [0:110]
set label "server max\\_conn-super\\_reserved (95)" at 1,97 font ',9' tc rgb "#666666"
plot 95 with lines lw 2 lc rgb "#666666" dt 2 notitle axes x1y1, \
     'graphs/2pgb_poison_metrics.dat' using 2:3 with lines lw 2 lc rgb "#e41a1c" title "2 PgB Poison (nopeers)", \
     'graphs/1pgb_poison_metrics.dat' using 2:3 with lines lw 2 lc rgb "#984ea3" title "1 PgB Poison (nopeers)", \
     'graphs/2pgb_poison_pool_metrics.dat' using 2:3 with lines lw 2 lc rgb "#377eb8" title "2 PgB Poison (peers)", \
     'graphs/2pgb_sleep_metrics.dat' using 2:3 with lines lw 2 lc rgb "#ff7f00" title "2 PgB Sleep (nopeers)", \
     'graphs/2pgb_sleep_pool_metrics.dat' using 2:3 with lines lw 2 lc rgb "#4daf4a" title "2 PgB Sleep (peers)"
unset label

# Graph: Comparison of CLOSE-WAIT - All 4 cases
set output 'graphs/comparison_close_wait.png'
set title "TCP CLOSE-WAIT Connections: All Test Cases" font ',14'
set yrange [0:100]
plot 'graphs/2pgb_poison_metrics.dat' using 2:6 with lines lw 2 lc rgb "#e41a1c" title "2 PgB Poison (nopeers)", \
     'graphs/1pgb_poison_metrics.dat' using 2:6 with lines lw 2 lc rgb "#984ea3" title "1 PgB Poison (nopeers)", \
     'graphs/2pgb_poison_pool_metrics.dat' using 2:6 with lines lw 2 lc rgb "#377eb8" title "2 PgB Poison (peers)", \
     'graphs/2pgb_sleep_metrics.dat' using 2:6 with lines lw 2 lc rgb "#ff7f00" title "2 PgB Sleep (nopeers)", \
     'graphs/2pgb_sleep_pool_metrics.dat' using 2:6 with lines lw 2 lc rgb "#4daf4a" title "2 PgB Sleep (peers)"

# Graph: TPS Comparison - All 4 cases
set output 'graphs/comparison_tps.png'
set title "Transactions Per Second: All Test Cases" font ',14'
set ylabel "TPS"
set yrange [0:800]
plot 'graphs/2pgb_poison_metrics.dat' using 2:7 with lines lw 2 lc rgb "#e41a1c" title "2 PgB Poison (nopeers)", \
     'graphs/1pgb_poison_metrics.dat' using 2:7 with lines lw 2 lc rgb "#984ea3" title "1 PgB Poison (nopeers)", \
     'graphs/2pgb_poison_pool_metrics.dat' using 2:7 with lines lw 2 lc rgb "#377eb8" title "2 PgB Poison (peers)", \
     'graphs/2pgb_sleep_metrics.dat' using 2:7 with lines lw 2 lc rgb "#ff7f00" title "2 PgB Sleep (nopeers)", \
     'graphs/2pgb_sleep_pool_metrics.dat' using 2:7 with lines lw 2 lc rgb "#4daf4a" title "2 PgB Sleep (peers)"

# Dual Y-axis graphs - set common options
set y2tics
set ytics nomirror
set yrange [0:800]
set y2range [0:50]

# Graph: Poison Mode - TPS, cl_waiting, AvgWait, oldest_xact_age, total connections
set output 'graphs/poison_clwaiting_avgwait.png'
set title "2 PgBouncers, Poison Mode (nopeers)" font ',14'
set ylabel "TPS / Connections / cl\\_waiting" tc rgb "#000000"
set y2label "oldest\\_xact\\_age (s) / AvgWait (ms)" tc rgb "#000000"
set label 1 "pgbouncer max\\_user\\_conn (195)" at 1,210 font ',9' tc rgb "#666666"
set label 2 "server max\\_conn-super\\_reserved (95)" at 1,110 font ',9' tc rgb "#666666"
plot 195 with lines lw 2 lc rgb "#666666" dt 2 notitle axes x1y1, \
     95 with lines lw 2 lc rgb "#666666" dt 2 notitle axes x1y1, \
     'graphs/2pgb_poison_metrics.dat' using 2:7 with lines lw 2 lc rgb "#4daf4a" title "TPS" axes x1y1, \
     'graphs/2pgb_poison_metrics.dat' using 2:10 with lines lw 2 lc rgb "#984ea3" title "oldest\\_xact\\_age" axes x1y2, \
     'graphs/2pgb_poison_metrics.dat' using 2:3 with lines lw 2 lc rgb "#a65628" title "Total Connections" axes x1y1, \
     'graphs/2pgb_poison_metrics.dat' using 2:8 with lines lw 2 lc rgb "#e41a1c" title "PgBouncer #1 cl\\_waiting" axes x1y1, \
     'graphs/2pgb_poison_metrics.dat' using 2:9 with lines lw 2 lc rgb "#ff7f00" title "PgBouncer #2 cl\\_waiting" axes x1y1, \
     'graphs/2pgb_poison_avgwait.dat' using 2:3 with lines lw 2 lc rgb "#377eb8" title "AvgWait (ms)" axes x1y2
unset label 1
unset label 2

# Graph: Sleep Mode - TPS, cl_waiting, AvgWait, oldest_xact_age, total connections
set output 'graphs/sleep_clwaiting_avgwait.png'
set title "2 PgBouncers, Sleep Mode (nopeers)" font ',14'
set ylabel "TPS / Connections / cl\\_waiting / AvgWait (ms)" tc rgb "#000000"
set y2label "oldest\\_xact\\_age (s)" tc rgb "#000000"
set label 1 "server max\\_conn-super\\_reserved (95)" at 1,110 font ',9' tc rgb "#666666"
set label 2 "pgbouncer max\\_user\\_conn (195) {/:Bold \\^}" at 42,750 font ',9' tc rgb "#666666"
plot 95 with lines lw 2 lc rgb "#666666" dt 2 notitle axes x1y1, \
     'graphs/2pgb_sleep_metrics.dat' using 2:7 with lines lw 2 lc rgb "#4daf4a" title "TPS" axes x1y1, \
     'graphs/2pgb_sleep_metrics.dat' using 2:10 with lines lw 2 lc rgb "#984ea3" title "oldest\\_xact\\_age" axes x1y2, \
     'graphs/2pgb_sleep_metrics.dat' using 2:3 with lines lw 2 lc rgb "#a65628" title "Total Connections" axes x1y1, \
     'graphs/2pgb_sleep_metrics.dat' using 2:8 with lines lw 2 lc rgb "#e41a1c" title "PgBouncer #1 cl\\_waiting" axes x1y1, \
     'graphs/2pgb_sleep_metrics.dat' using 2:9 with lines lw 2 lc rgb "#ff7f00" title "PgBouncer #2 cl\\_waiting" axes x1y1, \
     'graphs/2pgb_sleep_avgwait.dat' using 2:3 with lines lw 2 lc rgb "#377eb8" title "AvgWait (ms)" axes x1y1
