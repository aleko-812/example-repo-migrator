#!/bin/bash

# Load environment variables
if [ -f .env ]; then
    # Read each line from .env and export variables
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ $key =~ ^#.*$ ]] || [ -z "$key" ] && continue
        # Remove quotes from value if present
        value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//')
        # Evaluate any variables in the value
        eval "value=\"$value\""
        export "$key=$value"
    done < .env
else
    echo "Error: .env file not found!"
    exit 1
fi

# Validate required environment variables
required_vars=("SOURCE_SSH_BASE" "TARGET_ORGANISATION" "TARGET_AUTHORIZATION_HEADER" "TARGET_SSH_BASE" "TARGET_API_BASE" "WORK_DIR" "REPOS_LIST")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: $var is not set in .env file"
        exit 1
    fi
done

# Create working directory
mkdir -p "$WORK_DIR"

# Function to migrate a single repository
migrate_repo() {
    local repo_name=$1
    local work_path="$WORK_DIR/$repo_name"

    echo "=== Starting migration of $repo_name ==="

    # Check if repository already exists in target VCS
    echo "Checking if repository $repo_name already exists..."
    local repo_check=$(curl -s -X 'GET' \
        "${TARGET_API_BASE}/repos/${TARGET_ORGANISATION}/${repo_name}" \
        -H 'accept: application/json' \
        -H "${TARGET_AUTHORIZATION_HEADER}" \
        -H 'Content-Type: application/json')

    # Check if id field exists and is not null
    # if echo "$repo_check" | grep -q '"id":[^null]'; then
    #     echo "Repository $repo_name already exists in target VCS. Skipping..."
    #     return 0
    # fi

    # Create repository in target VCS first
    echo "Creating repository $repo_name in target VCS..."
    curl -X 'POST' \
        "${TARGET_API_BASE}/orgs/${TARGET_ORGANISATION}/repos" \
        -H 'accept: application/json' \
        -H "${TARGET_AUTHORIZATION_HEADER}" \
        -H 'Content-Type: application/json' \
        -d "{\"name\": \"${repo_name}\", \"private\": true}"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to create repository $repo_name in target VCS"
        return 1
    fi

    # Wait a moment for the repository to be fully created
    sleep 2

    # Clone the source repository with all branches
    git clone --mirror "$SOURCE_SSH_BASE/$repo_name.git" "$work_path"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to clone $repo_name"
        return 1
    fi

    cd "$work_path"

    # Add new remote
    git remote add target "$TARGET_SSH_BASE/$repo_name.git"

    # Push all branches and tags to the new remote
    git push target --mirror

    if [ $? -ne 0 ]; then
        echo "Error: Failed to push $repo_name to target"
        return 1
    fi

    # Cleanup
    cd ..
    rm -rf "$work_path"

    echo "=== Successfully migrated $repo_name ==="
    echo
}

# Main execution
if [ ! -f "$REPOS_LIST" ]; then
    echo "Error: $REPOS_LIST file not found!"
    exit 1
fi

# Read and process each repository
while IFS= read -r repo; do
    # Skip empty lines and comments
    [[ -z "$repo" || "$repo" =~ ^#.*$ ]] && continue

    migrate_repo "$repo"
done < "$REPOS_LIST"

# Final cleanup
rm -rf "$WORK_DIR"

echo "Migration completed!"
