#!/bin/bash
set -e

# Cleanup function
cleanup() {
    if [ -n "$CONTAINER_ID" ]; then
        echo "Terminating Docker container..."
        docker stop $CONTAINER_ID 2>/dev/null || true
        docker rm $CONTAINER_ID 2>/dev/null || true
        echo "Container terminated successfully"
    fi
}

# Set trap to cleanup on exit
trap cleanup EXIT INT TERM

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --version) OPENSEARCH_VERSION="$2"; shift 2 ;;
    --components) COMPONENTS="$2"; shift 2 ;;
    --arch) ARCHITECTURE="$2"; shift 2 ;;
    --system) SYSTEM="$2"; shift 2 ;;
    --s3-bucket) S3_BUCKET="$2"; shift 2 ;;
    --snapshot) SNAPSHOT="true"; shift ;;
    *) echo "Unknown option $1"; exit 1 ;;
  esac
done

# Configuration variables with defaults
OPENSEARCH_VERSION=${OPENSEARCH_VERSION:-"3.3.0"}
COMPONENTS=${COMPONENTS:-"OpenSearch neural-search ml-commons job-scheduler"}
ARCHITECTURE=${ARCHITECTURE:-"arm64"}
SYSTEM=${SYSTEM:-"linux"}
SNAPSHOT=${SNAPSHOT:-"false"}

# Step 1: Start Docker container
echo "Starting Docker container..."
CONTAINER_ID=$(docker run -d --entrypoint bash opensearchstaging/ci-runner:ci-runner-al2-opensearch-build-v1 -c 'sleep infinity')
echo "Container ID: $CONTAINER_ID"

# Step 2: Setup build environment
echo "Setting up build environment..."
docker exec $CONTAINER_ID git clone https://github.com/opensearch-project/opensearch-build.git

# Step 3 & 4: Build OpenSearch
echo "Building OpenSearch $OPENSEARCH_VERSION components: $COMPONENTS..."
if [ "$SNAPSHOT" = "true" ]; then
    docker exec $CONTAINER_ID bash -c "export JAVA_HOME=/opt/java/openjdk-21 && cd opensearch-build && ./build.sh manifests/$OPENSEARCH_VERSION/opensearch-$OPENSEARCH_VERSION.yml -s -a $ARCHITECTURE -p $SYSTEM --component $COMPONENTS"
else
    docker exec $CONTAINER_ID bash -c "export JAVA_HOME=/opt/java/openjdk-21 && cd opensearch-build && ./build.sh manifests/$OPENSEARCH_VERSION/opensearch-$OPENSEARCH_VERSION.yml -a $ARCHITECTURE -p $SYSTEM --component $COMPONENTS"
fi

# Step 5: Create host folder
DATE_FOLDER=$(date +"%Y%m%d")
BUILD_DIR="$HOME/builds/$DATE_FOLDER"
mkdir -p "$BUILD_DIR"
echo "Created build directory: $BUILD_DIR"

# Step 7: Copy zip files
echo "Copying build artifacts..."
docker exec $CONTAINER_ID find /home/ci-runner/opensearch-build/tar/builds/opensearch/plugins -name "*.zip" -exec basename {} \; | while read file; do 
    docker exec $CONTAINER_ID find /home/ci-runner/opensearch-build/tar/builds/opensearch/plugins -name "$file" -exec cp {} /tmp/ \; && 
    docker cp "$CONTAINER_ID:/tmp/$file" "$BUILD_DIR/"
done

echo "Build complete! Artifacts saved to: $BUILD_DIR"

# Step 9: Upload to S3
if [ -n "$S3_BUCKET" ]; then
    echo "Uploading build artifacts to S3..."
    aws s3 cp "$BUILD_DIR" "s3://$S3_BUCKET/opensearch-builds/$DATE_FOLDER/" --recursive
    echo "Upload complete! S3 location: s3://$S3_BUCKET/opensearch-builds/$DATE_FOLDER/"
else
    echo "No S3 bucket specified. Use --s3-bucket to upload artifacts."
fi