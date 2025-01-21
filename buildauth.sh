#!/bin/bash

# Configuration variables - modify these according to your setup
USER="ansible"              # The user to be created on remote devices
GIT_USER="git"             # The user for git operations
KEY_PATH="/path/to/keys"   # Base path for storing SSH keys
LOG_FILE="/var/log/buildauth.log"
$BUILD_KEY_PATH="/path/to/build_key_on_device" # Path to the build key on the device
TAG_GATEWAY="gateways"     # Tag used to identify gateway devices
# Add constants for logging
LOG_FILE="/var/log/buildauth.log"
MAX_LOG_SIZE=$((5 * 1024 * 1024)) # 5 MB

# Function to check and rotate log file
check_log_size() {
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)
        if [[ $size -gt $MAX_LOG_SIZE ]]; then
            mv "$LOG_FILE" "$LOG_FILE.old"
            touch "$LOG_FILE"
            chmod 644 "$LOG_FILE"
        fi
    fi
}

# Modified logging function
log_message() {
    local level=$1
    local message=$2
    check_log_size
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" | tee -a "$LOG_FILE"
}

# Function to get current SSH connections
get_ssh_connections() {
    local connections
    if ! connections=$(ss -tn state established | grep "100" | awk '{print $4}' | cut -d: -f1); then
        log_message "ERROR" "Failed to get SSH connections"
        return 1
    fi
    echo "$connections"
}

# Function to check if IP is from Tailscale
check_tailscale_ip() {
    local ip=$1
    if [[ -z "$ip" ]]; then
        log_message "ERROR" "No IP address provided to check_tailscale_ip"
        return 1
    fi
    if ! tailscale whois "$ip" >/dev/null 2>&1; then
        log_message "WARN" "IP $ip is not a valid Tailscale IP"
        return 1
    fi
    return 0
}

# Retrieve device info from Tailscale whois command
get_device_info() {
    local ip=$1
    local device_info

    if [[ -z "$ip" ]]; then
        log_message "ERROR" "No IP address provided to get_device_info"
        return 1
    fi

    if ! device_info=$(tailscale whois "$ip"); then
        log_message "ERROR" "Failed to get device info for IP $ip"
        return 1
    fi
    
    local name
    local tags
    
    name=$(echo "$device_info" | grep "Name:" | awk '{print $2}' | sed 's/\.tail.*\.ts\.net//')
    tags=$(echo "$device_info" | grep "Tags:" | cut -d':' -f2- | tr -d ' ')
    
    if [[ -z "$name" ]]; then
        log_message "ERROR" "Could not extract device name from whois output"
        return 1
    fi
    
    echo "$name"
    echo "$tags"
}

# Creates a key pair for the device and stores it in the KEY_PATH directory
generate_key_pair() {
    local name=$1
    log_message "DEBUG" "Entering generate_key_pair with name=$name"
    
    if [[ -z "$name" ]]; then
        log_message "ERROR" "No device name provided to generate_key_pair"
        return 1
    fi

    local key_path="$KEY_PATH/id_ed25519_${name}"
    
    if ! ssh-keygen -t ed25519 -f "$key_path" -N "" -C "buildauthkey"; then
        log_message "ERROR" "Failed to generate key pair for $name"
        return 1
    fi
    
    log_message "INFO" "Successfully generated key pair for $name"
    ssh-keyscan -H "$name" >> /home/ubuntu/.ssh/known_hosts
    return 0
}

copy_key_to_git_user() {
    local name=$1
    local key_path="$KEY_PATH/id_ed25519_${name}"

    if [[ -z "$key_path" ]]; then  
        log_message "ERROR" "No key path provided to copy_key_to_git_user"
        return 1
    fi

    log_message "INFO" "Copying public key to $GIT_USER's authorized_keys..."
    if ! sudo bash -c "if ! grep -q \"$(cat $key_path.pub)\" /home/$GIT_USER/.ssh/authorized_keys; then cat $key_path.pub >> /home/$GIT_USER/.ssh/authorized_keys; fi && chmod 600 /home/$GIT_USER/.ssh/authorized_keys"; then
        log_message "ERROR" "Failed to copy public key to $GIT_USER's authorized_keys"
        echo "Failed to copy public key to $GIT_USER's authorized_keys for $name" >> failed_to_append.txt
        return 1
    fi
    
    log_message "INFO" "Successfully copied key to $GIT_USER's authorized_keys"
    return 0
}

check_targets() {
    local name=$1
    local key_path="$KEY_PATH/id_ed25519_$name"
    
    log_message "DEBUG" "Entering check_targets with name=$name"
    
    # Check if device name is empty
    if [[ -z "$name" ]]; then
        log_message "ERROR" "Empty device name provided to check_targets"
        return 1
    fi
    
    # Check if there is already a key present for the device
    if [ -f "$key_path.pub" ]; then
        log_message "INFO" "Key already exists for $name"
        echo "$name" >>/home/ubuntu/ssh_keys/gateway_key_pairs/provisioned_targets
        return 1
    fi
    
    # Device is valid for provisioning
    return 0
}

# Define playbook content
PLAYBOOK_CONTENT=$(cat <<EOF
---
- name: Provision Device
  hosts: all
  tasks:
    # Basic user setup
    - name: enter your ansible playbook here
      become: yes
EOF
)

provision() {
    local name=$1
    local tags=$2
    
    log_message "DEBUG" "Entering provision with name=$1, tags=$2"
    
    if [[ -z "$name" ]] || [[ -z "$tags" ]]; then
        log_message "ERROR" "Missing name or tags in provision function"
        return 1
    fi

    if [[ "$tags" != *"$TAG_GATEWAY"* ]]; then
        log_message "INFO" "Device $name doesn't have gateway tag, skipping"
        return 1
    fi

    if ! copy_key_to_git_user "$name"; then
        log_message "ERROR" "Failed to copy key to git user for $name"
        return 1
    fi
    
    local temp_playbook="/tmp/provision_${name}_playbook.yml"
    echo "$PLAYBOOK_CONTENT" > "$temp_playbook" || {
        log_message "ERROR" "Failed to create temporary playbook for $name"
        return 1
    }
    
    if ! ansible-playbook -i "$name," "$temp_playbook" --private-key $BUILD_KEY_PATH -u $USER --ssh-common-args='-o StrictHostKeyChecking=no'; then
        log_message "ERROR" "Ansible playbook execution failed for $name"
        rm "$temp_playbook"
        return 1
    fi
    
    rm "$temp_playbook"
    log_message "INFO" "Successfully provisioned device $name"
    return 0
}

# Main loop
while true; do
    if ! mapfile -t current_connections < <(get_ssh_connections); then
        log_message "ERROR" "Failed to get current connections"
        sleep 5
        continue
    fi
    
    log_message "INFO" "Found ${#current_connections[@]} connections"
    
    for ip in "${current_connections[@]}"; do
        log_message "INFO" "Examining connection from: $ip"
        if check_tailscale_ip "$ip"; then
            log_message "INFO" "✓ Tailscale connection detected from: $ip"
            
            if ! mapfile -t device_info < <(get_device_info "$ip"); then
                log_message "ERROR" "Failed to get device info for $ip"
                continue
            fi
            
            name="${device_info[0]}"
            tags="${device_info[1]}"
            
            # Check if device is eligible for provisioning
            if [[ "$tags" == *"tag:$TAG_GATEWAY"* ]] && check_targets "$name"; then
                if generate_key_pair "$name"; then
                    if ! provision "$name" "$tags"; then
                        log_message "ERROR" "Provisioning failed for device $name"
                    fi
                else
                    log_message "ERROR" "Key pair generation failed for device $name"
                fi
            fi
        else
            log_message "WARN" "✗ Non-Tailscale connection from: $ip"
            echo "✗ Non-Tailscale connection from: $ip $(date)" >> non_tailscale_connections.log
        fi
    done
    
    sleep 5
done
