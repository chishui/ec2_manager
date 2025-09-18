#!/bin/bash

# OpenSearch Installation Script
# Downloads OpenSearch and plugins, configures JVM settings, and installs plugins

set -e  # Exit on any error

# ============================================================================
# CONFIGURATION VARIABLES
# ============================================================================

# OpenSearch version configuration
OPENSEARCH_VERSION="3.3.0-SNAPSHOT"  # Change this to your desired version
OPENSEARCH_BASE_URL="https://artifacts.opensearch.org/snapshots/core/opensearch"

# Plugin base URL template (without specific plugin name)
PLUGIN_BASE_URL="https://aws.oss.sonatype.org/content/repositories/snapshots/org/opensearch/plugin"

# JVM heap size configuration
JVM_HEAP_SIZE="31g"  # Change this to your desired heap size (e.g., "4g", "8g")

# Installation directory
INSTALL_DIR="./opensearch"
DOWNLOAD_DIR="./downloads"

# Plugin configuration
# Two ways to specify plugins:
# 1. Plugin name (uses maven metadata): "plugin-name"
# 2. Direct URL (downloads directly): "https://example.com/plugin.zip"

PLUGINS=(
    "opensearch-sql-plugin"
    # Direct URL example:
    # "https://artifacts.opensearch.org/releases/plugins/opensearch-neural-search/2.11.0.0/opensearch-neural-search-2.11.0.0.zip"
    # Add more plugins as needed
    # "opensearch-security-plugin"
    # "opensearch-alerting-plugin"
)

# Plugin version (used only for maven metadata approach)
PLUGIN_VERSION="3.3.0.0-SNAPSHOT"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

detect_architecture() {
    local os_type=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch=$(uname -m)
    
    # Map OS types
    case "$os_type" in
        linux*)   os_type="linux" ;;
        darwin*)  os_type="darwin" ;;
        *)        error "Unsupported OS: $os_type" ;;
    esac
    
    # Map architectures
    case "$arch" in
        x86_64|amd64)  arch="x64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)             error "Unsupported architecture: $arch" ;;
    esac
    
    echo "${os_type}-${arch}"
}

construct_opensearch_url() {
    local arch_string=$(detect_architecture)
    local opensearch_url="${OPENSEARCH_BASE_URL}/${OPENSEARCH_VERSION}/opensearch-min-${OPENSEARCH_VERSION}-${arch_string}-latest.tar.gz"
    
    echo "$opensearch_url"
}

is_url() {
    local input="$1"
    if [[ "$input" =~ ^https?:// ]]; then
        return 0  # true - it's a URL
    else
        return 1  # false - it's not a URL
    fi
}

create_directories() {
    log "Creating directories..."
    mkdir -p "$DOWNLOAD_DIR"
    mkdir -p "$INSTALL_DIR"
}

# ============================================================================
# DOWNLOAD FUNCTIONS
# ============================================================================

download_opensearch() {
    log "Downloading OpenSearch..."
    
    # Detect architecture and construct URL
    local arch_string=$(detect_architecture)
    local opensearch_url=$(construct_opensearch_url)
    local filename=$(basename "$opensearch_url")
    local filepath="$DOWNLOAD_DIR/$filename"
    
    log "Detected architecture: $arch_string"
    log "OpenSearch version: $OPENSEARCH_VERSION"
    log "Download URL: $opensearch_url"
    
    if [[ -f "$filepath" ]]; then
        log "OpenSearch already downloaded: $filepath"
        return 0
    fi
    
    curl -L -o "$filepath" "$opensearch_url" || error "Failed to download OpenSearch from: $opensearch_url"
    log "OpenSearch downloaded successfully: $filepath"
}

parse_latest_plugin_build() {
    local plugin_name="$1"
    local metadata_url="$PLUGIN_BASE_URL/$plugin_name/$PLUGIN_VERSION/maven-metadata.xml"
    
    # Download the maven metadata XML with proper error handling
    local http_code=$(curl -s -w "%{http_code}" -o /tmp/maven-metadata.xml "$metadata_url" 2>/dev/null)
    
    # Check if the HTTP request was successful
    if [[ "$http_code" != "200" ]]; then
        error "Failed to download maven metadata from: $metadata_url (HTTP $http_code). Please check if the plugin name and version are correct."
    fi
    
    # Read the downloaded metadata
    local metadata=$(cat /tmp/maven-metadata.xml 2>/dev/null)
    
    # Clean up temporary file
    rm -f /tmp/maven-metadata.xml
    
    if [[ -z "$metadata" ]]; then
        error "Maven metadata file is empty or could not be read for plugin: $plugin_name"
    fi
    
    # Check if the metadata contains valid XML structure
    if ! echo "$metadata" | grep -q "<metadata"; then
        error "Invalid maven metadata format for plugin: $plugin_name. Response: ${metadata:0:200}..."
    fi
    
    # Parse the XML to extract the snapshot version for .zip extension
    # Look for <snapshotVersion> with <extension>zip</extension> and extract <value>
    local snapshot_version=$(echo "$metadata" | grep -A 3 -B 1 '<extension>zip</extension>' | grep '<value>' | sed 's/.*<value>\(.*\)<\/value>.*/\1/')
    
    if [[ -z "$snapshot_version" ]]; then
        error "Could not find snapshot version for .zip extension in metadata for plugin: $plugin_name. Please verify the plugin exists and has a .zip artifact."
    fi
    
    # Construct the plugin filename
    # Format: {plugin-name}-{snapshot-version}.zip
    local plugin_filename="${plugin_name}-${snapshot_version}.zip"
    
    echo "$plugin_filename"
}

download_plugin_from_url() {
    local plugin_url="$1"
    local filename=$(basename "$plugin_url")
    local filepath="$DOWNLOAD_DIR/$filename"
    
    log "Processing direct plugin URL: $plugin_url"
    log "Plugin filename: $filename"
    
    if [[ -f "$filepath" ]]; then
        log "Plugin already downloaded: $filepath"
        return 0
    fi
    
    log "Downloading plugin from: $plugin_url"
    
    # Download with HTTP status check
    local http_code=$(curl -L -w "%{http_code}" -o "$filepath" "$plugin_url" 2>/dev/null)
    
    if [[ "$http_code" != "200" ]]; then
        rm -f "$filepath"  # Clean up partial download
        error "Failed to download plugin from: $plugin_url (HTTP $http_code)"
    fi
    
    # Verify the downloaded file is a valid zip
    if ! file "$filepath" | grep -q -i zip; then
        rm -f "$filepath"  # Clean up invalid file
        error "Downloaded file is not a valid ZIP archive: $filepath"
    fi
    
    log "Plugin downloaded successfully: $filepath"
}

download_plugin_from_maven() {
    local plugin_name="$1"
    log "Processing plugin: $plugin_name"
    
    # Fetch maven metadata
    local metadata_url="$PLUGIN_BASE_URL/$plugin_name/$PLUGIN_VERSION/maven-metadata.xml"
    log "Fetching maven metadata from: $metadata_url"
    
    # Get the latest build filename
    local latest_zip=$(parse_latest_plugin_build "$plugin_name")
    local plugin_url="$PLUGIN_BASE_URL/$plugin_name/$PLUGIN_VERSION/$latest_zip"
    local filepath="$DOWNLOAD_DIR/$latest_zip"
    
    log "Latest plugin build: $latest_zip"
    
    if [[ -f "$filepath" ]]; then
        log "Plugin already downloaded: $filepath"
        return 0
    fi
    
    log "Downloading plugin from: $plugin_url"
    
    # Download with HTTP status check
    local http_code=$(curl -L -w "%{http_code}" -o "$filepath" "$plugin_url" 2>/dev/null)
    
    if [[ "$http_code" != "200" ]]; then
        rm -f "$filepath"  # Clean up partial download
        error "Failed to download plugin: $plugin_name from: $plugin_url (HTTP $http_code)"
    fi
    
    log "Plugin downloaded successfully: $filepath"
}

download_plugin() {
    local plugin_entry="$1"
    
    if is_url "$plugin_entry"; then
        download_plugin_from_url "$plugin_entry"
    else
        download_plugin_from_maven "$plugin_entry"
    fi
}

download_all_plugins() {
    log "Downloading all plugins..."
    for plugin in "${PLUGINS[@]}"; do
        download_plugin "$plugin"
    done
}

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

extract_opensearch() {
    log "Extracting OpenSearch..."
    local opensearch_file=$(find "$DOWNLOAD_DIR" -name "opensearch-*.tar.gz" | head -1)
    
    if [[ -z "$opensearch_file" ]]; then
        error "OpenSearch tar.gz file not found in $DOWNLOAD_DIR"
    fi
    
    # Extract to a temporary directory first
    local temp_dir=$(mktemp -d)
    tar -xzf "$opensearch_file" -C "$temp_dir" || error "Failed to extract OpenSearch"
    
    # Move the extracted directory to our install location
    local extracted_dir=$(find "$temp_dir" -maxdepth 1 -type d -name "opensearch-*" | head -1)
    if [[ -z "$extracted_dir" ]]; then
        error "Could not find extracted OpenSearch directory"
    fi
    
    # Remove existing installation if it exists
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
    fi
    
    mv "$extracted_dir" "$INSTALL_DIR" || error "Failed to move OpenSearch to install directory"
    rm -rf "$temp_dir"
    
    log "OpenSearch extracted to: $INSTALL_DIR"
}

configure_jvm() {
    log "Configuring JVM settings..."
    local jvm_options_file="$INSTALL_DIR/config/jvm.options"
    
    if [[ ! -f "$jvm_options_file" ]]; then
        error "JVM options file not found: $jvm_options_file"
    fi
    
    # Backup original file
    cp "$jvm_options_file" "$jvm_options_file.backup"
    
    # Update heap size settings
    sed -i.tmp "s/^-Xms.*/-Xms$JVM_HEAP_SIZE/" "$jvm_options_file"
    sed -i.tmp "s/^-Xmx.*/-Xmx$JVM_HEAP_SIZE/" "$jvm_options_file"
    rm -f "$jvm_options_file.tmp"
    
    log "JVM heap size configured to: $JVM_HEAP_SIZE"
}

install_plugins() {
    log "Installing plugins..."
    local plugin_install_cmd="$INSTALL_DIR/bin/opensearch-plugin"
    
    if [[ ! -f "$plugin_install_cmd" ]]; then
        error "OpenSearch plugin installer not found: $plugin_install_cmd"
    fi
    
    # Make sure the plugin installer is executable
    chmod +x "$plugin_install_cmd"
    
    # Install each downloaded plugin
    for plugin_file in "$DOWNLOAD_DIR"/*.zip; do
        if [[ -f "$plugin_file" ]]; then
            log "Installing plugin: $(basename "$plugin_file")"
            "$plugin_install_cmd" install "file://$PWD/$plugin_file" || error "Failed to install plugin: $plugin_file"
        fi
    done
    
    log "All plugins installed successfully"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    log "Starting OpenSearch installation process..."
    
    # Create necessary directories
    create_directories
    
    # Download OpenSearch and plugins
    download_opensearch
    download_all_plugins
    
    # Extract and configure OpenSearch
    extract_opensearch
    configure_jvm
    
    # Install plugins
    install_plugins
    
    log "OpenSearch installation completed successfully!"
    log "Installation directory: $INSTALL_DIR"
    log "To start OpenSearch, run: $INSTALL_DIR/bin/opensearch"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi