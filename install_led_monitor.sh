#!/bin/sh

echo "Starting LED Status Monitor Installation..."

# Change directory to /root
cd /root || { echo "Failed to change directory to /root. Exiting."; exit 1; }
echo "Working directory changed to $(pwd)"
echo ""

# ==========================================
# 1. INTELLIGENT WAN DETECTION
# ==========================================
echo "Detecting WAN interfaces (ignoring VPNs)..."
DETECTED_WANS=""

# Find all firewall zones that have masquerading enabled (Standard WAN zones)
for zone in $(uci show firewall 2>/dev/null | grep "\.masq='1'" | cut -d. -f2); do
    networks=$(uci -q get firewall.$zone.network)
    for net in $networks; do
        # Ignore IPv6 duplicate logical interfaces
        case "$net" in *6) continue ;; esac
        
        # Get the actual physical/virtual device (e.g., pppoe-wan)
        dev=$(ubus call network.interface.$net status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
        
        # Fallback if ubus doesn't return l3_device but network name is the device name
        [ -z "$dev" ] && [ -d "/sys/class/net/$net" ] && dev="$net"

        if [ -n "$dev" ]; then
            # IGNORE VPN INTERFACES
            if echo "$dev" | grep -qE '^(wg|tun|tap|tailscale|zerotier|zt)'; then
                continue
            fi
            DETECTED_WANS="$DETECTED_WANS $dev"
        fi
    done
done

# Remove duplicates and clean spaces
DETECTED_WANS=$(echo "$DETECTED_WANS" | tr ' ' '\n' | sort -u | xargs)
NUM_WANS=$(echo "$DETECTED_WANS" | wc -w)

# --- Master Installation Menu ---
echo "=========================================="
echo " Installation Options"
echo "=========================================="
echo "1) Express Install (Accept all defaults)"
echo "2) Custom Install  (Choose Dual-WAN, LEDs, Features)"
echo "3) Cancel / Deny   (Abort installation)"
printf "Choose an option [1/2/3] (Default: 1): "

read -r install_mode < /dev/tty

if [ "$install_mode" = "3" ]; then
    echo ""
    echo "Installation cancelled by user. Exiting."
    exit 0
elif [ "$install_mode" = "2" ]; then
    echo ""
    # --- Multi-WAN Prompt ---
    echo "=========================================="
    echo " Internet Connection Mode"
    echo "=========================================="
    if [ "$NUM_WANS" -ge 2 ]; then
        echo "Detected Multiple WANs: [ $DETECTED_WANS ]"
        echo "If enabled: Solid LED = All UP | Flashing LED = One UP | Red = All DOWN"
        printf "Enable Dual/Multi-WAN monitoring for these? [y/n] (Default: y): "
        read -r dual_choice < /dev/tty
        
        if [ -z "$dual_choice" ] || [ "$dual_choice" = "y" ] || [ "$dual_choice" = "Y" ]; then
            TARGET_WANS="$DETECTED_WANS"
            echo "-> Multi-WAN Monitoring ENABLED."
        else
            TARGET_WANS=""
            echo "-> Standard Single WAN route tracking selected."
        fi
    elif [ "$NUM_WANS" -eq 1 ]; then
        echo "Detected Single WAN: [ $DETECTED_WANS ]"
        TARGET_WANS="$DETECTED_WANS"
        echo "-> Standard Single WAN route tracking selected."
    else
        echo "Could not auto-detect physical WANs. Will use default route tracking."
        TARGET_WANS=""
    fi
    echo "=========================================="
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
    else
        ENABLE_WARN=1
        echo "-> 100M Port Warnings ENABLED."
    fi
    echo "=========================================="
    echo ""

    # --- LED Configuration Prompt ---
    echo "=========================================="
    echo " LED Configuration"
    echo "=========================================="
    echo "Which LED should indicate the Internet is WORKING?"
    if [ "$ENABLE_WARN" -eq 1 ]; then
        echo "1) Blue  (Green will show 100M warnings)"
        echo "2) Green (Blue will show 100M warnings)"
    else
        echo "1) Blue"
        echo "2) Green"
    fi
    printf "Enter 1 or 2 [Default: 1]: "
    
    read -r led_choice < /dev/tty
    
    if [ "$led_choice" = "2" ]; then
        LED_NET="green"
        LED_WARN="blue"
        echo "-> Selected: GREEN for Internet."
    else
        LED_NET="blue"
        LED_WARN="green"
        echo "-> Selected: BLUE for Internet."
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
    
    # Auto-apply Dual WAN if detected
    if [ "$NUM_WANS" -ge 2 ]; then
        TARGET_WANS="$DETECTED_WANS"
        echo "-> Express: Multi-WAN automatically enabled for [ $TARGET_WANS ]"
    else
        TARGET_WANS=""
    fi
    echo ""
    echo "-> Proceeding with Express Install (Defaults applied)."
    echo ""
fi

# Ensure the target directory exists
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
mkdir -p "$SCRIPT_DIR"

# 2. Clean up default Router Startup LED behaviors (Disables conflicts)
echo "Cleaning up default startup LED behaviors to prevent conflicts..."

# 2A. Permanently neutralize custom /etc/init.d/wan-led script
if [ -f "/etc/init.d/wan-led" ]; then
    echo "-> Disabling and stopping custom /etc/init.d/wan-led startup script..."
    /etc/init.d/wan-led disable >/dev/null 2>&1
    /etc/init.d/wan-led stop >/dev/null 2>&1
    
    # Strip executable permissions so the router cannot ever run it again
    chmod -x /etc/init.d/wan-led
    
    # Override the red LED hardcode left behind by its stop command
    for color in red green blue; do
        if [ -d "/sys/class/leds/${color}:status" ]; then
            echo none > "/sys/class/leds/${color}:status/trigger" 2>/dev/null
            echo 0 > "/sys/class/leds/${color}:status/brightness" 2>/dev/null
        fi
    done
fi

# 2B. Remove default OpenWrt UCI configurations that fight for these specific LEDs
while uci -q show system | grep -E "\.sysfs='?(blue:status|red:status|green:status)'?" >/dev/null; do
    cfg=$(uci -q show system | grep -E "\.sysfs='?(blue:status|red:status|green:status)'?" | head -n 1 | cut -d. -f2)
    uci delete "system.$cfg"
done
uci commit system
/etc/init.d/led reload >/dev/null 2>&1

# 3. Install Dependencies (OpenWrt opkg & apk)
if command -v opkg > /dev/null 2>&1; then
    echo "Updating packages..."
    opkg update >/dev/null 2>&1
    opkg install coreutils-timeout >/dev/null 2>&1
elif command -v apk > /dev/null 2>&1; then
    apk update >/dev/null 2>&1
    apk add coreutils >/dev/null 2>&1
fi

# 4. Write the script payload
echo "Writing payload to $SCRIPT_PATH..."

# Write the user-selected variables
cat << EOF > "$SCRIPT_PATH"
#!/bin/sh

NET_LED="/sys/class/leds/${LED_NET}:status"
WARN_LED="/sys/class/leds/${LED_WARN}:status"
DOWN_LED="/sys/class/leds/red:status"

ENABLE_WARN=${ENABLE_WARN}
TARGET_WANS="${TARGET_WANS}"
EOF

# Append the rest of the script logic
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

    # Check Internet connectivity
    if [ -n "$TARGET_WANS" ]; then
        # --- EXPLICIT INTERFACE CHECKING (Dual/Multi WAN) ---
        EXPECTED_WANS=0
        ACTIVE_WANS=0
        
        for iface in $TARGET_WANS; do
            EXPECTED_WANS=$((EXPECTED_WANS + 1))
            # Safely check if interface currently exists in OS (handles temporary PPPoE drops)
            if [ -d "/sys/class/net/$iface" ]; then
                if ping -c 1 -W 3 -I "$iface" "$TARGET" >/dev/null 2>&1; then
                    ACTIVE_WANS=$((ACTIVE_WANS + 1))
                fi
            fi
        done
        
        if [ "$EXPECTED_WANS" -gt 1 ]; then
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
            # Single Interface fallback behavior
            if [ "$ACTIVE_WANS" -gt 0 ]; then
                echo none > "$DOWN_LED/trigger"
                echo 0 > "$DOWN_LED/brightness"
                echo none > "$NET_LED/trigger"
                echo 255 > "$NET_LED/brightness"
            else
                echo none > "$NET_LED/trigger"
                echo 0 > "$NET_LED/brightness"
                echo timer > "$DOWN_LED/trigger"
            fi
        fi
    else
        # --- STANDARD ROUTING CHECK ---
        if ping -c 1 -W 3 "$TARGET" > /dev/null 2>&1; then
            # Internet is WORKING
            echo none > "$DOWN_LED/trigger"
            echo 0 > "$DOWN_LED/brightness"
            echo none > "$NET_LED/trigger"
            echo 255 > "$NET_LED/brightness"
        else
            # Internet is DOWN
            echo none > "$NET_LED/trigger"
            echo 0 > "$NET_LED/brightness"
            echo timer > "$DOWN_LED/trigger"
        fi
    fi
fi
EOF

# 5. Set Permissions
chmod +x "$SCRIPT_PATH"
echo "Set $SCRIPT_PATH as executable."

# 6. Apply Crontab Entries
echo "Configuring cron schedules..."
TMP_CRON="/tmp/led_cron_tmp"

crontab -l 2>/dev/null | \
  sed '/# --- BEGIN LED MONITOR ---/,/# --- END LED MONITOR ---/d' | \
  grep -v "$SCRIPT_PATH" > "$TMP_CRON"

echo "# --- BEGIN LED MONITOR ---" >> "$TMP_CRON"
echo "* * * * * timeout 25 /bin/sh $SCRIPT_PATH >/dev/null 2>&1" >> "$TMP_CRON"
echo "* * * * * sleep 30 && timeout 25 /bin/sh $SCRIPT_PATH >/dev/null 2>&1" >> "$TMP_CRON"
echo "# --- END LED MONITOR ---" >> "$TMP_CRON"

crontab "$TMP_CRON"
rm "$TMP_CRON"

# Restart cron service
if [ -x "/etc/init.d/cron" ]; then
    /etc/init.d/cron restart >/dev/null 2>&1
fi

# Run it once immediately
/bin/sh "$SCRIPT_PATH" &

echo "Installation complete! The script is now running in the background."
