#!/bin/bash
# SSH 2FA 完整自動化設定腳本
# 基於 SSH 雙重認證 (2FA) 設定與故障排除指南
# 版本: 2.0
# 最後更新: 2025年7月4日
# 作者: Chen YouShen

set -euo pipefail

# ================== 全域變數設定 ==================
SCRIPT_NAME="SSH 2FA Setup"
SCRIPT_VERSION="2.0"
LOG_FILE="/tmp/ssh_2fa_setup_$(date +%Y%m%d_%H%M%S).log"
BACKUP_DIR="$HOME/ssh_2fa_backups"
SSH_PORT=2222

# ================== 顏色定義 ==================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# ================== 日誌函數 ==================
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log_message "INFO" "$1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    log_message "SUCCESS" "$1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log_message "WARNING" "$1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log_message "ERROR" "$1"
}

log_debug() {
    echo -e "${PURPLE}[DEBUG]${NC} $1"
    log_message "DEBUG" "$1"
}

# ================== 標題顯示 ==================
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                     SSH 2FA 自動化設定腳本                      ║
║              SSH 雙重認證 (密碼 + Google Authenticator)          ║
║                                                              ║
║  版本: 2.0                     作者: Chen YouShen              ║
║  支援系統: Debian 11/12        最後更新: 2025-07-04            ║
╚══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo
}

# ================== 進度顯示 ==================
show_progress() {
    local current=$1
    local total=$2
    local step_name="$3"
    local percentage=$((current * 100 / total))
    local filled=$((percentage / 2))
    local empty=$((50 - filled))
    
    printf "\r${CYAN}進度: [${GREEN}"
    printf "%${filled}s" | tr ' ' '█'
    printf "${NC}"
    printf "%${empty}s" | tr ' ' '░'
    printf "${CYAN}] ${percentage}%% - ${step_name}${NC}"
    
    if [ "$current" -eq "$total" ]; then
        echo
    fi
}

# ================== 確認函數 ==================
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response
    
    if [[ "$default" == "y" ]]; then
        prompt="${prompt} [Y/n]: "
    else
        prompt="${prompt} [y/N]: "
    fi
    
    while true; do
        read -p "$prompt" response
        response=${response,,} # 轉換為小寫
        
        if [[ -z "$response" ]]; then
            response="$default"
        fi
        
        case "$response" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) echo "請輸入 y/yes 或 n/no" ;;
        esac
    done
}

# ================== 系統檢查函數 ==================
check_system() {
    log_info "執行系統檢查..."
    local errors=0
    
    # 檢查是否為 root 用戶
    if [[ $EUID -eq 0 ]]; then
        log_error "請不要以 root 用戶執行此腳本"
        ((errors++))
    fi
    
    # 檢查 sudo 權限
    if ! sudo -n true 2>/dev/null; then
        log_error "需要 sudo 權限才能執行此腳本"
        ((errors++))
    fi
    
    # 檢查作業系統
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$ID" != "debian" && "$ID_LIKE" != *"debian"* ]]; then
            log_warning "此腳本專為 Debian 系統設計，在 $PRETTY_NAME 上可能需要調整"
        else
            log_success "檢測到 $PRETTY_NAME 系統"
        fi
    else
        log_warning "無法檢測作業系統類型"
    fi
    
    # 檢查網路連線
    if ! ping -c 1 8.8.8.8 &>/dev/null; then
        log_warning "網路連線可能有問題，請確保能夠訪問網際網路"
    fi
    
    # 檢查必要命令
    local required_commands=("apt" "systemctl" "grep" "sed" "dpkg")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "找不到必要命令: $cmd"
            ((errors++))
        fi
    done
    
    if [[ $errors -gt 0 ]]; then
        log_error "系統檢查失敗，發現 $errors 個錯誤"
        exit 1
    fi
    
    log_success "系統檢查完成"
}

# ================== 備份目錄建立 ==================
create_backup_dir() {
    log_info "建立備份目錄..."
    mkdir -p "$BACKUP_DIR"
    log_success "備份目錄已建立: $BACKUP_DIR"
}

# ================== 套件更新 ==================
update_packages() {
    log_info "更新系統套件..."
    
    sudo apt update || {
        log_error "套件列表更新失敗"
        exit 1
    }
    
    if confirm "是否要升級已安裝的套件？" "n"; then
        sudo apt upgrade -y || {
            log_warning "套件升級過程中出現問題"
        }
    fi
    
    log_success "系統套件更新完成"
}

# ================== 安裝 Google Authenticator ==================
install_google_authenticator() {
    log_info "安裝 Google Authenticator PAM 模組..."
    
    # 檢查是否已安裝
    if dpkg -l libpam-google-authenticator 2>/dev/null | grep -q "^ii"; then
        log_warning "Google Authenticator PAM 模組已安裝"
        if confirm "是否要重新安裝？" "n"; then
            sudo apt remove --purge libpam-google-authenticator -y
        else
            return 0
        fi
    fi
    
    # 安裝套件
    sudo apt install -y libpam-google-authenticator || {
        log_error "Google Authenticator PAM 模組安裝失敗"
        exit 1
    }
    
    # 驗證安裝
    if dpkg -l libpam-google-authenticator 2>/dev/null | grep -q "^ii"; then
        log_success "Google Authenticator PAM 模組安裝成功"
    else
        log_error "安裝驗證失敗"
        exit 1
    fi
}

# ================== 設定 Google Authenticator ==================
setup_google_authenticator() {
    log_info "設定 Google Authenticator..."
    
    # 檢查是否已設定
    if [[ -f ~/.google_authenticator ]]; then
        log_warning "Google Authenticator 設定檔已存在"
        if confirm "是否要重新設定？" "n"; then
            mv ~/.google_authenticator ~/.google_authenticator.backup.$(date +%Y%m%d_%H%M%S)
        else
            chmod 600 ~/.google_authenticator
            log_success "使用現有的 Google Authenticator 設定"
            return 0
        fi
    fi
    
    echo
    log_info "準備執行 Google Authenticator 設定..."
    echo -e "${YELLOW}設定選項建議：${NC}"
    echo "  1. Time-based tokens (時間同步令牌): ${GREEN}Yes (Y)${NC}"
    echo "  2. Update ~/.google_authenticator (更新設定檔): ${GREEN}Yes (Y)${NC}"
    echo "  3. Disallow multiple uses (禁止重複使用): ${GREEN}Yes (Y)${NC}"
    echo "  4. Increase window size (增加時間窗口): ${RED}No (N)${NC}"
    echo "  5. Enable rate-limiting (啟用速率限制): ${GREEN}Yes (Y)${NC}"
    echo
    log_warning "請掃描 QR 碼並妥善保存緊急備用碼！"
    echo
    
    if confirm "準備好開始設定了嗎？" "y"; then
        google-authenticator || {
            log_error "Google Authenticator 設定失敗"
            exit 1
        }
    else
        log_error "用戶取消設定"
        exit 1
    fi
    
    # 檢查設定結果並設定權限
    if [[ -f ~/.google_authenticator ]]; then
        chmod 600 ~/.google_authenticator
        log_success "Google Authenticator 設定完成，權限已設定為 600"
    else
        log_error "Google Authenticator 設定檔案未找到"
        exit 1
    fi
}

# ================== 備份配置檔案 ==================
backup_configs() {
    log_info "備份原始配置檔案..."
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    # 備份 SSH 配置
    if [[ -f /etc/ssh/sshd_config ]]; then
        sudo cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.backup.$timestamp"
        log_success "SSH 配置檔案已備份"
    else
        log_error "SSH 配置檔案不存在"
        exit 1
    fi
    
    # 備份 PAM 配置
    if [[ -f /etc/pam.d/sshd ]]; then
        sudo cp /etc/pam.d/sshd "$BACKUP_DIR/pam_sshd.backup.$timestamp"
        log_success "PAM SSH 配置檔案已備份"
    else
        log_error "PAM SSH 配置檔案不存在"
        exit 1
    fi
    
    log_success "所有配置檔案備份完成"
}

# ================== SSH 端口設定 ==================
configure_ssh_port() {
    log_info "設定 SSH 端口..."
    
    echo -e "目前預設 SSH 端口: ${YELLOW}$SSH_PORT${NC}"
    if confirm "是否要使用不同的端口？" "n"; then
        while true; do
            read -p "請輸入新的 SSH 端口 (1024-65535): " new_port
            if [[ "$new_port" =~ ^[0-9]+$ ]] && [[ $new_port -ge 1024 ]] && [[ $new_port -le 65535 ]]; then
                SSH_PORT=$new_port
                break
            else
                log_error "請輸入有效的端口號 (1024-65535)"
            fi
        done
    fi
    
    log_success "SSH 端口設定為: $SSH_PORT"
}

# ================== SSH 配置 ==================
configure_ssh() {
    log_info "配置 SSH 設定..."
    
    # 檢查並設定 SSH 配置
    local ssh_config="/etc/ssh/sshd_config"
    local temp_config="/tmp/sshd_config.tmp"
    
    # 複製原始配置
    sudo cp "$ssh_config" "$temp_config"
    
    # 設定端口
    if grep -q "^Port " "$temp_config"; then
        sudo sed -i "s/^Port .*/Port $SSH_PORT/" "$temp_config"
    else
        echo "Port $SSH_PORT" | sudo tee -a "$temp_config" >/dev/null
    fi
    
    # 設定認證方法
    local ssh_settings=(
        "PasswordAuthentication yes"
        "ChallengeResponseAuthentication yes"
        "KbdInteractiveAuthentication yes"
        "AuthenticationMethods keyboard-interactive:pam"
        "MaxAuthTries 3"
    )
    
    for setting in "${ssh_settings[@]}"; do
        local key=$(echo "$setting" | cut -d' ' -f1)
        if grep -q "^$key " "$temp_config"; then
            sudo sed -i "s/^$key .*/$setting/" "$temp_config"
        else
            echo "$setting" | sudo tee -a "$temp_config" >/dev/null
        fi
    done
    
    # 詢問是否禁用公鑰認證
    echo
    log_warning "重要決定：SSH 公鑰認證設定"
    echo -e "${YELLOW}選項說明：${NC}"
    echo "  • 禁用公鑰認證 (PubkeyAuthentication no): 僅使用密碼+2FA"
    echo "  • 保留公鑰認證 (PubkeyAuthentication yes): 支援公鑰或密碼+2FA"
    echo
    
    if confirm "是否要禁用 SSH 公鑰認證？" "n"; then
        if grep -q "^PubkeyAuthentication " "$temp_config"; then
            sudo sed -i "s/^PubkeyAuthentication .*/PubkeyAuthentication no/" "$temp_config"
        else
            echo "PubkeyAuthentication no" | sudo tee -a "$temp_config" >/dev/null
        fi
        log_warning "SSH 公鑰認證已禁用"
    else
        if grep -q "^PubkeyAuthentication " "$temp_config"; then
            sudo sed -i "s/^PubkeyAuthentication .*/PubkeyAuthentication yes/" "$temp_config"
        else
            echo "PubkeyAuthentication yes" | sudo tee -a "$temp_config" >/dev/null
        fi
        # 設定混合認證方法
        sudo sed -i "s/^AuthenticationMethods .*/AuthenticationMethods publickey,keyboard-interactive:pam/" "$temp_config"
        log_info "SSH 公鑰認證已保留，支援公鑰+密碼+2FA 混合認證"
    fi
    
    # 測試配置語法
    if sudo sshd -t -f "$temp_config"; then
        sudo mv "$temp_config" "$ssh_config"
        log_success "SSH 配置已更新"
    else
        log_error "SSH 配置語法錯誤"
        sudo rm -f "$temp_config"
        exit 1
    fi
}

# ================== PAM 配置 ==================
configure_pam() {
    log_info "配置 PAM 設定..."
    
    local pam_config="/etc/pam.d/sshd"
    
    # 檢查是否已配置
    if grep -q "pam_google_authenticator.so" "$pam_config"; then
        log_warning "PAM Google Authenticator 配置已存在"
        if ! confirm "是否要重新配置？" "n"; then
            return 0
        fi
        # 移除現有配置
        sudo sed -i '/pam_google_authenticator.so/d' "$pam_config"
    fi
    
    # 詢問 nullok 設定
    echo
    log_info "PAM nullok 選項設定"
    echo -e "${YELLOW}選項說明：${NC}"
    echo "  • 包含 nullok: 允許未設定 2FA 的使用者僅用密碼登入"
    echo "  • 移除 nullok: 強制所有使用者必須設定 2FA 才能登入"
    echo
    
    local nullok_option=""
    if confirm "是否要允許未設定 2FA 的使用者登入？(建議設定階段選擇是)" "y"; then
        nullok_option=" nullok"
        log_info "設定為允許模式 (設定階段建議)"
    else
        log_warning "設定為強制模式 (生產環境建議)"
    fi
    
    # 在 @include common-auth 後添加 Google Authenticator
    sudo sed -i "/^@include common-auth$/a auth required pam_google_authenticator.so${nullok_option}" "$pam_config"
    
    log_success "PAM 配置已更新"
}

# ================== 服務重啟 ==================
restart_ssh_service() {
    log_info "驗證配置並重啟 SSH 服務..."
    
    # 測試 SSH 配置語法
    if ! sudo sshd -t; then
        log_error "SSH 配置語法錯誤，請檢查配置"
        exit 1
    fi
    log_success "SSH 配置語法正確"
    
    # 重新載入 SSH 服務
    if sudo systemctl reload ssh; then
        log_success "SSH 服務已重新載入"
    else
        log_error "SSH 服務重新載入失敗"
        exit 1
    fi
    
    # 檢查服務狀態
    if sudo systemctl is-active --quiet ssh; then
        log_success "SSH 服務運行正常"
    else
        log_error "SSH 服務狀態異常"
        exit 1
    fi
    
    # 檢查端口監聽
    sleep 2
    if ss -tlnp | grep -q ":$SSH_PORT "; then
        log_success "SSH 服務正在監聽端口 $SSH_PORT"
    else
        log_warning "SSH 端口 $SSH_PORT 監聽狀態檢查失敗"
    fi
}

# ================== 建立測試腳本 ==================
create_test_script() {
    log_info "建立測試腳本..."
    
    cat > ~/test_ssh_2fa.sh << EOF
#!/bin/bash
# SSH 2FA 配置檢查腳本
# 自動生成於: $(date)

echo "=============================================="
echo "         SSH 2FA 配置檢查報告"
echo "=============================================="
echo "檢查時間: \$(date)"
echo

echo "1. SSH 服務狀態："
if systemctl is-active --quiet ssh; then
    echo "   ✓ SSH 服務運行中"
else
    echo "   ✗ SSH 服務未運行"
fi

echo "2. SSH 端口監聽："
if ss -tlnp | grep -q ":$SSH_PORT "; then
    echo "   ✓ SSH 服務正在監聽端口 $SSH_PORT"
    ss -tlnp | grep ":$SSH_PORT "
else
    echo "   ✗ SSH 服務未在端口 $SSH_PORT 上監聽"
fi

echo "3. 關鍵配置檢查："
echo "   - Port: \$(grep "^Port " /etc/ssh/sshd_config || echo "預設 22")"
echo "   - PasswordAuthentication: \$(grep "^PasswordAuthentication" /etc/ssh/sshd_config || echo "未設定")"
echo "   - AuthenticationMethods: \$(grep "^AuthenticationMethods" /etc/ssh/sshd_config || echo "未設定")"
echo "   - PubkeyAuthentication: \$(grep "^PubkeyAuthentication" /etc/ssh/sshd_config || echo "未設定")"

echo "4. Google Authenticator 檔案："
if [[ -f ~/.google_authenticator ]]; then
    echo "   ✓ 檔案存在，權限: \$(stat -c %a ~/.google_authenticator)"
else
    echo "   ✗ 檔案不存在"
fi

echo "5. PAM 配置："
if grep -q "pam_google_authenticator.so" /etc/pam.d/sshd; then
    echo "   ✓ PAM Google Authenticator 已配置"
    grep "pam_google_authenticator.so" /etc/pam.d/sshd
else
    echo "   ✗ PAM Google Authenticator 未配置"
fi

echo "6. 時間同步狀態："
if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
    echo "   ✓ 時間同步正常"
else
    echo "   ✗ 時間同步異常"
fi

echo
echo "=============================================="
echo "            測試連線指令"
echo "=============================================="
echo "從其他機器測試連線："
echo "ssh -p $SSH_PORT \$(whoami)@\$(hostname -I | awk '{print \$1}')"
echo
echo "預期登入流程："
echo "1. 提示輸入密碼"
echo "2. 提示輸入 6 位驗證碼"
echo "3. 成功建立連線"
EOF

    chmod +x ~/test_ssh_2fa.sh
    log_success "測試腳本已建立: ~/test_ssh_2fa.sh"
}

# ================== 建立備份腳本 ==================
create_backup_script() {
    log_info "建立備份腳本..."
    
    cat > ~/backup_ssh_config.sh << 'EOF'
#!/bin/bash
# SSH 配置備份腳本
# 自動生成

BACKUP_DIR="$HOME/ssh_2fa_backups"
DATE=$(date +%Y%m%d_%H%M%S)

echo "開始備份 SSH 2FA 配置..."

# 建立備份目錄
mkdir -p "$BACKUP_DIR"

# 備份 SSH 配置
if sudo cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config_$DATE"; then
    echo "✓ SSH 配置已備份"
else
    echo "✗ SSH 配置備份失敗"
fi

# 備份 PAM 配置
if sudo cp /etc/pam.d/sshd "$BACKUP_DIR/pam_sshd_$DATE"; then
    echo "✓ PAM 配置已備份"
else
    echo "✗ PAM 配置備份失敗"
fi

# 備份 Google Authenticator 設定
if [[ -f ~/.google_authenticator ]]; then
    if cp ~/.google_authenticator "$BACKUP_DIR/google_authenticator_$DATE"; then
        echo "✓ Google Authenticator 設定已備份"
    else
        echo "✗ Google Authenticator 設定備份失敗"
    fi
else
    echo "! Google Authenticator 設定檔不存在"
fi

echo "備份完成，檔案儲存於: $BACKUP_DIR"
ls -la "$BACKUP_DIR/"*"$DATE"*
EOF

    chmod +x ~/backup_ssh_config.sh
    log_success "備份腳本已建立: ~/backup_ssh_config.sh"
}

# ================== 建立還原腳本 ==================
create_restore_script() {
    log_info "建立緊急還原腳本..."
    
    local latest_backup=$(ls -t "$BACKUP_DIR"/sshd_config.backup.* 2>/dev/null | head -n1)
    if [[ -z "$latest_backup" ]]; then
        log_warning "找不到備份檔案，跳過還原腳本建立"
        return 0
    fi
    
    local backup_timestamp=$(basename "$latest_backup" | sed 's/sshd_config.backup.//')
    
    cat > ~/restore_ssh_config.sh << EOF
#!/bin/bash
# SSH 配置緊急還原腳本
# 備份時間: $backup_timestamp

echo "警告：此腳本將還原 SSH 配置到 2FA 設定前的狀態"
read -p "確定要繼續嗎？(yes/no): " confirm

if [[ "\$confirm" != "yes" ]]; then
    echo "取消還原操作"
    exit 0
fi

echo "開始還原 SSH 配置..."

# 還原 SSH 配置
if sudo cp "$BACKUP_DIR/sshd_config.backup.$backup_timestamp" /etc/ssh/sshd_config; then
    echo "✓ SSH 配置已還原"
else
    echo "✗ SSH 配置還原失敗"
    exit 1
fi

# 還原 PAM 配置
if sudo cp "$BACKUP_DIR/pam_sshd.backup.$backup_timestamp" /etc/pam.d/sshd; then
    echo "✓ PAM 配置已還原"
else
    echo "✗ PAM 配置還原失敗"
    exit 1
fi

# 測試配置
if sudo sshd -t; then
    echo "✓ SSH 配置語法正確"
else
    echo "✗ SSH 配置語法錯誤"
    exit 1
fi

# 重新載入服務
if sudo systemctl reload ssh; then
    echo "✓ SSH 服務已重新載入"
else
    echo "✗ SSH 服務重新載入失敗"
    exit 1
fi

echo "還原完成！SSH 服務已回復到 2FA 設定前的狀態"
EOF

    chmod +x ~/restore_ssh_config.sh
    log_success "緊急還原腳本已建立: ~/restore_ssh_config.sh"
}

# ================== 安全建議安裝 ==================
install_security_tools() {
    if confirm "是否要安裝額外的安全工具 (Fail2Ban)？" "y"; then
        log_info "安裝 Fail2Ban..."
        
        sudo apt install -y fail2ban || {
            log_warning "Fail2Ban 安裝失敗"
            return 1
        }
        
        # 建立 Fail2Ban 配置
        sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
        
        # 設定 SSH 保護
        cat > /tmp/jail.local.ssh << EOF

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
EOF

        sudo tee -a /etc/fail2ban/jail.local < /tmp/jail.local.ssh >/dev/null
        rm -f /tmp/jail.local.ssh
        
        sudo systemctl enable fail2ban
        sudo systemctl start fail2ban
        
        log_success "Fail2Ban 已安裝並配置"
    fi
}

# ================== 執行最終測試 ==================
run_final_test() {
    log_info "執行最終配置驗證..."
    
    if [[ -f ~/test_ssh_2fa.sh ]]; then
        echo
        echo -e "${CYAN}=== 配置驗證報告 ===${NC}"
        ~/test_ssh_2fa.sh
        echo
    else
        log_error "測試腳本不存在"
    fi
}

# ================== 顯示完成資訊 ==================
show_completion_info() {
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    🎉 設定完成！                              ║${NC}"
    echo -e "${GREEN}║              SSH 2FA 已成功配置                             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    log_success "SSH 2FA 設定完成！"
    
    echo -e "${CYAN}📋 重要資訊：${NC}"
    echo "• SSH 端口: $SSH_PORT"
    echo "• 備份目錄: $BACKUP_DIR"
    echo "• 日誌檔案: $LOG_FILE"
    echo
    
    echo -e "${YELLOW}🔧 可用腳本：${NC}"
    echo "• 測試腳本: ~/test_ssh_2fa.sh"
    echo "• 備份腳本: ~/backup_ssh_config.sh"
    echo "• 還原腳本: ~/restore_ssh_config.sh"
    echo
    
    echo -e "${CYAN}🧪 測試指引：${NC}"
    echo "1. 保持當前 SSH 連線開啟"
    echo "2. 開啟新終端測試連線："
    echo "   ssh -p $SSH_PORT $(whoami)@$(hostname -I | awk '{print $1}')"
    echo "3. 預期流程："
    echo "   • 輸入系統密碼"
    echo "   • 輸入 6 位驗證碼"
    echo "   • 成功登入"
    echo
    
    echo -e "${RED}⚠️  重要提醒：${NC}"
    echo "• 請務必測試新連線成功後再關閉此會話"
    echo "• 妥善保存 Google Authenticator 緊急備用碼"
    echo "• 建議定期備份配置檔案"
    echo "• 如遇問題可使用還原腳本復原設定"
    echo
    
    echo -e "${BLUE}📚 故障排除：${NC}"
    echo "• 查看認證日誌: sudo tail -f /var/log/auth.log"
    echo "• 檢查時間同步: timedatectl status"
    echo "• 緊急還原: ~/restore_ssh_config.sh"
    echo
}

# ================== 清理函數 ==================
cleanup() {
    log_info "清理臨時檔案..."
    rm -f /tmp/sshd_config.tmp 2>/dev/null
    rm -f /tmp/jail.local.ssh 2>/dev/null
}

# ================== 錯誤處理 ==================
error_handler() {
    local line_number=$1
    log_error "腳本在第 $line_number 行發生錯誤"
    cleanup
    echo
    echo -e "${RED}設定過程中發生錯誤！${NC}"
    echo "日誌檔案: $LOG_FILE"
    echo "如需協助，請查看日誌檔案或使用還原腳本復原設定"
    exit 1
}

# ================== 主要流程 ==================
main() {
    # 設定錯誤處理
    trap 'error_handler $LINENO' ERR
    trap cleanup EXIT
    
    # 顯示標題
    show_banner
    
    # 建立日誌檔案
    touch "$LOG_FILE"
    log_info "開始執行 SSH 2FA 設定腳本 v$SCRIPT_VERSION"
    
    # 確認執行
    if ! confirm "確定要開始 SSH 2FA 設定嗎？" "y"; then
        log_info "用戶取消執行"
        exit 0
    fi
    
    echo
    log_info "開始 SSH 2FA 設定流程..."
    
    # 主要設定步驟
    local total_steps=13
    local current_step=0
    
    ((current_step++))
    show_progress $current_step $total_steps "系統檢查"
    check_system
    
    ((current_step++))
    show_progress $current_step $total_steps "建立備份目錄"
    create_backup_dir
    
    ((current_step++))
    show_progress $current_step $total_steps "更新系統套件"
    update_packages
    
    ((current_step++))
    show_progress $current_step $total_steps "安裝 Google Authenticator"
    install_google_authenticator
    
    ((current_step++))
    show_progress $current_step $total_steps "設定 Google Authenticator"
    setup_google_authenticator
    
    ((current_step++))
    show_progress $current_step $total_steps "備份配置檔案"
    backup_configs
    
    ((current_step++))
    show_progress $current_step $total_steps "設定 SSH 端口"
    configure_ssh_port
    
    ((current_step++))
    show_progress $current_step $total_steps "配置 SSH"
    configure_ssh
    
    ((current_step++))
    show_progress $current_step $total_steps "配置 PAM"
    configure_pam
    
    ((current_step++))
    show_progress $current_step $total_steps "重啟 SSH 服務"
    restart_ssh_service
    
    ((current_step++))
    show_progress $current_step $total_steps "建立測試腳本"
    create_test_script
    
    ((current_step++))
    show_progress $current_step $total_steps "建立備份腳本"
    create_backup_script
    
    ((current_step++))
    show_progress $current_step $total_steps "建立還原腳本"
    create_restore_script
    
    echo
    
    # 可選功能
    install_security_tools
    
    # 最終測試
    run_final_test
    
    # 顯示完成資訊
    show_completion_info
    
    log_success "SSH 2FA 設定腳本執行完成"
}

# ================== 腳本入口點 ==================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi