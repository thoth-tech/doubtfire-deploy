#!/usr/bin/env zsh

echo "Starting Formatif development container..."

# Start mysql
# sudo -E /workspace/.devcontainer/launch_db.sh mysqld

# Start the redis server
mkdir -p /workspace/tmp/sidekiq-redis
sudo rm -rf /workspace/tmp/redis.log
sudo redis-server --dir /workspace/tmp/sidekiq-redis >>/workspace/tmp/redis.log 2>>/workspace/tmp/redis.log &

# Wait for mysql to start then setup the database if needed
/workspace/.devcontainer/setup_formatif_db.sh

exec "$@"
