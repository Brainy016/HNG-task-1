#!/bin/bash

# Collect User Parameters
# Git details
read -p "Enter the Git repository URL: " GIT_REPO_URL
read -sp "Enter your Git Personal Access Token (input will be hidden): " GIT_PAT
echo # Add a newline after hidden input
read -p "Enter the branch name (default: main): " branch_name
BRANCH_NAME=${branch_name:-main}

# SSH details
read -p "Enter the remote server's SSH username: " REMOTE_USER
read -p "Enter the remote server's IP address: " REMOTE_IP
read -p "Enter the path to your SSH private key (e.g., ~/.ssh/id_rsa): " SSH_KEY_PATH

# Application details
read -p "Enter the application's internal container port (e.g., 3000): " APP_PORT

echo ""
echo "-----------------------------------"
echo "Configuration received:"
echo "-----------------------------------"
echo "Repo URL: $GIT_REPO_URL"
echo "Branch: $BRANCH_NAME"
echo "SSH User: $REMOTE_USER"
echo "Server IP: $REMOTE_IP"
echo "SSH Key: $SSH_KEY_PATH"
echo "App Port: $APP_PORT"
echo "PAT: [HIDDEN]"
echo "-----------------------------------"

REPO_NAME=$(basename -s .git "$GIT_REPO_URL")

echo "--- Preparing source code ---"

# Check if the repository directory already exists
if [ -d "$REPO_NAME" ]; then
  echo "Repository '$REPO_NAME' already exists. Pulling latest changes..."
  cd "$REPO_NAME"
  git checkout "$BRANCH_NAME"
  git pull origin "$BRANCH_NAME"
else
  echo "Cloning repository '$REPO_NAME'"
  CLONE_URL="https://oauth2:${GIT_PAT}@${GIT_REPO_URL#https://}"
  git clone --branch "$BRANCH_NAME" "$CLONE_URL"
  cd "$REPO_NAME"
fi

echo "Successfully checked out branch '$BRANCH_NAME'."

echo "--- Verifying project structure ---"


# Check for the presence of a Dockerfile or docker-compose.yml
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
  echo "Found Dockerfile or docker-compose.yml. Project is deployable."
else
  echo " Error: Neither Dockerfile nor docker-compose.yml found in the repository root."
  exit 1
fi

echo "--- Source code preparation complete -
