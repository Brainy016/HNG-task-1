#!/bin/bash
set -e

# --- 1. Collect User Parameters (No logging yet) ---
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
echo "Configuration received. Starting deployment..."
echo "-----------------------------------"


# --- 2. Setup Logging & Error Handling ---
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
# Redirect all subsequent stdout/stderr to both console and log file
exec > >(tee -a "$LOG_FILE") 2>&1

# Function for timestamped logs
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] - $1"
}

# Function to handle errors
handle_error() {
  local exit_code=$?
  local line_number=$1
  local command=$2
  log "ERROR: Command '$command' failed on line $line_number with exit code $exit_code"
  log "Deployment FAILED. See $LOG_FILE for details."
  exit $exit_code
}

# Trap ERR signals to call our error handler
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

log "Script started. Logging to $LOG_FILE"
log "-----------------------------------"
log "Configuration:"
log "Repo URL: $GIT_REPO_URL"
log "Branch: $BRANCH_NAME"
log "SSH User: $REMOTE_USER"
log "Server IP: $REMOTE_IP"
log "SSH Key: $SSH_KEY_PATH"
log "App Port: $APP_PORT"
log "PAT: [HIDDEN]"
log "-----------------------------------"


# --- 3. Prepare Source Code ---
REPO_NAME=$(basename -s .git "$GIT_REPO_URL")

log "--- Preparing source code ---"

if [ -d "$REPO_NAME" ]; then
  log "Repository '$REPO_NAME' already exists. Pulling latest changes..."
  cd "$REPO_NAME"
  git checkout "$BRANCH_NAME"
  git pull origin "$BRANCH_NAME"
else
  log "Cloning repository '$REPO_NAME'"
  CLONE_URL="https://oauth2:${GIT_PAT}@${GIT_REPO_URL#https://}"
  git clone --branch "$BRANCH_NAME" "$CLONE_URL"
  cd "$REPO_NAME"
fi

log "Successfully checked out branch '$BRANCH_NAME'."

log "--- Verifying project structure ---"
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
  log "Found Dockerfile or docker-compose.yml. Project is deployable."
else
  log "Error: Neither Dockerfile nor docker-compose.yml found in the repository root."
  exit 1
fi

log "--- Source code preparation complete ---"


# --- 4. Prepare Remote Server ---
log "--- Connecting to remote server $REMOTE_USER@$REMOTE_IP ---"

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REMOTE_USER"@"$REMOTE_IP" << 'EOF'

  set -e

  echo "--- (Remote) Updating system packages ---"
  sudo apt-get update -y

  echo "--- (Remote) Checking for required packages ---"
  PACKAGES_TO_INSTALL=""
  
  if ! command -v docker &> /dev/null; then
    echo "Docker not found, adding to install list."
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL docker.io"
  else
    echo "Docker is already installed."
  fi
  
  if ! command -v docker-compose &> /dev/null; then
    echo "Docker Compose not found, adding to install list."
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL docker-compose"
  else
    echo "Docker Compose is already installed."
  fi
  
  if ! command -v nginx &> /dev/null; then
    echo "Nginx not found, adding to install list."
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL nginx"
  else
    echo "Nginx is already installed."
  fi
  
  # Install curl for health checks
  if ! command -v curl &> /dev/null; then
    echo "curl not found, adding to install list."
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL curl"
  fi

  if [ -n "$PACKAGES_TO_INSTALL" ]; then
    echo "Installing: $PACKAGES_TO_INSTALL"
    sudo apt-get install -y $PACKAGES_TO_INSTALL
  else
    echo "All required packages are already present."
  fi

  echo "--- (Remote) Enabling and starting services ---"
  sudo systemctl enable docker
  sudo systemctl start docker
  
  sudo systemctl enable nginx
  sudo systemctl start nginx

  echo "--- (Remote) Validating services are active ---"
  sudo systemctl is-active --quiet docker
  echo "Docker service is active."
  sudo systemctl is-active --quiet nginx
  echo "Nginx service is active."

  echo "--- (Remote) Configuring Docker group ---"
  if ! getent group docker | grep -q "\b$USER\b"; then
    echo "Adding user '$USER' to the 'docker' group."
    sudo usermod -aG docker "$USER"
    echo "WARNING: Group changes may require a new login session to take effect."
  else
    echo "User '$USER' is already in the 'docker' group."
  fi

  echo "(Remote) Server preparation complete."
EOF

log "--- Server preparation finished ---"


# --- 5. Deploy Application to Remote Server ---
log "--- Deploying application to remote server ---"

log "Transferring source code to remote server..."
rsync -avz --delete -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
  ./"$REPO_NAME"/ "$REMOTE_USER@$REMOTE_IP:~/app/"

log "Running remote deployment and validation..."
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REMOTE_USER"@"$REMOTE_IP" << EOF
  set -e
  
  # Pass local variables to the remote shell
  APP_PORT=$APP_PORT
  REMOTE_IP=$REMOTE_IP

  echo "--- (Remote) Starting application deployment ---"
  cd ~/app
  
  if [ -f "docker-compose.yml" ]; then
    echo "Using docker-compose for deployment..."
    # Corrected Warning:
    echo "WARNING: Make sure your docker-compose.yml maps its service to port $APP_PORT"
    
    echo "Stopping existing docker-compose containers..."
    docker-compose down 2>/dev/null || true
    
    echo "Building and starting new containers..."
    docker-compose up --build -d
    
    echo "Waiting for containers to start..."
    sleep 15
    
    if ! docker-compose ps | grep -q "Up"; then
      echo "Error: Containers failed to start properly"
      docker-compose logs
      exit 2 # Exit code for compose start fail
    fi
    echo "Application deployed successfully with docker-compose!"

    echo "--- (Remote) Validating compose app health (http://localhost:$APP_PORT) ---"
    if ! curl -f http://localhost:$APP_PORT; then
        echo "ERROR: Health check failed for compose app at http://localhost:$APP_PORT"
        docker-compose logs
        exit 3 # Exit code for compose health fail
    fi
    echo "--- (Remote) Compose health check passed ---"
    
  elif [ -f "Dockerfile" ]; then
    echo "Using Dockerfile for deployment..."
    
    echo "Building the Docker image..."
    docker build -t app-deployment .
    
    echo "Stopping and removing existing container..."
    docker stop app-container 2>/dev/null || true
    docker rm app-container 2>/dev/null || true
    
    echo "Running new container on $APP_PORT:$APP_PORT..."
    docker run -d --name app-container -p $APP_PORT:$APP_PORT app-deployment
    
    echo "Waiting for container to start..."
    sleep 15
    
    if ! docker ps | grep -q "app-container"; then
      echo "Error: Container failed to start properly"
      docker logs app-container
      exit 4 # Exit code for Docker start fail
    fi
    echo "Application deployed successfully with Docker!"

    echo "--- (Remote) Validating Dockerfile app health (http://localhost:$APP_PORT) ---"
    if ! curl -f http://localhost:$APP_PORT; then
        echo "ERROR: Health check failed for Dockerfile app at http://localhost:$APP_PORT"
        docker logs app-container
        exit 5 # Exit code for Docker health fail
    fi
    echo "--- (Remote) Dockerfile health check passed ---"
  fi
  
  echo "--- (Remote) Application deployment complete ---"
  
  echo "--- (Remote) Configuring Nginx proxy ---"
  sudo tee /etc/nginx/sites-available/app > /dev/null << NGINX_EOF
server {
    listen 80;
    server_name $REMOTE_IP _;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Handle WebSocket connections
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX_EOF

  echo "Enabling site and restarting Nginx..."
  sudo ln -sf /etc/nginx/sites-available/app /etc/nginx/sites-enabled/
  sudo rm -f /etc/nginx/sites-enabled/default
  
  echo "Testing Nginx configuration..."
  sudo nginx -t
  
  echo "Reloading Nginx..."
  sudo systemctl reload nginx
  
  echo "--- (Remote) Validating Nginx proxy (127.0.0.1:80) ---"
  if ! curl -f http://127.0.0.1; then
    echo "ERROR: Nginx proxy validation failed. Could not reach app via proxy."
    echo "Dumping Nginx error log:"
    sudo tail -n 20 /var/log/nginx/error.log || true
    exit 6 # Exit code for Nginx fail
  fi

  echo "Nginx configured and validated successfully!"
  echo "Application should be accessible at: http://$REMOTE_IP"
  
EOF

# --- 6. Final Remote Validation ---
log "--- Remote deployment finished. ---"
log "--- Performing final validation from local machine... ---"

if curl -f "http://$REMOTE_IP"; then
  log "SUCCESS: Remote validation passed. Application is LIVE at http://$REMOTE_IP"
else
  log "ERROR: Remote validation FAILED. The site http://$REMOTE_IP is not accessible."
  exit 7 # Exit code for final validation fail
fi


# --- 7. Summary ---
log "--- Deployment finished successfully ---"
echo "" 
log "========================================="
log "DEPLOYMENT SUMMARY"
log "========================================="
log "Repository: $REPO_NAME"
log "Branch: $BRANCH_NAME"
log "Server: $REMOTE_USER@$REMOTE_IP"
log "Application URL: http://$REMOTE_IP"
log "Log File: $LOG_FILE"
log "========================================="
echo ""
log "Deployment completed!"