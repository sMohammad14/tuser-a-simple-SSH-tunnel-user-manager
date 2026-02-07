#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "Error: Please run as root."
   exit 1
fi

echo "Setting time to Tehran..."
timedatectl set-timezone Asia/Tehran

echo "Installing dependencies..."
apt-get update -qq && apt-get install -y jq -qq

echo "Creating application directories..."
mkdir -p /opt/tuser/backups

echo "Installing connection limiter..."
cat << 'EOF' > /opt/tuser/tuser_limit.sh
#!/bin/bash
JSON_FILE="/opt/tuser/db.json"
last_check=""
while true; do
    current_sessions=$(ps aux | grep "sshd: " | grep -v "\[" | grep -v grep | md5sum | awk '{print $1}')
    if [[ "$current_sessions" != "$last_check" ]]; then
        users=$(jq -c '.[]' "$JSON_FILE" 2>/dev/null)
        echo "$users" | while read -r user_data; do
            username=$(echo "$user_data" | jq -r '.username')
            conn_limit=$(echo "$user_data" | jq -r '.conn_limit')
            status=$(echo "$user_data" | jq -r '.status')
            if [ "$status" = "disabled" ] || [ "$conn_limit" -eq 0 ]; then
                continue
            fi
            sessions=$(ps -eo pid,etime,cmd | grep "sshd: $username$" | grep -v grep | sort -k2 -r)
            session_count=$(echo "$sessions" | wc -l)
            if [ "$session_count" -gt "$conn_limit" ]; then
                counter=0
                echo "$sessions" | while read -r session; do
                    if [ -n "$session" ]; then
                        pid=$(echo "$session" | awk '{print $1}')
                        counter=$((counter + 1))
                        if [ "$counter" -gt "$conn_limit" ]; then
                            kill -9 "$pid" 2>/dev/null
                        fi
                    fi
                done
            fi
        done
        last_check="$current_sessions"
    fi
    sleep 1
done
EOF

chmod +x /opt/tuser/tuser_limit.sh

cat << 'EOF' > /etc/systemd/system/tuser_limit.service
[Unit]
Description=TUser Connection Limiter
After=network.target sshd.service
Wants=sshd.service

[Service]
Type=simple
ExecStart=/opt/tuser/tuser_limit.sh
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tuser_limit.service
systemctl start tuser_limit.service

echo "Writing the main application to /usr/local/bin/tuser..."
cat << 'EOF' > /usr/local/bin/tuser
#!/bin/bash

DB_FILE="/opt/tuser/db.json"
BACKUP_DIR="/opt/tuser/backups"
SSH_CONFIG="/etc/ssh/sshd_config"

init_check() {
    if [[ $EUID -ne 0 ]]; then
        echo "Root access required."
        exit 1
    fi
    mkdir -p "$(dirname "$DB_FILE")"
    mkdir -p "$BACKUP_DIR"
    if [[ ! -f "$DB_FILE" ]]; then
        echo "[]" > "$DB_FILE"
    fi
}

reload_ssh() {
    systemctl reload sshd
}

kill_user_sessions() {
    local user=$1
    pkill -u "$user" -9 &>/dev/null
}

update_ssh_config() {
    local user=$1
    local action=$2 
    sed -i "/# TUSER_START_$user/,/# TUSER_END_$user/d" "$SSH_CONFIG"
    if [[ "$action" == "add" ]]; then
        echo "" >> "$SSH_CONFIG"
        echo "# TUSER_START_$user" >> "$SSH_CONFIG"
        echo "Match User $user" >> "$SSH_CONFIG"
        echo "    AllowTcpForwarding yes" >> "$SSH_CONFIG"
        echo "    X11Forwarding no" >> "$SSH_CONFIG"
        echo "    PermitTunnel no" >> "$SSH_CONFIG"
        echo "    GatewayPorts yes" >> "$SSH_CONFIG"
        echo "    ForceCommand /usr/sbin/nologin" >> "$SSH_CONFIG"
        echo "# TUSER_END_$user" >> "$SSH_CONFIG"
    fi
    reload_ssh
}

sync_user_lock() {
    local user=$1
    local status=$2
    if [[ "$status" == "active" ]]; then
        passwd -u "$user" &>/dev/null
        update_ssh_config "$user" "add"
    else
        kill_user_sessions "$user"
        passwd -l "$user" &>/dev/null
        update_ssh_config "$user" "remove"
    fi
}

add_user() {
    read -p "Username: " username
    if [[ "$username" == "root" ]]; then
        echo "Error: Modification of root is not allowed."
        return
    fi
    in_db=$(jq -r ".[] | select(.username == \"$username\") | .username" "$DB_FILE")
    in_sys=$(id -u "$username" 2>/dev/null)
    if [[ -n "$in_db" ]]; then
        echo "Error: User '$username' already exists in this program's database."
        return
    fi
    if [[ -n "$in_sys" ]]; then
        echo "Error: User '$username' already exists in the Linux system."
        return
    fi
    read -p "Password: " password
    read -p "Valid Days (Default 30, 0 for Unlimited): " days
    days=${days:-30}
    read -p "Connection Limit (Default 1, 0 for Unlimited): " limit
    limit=${limit:-1}
    useradd -m -s /usr/sbin/nologin "$username"
    echo "$username:$password" | chpasswd
    update_ssh_config "$username" "add"
    current_date=$(date +%Y-%m-%d)
    jq --arg u "$username" --arg p "$password" --arg d "$current_date" --argjson v "$days" --argjson l "$limit" \
       '. += [{"username": $u, "password": $p, "created_at": $d, "valid_days": $v, "conn_limit": $l, "status": "active"}]' \
       "$DB_FILE" > "$DB_FILE.tmp" && mv "$DB_FILE.tmp" "$DB_FILE"
    echo "User $username created successfully."
}

list_users() {
    printf "%-15s | %-10s | %-10s | %-10s | %-10s | %-8s\n" "User" "Created" "Days" "Remaining" "Limit" "Status"
    echo "-----------------------------------------------------------------------------------"
    jq -c '.[]' "$DB_FILE" | while read -r row; do
        u=$(echo "$row" | jq -r '.username')
        c=$(echo "$row" | jq -r '.created_at')
        d=$(echo "$row" | jq -r '.valid_days')
        l=$(echo "$row" | jq -r '.conn_limit')
        s=$(echo "$row" | jq -r '.status')
        
        rem="Unlimited"
        if [[ "$d" -ne 0 ]]; then
            s_ts=$(date -d "$c" +%s)
            n_ts=$(date +%s)
            diff=$(( (n_ts - s_ts) / 86400 ))
            r_val=$(( d - diff ))
            rem="$r_val"
            if [[ "$r_val" -le 0 ]]; then rem="Expired"; fi
        fi

        disp_limit="$l"
        if [[ "$l" -eq 0 ]]; then disp_limit="Unlimited"; fi

        printf "%-15s | %-10s | %-10s | %-10s | %-10s | %-8s\n" "$u" "$c" "$d" "$rem" "$disp_limit" "$s"
    done
}

modify_password() {
    read -p "Username: " user
    if ! jq -e ".[] | select(.username == \"$user\")" "$DB_FILE" >/dev/null; then
        echo "Error: User '$user' not found in this program."
        return
    fi
    read -p "New Password: " new_pass
    kill_user_sessions "$user"
    echo "$user:$new_pass" | chpasswd
    jq --arg u "$user" --arg p "$new_pass" 'map(if .username == $u then .password = $p else . end)' "$DB_FILE" > "$DB_FILE.tmp" && mv "$DB_FILE.tmp" "$DB_FILE"
    echo "Password updated and sessions closed."
}

modify_days() {
    read -p "Username: " user
    if ! jq -e ".[] | select(.username == \"$user\")" "$DB_FILE" >/dev/null; then
        echo "Error: User '$user' not found in this program."
        return
    fi
    read -p "New Valid Days (Default 30, 0 for Unlimited): " new_days
    new_days=${new_days:-30}
    jq --arg u "$user" --argjson d "$new_days" 'map(if .username == $u then .valid_days = $d else . end)' "$DB_FILE" > "$DB_FILE.tmp" && mv "$DB_FILE.tmp" "$DB_FILE"
    echo "Updated valid days."
    sync_user_lock "$user" "active"
}

modify_limit() {
    read -p "Username: " user
    if ! jq -e ".[] | select(.username == \"$user\")" "$DB_FILE" >/dev/null; then
        echo "Error: User '$user' not found in this program."
        return
    fi
    read -p "New Connection Limit (Default 1, 0 for Unlimited): " new_limit
    new_limit=${new_limit:-1}
    kill_user_sessions "$user"
    jq --arg u "$user" --argjson l "$new_limit" 'map(if .username == $u then .conn_limit = $l else . end)' "$DB_FILE" > "$DB_FILE.tmp" && mv "$DB_FILE.tmp" "$DB_FILE"
    echo "Updated limit and sessions closed."
}

toggle_status() {
    read -p "Username: " user
    if ! jq -e ".[] | select(.username == \"$user\")" "$DB_FILE" >/dev/null; then
        echo "Error: User '$user' not found in this program."
        return
    fi
    curr=$(jq -r ".[] | select(.username == \"$user\") | .status" "$DB_FILE")
    if [[ "$curr" == "active" ]]; then
        new_status="disabled"
        sync_user_lock "$user" "disabled"
    else
        new_status="active"
        sync_user_lock "$user" "active"
    fi
    jq --arg u "$user" --arg s "$new_status" 'map(if .username == $u then .status = $s else . end)' "$DB_FILE" > "$DB_FILE.tmp" && mv "$DB_FILE.tmp" "$DB_FILE"
    echo "User $user is now $new_status."
}

delete_user() {
    read -p "Username to delete: " user
    if ! jq -e ".[] | select(.username == \"$user\")" "$DB_FILE" >/dev/null; then
        echo "Error: User '$user' not found in this program."
        return
    fi
    kill_user_sessions "$user"
    userdel -r -f "$user" 2>/dev/null
    update_ssh_config "$user" "remove"
    jq --arg u "$user" 'map(select(.username != $u))' "$DB_FILE" > "$DB_FILE.tmp" && mv "$DB_FILE.tmp" "$DB_FILE"
    echo "User deleted."
}

full_uninstall() {
    echo "WARNING: This will delete ALL users created by this tool and the database."
    read -p "Type 'YES' to confirm: " confirm
    if [[ "$confirm" != "YES" ]]; then echo "Aborted."; return; fi
    
    systemctl stop tuser_limit.service
    systemctl disable tuser_limit.service
    rm -f /etc/systemd/system/tuser_limit.service
    
    jq -r '.[].username' "$DB_FILE" | while read -r user; do
        kill_user_sessions "$user"
        userdel -r -f "$user" 2>/dev/null
        sed -i "/# TUSER_START_$user/,/# TUSER_END_$user/d" "$SSH_CONFIG"
    done
    
    rm -rf /opt/tuser
    rm -f /usr/local/bin/tuser
    crontab -l | grep -v "tuser --cron" | crontab -
    reload_ssh
    systemctl daemon-reload
    echo "Uninstalled completely."
    exit 0
}

cron_check() {
    jq -c '.[]' "$DB_FILE" | while read -r row; do
        u=$(echo "$row" | jq -r '.username')
        c=$(echo "$row" | jq -r '.created_at')
        d=$(echo "$row" | jq -r '.valid_days')
        s=$(echo "$row" | jq -r '.status')
        if [[ "$d" -eq 0 || "$s" == "disabled" || "$s" == "expired" ]]; then continue; fi
        s_ts=$(date -d "$c" +%s)
        n_ts=$(date +%s)
        diff=$(( (n_ts - s_ts) / 86400 ))
        if [[ "$diff" -ge "$d" ]]; then
             jq --arg u "$u" 'map(if .username == $u then .status = "expired" else . end)' "$DB_FILE" > "$DB_FILE.tmp" && mv "$DB_FILE.tmp" "$DB_FILE"
             sync_user_lock "$u" "disabled"
        fi
    done
}

backup_restore() {
    echo "1. Backup"
    echo "2. Restore"
    read -p "Select: " br
    if [[ "$br" == "1" ]]; then
        cp "$DB_FILE" "$BACKUP_DIR/db_$(date +%s).json"
        echo "Backed up."
    elif [[ "$br" == "2" ]]; then
        ls "$BACKUP_DIR"
        read -p "Filename: " fname
        if [[ -f "$BACKUP_DIR/$fname" ]]; then
            cp "$BACKUP_DIR/$fname" "$DB_FILE"
            jq -c '.[]' "$DB_FILE" | while read -r row; do
                u=$(echo "$row" | jq -r '.username')
                p=$(echo "$row" | jq -r '.password')
                s=$(echo "$row" | jq -r '.status')
                if ! id "$u" &>/dev/null; then
                    useradd -m -s /usr/sbin/nologin "$u"
                    echo "$u:$p" | chpasswd
                    sync_user_lock "$u" "$s"
                fi
            done
            echo "Restored and synced."
        fi
    fi
}

init_check
if [[ "$1" == "--cron" ]]; then
    cron_check
    exit 0
fi

while true; do
    clear
    echo "=== SSH TUNNEL USERS (tuser) ==="
    echo "by sMohammd14 (@github)"
    echo ""
    echo "1. Add User"
    echo "2. Delete User"
    echo "3. Toggle Status (Enable/Disable)"
    echo "4. Edit Days"
    echo "5. Edit Password"
    echo "6. Edit Connection Limit"
    echo "7. List Users"
    echo "8. Backup / Restore"
    echo "9. FULL UNINSTALL"
    echo "0. Exit"
    read -p "Select: " opt
    case $opt in
        1) add_user ;;
        2) delete_user ;;
        3) toggle_status ;;
        4) modify_days ;;
        5) modify_password ;;
        6) modify_limit ;;
        7) list_users ;;
        8) backup_restore ;;
        9) full_uninstall ;;
        0) exit 0 ;;
        *) echo "Invalid" ;;
    esac
    read -p "Press Enter..."
done
EOF

chmod +x /usr/local/bin/tuser
(crontab -l 2>/dev/null | grep -v "tuser --cron"; echo "0 3 * * * /usr/local/bin/tuser --cron") | crontab -
echo "Installation complete. Type 'tuser' to start."
