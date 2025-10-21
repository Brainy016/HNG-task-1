# Automated Docker Deployment Script

A production-ready, POSIX-compliant shell script that automates the deployment of a Git repository to a remote server. It deploys applications using Docker/Docker Compose and automatically configures an Nginx reverse proxy.

## Features

-   **POSIX-Compliant**: Built to run on any standard `/bin/sh` shell (e.g., `dash`, `ash`, `bash`).
-   **Interactive Setup**: Securely collects configuration, including a hidden prompt for your Git Personal Access Token.
-   **Git Integration**: Automatically clones a repository or pulls the latest changes from a specified branch.
-   **Versatile Deployment**: Natively supports projects using either a `Dockerfile` or a `docker-compose.yml` file.
-   **Automated Nginx Proxy**: Sets up Nginx as a reverse proxy, forwarding traffic from port 80 to your application's container port.
-   **Multi-Level Health Checks**: Validates the deployment at every stage:
    1.  Checks the application container directly.
    2.  Checks the Nginx proxy locally.
    3.  Checks the public-facing IP address.
-   **Idempotent**: The script is safe to re-run. It gracefully stops and removes old containers before deploying new ones.

## Prerequisites

### Local Machine Requirements
-   A POSIX-compliant shell (`/bin/sh`)
-   **Git**
-   **SSH Client** (with key-based authentication set up)
-   **rsync**
-   **curl**

### Remote Server Requirements
-   **Ubuntu/Debian-based Linux** (tested on Ubuntu 20.04+)
-   **SSH server** configured for key-based authentication.
-   A user account with **`sudo` privileges**.
-   Internet connection to download packages.

### Application Requirements
Your Git repository **must** contain one of the following in its root directory:
-   `Dockerfile` - For single-container applications.
-   `docker-compose.yml` - For multi-container applications.

## Installation & Setup

1.  **Clone the Repository (or save the script):**
    If this script is in a repo:
    ```sh
    git clone [https://github.com/your-username/your-repo.git](https://github.com/your-username/your-repo.git)
    cd your-repo
    ```
    Or, save the script as `deploy.sh`.

2.  **Make the Script Executable:**
    ```sh
    chmod +x deploy.sh
    ```

3.  **Ensure Your SSH Key is Set Up:**
    If you haven't already, you need to be able to SSH into your server without a password.
    ```sh
    # If you don't have a key
    ssh-keygen -t rsa -b 4096

    # Copy your public key to the server
    ssh-copy-id your-user@your-server-ip
    ```

4.  **Create a GitHub Personal Access Token (PAT):**
    1.  Go to GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic).
    2.  Generate a new token with the **`repo`** scope (for private repos).
    3.  Copy the token. You will need it when you run the script.

## Usage

To run the script, simply execute it from your terminal.

### Standard Execution
```sh
./deploy.sh