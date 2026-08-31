# OpenWrt Scripts For Jio Router....

***LED Color script based on internet connectivity. Runs every 30s using cronjob***

***Login to router using SSH and add these packages***

    apk update && apk add curl bash coreutils-timeout

***Run this command in SSH***

    curl -L https://raw.githubusercontent.com/the-diy-daddy/jio_router_scripts/refs/heads/main/install_led_monitor.sh | bash
