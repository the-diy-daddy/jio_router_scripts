#!/bin/sh

echo "Starting LED Status Monitor Installation..."

# Change directory to /root
cd /root || { echo "Failed to change directory to /root. Exiting."; exit 1; }
echo "Working directory changed to $(pwd)"
echo ""

# --- LED Selection Prompt ---
echo "=========================================="
echo " LED Configuration"
echo "=========================================="
echo "Which LED should indicate the Internet is WORKING?"
echo "1) Blue  (Default - Green will show 100M port warnings)"
echo "2) Green (Blue will show 100M port warnings)"
printf "Enter 1 or 2 [Default: 1]: "

# Read directly from the terminal to support 'curl | bash' execution
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
echo "=========================================="
echo ""

# --- Script Location Prompt ---
echo "=========================================="
echo " Script Location"
echo "=========================================="
printf "Only Type full path for the script or Hit Enter for [Default: /root/led_status.sh]: "

read -r user_script_path < /dev/tty

if [ -z "$user_script_path" ]; then
    SCRIPT_PATH="/root/led_status.sh"
else
    SCRIPT_PATH="$user_script_path"
fi

# Ensure the target directory exists
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
mkdir -p "$SCRIPT_DIR"

echo "-> Script will be saved to: $SCRIPT_PATH"
echo "=========================================="
echo ""

# 1. Install Dependencies (OpenWrt opkg & apk)
if command -v opkg > /dev/null 2>&1; then
    echo "opkg (OpenWrt classic) detected. Updating..."
    opkg update
    echo "Ensuring coreutils-timeout is installed..."
    opkg install coreutils-timeout
elif command -v apk > /dev/null 2>&1; then
    echo "apk (OpenWrt 24.x+) detected. Updating..."
    apk update
    echo "Ensuring coreutils is installed for the timeout command..."
    apk add coreutils coreutils-timeout
else
    echo "Warning: Neither opkg nor apk found. Assuming 'timeout' is natively available."
fi

# 2. Write the script payload
echo "Writing payload to $SCRIPT_PATH..."

# Write the user-selected variables (EOF without quotes evaluates variables)
cat << EOF > "$SCRIPT_PATH"
#!/bin/sh

NET_LED="/sys/class/leds/${LED_NET}:status"
WARN_LED="/sys/class/leds/${LED_WARN}:status"
DOWN_LED="/sys/class/leds/red:status"
EOF

# Append the rest of the script logic ('EOF' with quotes protects script variables)
cat << 'EOF' >> "$SCRIPT_PATH"
TARGET="1.1.1.1"

# Initialize 100M warning flag
PORT_WARNING=0

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
    # Ports are healthy: Clear the warning flashing state
    echo none > "$WARN_LED/trigger"
    echo 0 > "$WARN_LED/brightness"

    # Check internet connectivity
    if ping -c 1 -W 3 "$TARGET" > /dev/null 2>&1; then
        # Internet is WORKING: Clear down, set Net LED to SOLID ON
        echo none > "$DOWN_LED/trigger"
        echo 0 > "$DOWN_LED/brightness"

        echo none > "$NET_LED/trigger"
        echo 255 > "$NET_LED/brightness"
    else
        # Internet is DOWN: Clear net, set Down LED to FLASH
        echo none > "$NET_LED/trigger"
        echo 0 > "$NET_LED/brightness"

        echo timer > "$DOWN_LED/trigger"
    fi
fi
EOF

# 3. Set Permissions
chmod +x "$SCRIPT_PATH"
echo "Set $SCRIPT_PATH as executable."

# 4. Apply Crontab Entries
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

echo "Installation complete! The script is now running in the background."
