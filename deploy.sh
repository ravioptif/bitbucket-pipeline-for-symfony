#!/bin/bash

set -eo pipefail

echo "🔧 Installing necessary tools..."
apt-get update && apt-get install -y openssh-client rsync curl unzip git

echo "🔐 Setting up SSH..."
mkdir -p ~/.ssh
(umask  077 ; echo $SERVER_SSH_KEY | base64 --decode > ~/.ssh/id_rsa)

ssh-keyscan -H "$SERVER_HOST" >> ~/.ssh/known_hosts

# Variables
TEMP_DIR="${DEPLOY_DIR_NAME}_tmp_$(date +"%Y%m%d%I%M")"
REMOTE_TMP_DEPLOY_DIR="$SERVER_REMOTE_PATH/dmp_deploy_history/$TEMP_DIR"
DEPLOY_DIR="$SERVER_REMOTE_PATH/$DEPLOY_DIR_NAME"

echo "📁 Remote deploy_history dir: $REMOTE_TMP_DEPLOY_DIR"
echo "📁 Final deployment dir: $DEPLOY_DIR"

#trap 'echo "⚠️ Cleanup: removing remote temp dir on failure..."; ssh $SERVER_USER@$SERVER_HOST "rm -rf $REMOTE_TMP_DEPLOY_DIR"' ERR

echo "📂 Creating remote temporary directory..."
ssh $SERVER_USER@$SERVER_HOST "mkdir -p \"$REMOTE_TMP_DEPLOY_DIR\""

echo "📤 Uploading project files..."
rsync -az -e "ssh -i ~/.ssh/id_rsa" . "$SERVER_USER@$SERVER_HOST:$REMOTE_TMP_DEPLOY_DIR"

echo "🔧 Running remote setup and tests..."
ssh $SERVER_USER@$SERVER_HOST bash <<EOF
  set -e

  export PATH="/usr/bin:\$PATH"
  cd "$REMOTE_TMP_DEPLOY_DIR"

  echo "📦 Installing Composer dependencies..."
  php8.4 /usr/local/bin/composer8.4 install -vvv --optimize-autoloader

  echo "⚙️ Creating environment configuration..."
  cat > .env.local.php <<EOL
<?php
return [
    'APP_ENV' => '${APP_ENV}',
    'APP_SECRET' => '${APP_SECRET}',
    'DATABASE_URL' => '${DATABASE_URL}',
    'JWT_SECRET_KEY' => '%kernel.project_dir%/config/jwt/private.pem',
    'JWT_PUBLIC_KEY' => '%kernel.project_dir%/config/jwt/public.pem',
    'JWT_PASSPHRASE' => '${JWT_PASSPHRASE}',
    'API_BASE_URL' => '${API_BASE_URL}',
];
EOL

  echo "🔑 Setting up JWT keys..."
  mkdir -p config/jwt
  echo "${JWT_PRIVATE_PEM}" | base64 -d > config/jwt/private.pem
  echo "${JWT_PUBLIC_PEM}" | base64 -d > config/jwt/public.pem
  chmod 644 config/jwt/*.pem

  echo "🔍 Running PHP syntax check (lint)..."

    find . -type f -name "*.php" ! -path "./vendor/*" -exec php8.4 -l {} \; > "${REMOTE_TMP_DEPLOY_DIR}/php_lint.log" 2>&1;

    if grep -q "Parse error" "${REMOTE_TMP_DEPLOY_DIR}/php_lint.log"; then
      echo "❌ PHP syntax errors found. See log: ${REMOTE_TMP_DEPLOY_DIR}/php_lint.log"
      exit 1
    fi
    echo "✅ No PHP syntax errors found."

  if [ "$RUN_UNIT_TESTS" = "true" ]; then
      echo "🧪 Running Unit tests"
      if ! php8.4 bin/phpunit --testdox tests/UnitTest > "${REMOTE_TMP_DEPLOY_DIR}/phpunit.log" 2>&1; then
         echo "❌ PHPUnit tests failed in tests/UnitTest. See log: ${REMOTE_TMP_DEPLOY_DIR}/phpunit.log"
        exit 1
      fi
      echo "✅ All Unit Tests have passed successfully"
  else
    echo "🚫 Skipping Unit tests, as it disabled for this deployment."
  fi

EOF

echo "🔁 Deploying to environment: $BITBUCKET_DEPLOYMENT_ENVIRONMENT"

ssh $SERVER_USER@$SERVER_HOST <<EOF
  set -e
  cd "$SERVER_REMOTE_PATH"

  rsync -a --delete --exclude='var' "$REMOTE_TMP_DEPLOY_DIR"/ "$DEPLOY_DIR"/

  if [ ! -d "$DEPLOY_DIR/var" ]; then
    echo "📂 Setup for var/cache and var/log folders in $DEPLOY_DIR_NAME"
    cd "$DEPLOY_DIR" && php8.4 bin/console about
  fi

EOF

echo "✅ Deployment to '$BITBUCKET_DEPLOYMENT_ENVIRONMENT' completed successfully."
