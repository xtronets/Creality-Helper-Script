#!/bin/sh

set -e

function moonraker_nginx_message(){
  top_line
  title 'Moonraker and Nginx' "${yellow}"
  inner_line
  hr
  echo -e " │ ${cyan}Moonraker is a Python 3 based web server that exposes APIs   ${white}│"
  echo -e " │ ${cyan}with which client applications may use to interact with      ${white}│"
  echo -e " │ ${cyan}Klipper firmware.                                            ${white}│"
  echo -e " │ ${cyan}Nginx is a web server that can also be used as a reverse     ${white}│" 
  echo -e " │ ${cyan}proxy, load balancer, mail proxy and HTTP cache.             ${white}│"
  hr
  bottom_line
}

function install_moonraker_nginx(){
  moonraker_nginx_message
  local yn
  while true; do
    install_msg "Moonraker and Nginx" yn
    case "${yn}" in
      Y|y)
        echo -e "${white}"
        echo -e "Info: Extracting Moonraker files..."
        tar -xvf "$MOONRAKER_URL1" -C "$USR_DATA"
        echo -e "Info: Extracting Nginx files..."
        tar -xvf "$NGINX_URL" -C "$USR_DATA"
        echo -e "Info: Copying services files..."
        if [ ! -f "$INITD_FOLDER"/S50nginx ]; then
          cp "$NGINX_SERVICE_URL" "$INITD_FOLDER"/S50nginx
          chmod +x "$INITD_FOLDER"/S50nginx
        fi
        if [ ! -f "$INITD_FOLDER"/S56moonraker_service ]; then
          cp "$MOONRAKER_SERVICE_URL" "$INITD_FOLDER"/S56moonraker_service
          chmod +x "$INITD_FOLDER"/S56moonraker_service
        fi
        echo -e "Info: Copying Moonraker configuration file..."
        if [ -f "$KLIPPER_CONFIG_FOLDER"/moonraker.conf ]; then
          rm -f "$KLIPPER_CONFIG_FOLDER"/moonraker.conf
        fi
        cp "$MOONRAKER_URL2" "$KLIPPER_CONFIG_FOLDER"/moonraker.conf
        if [ -f "$PRINTER_DATA_FOLDER"/moonraker.asvc ]; then
          rm -f "$PRINTER_DATA_FOLDER"/moonraker.asvc
        fi
        cp "$MOONRAKER_URL3" "$PRINTER_DATA_FOLDER"/moonraker.asvc
        echo -e "Info: Pinning Moonraker version in moonraker.conf..."
        pin_moonraker_version
        install_moonraker_ipv4_fix
        echo -e "Info: Installing Supervisor Lite..."
        chmod 755 "$SUPERVISOR_URL"
        ln -sf "$SUPERVISOR_URL" "$SUPERVISOR_FILE"
        echo -e "Info: Installing Host Controls Support..."
        chmod 755 "$SUDO_URL"
        chmod 755 "$SYSTEMCTL_URL"
        ln -sf "$SUDO_URL" "$SUDO_FILE"
        ln -sf "$SYSTEMCTL_URL" "$SYSTEMCTL_FILE"
        echo -e "Info: Starting Nginx service..."
        start_nginx
        echo -e "Info: Starting Moonraker service..."
        start_moonraker
        ok_msg "Moonraker and Nginx have been installed successfully!"
        return;;
      N|n)
        error_msg "Installation canceled!"
        return;;
      *)
        error_msg "Please select a correct choice!";;
    esac
  done
}

function remove_moonraker_nginx(){
  moonraker_nginx_message
  local yn
  while true; do
    remove_msg "Moonraker and Nginx" yn
    case "${yn}" in
      Y|y)
        echo -e "${white}"
        echo -e "Info: Stopping Moonraker and Nginx services..."
        stop_moonraker
        stop_nginx
        echo -e "Info: Removing files..."
        rm -f "$INITD_FOLDER"/S50nginx
        rm -f "$INITD_FOLDER"/S56moonraker_service
        rm -f "$KLIPPER_CONFIG_FOLDER"/moonraker.conf
        rm -f "$KLIPPER_CONFIG_FOLDER"/.moonraker.conf.bkp
        rm -f "$PRINTER_DATA_FOLDER"/.moonraker.uuid
        rm -f "$PRINTER_DATA_FOLDER"/moonraker.asvc
        rm -rf "$PRINTER_DATA_FOLDER"/comms
        rm -rf "$NGINX_FOLDER"
        rm -rf "$MOONRAKER_FOLDER"
        rm -f "$SUPERVISOR_FILE"
        rm -f "$SUDO_FILE"
        rm -f "$SYSTEMCTL_FILE"
        ok_msg "Moonraker and Nginx have been removed successfully!"
        return;;
      N|n)
        error_msg "Deletion canceled!"
        return;;
      *)
        error_msg "Please select a correct choice!";;
    esac
  done
}

MOONRAKER_PINNED_COMMIT="b559b9a81161f958a43c2f527b6ad96f73310d5d"

function install_moonraker_ipv4_fix(){
  # K1C kernel has no IPv6: make Moonraker resolve hostnames to IPv4 only
  local sp
  for sp in "$MOONRAKER_FOLDER"/moonraker-env/lib/python3*/site-packages; do
    [ -d "$sp" ] && cp -f "$HELPER_SCRIPT_FOLDER"/files/moonraker/sitecustomize.py "$sp"/sitecustomize.py
  done
}

function pin_moonraker_version(){
  # Moonraker >= v0.11 officially requires Python 3.10, the K1C has 3.8.
  # Pin the update manager to the bundled, tested commit.
  if grep -q "^\[update_manager moonraker\]" "$MOONRAKER_CFG"; then
    if sed -n '/^\[update_manager moonraker\]/,/^\[/p' "$MOONRAKER_CFG" | grep -q "^pinned_commit:"; then
      sed -i "/^\[update_manager moonraker\]/,/^\[/ s/^pinned_commit:.*/pinned_commit: ${MOONRAKER_PINNED_COMMIT}/" "$MOONRAKER_CFG"
    else
      sed -i "/^\[update_manager moonraker\]/a pinned_commit: ${MOONRAKER_PINNED_COMMIT}" "$MOONRAKER_CFG"
    fi
  else
    printf '\n[update_manager moonraker]\npinned_commit: %s\n' "$MOONRAKER_PINNED_COMMIT" >> "$MOONRAKER_CFG"
  fi
}

function wait_for_moonraker(){
  local i=0
  while [ $i -lt 30 ]; do
    if "$CURL" -s -o /dev/null --connect-timeout 2 http://127.0.0.1:7125/server/info; then
      return 0
    fi
    sleep 3
    i=$((i + 1))
  done
  return 1
}

function update_moonraker_offline_message(){
  top_line
  title 'Update Moonraker (offline)' "${yellow}"
  inner_line
  hr
  echo -e " │ ${cyan}Replaces Moonraker with the version bundled in this script,  ${white}│"
  echo -e " │ ${cyan}without downloading anything. Your moonraker.conf, database  ${white}│"
  echo -e " │ ${cyan}and history are kept. The previous version is kept in        ${white}│"
  echo -e " │ ${cyan}/usr/data/moonraker.bak and restored automatically if the    ${white}│"
  echo -e " │ ${cyan}new version doesn't start.                                   ${white}│"
  hr
  bottom_line
}

function update_moonraker_offline(){
  update_moonraker_offline_message
  local yn
  while true; do
    read -p "${white} Are you sure you want to update ${green}Moonraker ${white}? (${yellow}y${white}/${yellow}n${white}): ${yellow}" yn
    case "${yn}" in
      Y|y)
        echo -e "${white}"
        local free_kb
        free_kb=$(df -k "$USR_DATA" | awk 'NR==2 {print $4}')
        if [ "${free_kb:-0}" -lt 102400 ]; then
          error_msg "Not enough free space in $USR_DATA (100 MB needed)!"
          return
        fi
        local had_timelapse=0
        if [ -e "$TIMELAPSE_FILE" ] || [ -L "$TIMELAPSE_FILE" ]; then
          had_timelapse=1
        fi
        echo -e "Info: Stopping Moonraker service..."
        stop_moonraker
        echo -e "Info: Backing up current Moonraker to ${MOONRAKER_FOLDER}.bak..."
        rm -rf "${MOONRAKER_FOLDER}.bak"
        mv "$MOONRAKER_FOLDER" "${MOONRAKER_FOLDER}.bak"
        echo -e "Info: Extracting bundled Moonraker..."
        set +e
        tar -xf "$MOONRAKER_URL1" -C "$USR_DATA"
        local tar_rc=$?
        set -e
        if [ $tar_rc -ne 0 ]; then
          echo -e "Info: Extraction failed, restoring previous version..."
          rm -rf "$MOONRAKER_FOLDER"
          mv "${MOONRAKER_FOLDER}.bak" "$MOONRAKER_FOLDER"
          start_moonraker
          error_msg "Moonraker update failed, previous version restored!"
          return
        fi
        if [ $had_timelapse -eq 1 ]; then
          echo -e "Info: Restoring Moonraker Timelapse component..."
          ln -sf "$TIMELAPSE_URL1" "$TIMELAPSE_FILE"
        fi
        echo -e "Info: Pinning Moonraker version in moonraker.conf..."
        pin_moonraker_version
        install_moonraker_ipv4_fix
        echo -e "Info: Starting Moonraker service..."
        start_moonraker
        echo -e "Info: Waiting for Moonraker to respond (up to 90 s)..."
        if wait_for_moonraker; then
          ok_msg "Moonraker has been updated successfully!"
          echo -e "   Previous version kept in ${yellow}${MOONRAKER_FOLDER}.bak${white}, remove it with:"
          echo -e "   ${yellow}rm -rf ${MOONRAKER_FOLDER}.bak${white}"
          echo
        else
          echo -e "Info: Moonraker didn't start, restoring previous version..."
          stop_moonraker
          rm -rf "$MOONRAKER_FOLDER"
          mv "${MOONRAKER_FOLDER}.bak" "$MOONRAKER_FOLDER"
          start_moonraker
          error_msg "Moonraker update failed, previous version restored! Check /usr/data/printer_data/logs/moonraker.log"
        fi
        return;;
      N|n)
        error_msg "Update canceled!"
        return;;
      *)
        error_msg "Please select a correct choice!";;
    esac
  done
}
