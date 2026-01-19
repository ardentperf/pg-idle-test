# Gnuplot script for connection exhaustion test results
# Usage: gnuplot generate_graphs.gp

set terminal pngcairo enhanced font 'Helvetica,12' size 800,500
set datafile separator " "
set bmargin 7

# Graph: Oldest Transaction Age - All Cases
set output 'graphs/oldest_xact_age.png'
set title "Oldest Transaction Age: Poison vs Sleep Mode" font ',14'
set xlabel "Time (seconds)"
set ylabel "Transaction Age (seconds)"
set key below box width 1 height 1 font ',11' samplen 2
set grid
set xrange [0:60]
set yrange [0:45]
plot 'graphs/2pgb_poison_metrics.dat' using 2:10 with lines lw 2 lc rgb "#e41a1c" title "2 PgB Poison (nopeers)", \
     'graphs/1pgb_poison_metrics.dat' using 2:10 with lines lw 2 lc rgb "#984ea3" title "1 PgB Poison (nopeers)", \
     'graphs/2pgb_poison_pool_metrics.dat' using 2:10 with lines lw 2 lc rgb "#377eb8" title "2 PgB Poison (peers)", \
     'graphs/2pgb_sleep_metrics.dat' using 2:10 with lines lw 2 lc rgb "#ff7f00" title "2 PgB Sleep (nopeers)", \
     'graphs/2pgb_sleep_pool_metrics.dat' using 2:10 with lines lw 2 lc rgb "#4daf4a" title "2 PgB Sleep (peers)"

# Graph: PostgreSQL Connections - 2 PgBouncers (Poison)
set output 'graphs/2pgb_poison_connections.png'
set title "2 PgBouncers + Poison Mode: PostgreSQL Connections" font ',14'
set xlabel "Time (seconds)"
set ylabel "Connections"
set key below box width 1 height 1 font ',11' samplen 2
set grid
set xrange [0:60]
set yrange [0:110]
plot 'graphs/2pgb_poison_metrics.dat' using 2:3 with lines lw 2 lc rgb "#e41a1c" title "Total PostgreSQL", \
     'graphs/2pgb_poison_metrics.dat' using 2:5 with lines lw 2 lc rgb "#377eb8" title "Waiting on Lock", \
     'graphs/2pgb_poison_metrics.dat' using 2:6 with lines lw 2 lc rgb "#ff7f00" title "TCP CLOSE-WAIT"

# Graph: PostgreSQL Connections - 1 PgBouncer (Poison)  
set output 'graphs/1pgb_poison_connections.png'
set title "1 PgBouncer + Poison Mode: PostgreSQL Connections" font ',14'
plot 'graphs/1pgb_poison_metrics.dat' using 2:3 with lines lw 2 lc rgb "#4daf4a" title "Total PostgreSQL", \
     'graphs/1pgb_poison_metrics.dat' using 2:5 with lines lw 2 lc rgb "#377eb8" title "Waiting on Lock", \
     'graphs/1pgb_poison_metrics.dat' using 2:6 with lines lw 2 lc rgb "#ff7f00" title "TCP CLOSE-WAIT"

# Graph: Comparison of Total PostgreSQL Connections - All 4 cases
set output 'graphs/comparison_pg_connections.png'
set title "PostgreSQL Total Connections: All Test Cases" font ',14'
set yrange [0:110]
set arrow from 0,95 to 60,95 nohead lc rgb "#666666" dt 3 lw 1
set label "max\\_connections - superuser\\_reserved (95)" at 1,88 left font ',9' tc rgb "#666666"
plot 'graphs/2pgb_poison_metrics.dat' using 2:3 with lines lw 2 lc rgb "#e41a1c" title "2 PgB Poison (nopeers)", \
     'graphs/1pgb_poison_metrics.dat' using 2:3 with lines lw 2 lc rgb "#984ea3" title "1 PgB Poison (nopeers)", \
     'graphs/2pgb_poison_pool_metrics.dat' using 2:3 with lines lw 2 lc rgb "#377eb8" title "2 PgB Poison (peers)", \
     'graphs/2pgb_sleep_metrics.dat' using 2:3 with lines lw 2 lc rgb "#ff7f00" title "2 PgB Sleep (nopeers)", \
     'graphs/2pgb_sleep_pool_metrics.dat' using 2:3 with lines lw 2 lc rgb "#4daf4a" title "2 PgB Sleep (peers)"

unset arrow
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

# Graph: Poison Mode - TPS, cl_waiting, AvgWait, oldest_xact_age, total connections
set output 'graphs/poison_clwaiting_avgwait.png'
set title "2 PgBouncers, Poison Mode (nopeers)" font ',14'
set xlabel "Time (seconds)"
set ylabel "TPS / Connections / cl\\_waiting" tc rgb "#000000"
set y2label "oldest\\_xact\\_age (s) / AvgWait (ms)" tc rgb "#000000"
set key below box width 1 height 1 font ',11' samplen 2
set grid
set xrange [0:60]
set y2tics
set ytics nomirror
set yrange [0:800]
set y2range [0:50]
set label 1 "max\\_user\\_connections (195)" at 1,210 font ',9' tc rgb "#999999"
set label 2 "max\\_connections - superuser (95)" at 1,110 font ',9' tc rgb "#666666"
plot 195 with lines lw 2 lc rgb "#999999" dt 2 notitle axes x1y1, \
     95 with lines lw 2 lc rgb "#666666" dt 2 notitle axes x1y1, \
     'graphs/2pgb_poison_metrics.dat' using 2:7 with lines lw 2 lc rgb "#4daf4a" title "TPS" axes x1y1, \
     'graphs/2pgb_poison_metrics.dat' using 2:10 with lines lw 2 lc rgb "#984ea3" title "oldest\\_xact\\_age" axes x1y2, \
     'graphs/2pgb_poison_metrics.dat' using 2:3 with lines lw 2 lc rgb "#a65628" title "Total Connections" axes x1y1, \
     'graphs/2pgb_poison_metrics.dat' using 2:8 with lines lw 2 lc rgb "#e41a1c" title "PgBouncer #1 cl\\_waiting" axes x1y1, \
     'graphs/2pgb_poison_metrics.dat' using 2:9 with lines lw 2 lc rgb "#ff7f00" title "PgBouncer #2 cl\\_waiting" axes x1y1, \
     'graphs/2pgb_poison_avgwait.dat' using 2:3 with lines lw 2 lc rgb "#377eb8" title "AvgWait (ms)" axes x1y2
unset label 1
unset label 2

unset y2tics
unset y2label
set ytics mirror

# Graph: Sleep Mode - TPS, cl_waiting, AvgWait, oldest_xact_age, total connections
set output 'graphs/sleep_clwaiting_avgwait.png'
set title "2 PgBouncers, Sleep Mode (nopeers)" font ',14'
set xlabel "Time (seconds)"
set ylabel "TPS / Connections / AvgWait (ms)" tc rgb "#000000"
set y2label "oldest\\_xact\\_age (s) / cl\\_waiting" tc rgb "#000000"
set key below box width 1 height 1 font ',11' samplen 2
set grid
set xrange [0:60]
set y2tics
set ytics nomirror
set yrange [0:800]
set y2range [0:50]
set label 1 "max\\_connections - superuser (95)" at 1,110 font ',9' tc rgb "#666666"
set label 2 "max\\_user\\_connections (195) {/:Bold \\^}" at 42,750 font ',9' tc rgb "#999999"
plot 95 with lines lw 2 lc rgb "#666666" dt 2 notitle axes x1y1, \
     'graphs/2pgb_sleep_metrics.dat' using 2:7 with lines lw 2 lc rgb "#4daf4a" title "TPS" axes x1y1, \
     'graphs/2pgb_sleep_metrics.dat' using 2:10 with lines lw 2 lc rgb "#984ea3" title "oldest\\_xact\\_age" axes x1y2, \
     'graphs/2pgb_sleep_metrics.dat' using 2:3 with lines lw 2 lc rgb "#a65628" title "Total Connections" axes x1y1, \
     'graphs/2pgb_sleep_metrics.dat' using 2:8 with lines lw 2 lc rgb "#e41a1c" title "PgBouncer #1 cl\\_waiting" axes x1y2, \
     'graphs/2pgb_sleep_metrics.dat' using 2:9 with lines lw 2 lc rgb "#ff7f00" title "PgBouncer #2 cl\\_waiting" axes x1y2, \
     'graphs/2pgb_sleep_avgwait.dat' using 2:3 with lines lw 2 lc rgb "#377eb8" title "AvgWait (ms)" axes x1y1
unset label 1
unset label 2

unset y2tics
unset y2label
set ytics mirror
