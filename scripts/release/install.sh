#!/bin/sh

# AdGuard VPN Installation Script

set -e -f -u

# Function log is an echo wrapper that writes to stderr if the caller
# requested verbosity level greater than 0.  Otherwise, it does nothing.
log() {
  if [ "$verbose" -gt '0' ]
  then
    echo "$1" 1>&2
  fi
}

# Function error_exit is an echo wrapper that writes to stderr and stops the
# script execution with code 1.
error_exit() {
  echo "$1" 1>&2

  exit 1
}

# Function usage prints the note about how to use the script.
usage() {
  echo 'Usage: install.sh [-o output_dir] [-v] [-h] [-u]' 1>&2
}

# Function parse_opts parses the options list and validates it's combinations.
parse_opts() {
  while getopts 'vho:uV:' opt "$@"
  do
    case "$opt"
    in
    'v')
      verbose='1'
      ;;
    'h')
      usage
      ;;
    'o')
      output_dir="$OPTARG"
      ;;
    'u')
      uninstall='1'
      ;;
    'V')
      version="$OPTARG"
      ;;
    *)
      log "bad option $OPTARG"
      usage
    ;;
    esac
  done
}

# Function is_little_endian checks if the CPU is little-endian.
#
# See https://serverfault.com/a/163493/267530.
is_little_endian() {
  # The ASCII character "I" has the octal code of 111.  In the two-byte octal
  # display mode (-o), hexdump will print it either as "000111" on a little
  # endian system or as a "111000" on a big endian one.  Return the sixth
  # character to compare it against the number '1'.
  #
  # Do not use echo -n, because its behavior in the presence of the -n flag is
  # explicitly implementation-defined in POSIX.  Use hexdump instead of od,
  # because OpenWrt and its derivatives have the former but not the latter.
  is_little_endian_result="$(
    printf 'I'\
      | hexdump -o\
      | awk '{ print substr($2, 6, 1); exit; }'
  )"
  readonly is_little_endian_result

  [ "$is_little_endian_result" -eq '1' ]
}

# Function set_os sets the os if needed and validates the value.
set_os() {
  # Set if needed.
  if [ "$os" = '' ]
  then
    os="$( uname -s )"
    case "$os"
    in
    ('Darwin')
      os='macos'
      ;;
    ('Linux')
      os='linux'
      ;;
    (*)
      error_exit "Unsupported operating system: '$os'"
      ;;
    esac
  fi

  # Validate.
  case "$os"
  in
  ('macos'|'linux')
    # All right, go on.
    ;;
  (*)
    error_exit "Unsupported operating system: '$os'"
    ;;
  esac

  # Log.
  log "Operating system: $os"
}

# Function set_cpu sets the cpu if needed and validates the value.
set_cpu() {
  # For macOS there is universal binary, so we don't need to set cpu
  if [ "$os" = 'macos' ]
  then
    return 0
  fi

  # Set if needed.
  if [ "$cpu" = '' ]
  then
    cpu="$( uname -m )"
    case "$cpu"
    in
    ('x86_64'|'x86-64'|'x64'|'amd64')
      cpu='x86_64'
      ;;
    ('armv7l' | 'armv8l')
      cpu='armv7'
      ;;
    ('aarch64'|'arm64')
      cpu='aarch64'
      ;;
    ('mips')
      if is_little_endian
      then
        cpu="mipsel"
      fi
      ;;
    (*)
      error_exit "unsupported cpu type: $cpu"
      ;;
    esac
  fi

  # Validate.
  case "$cpu"
  in
  ('x86_64'|'armv7'|'aarch64')
    # All right, go on.
    ;;
  ('mips'|'mipsel')
    # That's right too.
    ;;
  (*)
    error_exit "Unsupported cpu type: $cpu"
    ;;
  esac

  # Log.
  log "CPU type: $cpu"
}

# Function is_dir_owned_by_current_user checks if the output directory is owned by the current user
is_dir_owned_by_current_user() {
  dir="$1"

  if [ "$os" = "macos" ]; then
      # macOS
      owner_name=$(stat -f '%Su' "$dir")
  elif [ "$os" = "linux" ]; then
      # Linux
      owner_name=$(stat -c '%U' "$dir")
  else
      echo "Unsupported OS: $os"
      return 1
  fi

  if [ "$owner_name" = "$USER" ]; then
      return 0
  else
      return 1
  fi
}

# Function create_dir creates the output directory if it does not exist.
create_dir() {
  mkdir -p "$output_dir" 2>/dev/null
  if [ $? -eq 1 ];
  then
    echo "Starting sudo to create directory '$output_dir'"
    if sudo mkdir -p "$output_dir"; then
        sudo chown -R "${SUDO_USER:-$USER}" "$output_dir"
        log "'$output_dir' has been created and ownership has been set to '${SUDO_USER:-$USER}'"
    else
        error_exit "Failed to create '$output_dir' with sudo"
    fi
  else
    log "'$output_dir' has been created"
  fi
}

# Check if the directory is owned by the current user and change the ownership if needed
check_owner() {
  if is_dir_owned_by_current_user "$output_dir";
  then
    log "'$output_dir' exists and is owned by '$USER'"
  else
    log "'$output_dir' exists but is not owned by '$USER'"
    printf "Would you like to change the ownership of %s to %s? [y/N] " "$output_dir" "$USER"
    read -r response < /dev/tty
    case "$response" in
    [yY]|[yY][eE][sS])
      target_user="${SUDO_USER:-$USER}"
      if sudo chown -R "$target_user" "$output_dir"; then
        log "Ownership of $output_dir has been changed to '${target_user}'"
      else
        error_exit "Failed to change ownership of '$output_dir'"
      fi
      ;;
    *)
      error_exit "Installation cannot proceed without changing ownership of '$output_dir'"
      ;;
    esac
  fi
}

# Function check_out_dir requires the output directory to be set and exist.
check_out_dir() {
  if [ "$output_dir" = '' ]
  then
    # If output_dir is not set, we will install to /opt
    output_dir='/opt'
  fi

  # If output_dir is '.'or '/opt', create inside it `adguardvpn_cli` directory
  if [ "$output_dir" = '.' ] || [ "$output_dir" = '/opt' ]
  then
    output_dir="${output_dir}/adguardvpn_cli"
  fi

  if [ "$uninstall" -eq '1' ]
  then
    echo "AdGuard VPN will be uninstalled from '$output_dir'"
    return 0
  else
    echo "AdGuard VPN will be installed to '$output_dir'"
  fi

  set +e
  # Check if directory exists
  if [ ! -d "$output_dir" ];
  then
    log "'$output_dir' directory does not exist, attempting to create it..."
    create_dir
  else
    log "'$output_dir' directory exists"
    check_owner
  fi
  set -e
}

# Function verify_hint prints a hint about how to verify the installation.
verify_hint() {
  # Check if `.sig` file exists
  if [ -f "${output_dir}/${exe_name}.sig" ]
  then
    echo
    echo "To verify the installation, run the following command to import the public key and verify the signature:"
    echo "    gpg --keyserver 'keys.openpgp.org' --recv-key '28645AC9776EC4C00BCE2AFC0FE641E7235E2EC6'"
    echo "    gpg --verify ${output_dir}/${exe_name}.sig ${output_dir}/${exe_name}"
  fi
}

# Function unpack unpacks the passed archive depending on it's extension.
unpack() {
  log "Unpacking package from '$pkg_name' into '$output_dir'"
  if ! mkdir -p "$output_dir"
  then
    error_exit "Cannot create directory '$output_dir'"
  fi

  if ! tar -C "$output_dir" -f "$pkg_name" -x -z
  then
    $remove_command "$pkg_name"
    error_exit "Cannot unpack '$pkg_name'"
  fi

  $remove_command "$pkg_name"
  log "Package has been unpacked successfully"

  # Check for existing symlink or .nosymlink file
  if [ -L "/usr/local/bin/${exe_name}" ] && \
      [ "$(readlink -f "/usr/local/bin/${exe_name}")" = "$(readlink -f "${output_dir}/${exe_name}")" ]; then
    symlink_exists='1'
  fi

  if [ "${symlink_exists}" -eq 1 ]; then
    log "A symlink exists. No further action taken."
  elif [ -f "${output_dir}/.nosymlink" ]; then
    log "'.nosymlink' file exists in the installation directory. No further action taken."
  else
    # Ask user about linking the binary to /usr/local/bin
    printf "Would you like to link the binary to /usr/local/bin? [y/N] "
    read -r response < /dev/tty
    case "$response" in
    [yY]|[yY][eE][sS])
      # Create a symlink with an absolute path
      absolute_path=$(readlink -f "${output_dir}/${exe_name}")
      if ln -sf "${absolute_path}" /usr/local/bin 2> /dev/null || sudo ln -sf "${absolute_path}" /usr/local/bin; then
        symlink_exists='1'
        log "Binary has been linked to '/usr/local/bin'"
      else
        log "Failed to link the binary to '/usr/local/bin'"
      fi
      ;;
    [Nn][Oo]|[Nn])
      # Create a .nosymlink file in the installation directory
      touch "${output_dir}/.nosymlink"
      log "'.nosymlink' file has been created in the installation directory"
      ;;
    *)
      log "Invalid response. No further action taken."
      ;;
    esac
  fi

  verify_hint
}

# Function unpack unpacks the passed archive depending on it's extension.
check_package() {
  log "Checking downloaded package '$pkg_name'"
  case "$pkg_ext"
  in
  ('zip')
    if ! unzip "$pkg_name" -t -q
    then
      $remove_command "$pkg_name"
      error_exit "Error checking $pkg_name"
    fi
    ;;
  ('tar.gz')
    if ! tar -f "$pkg_name" -z -t > /dev/null
    then
      $remove_command "$pkg_name"
      error_exit "Error checking '$pkg_name'"
    fi
    ;;
  (*)
    error_exit "Unexpected package extension: '$pkg_ext'"
    ;;
  esac
}

# Function parse_version parses the version from the passed script and it's arguments.
parse_version() {
  if [ -n "$version" ]; then
    return 0
  fi
  # Extract the base name of the script
  script_name="${0##*/}"

  version=$(echo "${script_name}" | sed -nE 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
  if [ -z "$version" ]; then
    echo "Version required"
    return 1
  fi
  echo "Version number extracted from script name: $version"
}

# Add version to the package name if it's not empty.
apply_version() {
  if [ -z "$version" ]; then
    return 0
  fi

  pkg_name=$(echo "${pkg_name}" | sed -E "s/${exe_name}/${exe_name}-${version}/")
}

# Main function.
configure() {
  if [ "$uninstall" -eq '1' ]
  then
    echo 'Uninstalling AdGuard VPN...'
  else
    echo 'Installing AdGuard VPN...'
    log "Update channel: $channel"
  fi

  set_cpu
  set_os
  parse_version
  check_out_dir

  pkg_ext='tar.gz'
  if [ "$os" = 'macos' ]
  then
    pkg_name="${exe_name}-macos.${pkg_ext}"
  else
    pkg_name="${exe_name}-${os}-${cpu}.${pkg_ext}"
  fi
  apply_version
  url="https://github.com/AdguardTeam/AdGuardVPNCLI/releases/download/v${version}-${channel}/${pkg_name}"

  readonly output_dir url pkg_name

  if [ "$uninstall" -eq '0' ]
  then
    log "Package name: '$pkg_name'"
    log "AdGuard VPN will be installed to '$output_dir'"
  fi
}

# Function handle_uninstall removes the existing package from the output directory.
handle_uninstall() {
  # Check if the package is present in the output directory.
  if [ ! -f "${output_dir}/${exe_name}" ]
  then
    error_exit "AdGuard VPN is not installed in '${output_dir}'. Please specify the correct installation directory"
  fi

  # Check if vpn is running
  if pgrep -x "${exe_name}" > /dev/null
  then
    log 'AdGuard VPN is running. Stopping it...'
    "${output_dir}/${exe_name}" disconnect
  fi

  remove_existing

  # Check if the directory is empty
  if [ -z "$(ls -A "${output_dir}")" ]
  then
    set +e
    log "Remove empty directory: '${output_dir}'"
    rmdir "${output_dir}" 2>/dev/null
    if [ $? -eq 1 ];
    then
      echo "Starting sudo to remove '${output_dir}'"
      if sudo rmdir "${output_dir}"; then
        log "Empty directory '${output_dir}' has been removed"
      else
        error_exit "Failed to remove empty directory '${output_dir}' with sudo"
      fi
    else
      log "Empty directory '${output_dir}' has been removed"
    fi
    set -e
  fi

  # Check symlink in /usr/local/bin
  if [ -L "/usr/local/bin/${exe_name}" ]
  then
    set +e
    log "Remove symlink from '/usr/local/bin'"
    rm -f "/usr/local/bin/${exe_name}" 2> /dev/null
    # Check success
    if [ $? -eq 1 ];
    then
      echo "Starting sudo to remove '/usr/local/bin/${exe_name}'"
      if sudo rm -f "/usr/local/bin/${exe_name}"; then
        log "Symlink has been removed from '/usr/local/bin'"
      else
        log "Failed to remove symlink from '/usr/local/bin' with sudo"
      fi
    else
      log "Symlink has been removed from '/usr/local/bin'"
    fi
    set -e
  fi

  # Notify about service files
  echo "Service files are not removed. You can remove them manually if needed from: "
  if [ $os = 'linux' ]
  then
    echo "    '${XDG_DATA_HOME:-~/.local/share}/${exe_name}'"
  elif [ $os = 'macos' ]
  then
    echo "    '~/Library/Application Support/${exe_name}'"
  fi

  echo 'AdGuard VPN has been uninstalled successfully'
}

# Function remove_existing removes the existing package from the output directory before installing a new one.
remove_existing() {
  log 'Remove existing package...'
  # Remove executable file
  rm -f "${output_dir}/${exe_name}"
  log "'${exe_name}' has been removed from '${output_dir}'"
  # Remove .sig file
  rm -f "${output_dir}/${exe_name}.sig"
  log "'${exe_name}.sig' has been removed from '${output_dir}'"
  # Remove .sig file
  rm -f "${output_dir}/.nosymlink"
}

# Function checks if the package is already present in the output directory.
handle_existing() {
  if [ "$uninstall" -eq '1' ]
  then
    handle_uninstall
    exit 0
  fi

  if [ ! -f "${output_dir}/${exe_name}" ]
  then
    return
  fi

  log "Package ${exe_name} is already present in '${output_dir}'"
  PIDFILE=
  # Check if vpn is running
  if [ $os = 'linux' ]
  then
    PIDFILE="${XDG_DATA_HOME:-$HOME/.local/share}/${exe_name}/vpn.pid"
  elif [ $os = 'macos' ]
  then
    PIDFILE="$HOME/Library/Application Support/${exe_name}/vpn.pid"
  fi
  if [ -f "$PIDFILE" ] && pgrep -F "$PIDFILE" > /dev/null
  then
    error_exit "AdGuard VPN is running. Please, stop it before installing"
  fi

  remove_existing
}

# Function download downloads the package from the url.
download() {
  log "Downloading AdGuard VPN package: $url"

  # Temporary file name for testing file creation
  tmp_file="tmp_file_check_$$"

  # Check if we can write to the current directory by creating a temporary file
  if ! touch "$tmp_file" > /dev/null 2>&1; then
    printf "Cannot create file in the current directory. Try downloading as root? [y/N] "
    read -r response < /dev/tty
    case "$response" in
    [yY]|[yY][eE][sS])
      remove_command="sudo rm -f"
      if ! sudo curl -fsSL "$url" -o "$pkg_name"; then
        error_exit "Failed to download $pkg_name: $?"
      fi
      ;;
    *)
      error_exit "Cannot proceed without file creation rights."
      ;;
    esac
  else
    # Cleanup the temporary file
    rm "$tmp_file"
    if ! curl -fsSL "$url" -o "$pkg_name"; then
      error_exit "Failed to download $pkg_name: $?"
    fi
  fi

  log "AdGuard VPN package has been downloaded successfully"
}

# Entrypoint

exe_name='adguardvpn-cli'
output_dir=''
channel='release'
verbose='1'
cpu=''
os=''
version='1.0.0'
uninstall='0'
remove_command="rm -f"
symlink_exists='0'

parse_opts "$@"

configure

download
check_package

handle_existing

unpack

echo
echo "AdGuard VPN has been installed successfully!"
echo "You can use it by running command:"
if [ "$symlink_exists" -eq '1' ]
then
  echo "    ${exe_name} --help"
else
  echo "    ${output_dir}/${exe_name} --help"
fi
