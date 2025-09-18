#!/bin/sh

# get home folder
HOME_FOLDER=$(pwd)
PLUGIN_URL=""
PLUGIN_NAME="opensearch-neural-search"
# get file name from plugin url
PLUGIN_FILE_NAME=$(basename $PLUGIN_URL)
OPENSEARCH_PATH="/home/ubuntu/opensearch-2.17.0"
curl -O "$PLUGIN_URL"

function is_open_search_running() {
    local pids=$(pgrep -f opensearch)
    
    if [ -z "$pids" ]; then
        echo "No OpenSearch processes found"
        return 1
    }
    return 0
}

function kill_open_search() {
    # Find OpenSearch processes
    local pids=$(pgrep -f opensearch)
    
    if [ -z "$pids" ]; then
        echo "No OpenSearch processes found"
        return 1
    }
    
    # Attempt graceful shutdown first
    for pid in $pids; do
        if kill -15 "$pid" 2>/dev/null; then
            echo "Sent SIGTERM to OpenSearch process $pid"
        fi
    done
    
    # Wait for processes to terminate (up to 30 seconds)
    local count=0
    while pgrep -f opensearch >/dev/null && [ $count -lt 30 ]; do
        sleep 1
        ((count++))
    done
    
    # Force kill if still running
    pids=$(pgrep -f opensearch)
    if [ -n "$pids" ]; then
        for pid in $pids; do
            if kill -9 "$pid" 2>/dev/null; then
                echo "Force killed OpenSearch process $pid"
            fi
        done
    fi
}

# uninstall
$OPENSEARCH_PATH/bin/opensearch-plugin remove $PLUGIN_NAME
# install
$OPENSEARCH_PATH/bin/opensearch-plugin install -s file://$HOME_FOLDER/$PLUGIN_FILE_NAME

if is_open_search_running; then
    # restart open search
    kill_open_search;
fi

$OPENSEARCH_PATH/bin/opensearch;