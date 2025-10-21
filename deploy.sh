#!/bin/sh
set -e

# POSIX trap for interrupts (Ctrl+C)
handle_interrupt() {
  # We redirect to stderr (>&2) so it appears even if stdout is piped
  printf "\n--- INTERRUPTED: Deployment Halted ---\n" >&2
  exit 130
}
trap 'handle_interrupt' INT TERM

# --- 1. Collect User Parameters ---
# All prompts are written to stderr (>&2) so they appear on the
# console even when stdout is piped to a log file.

# POSIX-compliant prompt (no 'read -p')
printf "Enter the Git repository URL: " >&2
read GIT_REPO_URL

# POSIX-compliant silent prompt (no 'read -s')
printf "Enter your Git Personal Access Token (input will be hidden): " >&2
stty -echo
read GIT_PAT
stty echo
printf "\n" >&2 # Add the newline

printf "Enter the branch name (default: main): " >&2
read branch_name
BRANCH_NAME=${branch_name:-main}

printf "Enter the remote server's SSH username: " >&2
read REMOTE_USER
printf "Enter the remote server's IP address: " >&2
read REMOTE_IP
printf "Enter the path to your SSH private key (e.g., ~/.ssh/id_rsa): " >&2
read SSH_KEY_PATH

printf "Enter the application's internal container port (e.g., 3000): " >&2
read APP_PORT

echo ""
echo "-----------------------------------"
echo "Configuration received. Starting deployment..."
echo "-----------------------------------"
echo "Configuration:"
echo "Repo URL: $GIT_REPO_URL"
echo "Branch: $BRANCH_NAME"
echo "SSH User: $REMOTE_USER"
echo "Server IP: $REMOTE_IP"
echo "SSH Key: $SSH_KEY_PATH"
echo "App Port: $APP_PORT"
echo "PAT: [HIDDEN]"
echo "-----------------------------------"


# --- 2. Prepare Source Code ---
# POSIX-compliant parameter expansion
_temp_name=$(basename "$GIT_REPO_URL")
REPO_NAME=${_temp_name%.git}

echo "--- Preparing source code ---"

if [ -d "$REPO_NAME" ]; then
  echo "Repository '$REPO_NAME' already exists. Pulling latest changes..."
  cd "$REPO_NAME"
  git checkout "$BRANCH_NAME"
  git pull origin "$BRANCH_NAME"
else
  echo "Cloning repository '$REPO_NAME'"
  # POSIX-compliant parameter expansion
  CLONE_URL="https://oauth2:${GIT_PAT}@${GIT_REPO_URL#https://}"
  git clone --branch "$BRANCH_NAME" "$CLONE_URL"
  cd "$REPO_NAME"
fi

echo "Successfully checked out branch '$BRANCH_NAME'."

echo "--- Verifying project structure ---"
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
  echo "Found Dockerfile or docker-compose.yml. Project is deployable."
else
  echo "Error: Neither Dockerfile nor docker-compose.yml found in the repository root."
  exit 1
fi

echo "--- Source code preparation complete ---"


# --- 3. Prepare Remote Server ---
echo "--- Connecting to remote server $REMOTE_USER@$REMOTE_IP ---"

# 'EOF' is quoted to prevent local variable expansion
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REMOTE_USER"@"$REMOTE_IP" << 'EOF'

  set -e

  echo "--- (Remote) Updating system packages ---"
  sudo apt-get update -y

  echo "--- (Remote) Checking for required packages ---"
  PACKAGES_TO_INSTALL=""
  
  # POSIX-compliant redirect
  if ! command -v docker > /dev/null 2>&1; then
    echo "Docker not found, adding to install list."
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL docker.io"
  else
    echo "Docker is already installed."
  fi
  
  if ! command -v docker-compose > /dev/null 2>&1; then
    echo "Docker Compose not found, adding to install list."
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL docker-compose"
  else
    echo "Docker Compose is already installed."
  fi
  
  if ! command -v nginx > /dev/null 2>&1; then
    echo "Nginx not found, adding to install list."
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL nginx"
  else
    echo "Nginx is already installed."
  fi
  
  if ! command -v curl > /dev/null 2>&1; then
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
  # POSIX-compliant grep -w (whole word)
  if ! getent group docker | grep -q -w "$USER"; then
    echo "Adding user '$USER' to the 'docker' group."
    sudo usermod -aG docker "$USER"
    echo "WARNING: Group changes may require a new login session to take effect."
  else
    echo "User '$USER' is already in the 'docker' group."
  fi

  echo "(Remote) Server preparation complete."
EOF

echo "--- Server preparation finished ---"


# --- 4. Deploy Application to Remote Server ---
echo "--- Deploying application to remote server ---"

echo "Transferring source code to remote server..."
rsync -avz --delete -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
  ./"$REPO_NAME"/ "$REMOTE_USER@$REMOTE_IP:~/app/"

echo "Running remote deployment and validation..."
# EOF is NOT quoted, allowing $APP_PORT and $REMOTE_IP to expand
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REMOTE_USER"@"$REMOTE_IP" << EOF
  set -e
  
  # Pass local variables to the remote shell
  APP_PORT=$APP_PORT
  REMOTE_IP=$REMOTE_IP

  echo "--- (Remote) Starting application deployment ---"
  cd ~/app
  
  if [ -f "docker-compose.yml" ]; then
    echo "Using docker-compose for deployment..."
    echo "WARNING: Make sure your docker-compose.yml maps its service to port $APP_PORT"
    
    echo "Stopping existing docker-compose containers..."
    # Correctly silence both stdout and stderr
    docker-compose down > /dev/null 2>&1 || true
    
    echo "Building and starting new containers..."
    docker-compose up --build -d
    
    echo "Waiting for containers to start..."
    sleep 15
    
    if ! docker-compose ps | grep -q "Up"; then
      echo "Error: Containers failed to start properly"
      docker-compose logs
      exit 2
    fi
    echo "Application deployed successfully with docker-compose!"

    echo "--- (Remote) Validating compose app health (http://localhost:$APP_PORT) ---"
    if ! curl -f --connect-timeout 10 --max-time 30 http://localhost:$APP_PORT; then
        echo "ERROR: Health check failed for compose app at http://localhost:$APP_PORT"
        docker-compose logs
        exit 3
    fi
    echo "--- (Remote) Compose health check passed ---"
    
  elif [ -f "Dockerfile" ]; then
    echo "Using Dockerfile for deployment..."
    
    echo "Building the Docker image..."
    docker build -t app-deployment .
    
    echo "Stopping and removing existing container..."
    # Correctly silence both stdout and stderr
    docker stop app-container > /dev/null 2>&1 || true
    docker rm app-container > /dev/null 2>&1 || true
    
    echo "Running new container on $APP_PORT:$APP_PORT..."
    docker run -d --name app-container -p $APP_PORT:$APP_PORT app-deployment
    
    echo "Waiting for container to start..."
    sleep 15
    
    if ! docker ps | grep -q "app-container"; then
      echo "Error: Container failed to start properly"
      docker logs app-container
      exit 4
    fi
    echo "Application deployed successfully with Docker!"

    echo "--- (Remote) Validating Dockerfile app health (http://localhost:$APP_PORT) ---"
    if ! curl -f --connect-timeout 10 --max-time 30 http://localhost:$APP_PORT; then
        echo "ERROR: Health check failed for Dockerfile app at http://localhost:$APP_PORT"
        docker logs app-container
        exit 5
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
  if ! curl -f --connect-timeout 10 --max-time 30 http://127.0.0.1; then
    echo "ERROR: Nginx proxy validation failed. Could not reach app via proxy."
    echo "Dumping Nginx error log:"
    sudo tail -n 20 /var/log/nginx/error.log || true
    exit 6
  fi

  echo "Nginx configured and validated successfully!"
  echo "Application should be accessible at: http://$REMOTE_IP"
  
EOF

# --- 5. Final Remote Validation ---
echo "--- Remote deployment finished. ---"
echo "--- Performing final validation from local machine... ---"

if curl -f --connect-timeout 10 --max-time 30 "http://$REMOTE_IP"; then
  echo "SUCCESS: Remote validation passed. Application is LIVE at http://$REMOTE_IP"
else
  echo "ERROR: Remote validation FAILED. The site http://$REMOTE_IP is not accessible."
  exit 7
fi

# --- 6. Summary ---
echo "--- Deployment finished successfully ---"
echo ""
echo "========================================="
echo "DEPLOYMENT SUMMARY"
echo "========================================="
echo "Repository: $REPO_NAME"
echo "Branch: $BRANCH_NAME"
echo "Server: $REMOTE_USER@$REMOTE_IP"
echo "Application URL: http://$REMOTE_IP"
echo "========================================="
echo ""
echo "Deployment completed!"