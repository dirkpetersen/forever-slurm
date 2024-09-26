#!/bin/bash

# Install traefik Proxy and configure forever-slurm

# Ensure the current directory is a git repository root
if [[ ! -d "$(pwd)/.git" ]]; then
  echo "Error: The current directory is not the root of a Git repository."
  exit 1
fi

MYUID=$(id -u)
if [[ ${MYUID} -eq 0 ]]; then
  echo "Error: This script should not be run as root. Please run this to create and switch to a new user:"
  echo 'NEWUSER=<username> && useradd $NEWUSER && loginctl enable-linger $NEWUSER && su - $NEWUSER'
  exit 1
fi
if [[ ! -d /run/user/${MYUID} ]]; then
  echo "Error: Folder /run/user/${MYUID} does not exist."
  echo "Please run: sudo loginctl enable-linger ${USER}"
  exit 1
fi

export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/${MYUID}/bus}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/${MYUID}}
export FOREVER_ROOT=${FOREVER_ROOT:-$(pwd)}  # Normally the root of the forever-slurm git repo
SYSTEMD_SERVICE_CONTENT=""

# Determine if --ssh flag was passed
SSH_CONFIG=false
for arg in "$@"; do
  if [[ "$arg" == "--ssh" ]]; then
    SSH_CONFIG=true
    break
  fi
done

create_folders_files() {
  # create required folder and files 
  mkdir -p "${FOREVER_ROOT}/.work/traefik-watch"
  mkdir -p "${FOREVER_ROOT}/.work/log"
  mkdir -p "${FOREVER_ROOT}/.work/slurm-output"
}

# Function to download and extract the latest version of Traefik
traefik_install() {
  
  # Set the work directory
  WORK_DIR="${FOREVER_ROOT}/.work"
  # Set the GitHub repo URL
  REPO_URL="https://api.github.com/repos/traefik/traefik/releases/latest"

  # Fetch the latest release version (e.g., v3.1.4)
  LATEST_VERSION=$(curl -s $REPO_URL | grep "tag_name" | cut -d '"' -f 4)

  # Check if the current version matches the latest version
  if [[ -f "${WORK_DIR}/LATEST_VERSION" && "$(cat ${WORK_DIR}/LATEST_VERSION)" == "${LATEST_VERSION}" ]]; then
    echo "Traefik $LATEST_VERSION is already installed. Skipping download."
    return
  fi

  # Determine the architecture: amd64 or arm64
  ARCH=$(uname -m)
  if [[ "$ARCH" == "aarch64" ]]; then
    ARCH="arm64"
  elif [[ "$ARCH" == "x86_64" ]]; then
    ARCH="amd64"
  else
    echo "Unsupported architecture: $ARCH"
    exit 1
  fi

  # Construct the download URL using the version number and architecture
  TAR_URL="https://github.com/traefik/traefik/releases/download/$LATEST_VERSION/traefik_${LATEST_VERSION}_linux_${ARCH}.tar.gz"

  # Download the tarball into the work directory
  echo "Downloading Traefik $LATEST_VERSION for $ARCH..."
  curl -L -o "${WORK_DIR}/traefik_${LATEST_VERSION}_linux_${ARCH}.tar.gz" $TAR_URL

  # Extract the tarball without changing directories
  echo "Extracting the tarball..."
  tar -xzf "${WORK_DIR}/traefik_${LATEST_VERSION}_linux_${ARCH}.tar.gz" -C "${WORK_DIR}"

  # Delete the tarball after extraction
  rm "${WORK_DIR}/traefik_${LATEST_VERSION}_linux_${ARCH}.tar.gz"
  #remove extra markdown files
  rm -f ${WORK_DIR}/LICENSE.md
  rm -f ${WORK_DIR}/CHANGELOG.md

  echo "${LATEST_VERSION}" > "${WORK_DIR}/LATEST_VERSION"

  echo "Traefik $LATEST_VERSION has been downloaded and extracted for $ARCH architecture."  

}

config_env() {

  # Determine the source file
  if [[ -f "${FOREVER_ROOT}/.env" ]]; then
    SOURCE_FILE="${FOREVER_ROOT}/.env"
  else
    SOURCE_FILE="${FOREVER_ROOT}/.env.default"
  fi
  echo -e "\n*** Reading config from ${SOURCE_FILE} ... \n"

  ENV_TMP_FILE="${FOREVER_ROOT}/.env.tmp"

  # Empty the temporary file
  > "${ENV_TMP_FILE}"

  COMMENTS=""

  # Open the source file descriptor
  exec 3< "${SOURCE_FILE}"

  while IFS= read -r line <&3 || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^#.* ]]; then
      # Line is a comment; accumulate it
      COMMENTS="${line}"
      # Write the comment to the temp file (ensures comments are preserved)
      echo "${COMMENTS}" >> "${ENV_TMP_FILE}"
    elif [[ -z "${line}" ]]; then
      # Empty line; just reset comments and preserve the empty line
      COMMENTS=""
      echo "" >> "${ENV_TMP_FILE}"
    elif [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.* ]]; then
      # Line is a key-value pair
      KEY="${line%%=*}"
      VALUE="${line#*=}"
      
      # Evaluate the value to expand variables
      VALUE=$(eval echo "${VALUE}")

      # Check if the value contains spaces and is not already quoted
      if [[ "$VALUE" =~ \  ]] && [[ "$VALUE" != \"*\" ]]; then
        VALUE="\"${VALUE}\""
      fi

      # Skip FS_SSH* keys if --ssh is not used, but write the comment
      if [[ "$KEY" == FS_SSH* && "$SSH_CONFIG" == false ]]; then
        # Write the original line to the file without prompting
        echo "${KEY}=${VALUE}" >> "${ENV_TMP_FILE}"
        continue
      fi

      # Prompt the user with the default value
      read -e -i "${VALUE}" -p "Enter value for ${KEY}: " NEW_VALUE </dev/tty

      # Add an empty line in the terminal after the prompt
      echo ""

      # Check if the new value contains spaces and is not already quoted
      if [[ "$NEW_VALUE" =~ \  ]] && [[ "$NEW_VALUE" != \"*\" ]]; then
        NEW_VALUE="\"${NEW_VALUE}\""
      fi

      # Write the key-value pair to the temp file
      echo "${KEY}=${NEW_VALUE}" >> "${ENV_TMP_FILE}"

      # Reset comments
      COMMENTS=""
    else
      # Other lines; write them as-is
      echo "${line}" >> "${ENV_TMP_FILE}"
    fi
  done

  # Close the file descriptor
  exec 3<&-

  # Replace the original .env file with the new values
  mv "${ENV_TMP_FILE}" "${FOREVER_ROOT}/.env"

  # Export all vars as environment vars
  set -a  # Automatically export all variables
  source "${FOREVER_ROOT}/.env"
  set +a  # Disable automatic export
}

# Function to activate services
activate_services() {
  # Get the list of available services
  SERVICES_DIR="${FOREVER_ROOT}/services"
  AVAILABLE_SERVICES=($(ls -d "${SERVICES_DIR}"/*/ | xargs -n 1 basename))

  SERVICE_LIST=""
  CURRENT_SERVICE_LIST=""

  # Load the current SERVICE_LIST if it exists, preserving quotes
  if [[ -f "${FOREVER_ROOT}/.env" ]]; then
    CURRENT_SERVICE_LIST=$(grep -E "^SERVICE_LIST=" "${FOREVER_ROOT}/.env" | cut -d'=' -f2-)
  fi

  # Convert current lists into arrays for easier manipulation
  IFS=' ' read -r -a CURRENT_SERVICES_ARRAY <<< "${CURRENT_SERVICE_LIST//\"/}"

  echo -e "\nWhich services do you want to add?\n"
  while true; do
    select SERVICE in "${AVAILABLE_SERVICES[@]}" "Done"; do
      if [[ "$SERVICE" == "Done" ]]; then
        break 2
      elif [[ -n "$SERVICE" ]]; then
        # Check if the service is already in the list
        if [[ " ${CURRENT_SERVICES_ARRAY[@]} " =~ " ${SERVICE} " ]]; then
          echo "${SERVICE} is already in the list, skipping."
        else
          # Copy the service files to .work directory
          WORK_DIR="${FOREVER_ROOT}/.work"
          mkdir -p "${WORK_DIR}"
          cp -nv "${SERVICES_DIR}/${SERVICE}/"* "${WORK_DIR}/"

          # Move all .yml files that start with the service name to traefik-watch directory
          mkdir -p "${WORK_DIR}/traefik-watch"
          for yaml_file in "${WORK_DIR}/${SERVICE}"*.yml; do
            if [[ -f "$yaml_file" && ! -f "${WORK_DIR}/traefik-watch/$(basename "$yaml_file")" ]]; then
              mv "$yaml_file" "${WORK_DIR}/traefik-watch/"
              echo "$(basename "$yaml_file") moved to ${WORK_DIR}/traefik-watch/"
            else
              echo "$(basename "$yaml_file") already exists in ${WORK_DIR}/traefik-watch/, skipping."
            fi
          done

          # Ask the user for the number of instances and ensure the input is numeric
          while true; do
            echo ""
            read -p "How many instances of ${SERVICE} should run as slurm jobs? " INSTANCES
            if [[ "$INSTANCES" =~ ^[0-9]+$ ]]; then
              break
            else
              echo "Please enter a valid numeric value."
            fi
          done

          # Append the service and instance count to the array
          CURRENT_SERVICES_ARRAY+=("${SERVICE}/${INSTANCES}")

          echo "${SERVICE} service activated with ${INSTANCES} instances."
        fi
      else
        echo "Invalid selection. Try again."
      fi
      break
    done
  done

  # Ensure no duplicates and maintain proper spacing
  SERVICE_LIST=$(IFS=" "; echo "${CURRENT_SERVICES_ARRAY[*]}")

  # Remove any existing SERVICE_LIST key from .env
  sed -i '/^SERVICE_LIST=/d' "${FOREVER_ROOT}/.env"

  # Write the results to the .env file with proper quotes
  echo "SERVICE_LIST=\"${SERVICE_LIST}\"" >> "${FOREVER_ROOT}/.env"

}

# Expected content of the systemd service file
# you can also use StandardOutput=file:${LOGFILE_PATH} 
SYSTEMD_TEMPLATE="[Unit]
Description=%%SERVICE_DESCR%%
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
WorkingDirectory=%%SERVICE_WORKDIR%%
ExecStart=%%SERVICE_CMDLINE%%
StandardOutput=append:%%LOGFILE_PATH%%
StandardError=append:%%LOGFILE_PATH%%
Restart=on-abnormal
KillMode=mixed

[Install]
WantedBy=default.target
"
# another option
#ExecStart=/bin/bash -c 'source ~/.bashrc && %%SERVICE_CMDLINE%%'

get_systemd_content() {
  local template="${SYSTEMD_TEMPLATE}"
  local service_cmdline="${1}"
  local service_workdir="${2}"
  local service_descr="${3}"
  local service_name="${4}"

  # Replace each placeholder using bash parameter expansion
  template="${template//%%SERVICE_CMDLINE%%/${service_cmdline}}"
  template="${template//%%SERVICE_WORKDIR%%/${service_workdir}}"
  template="${template//%%SERVICE_DESCR%%/${service_descr}}"
  template="${template//%%LOGFILE_PATH%%/${FOREVER_ROOT}/.work/log/${service_name}.service.log}"

  # Output the final systemd service content
  #echo "${template}"
  # Assign the output to SYSTEMD_SERVICE_CONTENT
  SYSTEMD_SERVICE_CONTENT="${template}"  
}

setup_systemd_service() {
  local service_cmdline="${1}"
  local service_workdir="${2}"
  local service_descr="${3}"
  local service_name="${4// /-}"  # Replace spaces in service name with hyphens
  local service_file="${HOME}/.config/systemd/user/${service_name}.service"

  get_systemd_content "${service_cmdline}" "${service_workdir}" "${service_descr}" "${service_name}"
  
  # Ensure the user's systemd directory exists
  mkdir -p "${HOME}/.config/systemd/user"

  # Write the service content to the .service file
  echo "${SYSTEMD_SERVICE_CONTENT}" > "${service_file}"

  # Enable and start the service for the user
  systemctl --user daemon-reload
  systemctl --user enable "${service_name}.service"
  systemctl --user restart "${service_name}.service"
  systemctl --user status "${service_name}.service" --no-pager
  
  # Check if the @reboot crontab entry already exists
  local crontab_entry="@reboot /usr/bin/systemctl --user restart ${service_name}.service"  
  if ! crontab -l 2>/dev/null | grep -Fq "${crontab_entry}"; then
    # Add the crontab entry only if it doesn't already exist
    echo "Adding @reboot crontab entry ... "
    (crontab -l 2>/dev/null; echo "${crontab_entry}") | crontab -
  fi

}

get_ssh_command() {
  local OPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  local SSH_LOCAL_PORT=${FS_TRAEFIK_PORT}
  local SSH_REMOTE_PORT=${FS_TRAEFIK_PORT}
  if [[ -n ${SSH_REMOTE_SERVER} ]]; then # if we want to not port forward to the login node but to another server
    local ssh_command="ssh ${OPT} -N -L 127.0.0.1:${SSH_LOCAL_PORT}:${SSH_REMOTE_SERVER}:${SSH_REMOTE_PORT} -i ${FS_SSH_KEY_PATH} -4 ${FS_SSH_USER}@${FS_SSH_LOGIN_NODE}"
  else
    local ssh_command="ssh ${OPT} -N -L ${SSH_LOCAL_PORT}:127.0.0.1:${SSH_REMOTE_PORT} -i ${FS_SSH_KEY_PATH} -4 ${FS_SSH_USER}@${FS_SSH_LOGIN_NODE}"
  fi  
  echo "${ssh_command}"
}

check_ssh_keys() {
  if [[ ! -f "${FS_SSH_KEY_PATH}" ]]; then
    echo "Error: SSH key file ${FS_SSH_KEY_PATH} not found, generating key pair "
    ssh-keygen -t ed25519 -f ${FS_SSH_KEY_PATH} -N ""
    chmod 600 ${FS_SSH_KEY_PATH}.pub
    echo -e "Add this public key to the ~/.ssh/authorized_keys file on the SSH gateway / login node ${FS_SSH_LOGIN_NODE}. Run command:"
    echo "echo \"$(cat ${FS_SSH_KEY_PATH}.pub)\"  >> ~/.ssh/authorized_keys"
    echo -e "\nOnce this is done, hit any key to continue..."
    read -n 1 -s
  fi
}

# Call the functions
if [[ "$SSH_CONFIG" == false ]]; then 
  create_folders_files
  traefik_install
fi

config_env

if [[ "$SSH_CONFIG" == true ]]; then
  check_ssh_keys
  # This will create a service named 'forever-ssh-forward"
  setup_systemd_service "$(get_ssh_command)" \
          "${FOREVER_ROOT}/.work/log" "SSH Forward Service" "forever-ssh-forward"  
  exit 0
fi

activate_services
envsubst < traefik-static.toml  > "${FOREVER_ROOT}/.work/traefik-static.toml"

# This will create a service named "forever-traefik"
setup_systemd_service "${FOREVER_ROOT}/.work/traefik --configfile ${FOREVER_ROOT}/.work/traefik-static.toml" \
          "${FOREVER_ROOT}/.work/log" "Traefik Proxy Service for Forever-SLURM" "forever-traefik"

# This will create a service named "forever-traefik"
setup_systemd_service "/bin/bash ${FOREVER_ROOT}/forever-slurm.sh" \
          "${FOREVER_ROOT}/.work/slurm-output" "Forever-SLURM Metadata Service" "forever-slurm"

echo -e "\n*** Installation complete. ***\n"