#!/bin/bash

# Updating file path logic to work in mac, linux, and windows with git bash, doesn't break
APP_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "${APP_PATH}"

echo "This script will automate the process of switching remote for the Doubtfire deploy project and submodules"
echo "At the end of this process you will have a origin referring to your fork, and upstream referring to the"
echo "thoth-tech organisation root for the project." # Updating output to thoth-tech not doubtfire-lms to reflect repository
echo

read -p "What is your github username: " GH_USER

echo

function setup_remote {
  PROJECT=$1
  PROJECT_PATH=$2

  # Adding logic if file path does not exist
  cd "$PROJECT_PATH" || {
    echo "The directory $PROJECT_PATH does not exist. Skipping $PROJECT"
    echo
    return
  }

  cd "$PROJECT_PATH"

  # Adding failure message if origin is not updated
  ORIGIN_URL="https://github.com/${GH_USER}/${PROJECT}.git" || echo "Script has failed to set origin for $PROJECT"

<<<<<<< HEAD
  # Updating upstream to current repo location and failure message if upstream is not updated
  UPSTREAM_URL="https://github.com/doubtfire-lms/${PROJECT}.git" || echo "Script has ailed to set upstream for $PROJECT"
=======
  # Updating upstream to current thoth-tech repository location and failure message if upstream is not updated
  UPSTREAM_URL="https://github.com/thoth-tech/${PROJECT}.git" || echo "Script has failed to set upstream for $PROJECT"
>>>>>>> 358e788f445bd2fb5233c591544693950f99e0f6

  # Changing output to changing as it will output "echo " - origin is now $ORIGIN_URL"" whether it succeeds or fails 
  echo "Setting up $PROJECT"
  echo " - Changing origin to $ORIGIN_URL"
  echo " - Changing upstream to $UPSTREAM_URL"
  echo

  git remote set-url origin "$ORIGIN_URL"
  git remote set-url upstream "$UPSTREAM_URL" 2>>/dev/null
  if [ $? -ne 0 ]; then
    git remote add upstream "$UPSTREAM_URL"
  fi
}

setup_remote 'doubtfire-deploy' "${APP_PATH}"
setup_remote 'doubtfire-api' "${APP_PATH}/doubtfire-api"
setup_remote 'doubtfire-web' "${APP_PATH}/doubtfire-web"
setup_remote 'doubtfire-overseer' "${APP_PATH}/doubtfire-overseer"
