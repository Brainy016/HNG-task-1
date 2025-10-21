# Automated Docker Deployment Script

A production-ready, automated deployment script that clones/pulls a Git repository, deploys it to a remote server using Docker or Docker Compose, and sets up an Nginx reverse proxy with comprehensive logging and error handling.

## 🚀 Features

- **Interactive Setup**: Secure input collection with hidden PAT entry
- **Git Integration**: Automated cloning/pulling with OAuth2 authentication
- **Docker Support**: Works with both `Dockerfile` and `docker-compose.yml`
- **Nginx Reverse Proxy**: Automatic configuration with WebSocket support
- **Comprehensive Logging**: Timestamped logs with error tracking
- **Health Checks**: Multi-level validation (app → proxy → public access)
- **Idempotent Operations**: Safe to run multiple times
- **POSIX Compliant**: Works on any Unix-like system

## 📋 Prerequisites

### Local Machine Requirements
- **Bash shell** (version 4.0+)
- **Git** installed and configured
- **SSH client** with key-based authentication
- **rsync** for file transfer
- **curl** for health checks

### Remote Server Requirements
- **Ubuntu/Debian-based Linux** (tested on Ubuntu 20.04+)
- **SSH access** with sudo privileges
- **Internet connection** for package installation

### Application Requirements
Your repository must contain **one** of the following in the root directory:
- `Dockerfile` - for single container deployments
- `docker-compose.yml` - for multi-container deployments

## ⚙️ Installation & Setup

### 1. Clone this repository
```bash
git clone https://github.com/Brainy016/HNG-task-1.git
cd HNG-task-1
```

### 2. Make the script executable
```bash
chmod +x deploy.sh
```

### 3. Prepare your SSH key
```bash
# Generate SSH key if you don't have one
ssh-keygen -t rsa -b 4096 -f ~/.ssh/deploy_key

# Copy public key to your remote server
ssh-copy-id -i ~/.ssh/deploy_key.pub user@your-server-ip
```

### 4. Create a GitHub Personal Access Token
1. Go to GitHub → Settings → Developer settings → Personal access tokens
2. Generate new token with **repo** permissions
3. Copy the token (you'll need it during script execution)

## 🎯 Usage

### Basic Usage
```bash
./deploy.sh
```

The script will interactively prompt you for:
- **Git repository URL** (e.g., `https://github.com/user/repo.git`)
- **Personal Access Token** (hidden input)
- **Branch name** (default: `main`)
- **SSH username** (e.g., `ubuntu`)
- **Server IP address** (e.g., `203.0.113.1`)
- **SSH private key path** (e.g., `~/.ssh/id_rsa`)
- **Application port** (e.g., `3000`)

### Example Session
```
Enter the Git repository URL: https://github.com/myuser/myapp.git
Enter your Git Personal Access Token (input will be hidden): ****
Enter the branch name (default: main): main
Enter the remote server's SSH username: ubuntu
Enter the remote server's IP address: 203.0.113.1
Enter the path to your SSH private key: ~/.ssh/deploy_key
Enter the application's internal container port: 3000
```

## 🏗️ How It Works

### 1. **Source Code Preparation**
- Clones repository (first run) or pulls latest changes (subsequent runs)
- Validates presence of `Dockerfile` or `docker-compose.yml`
- Sets up comprehensive logging with timestamps

### 2. **Remote Server Setup**
- Connects via SSH and updates system packages
- Installs required packages: `docker.io`, `docker-compose`, `nginx`, `curl`
- Configures Docker service and user permissions
- Validates all services are running

### 3. **Application Deployment**
- Transfers source code using `rsync` with optimizations
- Builds and deploys using Docker or Docker Compose
- Performs application health checks
- Handles container lifecycle management safely

### 4. **Nginx Configuration**
- Creates reverse proxy configuration
- Maps public port 80 to application port
- Enables WebSocket support and proper headers
- Validates proxy functionality

### 5. **Validation & Health Checks**
- **Local app check**: `curl http://localhost:APP_PORT`
- **Proxy check**: `curl http://127.0.0.1:80`
- **Public check**: `curl http://SERVER_IP:80`
- **Comprehensive logging** of all operations

## 📁 File Structure

```
your-app/
├── Dockerfile              # OR docker-compose.yml
├── (your application files)
└── ...

deployment-logs/
├── deploy_20231020_143022.log
├── deploy_20231020_151205.log
└── ...
```

## 🛡️ Security Features

- **Hidden PAT input** - Personal Access Token is not echoed to terminal
- **SSH key authentication** - No password-based authentication
- **Secure Git cloning** - Uses OAuth2 token for private repositories
- **SSH security options** - Disables host key checking for automation
- **Log sanitization** - PAT is marked as `[HIDDEN]` in logs

## 🔧 Docker Configuration Examples

### For Dockerfile Projects
Your `Dockerfile` should expose the port you specify during setup:
```dockerfile
FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
EXPOSE 3000
CMD ["npm", "start"]
```

### For Docker Compose Projects
Your `docker-compose.yml` should map to your specified port:
```yaml
version: '3.8'
services:
  app:
    build: .
    ports:
      - "3000:3000"  # Map to APP_PORT you specify
    environment:
      - NODE_ENV=production
```

## 📊 Error Handling & Exit Codes

| Exit Code | Description |
|-----------|-------------|
| 0 | Success |
| 1 | General script error |
| 2 | Docker Compose startup failure |
| 3 | Docker Compose health check failure |
| 4 | Docker container startup failure |
| 5 | Docker container health check failure |
| 6 | Nginx configuration/proxy failure |
| 7 | Final public validation failure |

## 📋 Troubleshooting

### Common Issues

**1. Permission denied (SSH)**
```bash
# Fix SSH key permissions
chmod 600 ~/.ssh/your_private_key
```

**2. Docker permission denied**
```bash
# On remote server, add user to docker group
sudo usermod -aG docker $USER
# Then logout and login again
```

**3. Port already in use**
```bash
# Check what's using the port
sudo netstat -tulpn | grep :80
# Stop conflicting service
sudo systemctl stop apache2  # if Apache is running
```

**4. Git authentication failed**
- Verify your Personal Access Token has `repo` permissions
- Check if the repository URL is correct
- Ensure the token hasn't expired

### Log Analysis
Check deployment logs for detailed error information:
```bash
# View latest log
tail -f deploy_*.log

# Search for errors
grep -i error deploy_*.log
```

## 🔄 Redeployment

The script is **idempotent** - you can run it multiple times safely:
- Subsequent runs will pull latest changes instead of cloning
- Existing containers are safely stopped before starting new ones
- Nginx configuration is updated automatically

## 🌐 Accessing Your Application

After successful deployment, your application will be available at:
- **Public URL**: `http://YOUR_SERVER_IP`
- **Direct app access**: `http://YOUR_SERVER_IP:APP_PORT` (bypassing Nginx)

The Nginx reverse proxy handles:
- SSL termination (when configured)
- Load balancing (for future scaling)
- WebSocket connections
- Proper client IP forwarding

## 📝 License

This project is open source and available under the [MIT License](LICENSE).

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📞 Support

If you encounter any issues or have questions:
1. Check the troubleshooting section above
2. Review the deployment logs
3. Open an issue in this repository

---

**Made with ❤️ for automated DevOps deployments**