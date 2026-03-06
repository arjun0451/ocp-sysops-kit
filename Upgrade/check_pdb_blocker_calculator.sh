#!/bin/bash

# ------------------------
# PDB Health & Disruption Checker with Summary
# ------------------------

# Color codes
RED="\033[31m"
ORANGE="\033[38;5;208m"
GREEN="\033[32m"
BLUE="\033[34m"
BOLD="\033[1m"
NC="\033[0m"

# Temporary file for JSON
TMP_JSON=$(mktemp)
oc get pdb -A -o json > "$TMP_JSON"

# Print calculation reference and table header
echo "Reference for disruptionsAllowed calculation:"
echo "-------------------------------------------------"
echo "If minAvailable is configured: disruptionsAllowed = currentHealthy - minAvailable"
echo "If maxUnavailable is configured: disruptionsAllowed = maxUnavailable - (expectedPods - currentHealthy)"
echo "disruptionsAllowed is capped at 0 if negative"
echo
echo -e "NAMESPACE\tPDB_NAME\tTYPE\tEXPECTED_PODS\tCURRENT_HEALTHY\tDISRUPTIONS_ALLOWED\tDISRUPTIONS_%\tREMARK"

# Parse PDB JSON and prepare table with color flags
TABLE=$(jq -r '
.items[] |
select(.metadata.namespace | test("^openshift") | not) |
{
  ns: .metadata.namespace,
  name: .metadata.name,
  expected: .status.expectedPods,
  healthy: .status.currentHealthy,
  minAvailable: .spec.minAvailable,
  maxUnavailable: .spec.maxUnavailable
} as $pdb |
(
  if $pdb.minAvailable != null then
    {
      type: "minAvailable",
      calc: ($pdb.healthy - $pdb.minAvailable),
      formula: "currentHealthy - minAvailable = \($pdb.healthy) - \($pdb.minAvailable) = \($pdb.healthy - $pdb.minAvailable)"
    }
  elif $pdb.maxUnavailable != null then
    {
      type: "maxUnavailable",
      calc: ($pdb.maxUnavailable - ($pdb.expected - $pdb.healthy)),
      formula: "maxUnavailable - (expected - currentHealthy) = \($pdb.maxUnavailable) - (\($pdb.expected) - \($pdb.healthy)) = \($pdb.maxUnavailable - ($pdb.expected - $pdb.healthy))"
    }
  else
    {
      type: "none",
      calc: 0,
      formula: "N/A"
    }
  end
) as $res |
($res.calc | if . < 0 then 0 else . end) as $disruptionsAllowed |
($pdb.expected | if . == 0 then 0 else (($disruptionsAllowed / .) * 100 + 0.5 | floor) end) as $disruptionsPercent |
($disruptionsAllowed |
  if $pdb.expected == 0 then
    "N/A (no pods configured)"
  elif . == 0 then
    "Blocked (\($res.formula))"
  else
    "OK (\($res.formula))"
  end
) as $remark |
# Determine color
(
  if $disruptionsAllowed == 0 then "RED"
  elif $disruptionsPercent == 100 then "BLUE"
  elif $disruptionsPercent < 30 then "ORANGE"
  else "GREEN"
  end
) as $color |
# Output fields plus percent for later summary
"\($color)\t\($disruptionsPercent)\t\($pdb.ns)\t\($pdb.name)\t\($res.type)\t\($pdb.expected)\t\($pdb.healthy)\t\($disruptionsAllowed)\t\($remark)"
' "$TMP_JSON")

# Count PDB categories
BLOCKED=$(echo "$TABLE" | awk -F'\t' '$1=="RED"{count++} END{print count+0}')
FULL_OUTAGE=$(echo "$TABLE" | awk -F'\t' '$1=="BLUE"{count++} END{print count+0}')
SAFE=$(echo "$TABLE" | awk -F'\t' '$1=="GREEN"{count++} END{print count+0}')
LOW_HA=$(echo "$TABLE" | awk -F'\t' '$1=="ORANGE"{count++} END{print count+0}')

# Total PDBs analyzed
TOTAL=$(echo "$TABLE" | wc -l)

# Print the table with colors
echo "$TABLE" | while IFS=$'\t' read -r color percent ns name type expected healthy disruptions remark; do
  case "$color" in
    RED) echo -e "${RED}${ns}\t${name}\t${type}\t${expected}\t${healthy}\t${disruptions}\t${percent}%\t${remark}${NC}" ;;
    ORANGE) echo -e "${ORANGE}${ns}\t${name}\t${type}\t${expected}\t${healthy}\t${disruptions}\t${percent}%\t${remark}${NC}" ;;
    GREEN) echo -e "${GREEN}${ns}\t${name}\t${type}\t${expected}\t${healthy}\t${disruptions}\t${percent}%\t${remark}${NC}" ;;
    BLUE) echo -e "${BLUE}${ns}\t${name}\t${type}\t${expected}\t${healthy}\t${disruptions}\t${percent}%\t${remark}${NC}" ;;
  esac
done | column -t -s $'\t'

# Bold banner note for full service outage
if [ "$FULL_OUTAGE" -gt 0 ]; then
  echo -e "\n${ORANGE}${BOLD}==============================================================${NC}"
  echo -e "${ORANGE}${BOLD}WARNING:${NC} Some PDBs show 100% disruptions allowed!"
  echo -e "${ORANGE}${BOLD}During maintenance, these services may experience FULL DOWNTIME.${NC}"
  echo -e "${ORANGE}${BOLD}==============================================================${NC}\n"
fi

# Enhanced Summary at the bottom
echo -e "${BOLD}Summary:${NC}"
echo -e "${RED}Blocked PDBs:${NC} $BLOCKED"
echo -e "${ORANGE}Low HA / Caution:${NC} $LOW_HA"
echo -e "${GREEN}Safe to perform maintenance:${NC} $SAFE"
echo -e "${BLUE}Full service outage allowed (100%):${NC} $FULL_OUTAGE"
echo -e "${BOLD}Total PDBs analyzed:${NC} $TOTAL"

# Cleanup
rm "$TMP_JSON"
