#!/bin/bash

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

printf "\n"
printf "%-32s %-10s %-15s %-15s %-15s %-8s %-15s %-15s %-15s %-8s\n" \
"NODE" \
"ALERT" \
"CPU_CAP(Core)" \
"CPU_REQ(Core)" \
"CPU_FREE(Core)" \
"CPU(%)" \
"MEM_CAP(GiB)" \
"MEM_REQ(GiB)" \
"MEM_FREE(GiB)" \
"MEM(%)"

printf "%s\n" "$(printf '=%.0s' {1..160})"

for node in $(oc get nodes -o name | awk -F/ '{print $2}')
do
    oc describe node "$node" | awk -v node="$node" '

    function mem_to_gib(val) {
        if (val ~ /Ki$/) {
            gsub("Ki","",val)
            return val/1024/1024
        }
        if (val ~ /Mi$/) {
            gsub("Mi","",val)
            return val/1024
        }
        if (val ~ /Gi$/) {
            gsub("Gi","",val)
            return val
        }
        if (val ~ /Ti$/) {
            gsub("Ti","",val)
            return val*1024
        }
        return val
    }

    BEGIN {
        alloc=0
        capture=0
    }

    /^Allocatable:/ {
        alloc=1
        next
    }

    alloc && /^[[:space:]]*cpu:/ {
        cpu_cap=$2

        if (cpu_cap ~ /m$/) {
            gsub("m","",cpu_cap)
            cpu_cap=cpu_cap/1000
        }
    }

    alloc && /^[[:space:]]*memory:/ {
        mem_cap=mem_to_gib($2)
        alloc=0
    }

    /Allocated resources:/ {
        capture=1
        next
    }

    capture && /^[[:space:]]*cpu[[:space:]]/ {

        cpu_req_raw=$2

        if (cpu_req_raw ~ /m$/) {
            gsub("m","",cpu_req_raw)
            cpu_req=cpu_req_raw/1000
        } else {
            cpu_req=cpu_req_raw
        }

        cpu_req_pct=$3
        gsub(/[()%]/,"",cpu_req_pct)
    }

    capture && /^[[:space:]]*memory[[:space:]]/ {

        mem_req=mem_to_gib($2)

        mem_req_pct=$3
        gsub(/[()%]/,"",mem_req_pct)

        cpu_free=cpu_cap-cpu_req
        mem_free=mem_cap-mem_req

        printf "%s|%.2f|%.2f|%.2f|%s|%.1f|%.1f|%.1f|%s\n",
               node,
               cpu_cap,
               cpu_req,
               cpu_free,
               cpu_req_pct,
               mem_cap,
               mem_req,
               mem_free,
               mem_req_pct

        capture=0
    }
    '
done | while IFS='|' read \
node cpu_cap cpu_req cpu_free cpu_pct \
mem_cap mem_req mem_free mem_pct
do

    alert="OK"

    if [ "$cpu_pct" -ge 90 ]; then
        alert="CPU!!"
    elif [ "$cpu_pct" -ge 80 ]; then
        alert="CPU!"
    fi

    if [ "$mem_pct" -ge 90 ]; then
        if [ "$alert" = "OK" ]; then
            alert="MEM!!"
        else
            alert="$alert,MEM!!"
        fi
    elif [ "$mem_pct" -ge 80 ]; then
        if [ "$alert" = "OK" ]; then
            alert="MEM!"
        else
            alert="$alert,MEM!"
        fi
    fi

    COLOR=$GREEN

    if [ "$cpu_pct" -ge 80 ] || [ "$mem_pct" -ge 80 ]; then
        COLOR=$RED
    elif [ "$cpu_pct" -ge 70 ] || [ "$mem_pct" -ge 70 ]; then
        COLOR=$YELLOW
    fi

    printf "${COLOR}%-32s %-10s %-15.2f %-15.2f %-15.2f %-8s %-15.1f %-15.1f %-15.1f %-8s${NC}\n" \
        "$node" \
        "$alert" \
        "$cpu_cap" \
        "$cpu_req" \
        "$cpu_free" \
        "${cpu_pct}%" \
        "$mem_cap" \
        "$mem_req" \
        "$mem_free" \
        "${mem_pct}%"
done

printf "\n"
printf "Legend:\n"
printf "  OK      = Healthy\n"
printf "  CPU!    = CPU Requests >= 80%%\n"
printf "  CPU!!   = CPU Requests >= 90%%\n"
printf "  MEM!    = Memory Requests >= 80%%\n"
printf "  MEM!!   = Memory Requests >= 90%%\n\n"
