#!/bin/bash
set -e
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
  echo "Error: Neither Dockerfile nor docker-compose.yml found in the repository root."
  exit 1
fi

echo "--- Source code preparation complete ---"

echo "--- Connecting to remote server $REMOTE_USER@$REMOTE_IP ---"

# Running a multi-line script on the remote server using a "here document" (<< 'EOF')
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REMOTE_USER"@"$REMOTE_IP" << 'EOF'

  set -e

  echo "--- (Remote) Updating system packages ---"
  sudo apt-get update -y

  echo "--- (Remote) Checking for required packages ---"
  
  # Build a list of packages that are missing
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

  # If the install list is not empty, install the missing packages
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

  echo "--- (Remote) Configuring Docker group ---"
  # Add the current user to the docker group, if not already a member
  if ! getent group docker | grep -q "\b$USER\b"; then
    echo "Adding user '$USER' to the 'docker' group."
    sudo usermod -aG docker "$USER"
    echo "WARNING: Group changes may require a new login session to take effect."
  else
    echo "User '$USER' is already in the 'docker' group."
  fi

  echo "(Remote) Server preparation complete."

EOF

echo "--- Server preparation finished ---"

echo "--- Deploying application to remote server ---"

# Transfer the source code to the remote server
echo "Transferring source code to remote server..."
# Note: Fixed rsync path to correctly copy the *contents* of the repo
rsync -avz --delete -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
  ./"$REPO_NAME"/ "$REMOTE_USER@$REMOTE_IP:~/app/"

# Deploy the application on the remote server
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REMOTE_USER@$REMOTE_IP" << EOF
  set -e
  
  # Pass the APP_PORT variable into the remote script
  APP_PORT=$APP_PORT

  echo "--- (Remote) Starting application deployment ---"
  cd ~/app
  
  # Build and start the application
  if [ -f "docker-compose.yml" ]; then
    echo "Using docker-compose for deployment..."
    echo "WARNING: Make sure your docker-compose.yml maps your service to port 80."
    
    # Stop existing docker-compose containers safely
    echo "Stopping existing docker-compose containers..."
    docker-compose down 2>/dev/null || true
    
    docker-compose up --build -d
    
    # Wait for containers to start
    sleep 10
    
    # Check if containers are running
    if docker-compose ps | grep -q "Up"; then
      echo "Application deployed successfully with docker-compose!"
    else
      echo "Error: Containers failed to start properly"
      docker-compose logs
      exit 1
    fi
    
  elif [ -f "Dockerfile" ]; then
    echo "Using Dockerfile for deployment..."
    
    # Build the Docker image
    docker build -t app-deployment .
    
    # Stop and remove existing container
    docker stop app-container 2>/dev/null || true
    docker rm app-container 2>/dev/null || true
    
    # Run the new container
    # Fixed: Map host APP_PORT to container's APP_PORT (avoiding Nginx conflict on port 80)
    docker run -d --name app-container -p $APP_PORT:$APP_PORT app-deployment
    
    # Wait for container to start
    sleep 10
    
    # Check if container is running
    if docker ps | grep -q "app-container"; then
      echo "Application deployed successfully with Docker!"
    else
      echo "Error: Container failed to start properly"
      docker logs app-container
      exit 1
    fi
  fi
  
  echo "--- (Remote) Application deployment complete ---"
  
  echo "--- (Remote) Configuring Nginx proxy ---"
  # Create Nginx configuration to proxy traffic from port 80 to the application
  sudo tee /etc/nginx/sites-available/app > /dev/null << NGINX_EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Handle WebSocket connections if needed
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX_EOF

  # Enable the site and restart Nginx
  sudo ln -sf /etc/nginx/sites-available/app /etc/nginx/sites-enabled/
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo nginx -t && sudo systemctl reload nginx
  
  echo "Nginx configured to proxy port 80 -> localhost:$APP_PORT"
  echo "Application should be accessible at: http://$REMOTE_IP"
  
EOF

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