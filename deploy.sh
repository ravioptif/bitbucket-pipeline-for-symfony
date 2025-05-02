#!/bin/bash

# Exit immediately if any command fails
set -e

# -----------------------------------------------------------
# Install necessary tools for deployment
# -----------------------------------------------------------
apt-get update && apt-get install -y openssh-client rsync curl unzip git

# -----------------------------------------------------------
# Setup SSH for connecting to the remote server
# -----------------------------------------------------------
mkdir -p ~/.ssh
echo "$SERVER_SSH_KEY" > ~/.ssh/id_rsa           # Add the private SSH key from environment variable
chmod 600 ~/.ssh/id_rsa                          # Set strict permissions on the key
ssh-keyscan $SERVER_HOST >> ~/.ssh/known_hosts   # Add the remote server to known hosts to prevent interactive prompt

# -----------------------------------------------------------
# Define paths for temporary and final deployment directories
# -----------------------------------------------------------
TEMP_DIR="tmp_$(date +%s)"                       # Unique temp folder using timestamp
REMOTE_TMP="$SERVER_REMOTE_PATH/$TEMP_DIR"       # Temp path on remote server
FINAL_DIR="$SERVER_REMOTE_PATH/$DEPLOY_ENV"      # Final path on remote server (per environment)

# -----------------------------------------------------------
# Create temporary deployment directory on the remote server
# -----------------------------------------------------------
ssh $SERVER_USER@$SERVER_HOST "mkdir -p $REMOTE_TMP"

# -----------------------------------------------------------
# Upload local project files to the remote server's temp folder
# -----------------------------------------------------------
rsync -avz -e "ssh -i ~/.ssh/id_rsa" . "$SERVER_USER@$SERVER_HOST:$REMOTE_TMP"

# -----------------------------------------------------------
# Perform remote operations: dependency install, environment setup
# -----------------------------------------------------------
ssh $SERVER_USER@$SERVER_HOST 'bash -s' <<EOF
cd $REMOTE_TMP

# -----------------------------------------------------------
# Install dependencies using Composer (with production flags)
# -----------------------------------------------------------
/usr/bin/php8.4 /usr/local/bin/composer8.4 install -vvv --no-dev --optimize-autoloader

# -----------------------------------------------------------
# Create Symfony environment configuration file (.env.local.php)
# -----------------------------------------------------------
cat <<EOL > .env.local.php
<?php
return array(
    'APP_ENV' => '${APP_ENV}',
    'APP_SECRET' => '${APP_SECRET}',
    'DATABASE_URL' => '${DATABASE_URL}',
    'JWT_SECRET_KEY' => '%kernel.project_dir%/config/jwt/private.pem',
    'JWT_PUBLIC_KEY' => '%kernel.project_dir%/config/jwt/public.pem',
    'JWT_PASSPHRASE' => '${JWT_PASSPHRASE}',
    'API_BASE_URL' => '${API_BASE_URL}',
);
EOL

# -----------------------------------------------------------
# Generate JWT keys for authentication (decoded from base64)
# -----------------------------------------------------------
mkdir -p config/jwt
echo "${JWT_PRIVATE_PEM}" | base64 -d > config/jwt/private.pem
echo "${JWT_PUBLIC_PEM}" | base64 -d > config/jwt/public.pem
chmod 644 config/jwt/*.pem

# -----------------------------------------------------------
# Ensure writable permissions for cache and log directories
# -----------------------------------------------------------
mkdir -p var/cache var/log
chmod -R 777 var
chmod -R 755 vendor
EOF

# -----------------------------------------------------------
# Finalize deployment: replace old deployment folder with the new one
# -----------------------------------------------------------
ssh $SERVER_USER@$SERVER_HOST "cd $SERVER_REMOTE_PATH && rm -rf $DEPLOY_ENV && mv $REMOTE_TMP $FINAL_DIR"

# -----------------------------------------------------------
# Deployment completed message
# -----------------------------------------------------------
echo "✅ Deployment to $DEPLOY_ENV completed successfully."
