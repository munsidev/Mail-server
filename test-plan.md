# Test Plan: Local Mail Server Setup and Management Toolkit

**Author:** Khalid hasan Munsi  
**Student ID:** 241-15-730  
**Course:** Operating Systems Lab / Project  

## 1. Overview & Test Scope

This test plan defines verification procedures for the **Local Mail Server Setup and Management Toolkit** (`mail-toolkit.sh`). The tests cover:
- Bash syntax and non-destructive dry-run capabilities.
- Prerequisite detection and package provisioning on Ubuntu.
- Multi-protocol mail operations: **SMTP**, **IMAP**, and **POP3**.
- **TLS/SSL Encryption** verification on ports 25, 110, 143, 993, and 995.
- **SpamAssassin spam filtering** verification using the standardized GTUBE test string.
- User account management and Maildir filesystem validation.
- Security constraints: closed relay enforcement and public internet delivery prevention.
- Clean uninstallation and configuration restoration.

---

## 2. Test Environment Requirements

| Requirement | Specification |
|---|---|
| **Target OS** | Ubuntu 22.04 LTS (Jammy) or Ubuntu 24.04 LTS (Noble) |
| **Access** | Root / sudo access |
| **Host Accounts** | Minimum two regular user accounts (e.g., `alice`, `bob`) |
| **Network** | Loopback interface (`127.0.0.1`) + Optional local Wi-Fi / LAN |

---

## 3. Test Cases Matrix

| Test ID | Category | Description | Target Port | Expected Result |
|---|---|---|---|---|
| **TC-01** | Syntax & Linting | Bash syntax check (`bash -n`) | N/A | Exit code 0, zero errors |
| **TC-02** | Simulation | Dry-run check (`--dry-run --check`) | N/A | Full simulated plan, zero system modifications |
| **TC-03** | Provisioning | Package installation (`--install`) | N/A | Postfix, Dovecot IMAP/POP3, SpamAssassin installed |
| **TC-04** | Configuration | Local mail setup (Option 3) | 25, 110, 143 | SMTP, IMAP, POP3 active; Maildir enabled |
| **TC-05** | Encryption | TLS/SSL setup (Option 4) | 993, 995, 25 | Self-signed cert created; IMAPS & POP3S listening |
| **TC-06** | Spam Filtering | SpamAssassin integration (Option 5) | Postfix pipe | Messages scanned; spam headers injected |
| **TC-07** | Delivery (SMTP) | Local user-to-user mail sending | 25 | Message delivered to `~bob/Maildir/new/` |
| **TC-08** | Access (IMAP) | Dovecot IMAP retrieval | 143 / 993 | Bob logs in, lists and reads email via IMAP |
| **TC-09** | Access (POP3) | Dovecot POP3 retrieval | 110 / 995 | Bob logs in, checks STAT, RETR 1 via POP3 |
| **TC-10** | Spam Detection | GTUBE spam test string | Pipe | Message tagged with `X-Spam-Flag: YES` |
| **TC-11** | Security (Relay) | Attempted open relay to external domain | 25 | Postfix rejects: `554 5.7.1 Relay access denied` |
| **TC-12** | Cleanup | Managed configuration removal (Option 11) | N/A | Managed tags removed; baseline config restored |

---

## 4. Detailed Test Procedures

### TC-01: Bash Syntax and Static Check
```bash
bash -n mail-toolkit.sh
```
* **Pass Criteria**: Exits with code `0`.

---

### TC-02: Non-Destructive Dry-Run Check
```bash
./mail-toolkit.sh --dry-run --check
./mail-toolkit.sh --dry-run --configure-local
./mail-toolkit.sh --dry-run --configure-ssl
./mail-toolkit.sh --dry-run --configure-spam
```
* **Pass Criteria**: Displays planned actions prefixed with `[DRY-RUN]`. Zero files in `/etc` are touched.

---

### TC-03: Package Provisioning
```bash
sudo ./mail-toolkit.sh --install --yes
```
* **Pass Criteria**: `postfix`, `dovecot-core`, `dovecot-imapd`, `dovecot-pop3d`, `mailutils`, `spamassassin`, and `spamc` are installed.

---

### TC-04: Local Delivery Configuration (SMTP, IMAP, POP3)
```bash
sudo ./mail-toolkit.sh --configure-local --yes
sudo ./mail-toolkit.sh --status
```
* **Pass Criteria**: Ports 25 (SMTP), 143 (IMAP), and 110 (POP3) are active and listening on `127.0.0.1`.

---

### TC-05: TLS/SSL Encryption Verification
```bash
sudo ./mail-toolkit.sh --configure-ssl --yes
```
* **Verification**:
  ```bash
  # Test IMAPS (Port 993)
  openssl s_client -connect 127.0.0.1:993 -quiet <<< "a1 LOGOUT"
  # Test POP3S (Port 995)
  openssl s_client -connect 127.0.0.1:995 -quiet <<< "QUIT"
  # Test SMTP STARTTLS (Port 25)
  openssl s_client -starttls smtp -connect 127.0.0.1:25 -quiet <<< "QUIT"
  ```
* **Pass Criteria**: TLS handshakes complete successfully on ports 25, 993, and 995.

---

### TC-06 & TC-10: SpamAssassin Filtering Verification
```bash
sudo ./mail-toolkit.sh --configure-spam --yes

# Send GTUBE spam string
echo "Subject: SpamAssassin Test
XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X" | sendmail -v bob@localhost

# Inspect headers in recipient Maildir
sudo grep -E 'X-Spam-Flag|X-Spam-Status' ~bob/Maildir/new/*
```
* **Pass Criteria**: Recipient email contains `X-Spam-Flag: YES` and `X-Spam-Status: Yes, score=1000.0`.

---

### TC-07: Local SMTP User Delivery
```bash
echo "Subject: Regular Mail Test
Hello Bob, this is a normal email from Alice." | sendmail -v bob@localhost
sudo ls -la ~bob/Maildir/new/
```
* **Pass Criteria**: Message file exists in `/home/bob/Maildir/new/`.

---

### TC-08: IMAP Mailbox Retrieval
```bash
python3 - <<'EOF'
import imaplib
mail = imaplib.IMAP4('127.0.0.1', 143)
mail.login('bob', 'TestPass123!')
status, messages = mail.select('INBOX')
print(f"IMAP SUCCESS! Messages: {messages[0].decode()}")
mail.logout()
EOF
```
* **Pass Criteria**: IMAP login succeeds and INBOX message count is displayed.

---

### TC-09: POP3 Mailbox Retrieval
```bash
python3 - <<'EOF'
import poplib
pop = poplib.POP3('127.0.0.1', 110)
pop.user('bob')
pop.pass_('TestPass123!')
count, size = pop.stat()
print(f"POP3 SUCCESS! Message count: {count}, Total size: {size}")
pop.quit()
EOF
```
* **Pass Criteria**: POP3 login succeeds and message count is displayed.

---

### TC-11: Closed Relay Penetration Test
```bash
python3 - <<'EOF'
import smtplib
try:
    server = smtplib.SMTP('127.0.0.1', 25)
    server.ehlo('localhost')
    server.mail('alice@localhost')
    code, resp = server.rcpt('victim@google.com')
    if code == 554 or b'Relay access denied' in resp:
        print("SUCCESS: Open relay blocked by Postfix!")
    else:
        print("FAILURE: Open relay permitted!")
    server.quit()
except smtplib.SMTPRecipientsRefused:
    print("SUCCESS: Recipient refused (Relay access denied)!")
EOF
```
* **Pass Criteria**: Output shows `SUCCESS: Open relay blocked by Postfix!`.

---

### TC-12: Complete Cleanup & Restoration
```bash
sudo ./mail-toolkit.sh --remove --yes
```
* **Pass Criteria**: All toolkit-managed configuration blocks are removed, baseline configuration is restored, and mail services reload cleanly.
