#!/bin/sh

echo "Starting LED Status Monitor Installation..."

# Change directory to /root
cd /root || { echo "Failed to change directory to /root. Exiting."; exit 1; }
echo "Working directory changed to $(pwd)"
echo ""

# ==========================================
# 1. INTELLIGENT LIVE WAN DETECTION
# ==========================================
echo "Detecting live WAN interfaces (ignoring VPNs)..."
DETECTED_WANS=""
LIVE_INFO=""

for zone in $(uci show firewall 2>/dev/null | grep "\.masq='1'" | cut -d. -f2); do
    networks=$(uci -q get firewall.$zone.network)
    for net in $networks; do
        case "$net" in *6|loopback) continue ;; esac
        
        # Aggressive VPN Name & Protocol Filter
        if echo "$net" | grep -qiE '(vpn|wg|tun|tap|tailscale|zerotier|zt)'; then continue; fi
        proto=$(uci -q get network.$net.proto 2>/dev/null)
        if echo "$proto" | grep -qiE '(wireguard|openvpn|tun|tap)'; then continue; fi
        
        # Add to tracking list
        DETECTED_WANS="$DETECTED_WANS $net"
        
        # Fetch Live Connection Info via Ubus
        is_up=$(ubus call network.interface.$net status 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null)
        ip_addr=$(ubus call network.interface.$net status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
        
        status_text="DOWN"
        [ "$is_up" = "true" ] && status_text="UP"
        [ -n "$ip_addr" ] && status_text="$status_text, IP: $ip_addr"
        
        LIVE_INFO="$LIVE_INFO  - $net: $status_text\n"
    done
done

DETECTED_WANS=$(echo "$DETECTED_WANS" | tr ' ' '\n' | sort -u | xargs)
[ -z "$DETECTED_WANS" ] && DETECTED_WANS="wan"

# Color Prompt Helper Function
prompt_color() {
    local p_text="$1"
    local d_val="$2"
    local d_name="$3"
    printf "%s\n[1=Blue 2=Green 3=Red 4=Yellow 5=Cyan 6=Magenta 7=White] (Default: %s): " "$p_text" "$d_name" >&2
    read -r c < /dev/tty
    [ -z "$c" ] && c=$d_val
    case "$c" in
        1) echo "blue" ;; 2) echo "green" ;; 3) echo "red" ;; 4) echo "yellow" ;;
        5) echo "cyan" ;; 6) echo "magenta" ;; 7) echo "white" ;; *) echo "blue" ;;
    esac
}

# --- Master Installation Menu ---
echo "=========================================="
echo " Installation Options"
echo "=========================================="
echo "1) Express Install (Accept all defaults)"
echo "2) Custom Install  (Choose 7-Color LED mapping, WANs, etc.)"
echo "3) Cancel / Deny   (Abort installation)"
printf "Choose an option [1/2/3] (Default: 1): "

read -r install_mode < /dev/tty

# Initialize defaults
WAN1=""
WAN2=""
WAN1_COLOR="blue"
WAN2_COLOR="green"
ALL_UP_COLOR="cyan"
NET_COLOR="blue"
ENABLE_WARN=1
WARN_COLOR="red"

if [ "$install_mode" = "3" ]; then
    echo ""
    echo "Installation cancelled by user. Exiting."
    exit 0
elif [ "$install_mode" = "2" ]; then
    echo ""
    # --- Multi-WAN Prompt ---
    echo "=========================================="
    echo " Live Internet Connection Status"
    echo "=========================================="
    printf "%b" "$LIVE_INFO"
    echo ""
    echo "Type the names of the interfaces you want to monitor, separated by space."
    printf "WANs to monitor [Default: $DETECTED_WANS]: "
    
    read -r user_wans < /dev/tty
    [ -n "$user_wans" ] && TARGET_WANS="$user_wans" || TARGET_WANS="$DETECTED_WANS"
    
    NUM_WANS=$(echo "$TARGET_WANS" | wc -w)
    echo "=========================================="
    echo ""
    
    # --- Color Mapping ---
    echo "=========================================="
    echo " Advanced LED Color Configuration"
    echo "=========================================="
    if [ "$NUM_WANS" -eq 2 ]; then
        WAN1=$(echo "$TARGET_WANS" | awk '{print $1}')
        WAN2=$(echo "$TARGET_WANS" | awk '{print $2}')
        
        echo "Dual WAN detected. Let's map your LEDs."
        WAN1_COLOR=$(prompt_color "Color to flash when ONLY [$WAN1] is active" "1" "1=Blue")
        WAN2_COLOR=$(prompt_color "Color to flash when ONLY [$WAN2] is active" "2" "2=Green")
        ALL_UP_COLOR=$(prompt_color "Color for SOLID ON when BOTH are active" "5" "5=Cyan")
        
        echo "-> $WAN1 = $WAN1_COLOR | $WAN2 = $WAN2_COLOR | Both = $ALL_UP_COLOR"
    else
        NET_COLOR=$(prompt_color "Which LED color should indicate the Internet is WORKING?" "1" "1=Blue")
        echo "-> Selected: $NET_COLOR for Internet."
    fi
    echo "=========================================="
    echo ""

    # --- 100M Warning Prompt ---
    echo "=========================================="
    echo " 100M Port Warning Feature"
    echo "=========================================="
    printf "Enable 100M port warning? [y/n] (Default: y): "
    read -r warn_choice < /dev/tty

    if [ "$warn_choice" = "n" ] || [ "$warn_choice" = "N" ]; then
        ENABLE_WARN=0
        echo "-> 100M Port Warnings DISABLED."
    else
        ENABLE_WARN=1
        WARN_COLOR=$(prompt_color "Color to flash for 100M Speed Warning" "3" "3=Red")
        echo "-> 100M Port Warnings ENABLED ($WARN_COLOR)."
    fi
    echo "=========================================="
    echo ""

    # --- Script Location Prompt ---
    echo "=========================================="
    echo " Script Location"
    echo "=========================================="
    printf "Enter full path for the script [Default: /root/led_status.sh]: "
    read -r user_script_path < /dev/tty
    [ -z "$user_script_path" ] && SCRIPT_PATH="/root/led_status.sh" || SCRIPT_PATH="$user_script_path"
    echo "-> Script will be saved to: $SCRIPT_PATH"
    echo "=========================================="
    echo ""
else
    # Express Install (Defaults)
    TARGET_WANS="$DETECTED_WANS"
    NUM_WANS=$(echo "$TARGET_WANS" | wc -w)
    if [ "$NUM_WANS" -eq 2 ]; then
        WAN1=$(echo "$TARGET_WANS" | awk '{print $1}')
        WAN2=$(echo "$TARGET_WANS" | awk '{print $2}')
    fi
    SCRIPT_PATH="/root/led_status.sh"
    echo ""
    echo "-> Proceeding with Express Install for WANs: [ $TARGET_WANS ]"
    echo ""
fi

# Ensure the target directory exists
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
mkdir -p "$SCRIPT_DIR"

# 2. Clean up default Router Startup LED behaviors (Disables conflicts)
echo "Cleaning up default startup LED behaviors to prevent conflicts..."

if [ -f "/etc/init.d/wan-led" ]; then
    echo "-> Neutralizing custom /etc/init.d/wan-led startup script..."
    /etc/init.d/wan-led disable >/dev/null 2>&1
    /etc/init.d/wan-led stop >/dev/null 2>&1
    chmod -x /etc/init.d/wan-led
    
    for color in red green blue; do
        if [ -d "/sys/class/leds/${color}:status" ]; then
            echo none > "/sys/class/leds/${color}:status/trigger" 2>/dev/null
            echo 0 > "/sys/class/leds/${color}:status/brightness" 2>/dev/null
        fi
    done
fi

while uci -q show system | grep -E "\.sysfs='?(blue:status|red:status|green:status)'?" >/dev/null; do
    cfg=$(uci -q show system | grep -E "\.sysfs='?(blue:status|red:status|green:status)'?" | head -n 1 | cut -d. -f2)
    uci delete "system.$cfg"
done
uci commit system
/etc/init.d/led reload >/dev/null 2>&1

# 3. Install Dependencies
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

cat << EOF > "$SCRIPT_PATH"
#!/bin/sh
# --- User Configured Variables ---
TARGET_WANS="${TARGET_WANS}"
NUM_WANS=${NUM_WANS}
WAN1_NAME="${WAN1}"
WAN2_NAME="${WAN2}"
WAN1_COLOR="${WAN1_COLOR}"
WAN2_COLOR="${WAN2_COLOR}"
ALL_UP_COLOR="${ALL_UP_COLOR}"
NET_COLOR="${NET_COLOR}"
ENABLE_WARN=${ENABLE_WARN}
WARN_COLOR="${WARN_COLOR}"
EOF

cat << 'EOF' >> "$SCRIPT_PATH"
# --- Core Logic ---
TARGET="1.1.1.1"
PORT_WARNING=0

# Hardware RGB mixing function
set_led() {
    local color="$1"
    local state="$2" # solid, flash
    
    local r=0; local g=0; local b=0
    case "$color" in
        red) r=1 ;;
        green) g=1 ;;
        blue) b=1 ;;
        yellow|amber) r=1; g=1 ;;
        cyan) g=1; b=1 ;;
        magenta|purple) r=1; b=1 ;;
        white) r=1; g=1; b=1 ;;
    esac
    
    for c in red green blue; do
        local c_val=0
        [ "$c" = "red" ] && c_val=$r
        [ "$c" = "green" ] && c_val=$g
        [ "$c" = "blue" ] && c_val=$b
        
        if [ "$c_val" -eq 1 ]; then
            if [ "$state" = "flash" ]; then
                echo timer > "/sys/class/leds/$c:status/trigger" 2>/dev/null
            elif [ "$state" = "solid" ]; then
                echo none > "/sys/class/leds/$c:status/trigger" 2>/dev/null
                echo 255 > "/sys/class/leds/$c:status/brightness" 2>/dev/null
            fi
        fi
    done
}

# Helper function to reliably ping a logical WAN interface
check_wan() {
    local logical_if="$1"
    local phys_dev="$logical_if"
    
    if [ ! -d "/sys/class/net/$logical_if" ]; then
        phys_dev=$(ubus call network.interface.$logical_if status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
        [ -z "$phys_dev" ] && phys_dev=$(ubus call network.interface.$logical_if status 2>/dev/null | jsonfilter -e '@.device' 2>/dev/null)
        if [ -z "$phys_dev" ]; then
            proto=$(uci -q get network.$logical_if.proto)
            if [ "$proto" = "pppoe" ]; then
                phys_dev="pppoe-$logical_if"
            else
                phys_dev=$(uci -q get network.$logical_if.device)
                [ -z "$phys_dev" ] && phys_dev=$(uci -q get network.$logical_if.ifname)
            fi
        fi
    fi
    
    if [ -n "$phys_dev" ] && [ -d "/sys/class/net/$phys_dev" ]; then
        if ping -c 1 -W 3 -I "$phys_dev" "$TARGET" >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

if [ "$ENABLE_WARN" -eq 1 ]; then
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

# Clear all LEDs cleanly before applying new state
for c in blue green red; do
    echo none > "/sys/class/leds/$c:status/trigger" 2>/dev/null
    echo 0 > "/sys/class/leds/$c:status/brightness" 2>/dev/null
done

if [ "$PORT_WARNING" -eq 1 ]; then
    # CRITICAL SPEED DROP
    set_led "$WARN_COLOR" "flash"
else
    # --- Dual WAN Exact Mapping ---
    if [ "$NUM_WANS" -eq 2 ] && [ -n "$WAN1_NAME" ] && [ -n "$WAN2_NAME" ]; then
        WAN1_UP=0
        WAN2_UP=0
        
        check_wan "$WAN1_NAME" && WAN1_UP=1
        check_wan "$WAN2_NAME" && WAN2_UP=1
        
        if [ "$WAN1_UP" -eq 1 ] && [ "$WAN2_UP" -eq 1 ]; then
            set_led "$ALL_UP_COLOR" "solid"
        elif [ "$WAN1_UP" -eq 1 ]; then
            set_led "$WAN1_COLOR" "flash"
        elif [ "$WAN2_UP" -eq 1 ]; then
            set_led "$WAN2_COLOR" "flash"
        else
            set_led "red" "flash"
        fi
        
    # --- Generic Single / 3+ WAN Mapping ---
    else
        EXPECTED_WANS=0
        ACTIVE_WANS=0
        
        for logical_if in $TARGET_WANS; do
            EXPECTED_WANS=$((EXPECTED_WANS + 1))
            check_wan "$logical_if" && ACTIVE_WANS=$((ACTIVE_WANS + 1))
        done
        
        if [ "$EXPECTED_WANS" -gt 0 ]; then
            if [ "$ACTIVE_WANS" -eq "$EXPECTED_WANS" ]; then
                set_led "$NET_COLOR" "solid"
            elif [ "$ACTIVE_WANS" -gt 0 ]; then
                set_led "$NET_COLOR" "flash"
            else
                set_led "red" "flash"
            fi
        else
            if ping -c 1 -W 3 "$TARGET" >/dev/null 2>&1; then
                set_led "$NET_COLOR" "solid"
            else
                set_led "red" "flash"
            fi
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

if [ -x "/etc/init.d/cron" ]; then
    /etc/init.d/cron restart >/dev/null 2>&1
fi

/bin/sh "$SCRIPT_PATH" &

echo "Installation complete! The script is dynamically mixing colors and monitoring your connections."
