#!/bin/sh

echo "Starting LED Status Monitor Installation..."

# Change directory to /root
cd /root || { echo "Failed to change directory to /root. Exiting."; exit 1; }
echo "Working directory changed to $(pwd)"
echo ""

# --- Master Installation Menu ---
echo "=========================================="
echo " Installation Options"
echo "=========================================="
echo "1) Express Install (Accept defaults, Auto Multi-WAN)"
echo "   - Internet LED: Blue"
echo "   - 100M Warnings: ENABLED (Green LED)"
echo "   - Script Path : /root/led_status.sh"
echo "2) Custom Install  (Choose LEDs and features)"
echo "3) Cancel / Deny   (Abort installation)"
printf "Choose an option [1/2/3] (Default: 1): "

# Read directly from the terminal to support 'curl | bash' execution
read -r install_mode < /dev/tty

if [ "$install_mode" = "3" ]; then
    echo ""
    echo "Installation cancelled by user. Exiting."
    exit 0
elif [ "$install_mode" = "2" ]; then
    echo ""
    # --- 100M Warning Prompt ---
    echo "=========================================="
    echo " 100M Port Warning Feature"
    echo "=========================================="
    echo "Do you want to flash a warning LED if a port drops to 100Mbps?"
    printf "Enable 100M warning? [y/n] (Default: y): "
    read -r warn_choice < /dev/tty

    if [ "$warn_choice" = "n" ] || [ "$warn_choice" = "N" ]; then
        ENABLE_WARN=0
        echo "-> 100M Port Warnings DISABLED."
        echo ""
        echo "=========================================="
        echo " LED Configuration"
        echo "=========================================="
        echo "Which LED should indicate the Internet is WORKING?"
        echo "1) Blue"
        echo "2) Green"
        printf "Enter 1 or 2 [Default: 1]: "
        
        read -r led_choice < /dev/tty
        
        if [ "$led_choice" = "2" ]; then
            LED_NET="green"
            LED_WARN="blue" # Unused
            echo "-> Selected: GREEN for Internet."
        else
            LED_NET="blue"
            LED_WARN="green" # Unused
            echo "-> Selected: BLUE for Internet."
        fi
    else
        ENABLE_WARN=1
        echo "-> 100M Port Warnings ENABLED."
        echo ""
        echo "=========================================="
        echo " LED Configuration"
        echo "=========================================="
        echo "Which LED should indicate the Internet is WORKING?"
        echo "1) Blue  (Green will show 100M warnings)"
        echo "2) Green (Blue will show 100M warnings)"
        printf "Enter 1 or 2 [Default: 1]: "
        
        read -r led_choice < /dev/tty
        
        if [ "$led_choice" = "2" ]; then
            LED_NET="green"
            LED_WARN="blue"
            echo "-> Selected: GREEN for Internet, BLUE for Warnings."
        else
            LED_NET="blue"
            LED_WARN="green"
            echo "-> Selected: BLUE for Internet, GREEN for Warnings."
        fi
    fi
    echo "=========================================="
    echo ""

    # --- Script Location Prompt ---
    echo "=========================================="
    echo " Script Location"
    echo "=========================================="
    printf "Enter full path for the script [Default: /root/led_status.sh]: "

    read -r user_script_path < /dev/tty

    if [ -z "$user_script_path" ]; then
        SCRIPT_PATH="/root/led_status.sh"
    else
        SCRIPT_PATH="$user_script_path"
    fi
    echo "-> Script will be saved to: $SCRIPT_PATH"
    echo "=========================================="
    echo ""
else
    # Express Install (Defaults)
    ENABLE_WARN=1
    LED_NET="blue"
    LED_WARN="green"
    SCRIPT_PATH="/root/led_status.sh"
    echo ""
    echo "-> Proceeding with Express Install (Defaults applied)."
    echo ""
fi

# Ensure the target directory exists
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
mkdir -p "$SCRIPT_DIR"

# 1. Clean up default Router Startup LED behaviors (Disables conflicts)
echo "Cleaning up default startup LED behaviors to prevent conflicts..."

# 1A. Permanently neutralize custom /etc/init.d/wan-led script
if [ -f "/etc/init.d/wan-led" ]; then
    echo "-> Disabling and stopping custom /etc/init.d/wan-led startup script..."
    /etc/init.d/wan-led disable >/dev/null 2>&1
    /etc/init.d/wan-led stop >/dev/null 2>&1
    
    # Strip executable permissions so the router cannot ever run it again
    chmod -x /etc/init.d/wan-led
    echo "-> Executable permissions removed from wan-led."
    
    # Override the red LED hardcode left behind by its stop command
    echo "-> Clearing residual LED states left by wan-led..."
    for color in red green blue; do
        if [ -d "/sys/class/leds/${color}:status" ]; then
            echo none > "/sys/class/leds/${color}:status/trigger" 2>/dev/null
            echo 0 > "/sys/class/leds/${color}:status/brightness" 2>/dev/null
        fi
    done
fi

# 1B. Remove default OpenWrt UCI configurations that fight for these specific LEDs
while uci -q show system | grep -E "\.sysfs='?(blue:status|red:status|green:status)'?" >/dev/null; do
    cfg=$(uci -q show system | grep -E "\.sysfs='?(blue:status|red:status|green:status)'?" | head -n 1 | cut -d. -f2)
    echo "-> Removing default UCI LED config: system.$cfg"
    uci delete "system.$cfg"
done
uci commit system
/etc/init.d/led reload >/dev/null 2>&1

# 2. Install Dependencies (OpenWrt opkg & apk)
if command -v opkg > /dev/null 2>&1; then
    echo "opkg (OpenWrt classic) detected. Updating..."
    opkg update
    echo "Ensuring coreutils-timeout is installed..."
    opkg install coreutils-timeout
elif command -v apk > /dev/null 2>&1; then
    echo "apk (OpenWrt 24.x+) detected. Updating..."
    apk update
    echo "Ensuring coreutils is installed for the timeout command..."
    apk add coreutils
else
    echo "Warning: Neither opkg nor apk found. Assuming 'timeout' is natively available."
fi

# 3. Write the script payload
echo "Writing payload to $SCRIPT_PATH..."

# Write the user-selected variables (EOF without quotes evaluates variables)
cat << EOF > "$SCRIPT_PATH"
#!/bin/sh

NET_LED="/sys/class/leds/${LED_NET}:status"
WARN_LED="/sys/class/leds/${LED_WARN}:status"
DOWN_LED="/sys/class/leds/red:status"
ENABLE_WARN=${ENABLE_WARN}
EOF

# Append the rest of the script logic ('EOF' with quotes protects script variables)
cat << 'EOF' >> "$SCRIPT_PATH"
TARGET="1.1.1.1"

# Initialize 100M warning flag
PORT_WARNING=0

if [ "$ENABLE_WARN" -eq 1 ]; then
    # Monitored ports
    PORTS="wan lan1 lan2 lan3 lan4"

    for port in $PORTS; do
        if [ -d "/sys/class/net/$port" ]; then
            SPEED=$(cat "/sys/class/net/$port/speed" 2>/dev/null)
            OPERSTATE=$(cat "/sys/class/net/$port/operstate" 2>/dev/null)

            if [ "$OPERSTATE" = "up" ] && [ "$SPEED" = "100" ]; then
                PORT_WARNING=1
                break
            fi
        fi
    done
fi

# --- LED Logic Tree ---
if [ "$PORT_WARNING" -eq 1 ]; then
    # 1. Clear old triggers
    echo none > "$NET_LED/trigger"
    echo none > "$DOWN_LED/trigger"

    # 2. Turn off unrelated LEDs
    echo 0 > "$NET_LED/brightness"
    echo 0 > "$DOWN_LED/brightness"

    # 3. CRITICAL SPEED DROP: Set Warning LED to FLASH
    echo timer > "$WARN_LED/trigger"
else
    # Ports are healthy or warning is disabled: Clear the warning flashing state
    if [ "$ENABLE_WARN" -eq 1 ]; then
        echo none > "$WARN_LED/trigger"
        echo 0 > "$WARN_LED/brightness"
    fi

    # --- Auto-Detect Multi-WAN vs Single-WAN ---
    EXPECTED_WANS=0
    ACTIVE_WANS=0

    # Method 1: Check if mwan3 is installed and tracking interfaces
    if command -v mwan3 >/dev/null 2>&1; then
        EXPECTED_WANS=$(mwan3 status 2>/dev/null | grep -E -c "interface.*is")
        ACTIVE_WANS=$(mwan3 status 2>/dev/null | grep -E -c "interface.*is online")
    else
        # Method 2: Native OpenWrt Firewall Zone detection (ubus)
        wan_zone=$(uci show firewall 2>/dev/null | grep -E "\.name='wan'" | head -n 1 | cut -d. -f2)
        if [ -n "$wan_zone" ]; then
            wan_interfaces=$(uci -q get firewall.$wan_zone.network)
            for iface in $wan_interfaces; do
                # Ignore duplicate logical tracking for IPv6 (e.g. wan6)
                case "$iface" in *6) continue ;; esac
                
                EXPECTED_WANS=$((EXPECTED_WANS + 1))
                
                # Fetch the dynamic physical device (e.g. pppoe-wan, eth1)
                dev=$(ubus call network.interface.$iface status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
                
                if [ -n "$dev" ] && [ -d "/sys/class/net/$dev" ]; then
                    if ping -c 1 -W 3 -I "$dev" "$TARGET" >/dev/null 2>&1; then
                        ACTIVE_WANS=$((ACTIVE_WANS + 1))
                    fi
                fi
            done
        fi
    fi

    # Fallback: If no WAN interfaces detected, default to standard single ping check
    if [ "$EXPECTED_WANS" -eq 0 ]; then
        EXPECTED_WANS=1
        if ping -c 1 -W 3 "$TARGET" > /dev/null 2>&1; then
            ACTIVE_WANS=1
        fi
    fi

    # --- Connectivity LED Enforcement ---
    if [ "$EXPECTED_WANS" -gt 1 ]; then
        # MULTI-WAN MODE DETECTED
        if [ "$ACTIVE_WANS" -eq "$EXPECTED_WANS" ]; then
            # All WANs UP
            echo none > "$DOWN_LED/trigger"
            echo 0 > "$DOWN_LED/brightness"
            echo none > "$NET_LED/trigger"
            echo 255 > "$NET_LED/brightness"
        elif [ "$ACTIVE_WANS" -gt 0 ]; then
            # Degraded / Failover Mode (One UP, One DOWN)
            echo none > "$DOWN_LED/trigger"
            echo 0 > "$DOWN_LED/brightness"
            echo timer > "$NET_LED/trigger"
        else
            # All WANs DOWN
            echo none > "$NET_LED/trigger"
            echo 0 > "$NET_LED/brightness"
            echo timer > "$DOWN_LED/trigger"
        fi
    else
        # SINGLE WAN MODE DETECTED
        if [ "$ACTIVE_WANS" -gt 0 ]; then
            # Internet UP
            echo none > "$DOWN_LED/trigger"
            echo 0 > "$DOWN_LED/brightness"
            echo none > "$NET_LED/trigger"
            echo 255 > "$NET_LED/brightness"
        else
            # Internet DOWN
            echo none > "$NET_LED/trigger"
            echo 0 > "$NET_LED/brightness"
            echo timer > "$DOWN_LED/trigger"
        fi
    fi
fi
EOF

# 4. Set Permissions
chmod +x "$SCRIPT_PATH"
echo "Set $SCRIPT_PATH as executable."

# 5. Apply Crontab Entries
echo "Configuring cron schedules..."
TMP_CRON="/tmp/led_cron_tmp"

# Clean up crontab: 
# Remove the designated block (for clean future updates) and remove any exact matches of this script path.
crontab -l 2>/dev/null | \
  sed '/# --- BEGIN LED MONITOR ---/,/# --- END LED MONITOR ---/d' | \
  grep -v "$SCRIPT_PATH" > "$TMP_CRON"

# Append the new, cleanly blocked cron jobs
echo "# --- BEGIN LED MONITOR ---" >> "$TMP_CRON"
echo "* * * * * timeout 25 /bin/sh $SCRIPT_PATH >/dev/null 2>&1" >> "$TMP_CRON"
echo "* * * * * sleep 30 && timeout 25 /bin/sh $SCRIPT_PATH >/dev/null 2>&1" >> "$TMP_CRON"
echo "# --- END LED MONITOR ---" >> "$TMP_CRON"

# Install new cron and clean up
crontab "$TMP_CRON"
rm "$TMP_CRON"

# Restart cron service (OpenWrt)
if [ -x "/etc/init.d/cron" ]; then
    /etc/init.d/cron restart
    echo "Cron service restarted."
fi

# Run it once immediately to set the correct state without waiting 30 seconds
/bin/sh "$SCRIPT_PATH" &

echo "Installation complete! The script is dynamically monitoring your WAN setup in the background."
