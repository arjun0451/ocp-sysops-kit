#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

TIMEOUT=8

ENDPOINTS=(
registry.redhat.io
registry.access.redhat.com
access.redhat.com
quay.io
cdn.quay.io
cdn01.quay.io
cdn02.quay.io
cdn03.quay.io
cdn04.quay.io
cdn05.quay.io
cdn06.quay.io
api.openshift.com
mirror.openshift.com
rhcos.mirror.openshift.com
console.redhat.com
sso.redhat.com
)

PASS=0
FAIL=0

echo "=============================================================="
echo "OpenShift External Connectivity Validation"
echo "=============================================================="
echo "Pod/Node : $(hostname)"
echo "Date     : $(date)"
echo "=============================================================="

printf "%-40s %-10s\n" "Endpoint" "Result"
printf "%-40s %-10s\n" "----------------------------------------" "------"

for url in "${ENDPOINTS[@]}"
do

curl -k -Is --connect-timeout $TIMEOUT https://$url >/dev/null 2>&1

if [ $? -eq 0 ]
then
RESULT="${GREEN}PASS${NC}"
((PASS++))
else
RESULT="${RED}FAIL${NC}"
((FAIL++))
fi

printf "%-40s %-10b\n" "$url" "$RESULT"

done

echo ""
echo "=============================================================="
echo "Summary"
echo "=============================================================="

echo "Successful Checks : $PASS"
echo "Failed Checks     : $FAIL"

if [ $FAIL -eq 0 ]; then
echo -e "${GREEN}All endpoints reachable. Connectivity OK.${NC}"
else
echo -e "${RED}Some endpoints unreachable. Firewall/Proxy issue likely.${NC}"
fi

echo "=============================================================="
