#!/bin/sh

# AdGuard VPN Installation Script

set -e -u

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
  echo 'Usage: install.sh [-o output_dir] [-v] [-h] [-u] [-p archive_path] [-a y|n]' 1>&2
  echo "On Linux, an installation into a system binary directory puts the files in '/opt/adguardvpn_cli' and creates a symlink in the requested directory." 1>&2
}

# Function parse_opts parses the options list and validates it's combinations.
parse_opts() {
  while getopts 'vho:uV:p:a:' opt "$@"
  do
    case "$opt"
    in
    'v')
      verbose='1'
      ;;
    'h')
      usage
      exit 0
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
    'p')
      archive_path="$OPTARG"
      ;;
    'a')
      case "$OPTARG" in
      [yY]|[yY][eE][sS])
        auto_answer="y"
        ;;
      [nN]|[nN][oO])
        auto_answer="n"
        ;;
      *)
        echo "Invalid value for -a. Use 'y' or 'n' (or 'yes'/'no')." 1>&2
        exit 1
        ;;
      esac
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

# Function check_macos_version refuses to install or update on macOS versions older
# than the minimum the binary supports (macOS 11.0, Big Sur). Big Sur reports either
# "11.x" or, in compatibility mode, "10.16", so 10.16 is the lowest accepted version.
check_macos_version() {
  [ "$os" = 'macos' ] || return 0

  macos_version="$( sw_vers -productVersion 2>/dev/null )"
  # If the version can't be determined, don't block the installation.
  [ -n "$macos_version" ] || return 0

  if version_lt "$macos_version" '10.16'
  then
    error_exit "AdGuard VPN CLI requires macOS 11.0 (Big Sur) or newer, but macOS ${macos_version} was detected."
  fi
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

# Function for queries with support for auto-answer
ask_user() {
  local prompt="$1"
  printf "%s" "$prompt"
  if [ -n "$auto_answer" ]; then
    response="$auto_answer"
    echo "$response"
  else
    read -r response < /dev/tty
  fi
}

set_is_root() {
  if [ $USER = "root" ]; then
    is_root='1'
  fi
  if [ "$(id -u)" = "0" ]; then
    is_root='1'
  fi
}

# Function is_dir_owned_by_current_user checks if the output directory is owned by the current user
is_dir_owned_by_current_user() {
  dir="$1"

  if [ "$os" = "macos" ]; then
      # macOS
      if ! owner_name=$(stat -f '%Su' "$dir"); then
          echo "Cannot stat '$dir'"
          return 0
      fi
  elif [ "$os" = "linux" ]; then
      # Linux
      if ! owner_name=$(stat -c '%U' "$dir"); then
          echo "Cannot stat '$dir'"
          return 0
      fi
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

# Function resolve_symlinks prints the passed path as an absolute path with all the
# symlinks resolved, like `readlink -f` does.
# Plain `readlink` is used instead of `readlink -f`, which is not available on
# macOS older than 12.3, while the script supports macOS 11.0 and newer.
resolve_symlinks() {
  target="$1"
  # The caller may install into a relative directory, but a symlink target has to be
  # absolute to stay valid regardless of the location of the link.
  case "$target"
  in
  /*)
    ;;
  *)
    target="$(pwd -P)/${target}"
    ;;
  esac
  # The hop limit only breaks symlink cycles: the kernel itself refuses to follow more
  # than MAXSYMLINKS links (40 on Linux, 32 on macOS), so longer chains are unresolvable.
  hops='0'
  while [ -L "$target" ] && [ "$hops" -lt '40' ]
  do
    link="$(readlink "$target")" || break
    case "$link"
    in
    /*)
      target="$link"
      ;;
    *)
      target="$(dirname "$target")/${link}"
      ;;
    esac
    hops=$((hops + 1))
  done
  printf '%s\n' "$target"
}

# Function canonical_dir prints the passed directory as an absolute path with the
# symlinks resolved in all its components, or the path itself if it cannot be entered.
canonical_dir() {
  ( cd "$1" 2> /dev/null && pwd -P ) || printf '%s\n' "$1"
}

# Function same_file checks that both paths refer to the same file.
same_file() {
  [ -e "$1" ] && [ -e "$2" ] && [ "$1" -ef "$2" ]
}

# Function path_entries prints the full paths of all `adguardvpn-cli` executables
# found in $PATH.
path_entries() {
  old_ifs="$IFS"
  IFS='
'
  for dir in $(printf '%s\n' "$PATH" | tr ':' '\n')
  do
    if [ -n "$dir" ] && { [ -f "${dir}/${bin_file_name}" ] || [ -L "${dir}/${bin_file_name}" ]; }
    then
      printf '%s\n' "${dir}/${bin_file_name}"
    fi
  done
  IFS="$old_ifs"
}

# Function find_existing_install_dirs prints the directories of all AdGuard VPN CLI
# installations found in $PATH, one per line, in $PATH order and without duplicates
# (the same installation may be reachable through several $PATH entries).
find_existing_install_dirs() {
  path_entries | while IFS= read -r entry
  do
    resolved="$(resolve_symlinks "$entry")"
    dir="${resolved%/*}"
    [ "$dir" != "$resolved" ] || dir='.'

    if [ -f "${dir}/bash-completion.sh" ]
    then
      canonical_dir "$dir"
    fi
  done | awk '!seen[$0]++'

  return 0
}

# Function warn_about_another_installation warns about every CLI installation found
# in $PATH that lives in a directory other than the one being installed into, so that
# installing next to existing installations does not go unnoticed.
warn_about_another_installation() {
  current_dir="$(canonical_dir "$output_dir")"
  find_existing_install_dirs | while IFS= read -r detected_dir
  do
    if [ "$detected_dir" != "$current_dir" ]
    then
      echo "WARNING: detected installation path '$detected_dir' differs from current installation path '$output_dir'" 1>&2
    fi
  done

  return 0
}

# Function create_dir creates the output directory if it does not exist.
create_dir() {
  mkdir -p "$output_dir" 2>/dev/null
  if [ $? -eq 1 ];
  then
    if [ "$is_root" -eq 0 ]; then
      echo "Starting sudo to create directory '$output_dir'"
      if sudo mkdir -p "$output_dir"; then
        sudo chown -R "${SUDO_USER:-$USER}" "$output_dir"
        log "'$output_dir' has been created and ownership has been set to '${SUDO_USER:-$USER}'"
      else
        error_exit "Failed to create '$output_dir' with sudo"
      fi
    else
      error_exit "Failed to create '$output_dir'"
    fi
  else
    log "'$output_dir' has been created"
  fi
}

# Check if the directory is owned by the current user and change the ownership if needed
check_owner() {
  if [ "${is_root}" -eq 1 ]; then
    return 0
  fi
  if is_dir_owned_by_current_user "$output_dir";
  then
    log "'$output_dir' exists and is owned by '$USER'"
  else
    log "'$output_dir' exists but is not owned by '$USER'"
    ask_user "Would you like to change the ownership of $output_dir to $USER (so no sudo is needed for the following steps)? [y/N] "
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

# Function is_listed_system_bin_dir checks whether the path matches one of the
# known system binary directories without resolving it.
is_listed_system_bin_dir() {
  bin_dir="$1"
  while [ "${bin_dir%/}" != "$bin_dir" ]
  do
    bin_dir="${bin_dir%/}"
  done
  for sys_dir in $system_bin_dirs
  do
    if [ "$bin_dir" = "$sys_dir" ]
    then
      return 0
    fi
  done
  return 1
}

# Function is_system_bin_dir checks whether the directory is a system binary directory.
is_system_bin_dir() {
  [ "$os" = 'linux' ] || return 1
  is_listed_system_bin_dir "$1" && return 0
  bin_dir_resolved="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  is_listed_system_bin_dir "$bin_dir_resolved"
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
    # Follow the symlink to the /opt installation when uninstalling from a system directory.
    if is_system_bin_dir "$output_dir" && \
        [ "$(readlink "${output_dir}/${bin_file_name}" 2>/dev/null)" = "/opt/adguardvpn_cli/${bin_file_name}" ]
    then
      link_dir="$output_dir"
      output_dir='/opt/adguardvpn_cli'
    fi
    echo "AdGuard VPN will be uninstalled from '$output_dir'"
    return 0
  fi

  # A missing system binary directory is most likely a typo.  Refuse it before
  # downloading, otherwise the installation would bypass the /opt redirect.
  if [ "$os" = 'linux' ] && is_listed_system_bin_dir "$output_dir" && [ ! -d "$output_dir" ]
  then
    error_exit "System binary directory '$output_dir' does not exist. Please specify an existing installation directory"
  fi

  # Install into /opt when the target is a system binary directory and keep a
  # symlink in the original directory.
  if is_system_bin_dir "$output_dir"
  then
    link_dir="$output_dir"
    output_dir='/opt/adguardvpn_cli'
  fi

  echo "AdGuard VPN will be installed to '$output_dir'"

  # Compare against the directory the installer will actually use, which may
  # differ from the requested one after the system-directory redirect above.
  warn_about_another_installation

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
  if [ -f "${output_dir}/${bin_file_name}.sig" ]
  then
    echo
    echo "To verify the installation, run the following command to import the public key and verify the signature:"
    echo "    gpg --keyserver 'keys.openpgp.org' --recv-key '28645AC9776EC4C00BCE2AFC0FE641E7235E2EC6'"
    echo "    gpg --verify ${output_dir}/${bin_file_name}.sig ${output_dir}/${bin_file_name}"
  fi
}

create_symlink() {
  # The installation was redirected from a system directory; link there.
  if [ -n "$link_dir" ]
  then
    if [ "$is_root" -eq 1 ] || [ -w "$link_dir" ]; then
      ln -sf "${output_dir}/${bin_file_name}" "${link_dir}/${bin_file_name}"
    else
      sudo ln -sf "${output_dir}/${bin_file_name}" "${link_dir}/${bin_file_name}"
    fi || error_exit "Failed to create symlink in '${link_dir}'"
    symlink_exists='1'
    echo "Binary has been linked to '${link_dir}/${bin_file_name}'"
    return 0
  fi

  # ask in case of ordinary user installation not in a system binary directory
  case "$PATH" in
  */usr/local/bin*)
    ;;
  *)
    return 0
    ;;
  esac
  # Check for existing symlink or .nosymlink file
  if [ -L "/usr/local/bin/${bin_file_name}" ] && \
      same_file "/usr/local/bin/${bin_file_name}" "${output_dir}/${bin_file_name}"; then
    symlink_exists='1'
  fi

  if [ "${symlink_exists}" -eq 1 ]; then
    log "A symlink exists. No further action taken."
  elif [ -f "${output_dir}/.nosymlink" ]; then
    log "'.nosymlink' file exists in the installation directory. No further action taken."
  else
    # Ask user about linking the binary to /usr/local/bin
    ask_user "Would you like to create a link in /usr/local/bin to the executable? [y/N] "
    case "$response" in
    [yY]|[yY][eE][sS])
      # Create a symlink with an absolute path
      absolute_path="$(resolve_symlinks "${output_dir}/${bin_file_name}")"
      if ln -sf "${absolute_path}" /usr/local/bin/ 2> /dev/null || [ "$is_root" -eq 0 ] && sudo ln -sf "${absolute_path}" /usr/local/bin/; then
        symlink_exists='1'
        log "Binary has been linked to '/usr/local/bin'"
      else
        log "Failed to link the binary to '/usr/local/bin'"
      fi
      ;;
    ""|[Nn][Oo]|[Nn])
      # Create a .nosymlink file in the installation directory
      touch "${output_dir}/.nosymlink"
      log "'.nosymlink' file has been created in the installation directory"
      ;;
    *)
      log "Invalid response. No further action taken."
      ;;
    esac
  fi
}

# Function remove_downloaded_package deletes the archive only if it was downloaded and not transferred.
remove_downloaded_package() {
  if [ -z "$archive_path" ]; then
    $remove_command "$pkg_name"
  fi
}

# Function unpack unpacks the passed archive depending on it's extension.
unpack() {
  log "Unpacking package from '$pkg_name' into '$output_dir'"
  if ! mkdir -p "$output_dir"
  then
    error_exit "Cannot create directory '$output_dir'"
  fi

  # Extract into a staging directory first, so a failed unpack does not destroy
  # the current installation. The trap covers an interrupted move as well.
  staging_dir="${output_dir}/.install"
  trap 'rm -rf "${output_dir}/.install"' EXIT
  rm -rf "$staging_dir"
  if ! mkdir -p "$staging_dir" || ! tar -C "$staging_dir" -f "$pkg_name" -x -z
  then
    rm -rf "$staging_dir"
    remove_downloaded_package
    error_exit "Cannot unpack '$pkg_name'"
  fi

  remove_downloaded_package
  log "Package has been unpacked successfully"

  # The archive layout is not part of the contract, so check what was actually
  # extracted instead of trusting the file name.
  base_name=$(echo "$pkg_name" | sed -E 's!.*/!!')
  dir_name=$(echo "${base_name}" | sed -E -e 's/(.*)(\.tar\.gz|\.zip)/\1/')
  if [ -f "${staging_dir}/${dir_name}/${bin_file_name}" ]; then
    unpack_dir="${staging_dir}/${dir_name}"
  elif [ -f "${staging_dir}/${bin_file_name}" ]; then
    unpack_dir="$staging_dir"
  else
    error_exit "Unexpected archive layout in '$pkg_name'"
  fi

  # Replace the current installation only after the new payload is checked.
  if [ -f "${output_dir}/${bin_file_name}" ]
  then
    remove_existing
  fi
  if [ -n "$legacy_dir" ]
  then
    remove_legacy_files
  fi

  if type mv > /dev/null 2>&1; then
    mv -f "${unpack_dir}/"* "${output_dir}" || error_exit "Cannot move files from '${unpack_dir}'"
  elif type ln > /dev/null 2>&1; then
    ln -f "${unpack_dir}/"* "${output_dir}" || error_exit "Cannot move files from '${unpack_dir}'"
  else
    error_exit "You need mv or ln for this script to work. Make sure that \"coreutils-mv\" is installed."
  fi
  rm -rf "$staging_dir"
}

# Function unpack unpacks the passed archive depending on it's extension.
check_package() {
  if [ "$uninstall" -eq '1' ]; then
    return 0
  fi

  log "Checking downloaded package '$pkg_name'"
  case "$pkg_ext"
  in
  ('zip')
    if ! unzip "$pkg_name" -t -q
    then
      remove_downloaded_package
      error_exit "Error checking $pkg_name"
    fi
    ;;
  ('tar.gz')
    if ! tar -f "$pkg_name" -z -t > /dev/null
    then
      remove_downloaded_package
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
  if [ "$uninstall" -eq '1' ]; then
    return 0
  fi
  
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

  pkg_name=$(echo "${pkg_name}" | sed -E "s/${bin_file_name}/${bin_file_name}-${version}/")
}

# version_lt returns success (0) if the first version is strictly lower than the second.
# Both arguments are expected in major.minor.patch form; missing parts default to 0.
version_lt() {
  a_major=$(echo "$1" | sed -nE 's/^([0-9]+).*$/\1/p'); [ -z "$a_major" ] && a_major=0
  a_minor=$(echo "$1" | sed -nE 's/^[0-9]+\.([0-9]+).*$/\1/p'); [ -z "$a_minor" ] && a_minor=0
  a_patch=$(echo "$1" | sed -nE 's/^[0-9]+\.[0-9]+\.([0-9]+).*$/\1/p'); [ -z "$a_patch" ] && a_patch=0
  b_major=$(echo "$2" | sed -nE 's/^([0-9]+).*$/\1/p'); [ -z "$b_major" ] && b_major=0
  b_minor=$(echo "$2" | sed -nE 's/^[0-9]+\.([0-9]+).*$/\1/p'); [ -z "$b_minor" ] && b_minor=0
  b_patch=$(echo "$2" | sed -nE 's/^[0-9]+\.[0-9]+\.([0-9]+).*$/\1/p'); [ -z "$b_patch" ] && b_patch=0

  [ "$a_major" -lt "$b_major" ] && return 0
  [ "$a_major" -gt "$b_major" ] && return 1
  [ "$a_minor" -lt "$b_minor" ] && return 0
  [ "$a_minor" -gt "$b_minor" ] && return 1
  [ "$a_patch" -lt "$b_patch" ] && return 0
  return 1
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

  set_is_root
  set_os
  if [ "$uninstall" -ne '1' ]
  then
    check_macos_version
  fi
  set_cpu
  check_out_dir

  pkg_ext='tar.gz'
  if [ -n "$archive_path" ]; then
    pkg_name="$archive_path"
    need_download='0'
    log "Use users archive: $archive_path"
    return
  fi

  parse_version

  if [ "$os" = 'macos' ]
  then
    pkg_name="${bin_file_name}-macos.${pkg_ext}"
  else
    pkg_name="${bin_file_name}-${os}-${cpu}.${pkg_ext}"
  fi
  apply_version
  # Releases before 1.8.0 use the v${version}-${channel} tag format.
  if version_lt "$version" '1.8.0'
  then
    release_tag="v${version}-${channel}"
  else
    release_tag="v${version}"
  fi
  url="https://github.com/AdguardTeam/AdGuardVPNCLI/releases/download/${release_tag}/${pkg_name}"

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
  if [ ! -f "${output_dir}/${bin_file_name}" ]
  then
    error_exit "AdGuard VPN is not installed in '${output_dir}'. Please specify the correct installation directory"
  fi

  # Check if vpn is running
  if pgrep -x "${bin_file_name}" > /dev/null
  then
    log 'AdGuard VPN is running. Stopping it...'
    "${output_dir}/${bin_file_name}" disconnect
  fi

  binary_path="$(readlink -f "${output_dir}/${bin_file_name}" 2>/dev/null)" ||
    binary_path="${output_dir}/${bin_file_name}"

  remove_existing

  # A staging directory left by an interrupted update would keep the install
  # directory from being removed below.
  rm -rf "${output_dir}/.install"

  # Check if the directory is empty
  if [ -z "$(ls -A "${output_dir}")" ]
  then
    set +e
    log "Remove empty directory: '${output_dir}'"
    rmdir "${output_dir}" 2>/dev/null
    if [ $? -eq 1 ];
    then
      if [ "$is_root" -eq 0 ]; then
        echo "Starting sudo to remove '${output_dir}'"
        if sudo rmdir "${output_dir}"; then
          log "Empty directory '${output_dir}' has been removed"
        else
          error_exit "Failed to remove empty directory '${output_dir}' with sudo"
        fi
      else
        error_exit "Failed to remove empty directory '${output_dir}'"
      fi
    else
      log "Empty directory '${output_dir}' has been removed"
    fi
    set -e
  fi

  # Remove the symlink created by the installer, if any.
  for dir in $system_bin_dirs
  do
    [ -L "${dir}/${bin_file_name}" ] || continue
    link_target="$(readlink "${dir}/${bin_file_name}")"
    if [ "$link_target" = "${output_dir}/${bin_file_name}" ] || [ "$link_target" = "$binary_path" ]
    then
      log "Remove symlink from '${dir}'"
      if [ "$is_root" -eq 1 ] || [ -w "$dir" ]; then
        rm -f "${dir}/${bin_file_name}"
      else
        echo "Starting sudo to remove '${dir}/${bin_file_name}'"
        sudo rm -f "${dir}/${bin_file_name}"
      fi || {
        echo "Failed to remove symlink from '${dir}'" 1>&2
        symlink_removal_failed='1'
      }
    fi
  done

  # Notify about service files
  echo "Service files are not removed. You can remove them manually if needed from: "
  if [ $os = 'linux' ]
  then
    echo "    '${XDG_DATA_HOME:-~/.local/share}/${bin_file_name}'"
  elif [ $os = 'macos' ]
  then
    echo "    '~/Library/Application Support/${bin_file_name}'"
  fi

  if [ "$symlink_removal_failed" -eq '1' ]
  then
    error_exit 'AdGuard VPN has been uninstalled, but its symlink could not be removed'
  fi

  echo 'AdGuard VPN has been uninstalled successfully'
}

# Function remove_existing removes the existing package from the output directory before installing a new one.
remove_existing() {
  log 'Removing existing package...'
  # Remove executable file
  rm -f "${output_dir}/${bin_file_name}"
  log "'${bin_file_name}' has been removed from '${output_dir}'"
  # Remove .sig file
  rm -f "${output_dir}/${bin_file_name}.sig"
  log "'${bin_file_name}.sig' has been removed from '${output_dir}'"
  # Remove bash-completion.sh
  rm -f "${output_dir}/bash-completion.sh"
  log "'bash-completion.sh' has been removed from '${output_dir}'"
  # Remove .nosymlink file
  rm -f "${output_dir}/.nosymlink"
}

# Function remove_legacy_files removes the files left in a system binary
# directory by a previous installation into that directory.  The binary itself
# is replaced with a symlink later.
remove_legacy_files() {
  set -- \
    "${legacy_dir}/${bin_file_name}.sig" \
    "${legacy_dir}/bash-completion.sh" \
    "${legacy_dir}/.nosymlink"

  if [ "$is_root" -eq 1 ] || [ -w "$legacy_dir" ]; then
    rm -f "$@"
  else
    sudo rm -f "$@"
  fi || echo "Warning: failed to remove files of the previous installation from '${legacy_dir}'" 1>&2
}

# Function checks if the package is already present in the output directory.
handle_existing() {
  if [ "$uninstall" -eq '1' ]
  then
    handle_uninstall
    exit 0
  fi

  # A previous version could be installed directly into a system binary
  # directory, before such installations were redirected to /opt.
  if [ -n "$link_dir" ] && [ -f "${link_dir}/${bin_file_name}" ] && [ ! -L "${link_dir}/${bin_file_name}" ]
  then
    legacy_dir="$link_dir"
  fi

  if [ ! -f "${output_dir}/${bin_file_name}" ] && [ -z "$legacy_dir" ]
  then
    return
  fi

  log "Package ${bin_file_name} is already present in '${legacy_dir:-$output_dir}'"
  PIDFILE=
  # Check if vpn is running
  if [ $os = 'linux' ]
  then
    PIDFILE="${XDG_DATA_HOME:-$HOME/.local/share}/${bin_file_name}/vpn.pid"
  elif [ $os = 'macos' ]
  then
    PIDFILE="$HOME/Library/Application Support/${bin_file_name}/vpn.pid"
  fi
  if [ -f "$PIDFILE" ] && pgrep -F "$PIDFILE" > /dev/null
  then
    error_exit "AdGuard VPN is running. Please, stop it before installing"
  fi
}

# Function download downloads the package from the url.
download() {
  if [ "$uninstall" -eq '1' ]; then
    return 0
  fi

  if [ "$need_download" -eq '0' ]; then
    return
  fi

  log "Downloading AdGuard VPN package: $url"

  # Temporary file name for testing file creation
  tmp_file="tmp_file_check_$$"

  # Check if we can write to the current directory by creating a temporary file
  if ! touch "$tmp_file" > /dev/null 2>&1; then
    if [ "$is_root" -eq 0 ]; then
      ask_user "Cannot create file in the current directory. Try downloading as root? [y/N] "
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
      log "Cannot create file in the current directory."
      error_exit "Cannot proceed without file creation rights."
    fi
  else
    # Cleanup the temporary file
    rm "$tmp_file"
    if ! curl -fsSL "$url" -o "$pkg_name"; then
      error_exit "Failed to download $pkg_name: $?"
    fi
  fi

  log "AdGuard VPN package has been downloaded successfully"
}

report_success() {
  echo
  echo "AdGuard VPN has been installed successfully!"
  echo
  echo "You can use it by running command:"
  if [ "$symlink_exists" -eq '1' ]
  then
    echo "    ${bin_file_name} --help"
  else
    echo "    ${output_dir}/${bin_file_name} --help"
  fi

  echo
  case ${SHELL:-sh} in
  *zsh)
    echo "To enable bash-completion, please add the following line to your shell configuration (~/.zshrc):"
    echo "    [ -s \"${output_dir}/bash-completion.sh\" ] && \. \"${output_dir}/bash-completion.sh\""
    ;;
  *bash*)
    echo "To enable bash-completion, please add the following line to your shell configuration (~/.bashrc):"
    echo "    [ -s \"${output_dir}/bash-completion.sh\" ] && \. \"${output_dir}/bash-completion.sh\""
    ;;
  esac
}

post_install() {
  if [ -z "$version" ]; then
    src=""
    if [ -n "${pkg_name:-}" ]; then
      src="$pkg_name"
    elif [ -n "${archive_path:-}" ]; then
      src="$archive_path"
    fi
    if [ -n "$src" ]; then
      version=$(echo "$src" | sed -nE "s@.*${bin_file_name}-([0-9]+\.[0-9]+\.[0-9]+).*@\\1@p")
    fi
  fi
  min_major=1
  min_minor=6
  min_patch=10

  v_major=$(echo "$version" | sed -nE 's/^([0-9]+).*$/\1/p')
  v_minor=$(echo "$version" | sed -nE 's/^[0-9]+\.([0-9]+).*$/\1/p')
  v_patch=$(echo "$version" | sed -nE 's/^[0-9]+\.[0-9]+\.([0-9]+).*$/\1/p')
  if [ -z "$v_major" ]; then
    return 0
  fi
  [ -z "$v_minor" ] && v_minor=0
  [ -z "$v_patch" ] && v_patch=0

  if [ "$v_major" -lt "$min_major" ] || { [ "$v_major" -eq "$min_major" ] && [ "$v_minor" -lt "$min_minor" ]; } || { [ "$v_major" -eq "$min_major" ] && [ "$v_minor" -eq "$min_minor" ] && [ "$v_patch" -lt "$min_patch" ]; } ; then
    return 0
  fi

  local args=""
  case "$auto_answer" in
  [Yy]) args="-y" ;;
  [Nn]) args="-n" ;;
  esac
  if ! "${output_dir}/${bin_file_name}" post_install $args; then
    echo "Post-installation step failed"
    exit 1
  fi
}

# Entrypoint

bin_file_name='adguardvpn-cli'
system_bin_dirs='/bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin'
output_dir=''
channel='beta'
verbose='1'
cpu=''
os=''
version='1.8.3'
uninstall='0'
remove_command="rm -f"
symlink_exists='0'
link_dir=''
legacy_dir=''
symlink_removal_failed='0'
is_root='0'
archive_path=''
auto_answer=''
need_download='1'

parse_opts "$@"

configure
download

check_package

handle_existing

unpack
create_symlink
post_install
verify_hint

report_success
