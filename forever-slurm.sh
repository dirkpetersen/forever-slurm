#!/bin/bash

# Directory of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
trap cleanup SIGINT SIGTERM

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

        local running_jobs
        local pending_jobs
        running_jobs=$(echo "${SQUEUE_DATA}" | grep "$job_name" | grep -c "RUNNING")
        pending_jobs=$(echo "${SQUEUE_DATA}" | grep "$job_name" | grep -c "PENDING")

        local total_jobs=$((running_jobs + pending_jobs))
        local jobs_to_submit=$((num_jobs - total_jobs))

        if [[ $jobs_to_submit -gt 0 ]]; then
          for ((i = 1; i <= jobs_to_submit; i++)); do
            sbatch --chdir "${FOREVER_ROOT}/.work/slurm-output" "$submission_script"
            log "Submitted job $i of $jobs_to_submit: $job_name"
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
  # This function is used to update the Traefik configuration files with the list of
  # servers and ports running the services. It reads the server information from 
  # the Slurm job comment field and updates the YAML files in .work/traefik-watch  
  local yaml_dir="${FOREVER_ROOT}/.work/traefik-watch"
  local last_config_file="/tmp/last_forever_slurm-${USER}.txt"

  # Use the get_server_info function to extract servers from comments in existing SQUEUE_DATA
  local current_servers
  current_servers=$(get_server_info)

  # Check if current_servers is empty
  if [[ -z "$current_servers" ]]; then
    log "No current servers found for Traefik."
    return
  fi

  # Check if there are changes in the server list
  if [[ -f "$last_config_file" ]] && diff -q <(echo "$current_servers") "$last_config_file" >/dev/null; then
    log "No changes in the Traefik service list."
    return
  fi

  declare -A service_servers

  # Process each server entry from current_servers
  while IFS=',' read -r prefix service url; do
    # Ensure service and url are not empty
    if [[ -n "$service" && -n "$url" ]]; then
      service_servers["$service"]+="$url|"
    else
      log "Invalid service or URL in current_servers: $service, $url"
    fi
  done <<< "$current_servers"

  # Update the YAML configuration for each service
  for service in "${!service_servers[@]}"; do
    local yaml_file="${yaml_dir}/${service}.yml"

    if [[ ! -f "$yaml_file" ]]; then
      log "Error: YAML file for service '${service}' does not exist."
      continue
    fi

    local temp_file
    temp_file=$(mktemp)

    awk -v servers="${service_servers[$service]::-1}" '
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
      log "Updated $yaml_file with new server configuration."
    else
      log "Error updating the YAML file for service '${service}'."
      rm "$temp_file"
    fi
  done

  echo "$current_servers" > "$last_config_file"
}

# Function that runs the forever loop
run_forever() {
  while true; do    
    log "Fetching squeue data..."
    SQUEUE_DATA=$(get_squeue_data)
    
    #echo "squeue_data:"
    #echo "${SQUEUE_DATA}"

    # Call the job submission function
    log "Submit missing jobs ..."
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