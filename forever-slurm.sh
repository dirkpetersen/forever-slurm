#!/bin/bash

# Directory of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}
export FOREVER_ROOT=${FOREVER_ROOT:-${SCRIPT_DIR}}

# Source .env file from the same directory
if [[ -f "${FOREVER_ROOT}/.env" ]]; then
  source "${FOREVER_ROOT}/.env"
  # Export all vars as environment vars
  set -a  # Automatically export all variables
  source "${FOREVER_ROOT}/.env"
  set +a  # Disable automatic export  
else
  echo ".env file not found in ${FOREVER_ROOT}. Please run ./config.sh first. Exiting..."
  exit 1
fi

source ~/.bashrc

# One-liner to set FS_SLEEP_INTERVAL to 300 if not set or empty
FS_SLEEP_INTERVAL=${FS_SLEEP_INTERVAL:-300}
#FS_SLEEP_INTERVAL=${FS_SLEEP_INTERVAL:-60}


# Log to journal (can be viewed with journalctl)
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to clean up before exiting
cleanup() {
  log "Caught termination signal. Cleaning up..."
  exit 0  
}

# Trap SIGINT (Ctrl+C) and SIGTERM (kill or systemd stop)
# trap cleanup SIGINT SIGTERM # not really working 

# Function to call squeue once and reuse its output
get_squeue_data() {
  squeue --me -h -o "%i %t %j %C %m %o %S %T" # Adapt the format as necessary
}

# Function to submit missing jobs
submit_missing_jobs() {
  # This function is used to submit missing jobs to SLURM until the desired number
  # of instances are running. It finds the SLURM submission scripts in 
  # ${FOREVER_ROOT}/.work/ and gets the maximum number of instances to run from
  # an entry in the SERVICE_LIST variable.
  for service_entry in ${SERVICE_LIST}; do
    local service_name=$(echo "${service_entry}" | cut -d'/' -f1)
    local num_jobs=$(echo "${service_entry}" | cut -d'/' -f2)

    # Find all .sub files that start with the service name
    for submission_script in "${FOREVER_ROOT}/.work/${service_name}"*.sub; do
      if [[ -f "$submission_script" ]]; then
        local job_name
        job_name=$(grep -Eo '^#SBATCH --job-name[= ]+("[^"]+"|\S+)' "$submission_script" | awk -F'[= ]+' '{print $NF}' | tr -d '"')

        if [[ -z "$job_name" ]]; then
          log "--job-name not found in the submission script: ${submission_script}"
          continue
        fi
        log "checking job name ${job_name} from script ${submission_script}"

        local running_jobs
        local pending_jobs
        running_jobs=$(echo "${SQUEUE_DATA}" | grep " ${job_name}" | grep -c "RUNNING")
        pending_jobs=$(echo "${SQUEUE_DATA}" | grep " ${job_name}" | grep -c "PENDING")

        # echo "running_jobs"
        # echo "${running_jobs}"

        # echo "pending_jobs"
        # echo "${pending_jobs}"

        local total_jobs=$((running_jobs + pending_jobs))
        local jobs_to_submit=$((num_jobs - total_jobs))

        if [[ $jobs_to_submit -gt 0 ]]; then
          for ((i = 1; i <= jobs_to_submit; i++)); do
            EXLCUDE=""
            EXCLUDED_NODES=$(squeue --me -h -n ${service_name} -t R -o %N | sort | uniq | tr '\n' ',' | sed 's/,$//')
            if [[ -n "$EXCLUDED_NODES" ]]; then
              EXCLUDE="--exclude=${EXCLUDED_NODES}"
            fi
            ret=$(nohup sbatch ${EXCLUDE} --chdir "${FOREVER_ROOT}/.work/slurm-output" "$submission_script" 2>&1 &)
            log "sbatch: ${ret}"
            log "Submitted job $i of $jobs_to_submit: $job_name"
            sleep 5 # Sleep for a few seconds before submitting the next job
            SQUEUE_DATA=$(get_squeue_data)
          done
        else
          log "Already $running_jobs running and $pending_jobs pending instances of $job_name."
        fi
      fi
    done
  done
}

# Function to get server info from Slurm jobs (restoring the old method)
get_server_info() {
  echo "${SQUEUE_DATA}" | awk '{print $1}' | while read -r jobid; do
    # Use scontrol to get the job comment
    comment=$(scontrol show job "$jobid" | sed -n 's/.*Comment=\([^[:space:]]*\).*/\1/p')
    # Check if the comment starts with "traefik,"
    if [[ $comment == traefik,* ]]; then
      echo "$comment"
    fi
  done
}

# Function to update Traefik configuration
update_traefik_configs() {
  # Directory for Traefik YAML files
  local yaml_dir="${FOREVER_ROOT}/.work/traefik-watch"
  local last_config_dir="/tmp/last_forever_slurm_configs-${USER}"
  
  # Create directory for last known configurations if it doesn't exist
  mkdir -p "$last_config_dir"

  # Fetch current server list from Slurm jobs
  local current_servers
  current_servers=$(get_server_info)

  # Check if current_servers is empty
  if [[ -z "$current_servers" ]]; then
    log "No current servers found for Traefik."
    return
  fi

  declare -A service_servers

  # Process the server list and group them by service
  while IFS=',' read -r prefix service url; do
    if [[ -n "$service" && -n "$url" ]]; then
      service_servers["$service"]+="$url|"
    else
      log "Invalid service or URL in current_servers: $service, $url"
    fi
  done <<< "$current_servers"

  # Loop through each service and update the corresponding YAML file if needed
  for service in "${!service_servers[@]}"; do
    local yaml_file="${yaml_dir}/${service}.yml"
    local last_config_file="${last_config_dir}/${service}.txt"
    
    # Skip if the YAML file doesn't exist
    if [[ ! -f "$yaml_file" ]]; then
      log "Error: YAML file for service '${service}' does not exist."
      continue
    fi

    # Create a temporary file for updating the YAML
    local temp_file
    temp_file=$(mktemp)

    # Get the current list of servers for the service
    local new_servers="${service_servers[$service]::-1}"

    # Compare with the last known server list for this service
    if [[ -f "$last_config_file" ]] && diff -q <(echo "$new_servers") "$last_config_file" >/dev/null; then
      log "No changes in the server list for ${service}."
      continue
    fi

    # Update the YAML file with new servers
    awk -v servers="${new_servers}" '
    BEGIN { split(servers, server_array, "|") }
    /servers:/ {
      print $0
      for (i in server_array) {
        print "          - url: \"" server_array[i] "\""
      }
      in_servers = 1
      next
    }
    in_servers && /^[^ ]/ { in_servers = 0 }
    !in_servers { print $0 }
    ' "$yaml_file" > "$temp_file"

    if [[ $? -eq 0 ]] && [[ -s "$temp_file" ]]; then
      mv "$temp_file" "$yaml_file"
      echo "$new_servers" > "$last_config_file"
      log "Updated $yaml_file with new server configuration."
    else
      log "Error updating the YAML file for service '${service}'."
      rm "$temp_file"
    fi
  done
}

# Function that runs the forever loop
run_forever() {
  while true; do
    log "Fetching current slurm jobs ..."
    SQUEUE_DATA=$(get_squeue_data)
    
    #echo "squeue_data:"
    #echo "${SQUEUE_DATA}"

    # Call the job submission function
    log "Check for missing jobs ..."
    submit_missing_jobs

    # Call the Traefik update function
    log "Updating metadata for Traefik ..."
    update_traefik_configs 

    log "Sleeping for ${FS_SLEEP_INTERVAL} seconds..."
    sleep "${FS_SLEEP_INTERVAL}"
  done
}

log "Starting forever-slurm.sh with a sleep interval of ${FS_SLEEP_INTERVAL} seconds"
run_forever