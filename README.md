************************************************************************************************************
The chkrootkit package is warning "WARNING: Possible Linux BPFDoor Malware installed".
However, it is not easy to diagnosis that is crytical problem or just warning by rule touching.
This Script is small example program which is teaching from AI assistant.
When following install instuction is done, mail should receive report to have general diagnosis refernece.

UPDATED: 2025.11.21
************************************************************************************************************
# bpfdoor-check (cron.daily + rotation + diff mail)

這個套件會安裝一個每日巡檢腳本，產生 BPFDoor 行為相關的診斷報告、
與前一次結果做 diff，並把差異寄出。


## 內含檔案
- `/usr/local/sbin/bpfdoor_daily_check.sh`：主腳本（不變更系統設定）。
- `/etc/cron.daily/bpfdoor-check`：每日自動執行包裝器。
- `/etc/logrotate.d/bpfdoor-check`：logrotate 規則，保留 30 天、壓縮日報告；baseline 以 `last_run.log` 維持可 diff。
- `/etc/default/bpfdoor-check`：可覆寫郵件收件人與其他變數。


## 安裝步驟（Ubuntu 24.04 測試通過）
```bash
sudo install -m 0755 usr_local_sbin_bpfdoor_daily_check.sh /usr/local/sbin/bpfdoor_daily_check.sh
sudo install -m 0755 etc_cron.daily_bpfdoor-check /etc/cron.daily/00-bpfdoor-check
sudo install -m 0644 etc_logrotate.d_bpfdoor-check /etc/logrotate.d/bpfdoor-check
sudo install -m 0644 etc_default_bpfdoor-check /etc/default/bpfdoor-check
sudo mkdir -p /var/log/bpfdoor-check
sudo chown root:adm /var/log/bpfdoor-check
sudo chmod 0755 /var/log/bpfdoor-check

# 設定收件人（編輯 /etc/default/bpfdoor-check，設定 MAIL_TO）
sudo sed -i 's/^# MAIL_TO=.*/MAIL_TO="you@example.com"/' /etc/default/bpfdoor-check
sudo nano /etc/default/bpfdoor-check  # 依需要調整


# 手動試跑一次
sudo /usr/local/sbin/bpfdoor_daily_check.sh
```

> 提醒：寄信功能需要系統上有 `sendmail` 或 `mail` 指令（例如安裝 Postfix、Exim、或 msmtp）。
> 若沒有 MTA，腳本仍會產生報告與 diff，但不會寄出。


## 移除
```bash
sudo rm -f /etc/cron.daily/00-bpfdoor-check /usr/local/sbin/bpfdoor_daily_check.sh /etc/logrotate.d/bpfdoor-check /etc/default/bpfdoor-check
sudo rm -rf /var/log/bpfdoor-check
```

## 安全性說明
- 腳本僅讀取系統狀態（`ss`, `bpftool`, `iptables`, `journalctl` 等），不改動防火牆與網路設定。
- diff 寄送前會限制大小，避免寄出巨量內容。


## Optional external config to override variables
# 可調變數（建議放進 /etc/default/bpfdoor-check）
# 可以把「標準端口」放進外部設定檔，改不同主機就不用改腳本
# Exmple：
#/etc/default/bpfdoor-check
STD_TCP_PORTS="21,22,25,80,110,139,143,443,445,465,587,5939,631,873,993,995,2222,3142,3306,5900,5901,6001,8891"
STD_UDP_PORTS="53,67,68,111,123,137,138,5353,41641"


************************************************************************************************************
If this small code is helping, it can donate BTC/BCH/LTC/DOGE coin to me for encourage as following address:

BTC - 3M4wWghm4MxmrSfXmHMEeCFNwP8Lxxqjzk
BCH - bitcoincash:qq6ghvdmyusnse9735rd5q09ensacl8z8qzrlwf49q
LTC - MR6HaFkfkmsfifX3jWu7xz33dULGotVUWB
DOGE- DGEFd3AAfJrBuaUwc4P6R2ZT754Jon9fQ7
Thank you very much.
************************************************************************************************************