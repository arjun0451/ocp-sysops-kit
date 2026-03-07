#!/bin/bash

# Script to run v9.sh, extract OpenShift cluster health check results, and populate HTML template
# Embeds static healthcheck_details.html content into healthcheck.html
# Cleans up log directories older than 2 days in /var/www/html/

# Configuration
INPUT_FILE="cluster_id.txt"
TEMPLATE_FILE="healthcheck_template.html"
DETAILS_FILE="healthcheck_details.html"
OUTPUT_FILE="/var/www/html/healthcheck.html"
LOG_BASE_DIR="/tmp/oc-health-logs"
V9_SCRIPT="v9.sh"
RESULTS_FILE="/tmp/check_results.txt"

# Validate inputs
if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: $INPUT_FILE not found"
    exit 1
fi
if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "Error: $TEMPLATE_FILE not found"
    exit 1
fi
if [[ ! -f "$DETAILS_FILE" ]]; then
    echo "Error: $DETAILS_FILE not found"
    exit 1
fi
if [[ ! -x "$V9_SCRIPT" ]]; then
    echo "Error: $V9_SCRIPT not found or not executable"
    exit 1
fi

# Read Cluster ID
CLUSTER_ID=$(grep '^cluster_id=' "$INPUT_FILE" | cut -d'=' -f2)
if [[ -z "$CLUSTER_ID" ]]; then
    echo "Error: cluster_id not found in $INPUT_FILE"
    exit 1
fi

# Clean up log directories older than 2 days in /var/www/html/
find /var/www/html/ -maxdepth 1 -type d -name 'oc-health-logs-*' -mtime +2 -exec rm -rf {} \;

# Run v9.sh to generate health check results
./v9.sh > /dev/null 2>&1

# Find the latest log directory
LOG_DIR=$(ls -d ${LOG_BASE_DIR}-* 2>/dev/null | sort -r | head -n 1)
if [[ -z "$LOG_DIR" ]]; then
    echo "Error: No log directory found in ${LOG_BASE_DIR}-*"
    exit 1
fi
TIMESTAMP=$(basename "$LOG_DIR" | grep -o '[0-9]\{8\}_[0-9]\{4\}')
SUMMARY_LOG="${LOG_DIR}/healthcheck-${TIMESTAMP}.log"
SSL_LOG="${LOG_DIR}/ssl_cert_check.log"

# Check if results file exists
if [[ ! -f "$RESULTS_FILE" ]]; then
    echo "Error: $RESULTS_FILE not found"
    exit 1
fi

# Extract results table
RESULTS=$(awk -F',' 'NR>1 {print}' "$RESULTS_FILE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

# Generate table content
TABLE_CONTENT=$(echo "$RESULTS" | while IFS=',' read -r number check_name status; do
    if [[ "$status" == "Passed" ]]; then
        status_class="bg-green-100 text-green-800"
    else
        status_class="bg-red-100 text-red-800"
    fi
    echo "<tr class=\"hover:bg-gray-50 transition\">"
    echo "  <td class=\"px-6 py-4 whitespace-nowrap\">$number</td>"
    echo "  <td class=\"px-6 py-4\">$check_name</td>"
    echo "  <td class=\"px-6 py-4 $status_class font-medium rounded-lg\">$status</td>"
    echo "</tr>"
done)

# Extract details content (skip <html>, <head>, <body> tags)
DETAILS_CONTENT=$(awk '/<div class="prose prose-sm max-w-none p-6">/,/<\/div>/' "$DETAILS_FILE" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')

# Escape content for sed
CLUSTER_ID_ESCAPED=$(printf '%s' "$CLUSTER_ID" | sed 's/[\/&]/\\&/g')
DISPLAY_TIMESTAMP=$(date -d "${TIMESTAMP:0:8} ${TIMESTAMP:9:2}:${TIMESTAMP:11:2}" +"%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || echo "$TIMESTAMP")
DISPLAY_TIMESTAMP_ESCAPED=$(printf '%s' "$DISPLAY_TIMESTAMP" | sed 's/[\/& ]/\\&/g')
SSL_DOWNLOAD_LINK=$([[ -f "$SSL_LOG" ]] && echo "<a href=\"/oc-health-logs-${TIMESTAMP}/ssl_cert_check.log\" class=\"inline-block bg-gradient-to-r from-red-600 to-red-500 hover:from-red-700 hover:to-red-600 text-white font-medium px-8 py-4 rounded-xl shadow-md text-center btn\">📄 Download SSL Log</a>" || echo "")

# Write table and details content to temporary files
printf '%s' "$TABLE_CONTENT" > /tmp/table_content_tmp
printf '%s' "$DETAILS_CONTENT" > /tmp/details_content_tmp

# Copy template and replace placeholders
cp "$TEMPLATE_FILE" "$OUTPUT_FILE"
sed -i "s/{{CLUSTER_ID}}/$CLUSTER_ID_ESCAPED/g" "$OUTPUT_FILE"
sed -i "s/{{DISPLAY_TIMESTAMP}}/$DISPLAY_TIMESTAMP_ESCAPED/g" "$OUTPUT_FILE"
sed -i -e "/{{TABLE_CONTENT}}/r /tmp/table_content_tmp" -e "s/{{TABLE_CONTENT}}//g" "$OUTPUT_FILE"
sed -i -e "/{{DETAILS_CONTENT}}/r /tmp/details_content_tmp" -e "s/{{DETAILS_CONTENT}}//g" "$OUTPUT_FILE"
sed -i "s/{{SSL_DOWNLOAD_LINK}}/$SSL_DOWNLOAD_LINK/g" "$OUTPUT_FILE"
sed -i "s/{{TIMESTAMP}}/$TIMESTAMP/g" "$OUTPUT_FILE"

# Clean up temporary files
rm -f /tmp/table_content_tmp /tmp/details_content_tmp

# Set permissions for output file
chmod 644 "$OUTPUT_FILE"
chown apache:apache "$OUTPUT_FILE" 2>/dev/null || true

# Copy logs to web directory
cp -r "$LOG_DIR" /var/www/html/
chmod -R 755 /var/www/html/oc-health-logs-${TIMESTAMP}
chown -R apache:apache /var/www/html/oc-health-logs-${TIMESTAMP} 2>/dev/null || true

echo "Generated $OUTPUT_FILE"##
