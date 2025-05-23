#!/bin/bash -e
#
# Script to join a Linux machine to an Active Directory domain.
# It installs necessary packages, configures SSSD, sudoers, and SSH access.
#
# Usage: ./AD_JOIN_optimized.sh [DOMAIN_ADMIN_USER] [TARGET_DOMAIN] [COMPUTER_OU] [SSH_ALLOW_GROUP] [SUDOERS_GROUP]
#   or   ./AD_JOIN_optimized.sh --help
#

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Causes a pipeline to return the exit status of the last command in the
# pipe that returned a non-zero return value.
set -o pipefail

# --- Configuration Variables (with defaults) ---
TARGET_DOMAIN="${1:-"test.local"}"
COMPUTER_OU="${2:-"ou=lastOU,ou=LINUX_SERVERS,ou=1stou,dc=test,dc=local"}" # Example OU
SSH_ALLOW_GROUP="${3:-"SSH_ALLOW_ALL_SECURITY_GROUP"}" # Example AD Group for SSH
SUDOERS_GROUP="${4:-"SUDORES_SECURITY_GROUP"}" # Example AD Group for Sudo
DOMAIN_ADMIN_USER="${5:-}" # Will be prompted if empty

# --- Global Variables ---
OS_NAME=""
OS_VERSION=""
SUDOERS_BACKUP_PATH="/root/sudoers_bak" # Fixed backup path
SUDOERS_BACKUP_FILE="" # Will be set dynamically in configure_sudoers

# --- Function Definitions ---

# Displays script usage
print_usage() {
  echo "Usage: $0 [DOMAIN_ADMIN_USER] [TARGET_DOMAIN] [COMPUTER_OU] [SSH_ALLOW_GROUP] [SUDOERS_GROUP]"
  echo "       $0 --help"
  echo ""
  echo "Arguments:"
  echo "  DOMAIN_ADMIN_USER  Username of the AD domain administrator (will be prompted if not provided)."
  echo "  TARGET_DOMAIN      Target Active Directory domain (default: \"$TARGET_DOMAIN\")."
  echo "  COMPUTER_OU        Organizational Unit for the computer account (default: \"$COMPUTER_OU\")."
  echo "  SSH_ALLOW_GROUP    AD group allowed SSH access (default: \"$SSH_ALLOW_GROUP\")."
  echo "  SUDOERS_GROUP      AD group granted sudo privileges (default: \"$SUDOERS_GROUP\")."
  echo ""
  echo "Example: $0 myadmin corp.example.com 'OU=Linux Servers,DC=corp,DC=example,DC=com' 'Domain Admins_SSH' 'Domain Admins_Sudo'"
}

# Gets OS Name and Version
get_os_info() {
  echo "Detecting Operating System..."
  if [ -f "/etc/os-release" ]; then
    # Source os-release file
    . /etc/os-release
    OS_NAME="$NAME"
    OS_VERSION="$VERSION_ID"
    echo "OS detected: $OS_NAME $OS_VERSION (from /etc/os-release)"
  elif [ -f "/etc/centos-release" ]; then
    OS_NAME=$(cat /etc/centos-release | sed -e 's/^\(CentOS\).*$/\1/')
    OS_VERSION=$(cat /etc/centos-release | sed -e 's/.*release \([0-9.]\+\).*/\1/')
    echo "OS detected: $OS_NAME $OS_VERSION (from /etc/centos-release)"
  elif [ -f "/etc/oracle-release" ]; then
    OS_NAME=$(cat /etc/oracle-release | sed -e 's/^\(Oracle Linux Server\).*$/\1/')
    OS_VERSION=$(cat /etc/oracle-release | sed -e 's/.*release \([0-9.]\+\).*/\1/')
    echo "OS detected: $OS_NAME $OS_VERSION (from /etc/oracle-release)"
  else
    echo "Error: Unsupported Operating System. Cannot determine OS Name and Version." >&2
    echo "Please ensure /etc/os-release, /etc/centos-release, or /etc/oracle-release is present." >&2
    exit 1
  fi

  if [ -z "$OS_NAME" ] || [ -z "$OS_VERSION" ]; then
    echo "Error: Could not reliably determine OS Name or Version from the release file." >&2
    exit 1
  fi
  echo "OS Detection complete. OS_NAME='${OS_NAME}', OS_VERSION='${OS_VERSION}'"
}

# Installs necessary packages
install_packages() {
  echo "Installing required packages..."
  # The script will exit on error due to 'set -e'
  yum install sssd realmd oddjob oddjob-mkhomedir adcli samba-common samba-common-tools krb5-workstation openldap-clients policycoreutils-python -y
  echo "Package installation completed successfully."
}

# Joins the machine to the AD domain
join_ad_domain() {
  echo "Attempting to discover domain '$TARGET_DOMAIN'..."
  if realm discover "$TARGET_DOMAIN"; then
    echo "Successfully discovered domain '$TARGET_DOMAIN'. Proceeding with join..."
  else
    # realm discover provides its own error messages, but we add context and exit.
    echo "Error: Could not discover domain '$TARGET_DOMAIN'. Realm discover command failed." >&2
    echo "Please check DNS resolution, network connectivity to domain controllers, and that the domain name is correct." >&2
    exit 1
  fi

  echo "Joining AD domain: $TARGET_DOMAIN using OU: '$COMPUTER_OU' and OS: '$OS_NAME $OS_VERSION'..."
  # The script will exit on error due to 'set -e'
  # Note: The original script used --os-name="$os_release" and --os-version="$os_version"
  # We are using the more standard $OS_NAME and $OS_VERSION from /etc/os-release if available
  realm join --computer-ou="$COMPUTER_OU" --os-name="$OS_NAME" --os-version="$OS_VERSION" --user="$DOMAIN_ADMIN_USER" "$TARGET_DOMAIN"
  # If realm join fails, 'set -e' will cause the script to exit here.
  echo "Domain join command executed for $TARGET_DOMAIN. Verification will be in the summary."
}

# Configures SSSD
configure_sssd() {
  echo "Configuring SSSD (/etc/sssd/sssd.conf)..."
  # The script will exit on error due to 'set -e'

  # Set use_fully_qualified_names to False
  if grep -q "use_fully_qualified_names" /etc/sssd/sssd.conf; then
    sed -i 's|^use_fully_qualified_names.*|use_fully_qualified_names = False|g' /etc/sssd/sssd.conf
    echo "Set 'use_fully_qualified_names = False'."
  else
    echo "Warning: 'use_fully_qualified_names' not found in /etc/sssd/sssd.conf. Adding it."
    # Add it under the [domain/*] section, or [sssd] if no domain section
    if grep -q '^\[domain\/.*\]' /etc/sssd/sssd.conf; then
      sed -i '/^\[domain\/.*\]/a use_fully_qualified_names = False' /etc/sssd/sssd.conf
    elif grep -q '^\[sssd\]' /etc/sssd/sssd.conf; then
      sed -i '/^\[sssd\]/a use_fully_qualified_names = False' /etc/sssd/sssd.conf
    else
      echo "use_fully_qualified_names = False" >> /etc/sssd/sssd.conf # Fallback, might not be ideal section
    fi
    echo "Added 'use_fully_qualified_names = False'."
  fi

  # Update fallback_homedir
  if grep -q "fallback_homedir" /etc/sssd/sssd.conf; then
    sed -i 's|^fallback_homedir.*|fallback_homedir = /home/%u|g' /etc/sssd/sssd.conf
    echo "Set 'fallback_homedir = /home/%u'."
  else
    echo "Warning: 'fallback_homedir' not found in /etc/sssd/sssd.conf. Adding it."
    # Add it under the [domain/*] section, or [sssd] if no domain section
    if grep -q '^\[domain\/.*\]' /etc/sssd/sssd.conf; then
      sed -i '/^\[domain\/.*\]/a fallback_homedir = /home/%u' /etc/sssd/sssd.conf
    elif grep -q '^\[sssd\]' /etc/sssd/sssd.conf; then
      sed -i '/^\[sssd\]/a fallback_homedir = /home/%u' /etc/sssd/sssd.conf
    else
      echo "fallback_homedir = /home/%u" >> /etc/sssd/sssd.conf # Fallback
    fi
    echo "Added 'fallback_homedir = /home/%u'."
  fi

  # Add override_homedir if it doesn't exist
  if grep -qxF 'override_homedir = /home/%u' /etc/sssd/sssd.conf; then
    echo "'override_homedir = /home/%u' already exists."
  else
    echo "override_homedir = /home/%u" >> /etc/sssd/sssd.conf
    echo "Added 'override_homedir = /home/%u'."
  fi

  echo "SSSD configuration complete."
}

# Configures sudoers for the AD group
configure_sudoers() {
  echo "Configuring sudoers for AD group: '$SUDOERS_GROUP'..."
  # The script will exit on error due to 'set -e'

  # Set the dynamic backup file name
  SUDOERS_BACKUP_FILE="$SUDOERS_BACKUP_PATH/ad_domain_sudoers.$(date +"%Y%m%d_%H%M%S").bak"
  local sudoers_target_file="/etc/sudoers.d/ad_domain_sudoers" # Specific file for our AD group

  echo "Ensuring sudoers backup directory exists: $SUDOERS_BACKUP_PATH"
  mkdir -p "$SUDOERS_BACKUP_PATH"

  if [ -f "$sudoers_target_file" ]; then
    echo "Backing up existing sudoers target file '$sudoers_target_file' to '$SUDOERS_BACKUP_FILE'..."
    mv "$sudoers_target_file" "$SUDOERS_BACKUP_FILE"
    echo "Backup complete."
  else
    echo "No existing sudoers target file '$sudoers_target_file' found to back up."
  fi

  echo "Creating new sudoers file '$sudoers_target_file' with rule for '$SUDOERS_GROUP'..."
  # Ensure the group name doesn't contain characters that could break the sudoers file.
  # For this script, we assume the group name is valid.
  # Using printf for safer output formatting, though echo should be fine here with quoted var.
  printf "%%\"%s\" ALL=(ALL:ALL) ALL\n" "$SUDOERS_GROUP" > "$sudoers_target_file"

  echo "Setting permissions for '$sudoers_target_file' to 440..."
  chmod 440 "$sudoers_target_file"

  echo "Sudoers configuration complete. Rule for '$SUDOERS_GROUP' added to '$sudoers_target_file'."
  echo "If a previous file existed, it was backed up to '$SUDOERS_BACKUP_FILE'."
}

# Configures SSH access for the AD group
configure_ssh_access() {
  echo "Configuring SSH access for AD group: '$SSH_ALLOW_GROUP' on domain '$TARGET_DOMAIN'..."
  # The script will exit on error due to 'set -e'
  realm permit -g "$SSH_ALLOW_GROUP" -R "$TARGET_DOMAIN"
  echo "SSH access configuration completed successfully for group '$SSH_ALLOW_GROUP'."
}

# Restarts relevant services
restart_services() {
  echo "Restarting sssd service and reloading daemon..."
  # The script will exit on error due to 'set -e'
  systemctl restart sssd
  echo "sssd service restarted."
  systemctl daemon-reload
  echo "Systemd daemon reloaded."
  echo "Services restarted successfully."
}

# Displays a summary of the actions taken
display_summary() {
  echo ""
  echo "--- AD Join Summary ---"
  local domain_list_output
  domain_list_output=$(realm list)

  if [ -n "$domain_list_output" ]; then
    echo "Current domain membership status from 'realm list':"
    echo "$domain_list_output"
    # Check if the specific target domain is listed as configured.
    # This is a more robust check than just assuming any output means success for *our* target domain.
    if echo "$domain_list_output" | grep -q "domain-name: $TARGET_DOMAIN" && echo "$domain_list_output" | grep -q "configured: yes"; then
      echo "Successfully joined and configured for domain: $TARGET_DOMAIN"
    else
      echo "Warning: The machine may not be correctly joined to '$TARGET_DOMAIN' or is joined to a different domain. Please check the output above carefully."
    fi
  else
    echo "Warning: Not currently joined to any AD domain according to 'realm list'."
  fi

  echo ""
  echo "Configuration Details:"
  echo "  Target Domain:      $TARGET_DOMAIN"
  echo "  Computer OU:        $COMPUTER_OU"
  echo "  OS Detected:        $OS_NAME $OS_VERSION"
  echo "  SSH Access Group:   $SSH_ALLOW_GROUP"
  echo "  Sudoers Group:      $SUDOERS_GROUP (configured in /etc/sudoers.d/ad_domain_sudoers)"

  if [ -f "$SUDOERS_BACKUP_FILE" ]; then # Check if a backup was actually made
    echo "  Sudoers Backup:     Original /etc/sudoers.d/ad_domain_sudoers backed up to $SUDOERS_BACKUP_FILE"
  elif [ -n "$SUDOERS_BACKUP_FILE" ]; then # Variable is set but file doesn't exist (meaning no original to backup)
     echo "  Sudoers Backup:     No pre-existing /etc/sudoers.d/ad_domain_sudoers file to back up."
  fi
  echo "--- End of Summary ---"
}

# --- Main Script Logic ---

# Parse for help flag
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
  print_usage
  exit 0
fi

# Prompt for Domain Admin User if not provided as the 5th argument or if empty
if [ -z "$DOMAIN_ADMIN_USER" ]; then
  read -r -p "Enter Domain Administrator Account (required for domain join): " DOMAIN_ADMIN_USER
  if [ -z "$DOMAIN_ADMIN_USER" ]; then
    echo "Error: Domain Administrator Account cannot be empty." >&2
    exit 1
  fi
fi

echo "Starting AD Domain Join Process..."

get_os_info
install_packages
join_ad_domain
configure_sssd
configure_sudoers
configure_ssh_access
restart_services
display_summary

echo "AD Domain Join Process steps executed. Review the summary above for join status."

exit 0
