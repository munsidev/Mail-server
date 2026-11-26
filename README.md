# Local Mail Server Setup and Management Toolkit

An educational Operating Systems course project toolkit designed to configure, validate, manage, and inspect a full-featured local mail server on **Ubuntu 22.04 LTS / 24.04 LTS** supporting **SMTP, IMAP, POP3, TLS/SSL Encryption, SpamAssassin Content Filtering, and Linux User Account Management**.

---

### Author & Student Information
* **Author:** Khalid hasan Munsi
* **Student ID:** 241-15-730
* **Course:** Operating Systems Lab / Project
* **Environment:** Ubuntu Linux (Server) & macOS / iOS (Client MUAs)

---

## 1. Project Overview & Syllabus Alignment

This project satisfies all requirements of a complete Operating Systems Mail Server project, demonstrating inter-process communication, network socket management, Unix daemon lifecycle, file permissions, concurrency control, and security boundaries:

| Course Requirement | Implementation Details |
|---|---|
| **Sending MTA** | **Postfix** configured for local SMTP delivery on ports 25 and 587. |
| **Receiving / Access MDA** | **Dovecot** configured with dual-engine architecture supporting v2.3 and modern v2.4+. |
| **SMTP Protocol** | RFC 5321 compliant local mail exchange without public open-relaying. |
| **IMAP Protocol** | Dovecot IMAP (`dovecot-imapd`) on port 143 (plain/STARTTLS) and port 993 (IMAPS). |
| **POP3 Protocol** | Dovecot POP3 (`dovecot-pop3d`) on port 110 (plain/STARTTLS) and port 995 (POP3S). |
| **Spam Filtering** | Postfix pipelined through `SpamAssassin` (`spamd` / `spamc`) content filter. |
| **Encryption (TLS/SSL)** | OpenSSL 2048-bit RSA self-signed certificates, Postfix opportunistic TLS, Dovecot SSL/TLS listeners. |
| **User Authentication** | Linux PAM (Pluggable Authentication Modules) and `/etc/shadow` integration. |
| **Mail Storage Architecture** | High-concurrency **Maildir** storage format (`~/Maildir/{cur,new,tmp}`). |
| **Security Boundaries** | Strict closed relay (`smtpd_relay_restrictions`), outbound transport blocked, no plaintext credential logging. |

---

## 2. System Architecture & Components

```
                +--------------------------------------------------+
                |           Local Wi-Fi Network (LAN)              |
                +--------------------------------------------------+
                        |                                  |
                        v                                  v
           [MUA: Mozilla Thunderbird]              [MUA: Mobile / iOS Mail]
            User: bob@localdomain                   User: alice@localdomain
                        |                                  |
                        +-----------------+----------------+
                                          |
                                          v
+----------------------------------------------------------------------------------------+
| Ubuntu Mail Server (IP: e.g. 192.168.0.113)                                            |
|                                                                                        |
|   +--------------------------------------------------------------------------------+   |
|   | Postfix (MTA - Ports 25, 587)                                                   |   |
|   |  * smtpd_banner: Local Mail Server (Trusted LAN Only)                          |   |
|   |  * smtpd_relay_restrictions = permit_mynetworks, reject                        |   |
|   |  * default_transport = error:Public Internet delivery is disabled              |   |
|   +--------------------------------------------------------------------------------+   |
|            |                                                                           |
|            v (Content Filter Pipe)                                                     |
|   +--------------------------------------------------------------------------------+   |
|   | SpamAssassin (Daemon: spamd, Client: spamc)                                    |   |
|   |  * Injects X-Spam-Flag and X-Spam-Status headers                               |   |
|   +--------------------------------------------------------------------------------+   |
|            |                                                                           |
|            v (Local Maildir Delivery)                                                  |
|   +--------------------------------------------------------------------------------+   |
|   | Linux Filesystem (Maildir Format - 0700/0600 Permissions)                       |   |
|   |  * /home/bob/Maildir/{cur,new,tmp}                                             |   |
|   |  * /home/alice/Maildir/{cur,new,tmp}                                           |   |
|   +--------------------------------------------------------------------------------+   |
|            ^                                                                           |
|            | (MDA Remote Fetch - IMAP: 143/993, POP3: 110/995)                         |
|   +--------------------------------------------------------------------------------+   |
|   | Dovecot (MDA / POP3 & IMAP Daemon)                                             |   |
|   |  * Engine v2.4+: mail_driver = maildir, mail_home = /home/%{user}              |   |
|   |  * Linux PAM / shadow authentication                                          |   |
|   +--------------------------------------------------------------------------------+   |
+----------------------------------------------------------------------------------------+
```

### Maildir vs. mbox: Why Maildir Was Chosen
* **mbox Bottleneck:** All messages are concatenated in a single flat file (`/var/mail/username`). Simultaneous reads and writes require advisory file locking (`fcntl`, `flock`), causing race conditions and mailbox corruption under concurrency.
* **Maildir Concurrency:** Every email is saved as an individual file with a unique timestamped filename inside `new/`, `cur/`, and `tmp/`. Maildir achieves **lock-free, atomic operations** across the MTA (writer) and MDA (reader).

### Dual Dovecot Engine Support
The toolkit includes dynamic version detection (`get_dovecot_version`) and template sanitization:
* **Dovecot 2.4.2+ (Ubuntu 24.04 LTS):** Adapts to the modern syntax:
  * `mail_driver = maildir`
  * `mail_home = /home/%{user}`
  * `mail_path = ~/Maildir`
  * `auth_allow_cleartext = yes`
  * Automatically supersedes deprecated `disable_plaintext_auth`, `mail_location`, and conflicting Ubuntu `mail_inbox_path` directives.
* **Dovecot 2.3 (Ubuntu 22.04 LTS):** Applies traditional syntax:
  * `mail_location = maildir:~/Maildir`
  * `disable_plaintext_auth = no`

---

## 3. Complete Step-by-Step Guide to Run the Project

### Step 1: Transfer & Make the Script Executable
Clone or copy `mail-toolkit.sh` to your Ubuntu machine:
```bash
# If copying from Mac/PC to Ubuntu via SCP:
scp mail-toolkit.sh <username>@<ubuntu-ip>:~/mail-toolkit.sh

# On Ubuntu: Make executable
chmod +x mail-toolkit.sh
```

---

### Step 2: Run the Interactive Management Toolkit
Launch the toolkit with root privileges:
```bash
sudo ./mail-toolkit.sh
```

You will see the main management menu:
```text
======================================================================
   Local Mail Server Setup and Management Toolkit
======================================================================
  1) Check prerequisites & installed packages
  2) Install full mail suite (Postfix, Dovecot IMAP/POP3, SpamAssassin)
  3) Configure local mail delivery (SMTP, IMAP, POP3, Maildir)
  4) Configure TLS/SSL encryption (Self-signed cert, IMAPS, POP3S)
  5) Configure SpamAssassin spam filtering
  6) Configure trusted LAN subnet access (Optional)
  7) Manage local mail user accounts (List / Add / Reset / Delete)
  8) Validate configuration (Postfix & Dovecot syntax)
  9) Show service status & listening ports (25, 110, 143, 993, 995, 587)
  10) Show testing guide (SMTP, IMAP, POP3, TLS, Spam)
  11) Stop & disable all mail services (Postfix, Dovecot, SpamAssassin)
  12) Remove toolkit-managed configuration (Restore clean configs)
  13) Exit
```

Execute the options in the following sequence:

1. **Option `1`:** Run prerequisite checks (CPU, RAM, disk space, and package availability).
2. **Option `2`:** Install all required packages (`postfix`, `dovecot-core`, `dovecot-imapd`, `dovecot-pop3d`, `spamassassin`, `spamc`).
3. **Option `3`:** Configure local delivery. Sets up Postfix for local Maildir delivery and Dovecot for IMAP/POP3.
4. **Option `4`:** Generate a 2048-bit RSA self-signed SSL/TLS certificate (`mail-toolkit.crt` & `mail-toolkit.key`) and configure secure listeners.
5. **Option `5`:** Enable SpamAssassin content filtering integrated into the Postfix pipeline.
6. **Option `6`:** Configure Trusted LAN Subnet Access.  
   * **Automatic Network Detection:** The toolkit automatically inspects the device's active network interface (via `ip route` / `ip addr` / `hostname -I`), resolves its local IP address, and calculates the exact CIDR subnet (e.g., `192.168.0.0/24`).  
   * Press **Enter** to immediately accept the auto-detected subnet, or enter a custom CIDR notation if needed.  
   * Binds Postfix and Dovecot to all interfaces (`0.0.0.0` / `[::]`) and authorizes your trusted LAN subnet in `mynetworks`.
7. **Option `7`:** User Management:
   * Select **`b`** to create user **`alice`** (set password e.g., `pass1234`).
   * Select **`b`** to create user **`bob`** (set password e.g., `pass1234`).
   * Select **`a`** to list accounts and verify their `~/Maildir` status.
   * Select **`e`** to return to the main menu.
8. **Option `8`:** Validate configuration. Runs `postfix check` and `doveconf -n` to guarantee zero syntax errors.
9. **Option `9`:** Inspect active listening ports. Confirm that ports `25`, `110`, `143`, `587`, `993`, and `995` are in `LISTEN` state.

---

### Step 3: Configure Desktop Client (Mozilla Thunderbird)

Set up **Bob** on your computer (Mac / Windows / Linux):

1. Open Mozilla Thunderbird $\rightarrow$ **Account Settings** $\rightarrow$ **Add Mail Account**.
2. Enter:
   * **Full Name:** `Bob`
   * **Email Address:** `bob@localdomain`
   * **Password:** *(Bob's password)*
3. Click **Configure manually** (do not use automated search):

| Field | Incoming Server (IMAP) | Outgoing Server (SMTP) |
|---|---|---|
| **Protocol** | `IMAP` | `SMTP` |
| **Hostname** | `<UBUNTU_IP>` (e.g. `192.168.0.113`) | `<UBUNTU_IP>` (e.g. `192.168.0.113`) |
| **Port** | `143` | `25` |
| **Connection Security** | `None` *(or `STARTTLS`)* | `None` |
| **Authentication** | `Normal password` | `Normal password` *(or `None`)* |
| **Username** | **`bob`** *(Delete `@localdomain`)* | **`bob`** |

4. Click **Re-test** $\rightarrow$ Click **Done** $\rightarrow$ Check **"I understand the risks"** and click **Confirm**.

---

### Step 4: Configure Mobile Client (iPhone / Android)

Set up **Alice** on your mobile phone:

> ⚠️ **Important Mobile Pre-requisite:**  
> Temporarily turn **OFF Cellular / Mobile Data** on your phone. Connect your phone to the **same Wi-Fi network** as the Ubuntu server.

#### iPhone (Apple Mail):
1. Go to **Settings** $\rightarrow$ **Apps** $\rightarrow$ **Mail** $\rightarrow$ **Mail Accounts** $\rightarrow$ **Add Account** $\rightarrow$ scroll to bottom and tap **Other** $\rightarrow$ **Add Mail Account**.
2. Enter:
   * **Name:** `Alice`
   * **Email:** `alice@localdomain`
   * **Password:** *(Alice's password)*
3. Tap **Next** $\rightarrow$ Select **IMAP**:
   * **Incoming Server:** Host Name: `<UBUNTU_IP>`, User Name: `alice`, Password: *(password)*
   * **Outgoing Server:** Host Name: `<UBUNTU_IP>`, User Name: `alice`, Password: *(password)*
4. Tap **Next**. When prompted *"Cannot Connect Using SSL. Do you want to try setting up without SSL?"*, tap **Yes** $\rightarrow$ Tap **Save**.
5. Tap the new account $\rightarrow$ tap **Account Settings**:
   * Tap **Advanced**: Set **Use SSL** to **OFF** $\rightarrow$ Set **Server Port** to **`143`**.
   * Go back $\rightarrow$ Tap **SMTP** $\rightarrow$ Primary Server: Set **Use SSL** to **OFF** $\rightarrow$ Set **Server Port** to **`25`** *(or `587`)*.

---

## 4. End-to-End Mail Verification Walkthrough

### Test A: Send Email from Mac (Bob) to Phone (Alice)
1. On your Mac in Thunderbird, compose a new message:
   * **To:** `alice@localdomain`
   * **Subject:** `Project Verification Test`
   * **Body:** `Hello Alice, this message proves local delivery across our LAN!`
2. Click **Send**.
3. On your iPhone, open the Mail app and pull down to refresh:
   * **The email will immediately appear in Alice's inbox!**
4. On Ubuntu, verify the physical Maildir file:
   ```bash
   sudo ls -l /home/alice/Maildir/new/
   sudo cat /home/alice/Maildir/new/*
   ```

---

### Test B: Reply from Phone (Alice) to Mac (Bob)
1. On your iPhone, open Bob's email and tap **Reply**.
2. Type: `Hi Bob, received successfully on iOS via our local Postfix MTA!`
3. Tap **Send**.
4. In Thunderbird on your Mac, click **Get Messages**:
   * **Alice's reply appears in Bob's inbox!**

---

### Test C: Command-Line Protocol Testing

#### 1. Test SMTP via Netcat (Port 25)
```bash
nc 127.0.0.1 25
HELO localdomain
MAIL FROM: <bob@localdomain>
RCPT TO: <alice@localdomain>
DATA
Subject: Direct Socket Test
Hello Alice via raw SMTP socket.
.
QUIT
```

#### 2. Test IMAP via Netcat (Port 143)
```bash
nc 127.0.0.1 143
a1 LOGIN alice <password>
a2 LIST "" "*"
a3 SELECT INBOX
a4 FETCH 1 BODY[HEADER.FIELDS (SUBJECT FROM)]
a5 LOGOUT
```

#### 3. Test POP3 via Netcat (Port 110)
```bash
nc 127.0.0.1 110
USER alice
PASS <password>
STAT
RETR 1
QUIT
```

#### 4. Test SSL/TLS Secure Sockets (OpenSSL)
```bash
# IMAPS (Port 993)
openssl s_client -connect 127.0.0.1:993 -quiet

# POP3S (Port 995)
openssl s_client -connect 127.0.0.1:995 -quiet
```

---

### Test D: Anti-Spam Filtering Verification (GTUBE)
Test SpamAssassin's content filter by sending the standard GTUBE spam signature:
```bash
echo "Subject: Spam Detection Test
XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X" | sendmail -v alice@localdomain
```
Check that SpamAssassin automatically scanned and flagged the message:
```bash
sudo grep -E 'X-Spam-Flag|X-Spam-Status' /home/alice/Maildir/new/*
```
Expected output:
```text
X-Spam-Flag: YES
X-Spam-Status: Yes, score=1000.0 required=5.0 ...
```

---

## 5. Security & Safety Model

1. **Closed Relay Protection:**  
   `smtpd_relay_restrictions = permit_mynetworks, reject`  
   Unauthorized external clients cannot use the server to bounce spam.
2. **Internet Isolation:**  
   `default_transport = error:Public Internet delivery is disabled by local mail toolkit`  
   Prevents accidental outbound mail leaks to public internet domains.
3. **Least Privilege & Privacy:**  
   User mailboxes are strictly set to `0700` (`drwx------`) and files to `0600` (`-rw-------`). Non-root users cannot read other users' emails.
4. **Automated Rollback & Defensive Backups:**  
   Prior to any file edit, timestamped backups are stored in `/var/backups/mail-toolkit/`. If syntax validation (`postfix check` or `doveconf -n`) fails, changes are automatically reverted.
5. **Zero Credential Exposure:**  
   No passwords are hardcoded, stored in plaintext, or committed to logs. Authentication relies on Linux PAM and `/etc/shadow`.

---

## 6. CLI Non-Interactive Automation Flags

For automated testing or scripting, the toolkit can be operated headlessly:
```bash
# Non-destructive dry run check
./mail-toolkit.sh --dry-run -c

# Automated installation & configuration
sudo ./mail-toolkit.sh --install --yes
sudo ./mail-toolkit.sh --configure-local --yes
sudo ./mail-toolkit.sh --configure-ssl --yes
sudo ./mail-toolkit.sh --configure-spam --yes
sudo ./mail-toolkit.sh --configure-lan --yes           # Uses auto-detected subnet, or pass custom CIDR e.g. 192.168.0.0/24

# Validate and show status
sudo ./mail-toolkit.sh -v
sudo ./mail-toolkit.sh -s

# Stop and disable all mail daemons
sudo ./mail-toolkit.sh --stop

# Strip all toolkit-managed configuration blocks
sudo ./mail-toolkit.sh --remove
```

---

## 7. How to Stop or Teardown Everything

When you have finished demonstrating the project and want to shut down or clean up:

### Method A: Stop & Disable All Services (Shutdown Mode)
To stop the daemons, release memory, and close all listening ports (`25`, `110`, `143`, `587`, `993`, `995`):
* **Interactive Menu:** Run `sudo ./mail-toolkit.sh` and select **Option `11`** (*Stop & disable all mail services*).
* **CLI Flag:**
  ```bash
  sudo ./mail-toolkit.sh --stop
  ```
* **Or direct systemctl command:**
  ```bash
  sudo systemctl stop postfix dovecot spamassassin
  sudo systemctl disable postfix dovecot spamassassin
  ```
> 💡 *To start the mail server again at any time:*  
> `sudo systemctl start postfix dovecot`

---

### Method B: Clean Teardown (Remove All Configurations)
If you want to completely remove all toolkit-managed settings and restore the original configuration files from timestamped backups:
* **Interactive Menu:** Run `sudo ./mail-toolkit.sh` and select **Option `12`** (*Remove toolkit-managed configuration*).
* **CLI Flag:**
  ```bash
  sudo ./mail-toolkit.sh --remove
  ```
This leaves the installed packages on the system while cleanly reverting configuration files to their original defaults.
