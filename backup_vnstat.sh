#!/bin/bash

# vnstat数据备份和还原脚本 - 简化版
# 使用方法: sudo ./backup_vnstat_simple.sh

set -e

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
BACKUP_BASE_DIR="/backup/vnstat"
VNSTAT_DATA_DIR="/var/lib/vnstat"
LOG_FILE="/var/log/vnstat-backup.log"

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}请使用 root 权限运行此脚本${NC}"
    exit 1
fi

# 显示菜单
show_menu() {
    clear
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}    vnstat 数据管理工具${NC}"
    echo -e "${GREEN}================================${NC}"
    echo -e "1) 备份 vnstat 数据"
    echo -e "2) 还原 vnstat 数据"
    echo -e "3) 列出所有备份"
    echo -e "4) 退出"
    echo
    echo -e "请选择操作 [1-4]: \c"
}

# 停止相关服务
stop_services() {
    echo -e "${YELLOW}正在停止相关服务...${NC}"
    
    # 停止 FlowMaster
    if command -v pm2 &> /dev/null; then
        pm2 stop flowmaster 2>/dev/null || true
        echo "已停止 FlowMaster 服务"
    fi
    
    # 停止 vnstat 服务
    systemctl stop vnstat 2>/dev/null || service vnstat stop 2>/dev/null || true
    echo "已停止 vnstat 服务"
}

# 启动相关服务
start_services() {
    echo -e "${YELLOW}正在启动相关服务...${NC}"
    
    # 启动 vnstat 服务
    systemctl start vnstat 2>/dev/null || service vnstat start 2>/dev/null || true
    echo "已启动 vnstat 服务"
    
    # 启动 FlowMaster
    if command -v pm2 &> /dev/null; then
        pm2 start flowmaster 2>/dev/null || true
        pm2 save 2>/dev/null || true
        echo "已启动 FlowMaster 服务"
    fi
}

# 备份函数
backup_data() {
    local backup_dir="$BACKUP_BASE_DIR-$(date +%Y%m%d-%H%M%S)"
    
    echo -e "${GREEN}开始备份vnstat数据...${NC}"
    echo "$(date): 开始备份vnstat数据..." | tee -a $LOG_FILE
    mkdir -p $backup_dir

    # 检查vnstat数据目录是否存在
    if [ ! -d "$VNSTAT_DATA_DIR" ]; then
        echo -e "${RED}错误: vnstat数据目录不存在: $VNSTAT_DATA_DIR${NC}"
        echo "$(date): 错误: vnstat数据目录不存在: $VNSTAT_DATA_DIR" | tee -a $LOG_FILE
        return 1
    fi

    # 备份数据库文件
    echo -e "${YELLOW}备份数据库文件...${NC}"
    echo "$(date): 备份数据库文件..." | tee -a $LOG_FILE
    cp -r $VNSTAT_DATA_DIR/* $backup_dir/

    # 导出文本格式数据
    echo -e "${YELLOW}导出文本格式数据...${NC}"
    echo "$(date): 导出文本格式数据..." | tee -a $LOG_FILE
    vnstat --dumpdb > $backup_dir/vnstat-dump.txt 2>/dev/null || echo "无法导出文本格式数据"

    # 显示备份信息
    echo -e "${GREEN}备份完成!${NC}"
    echo "$(date): 备份完成!" | tee -a $LOG_FILE
    echo -e "${BLUE}备份目录: $backup_dir${NC}"
    echo "备份文件:"
    ls -la $backup_dir | tee -a $LOG_FILE

    # 显示备份大小
    BACKUP_SIZE=$(du -sh $backup_dir | cut -f1)
    echo -e "${BLUE}备份大小: $BACKUP_SIZE${NC}"

    echo "$(date): 备份完成，备份位置: $backup_dir" | tee -a $LOG_FILE
}

# 还原函数
restore_data() {
    echo -e "${GREEN}可用的备份列表:${NC}"
    
    # 列出所有备份目录
    local backup_parent_dir="/backup"
    if [ ! -d "$backup_parent_dir" ]; then
        echo -e "${RED}没有找到备份目录: $backup_parent_dir${NC}"
        return 1
    fi
    
    local backups=($(ls -1td $backup_parent_dir/vnstat-* 2>/dev/null | head -10))
    
    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${RED}没有找到任何备份${NC}"
        return 1
    fi
    
    echo -e "${BLUE}最近的备份:${NC}"
    for i in "${!backups[@]}"; do
        local backup_name=$(basename ${backups[$i]})
        local backup_time=$(echo $backup_name | sed 's/.*-\([0-9]\{8\}-[0-9]\{6\}\)/\1/')
        local backup_size=$(du -sh ${backups[$i]} | cut -f1)
        echo -e "$((i+1))) $backup_name (大小: $backup_size, 时间: $backup_time)"
    done
    
    echo
    echo -e "请选择要还原的备份 [1-${#backups[@]}]: \c"
    read choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backups[@]} ]; then
        echo -e "${RED}无效的选择${NC}"
        return 1
    fi
    
    local selected_backup=${backups[$((choice-1))]}
    
    echo -e "${YELLOW}确认要还原备份: $(basename $selected_backup) ? [y/N]: \c"
    read confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}取消还原操作${NC}"
        return 0
    fi
    
    # 停止服务
    stop_services
    
    # 备份当前数据
    if [ -d "$VNSTAT_DATA_DIR" ]; then
        local current_backup="/var/lib/vnstat.backup.$(date +%Y%m%d-%H%M%S)"
        echo -e "${YELLOW}备份当前数据到: $current_backup${NC}"
        mv $VNSTAT_DATA_DIR $current_backup
    fi
    
    # 恢复数据
    echo -e "${YELLOW}正在恢复数据...${NC}"
    mkdir -p $VNSTAT_DATA_DIR
    cp -r $selected_backup/* $VNSTAT_DATA_DIR/
    
    # 设置正确的权限
    chown -R vnstat:vnstat $VNSTAT_DATA_DIR 2>/dev/null || chown -R root:root $VNSTAT_DATA_DIR
    chmod -R 755 $VNSTAT_DATA_DIR
    
    # 启动服务
    start_services
    
    echo -e "${GREEN}数据恢复完成!${NC}"
    echo "$(date): 数据恢复完成，使用备份: $selected_backup" | tee -a $LOG_FILE
    
    # 验证数据
    echo -e "${BLUE}验证数据:${NC}"
    echo "检查vnstat数据库文件:"
    ls -la $VNSTAT_DATA_DIR/
    echo
    echo "检查vnstat服务状态:"
    systemctl status vnstat --no-pager -l
    echo
    echo "检查可用的网络接口:"
    vnstat --iflist 2>/dev/null || echo "无法获取网络接口列表"
}

# 列出所有备份
list_backups() {
    echo -e "${GREEN}所有备份列表:${NC}"
    
    local backup_parent_dir="/backup"
    if [ ! -d "$backup_parent_dir" ]; then
        echo -e "${RED}没有找到备份目录: $backup_parent_dir${NC}"
        return 1
    fi
    
    local backups=($(ls -1td $backup_parent_dir/vnstat-* 2>/dev/null))
    
    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${RED}没有找到任何备份${NC}"
        return 1
    fi
    
    echo -e "${BLUE}备份列表 (按时间倒序):${NC}"
    printf "%-4s %-30s %-10s %-20s\n" "序号" "备份名称" "大小" "修改时间"
    echo "----------------------------------------------------------------"
    
    for i in "${!backups[@]}"; do
        local backup_name=$(basename ${backups[$i]})
        local backup_size=$(du -sh ${backups[$i]} | cut -f1)
        local backup_time=$(stat -c %y ${backups[$i]} | cut -d' ' -f1,2 | cut -d'.' -f1)
        printf "%-4s %-30s %-10s %-20s\n" "$((i+1))" "$backup_name" "$backup_size" "$backup_time"
    done
}

# 主程序
main() {
    while true; do
        show_menu
        read choice
        
        case $choice in
            1)
                backup_data
                echo
                echo -e "${GREEN}按任意键继续...${NC}"
                read -n 1 -r
                ;;
            2)
                restore_data
                echo
                echo -e "${GREEN}按任意键继续...${NC}"
                read -n 1 -r
                ;;
            3)
                list_backups
                echo
                echo -e "${GREEN}按任意键继续...${NC}"
                read -n 1 -r
                ;;
            4)
                echo -e "${GREEN}退出程序${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择，请重新选择${NC}"
                sleep 2
                ;;
        esac
    done
}

# 执行主程序
main
