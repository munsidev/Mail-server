# Course Project Report Outline: Local Mail Server Setup and Management Toolkit

**Student Name**: Khalid hasan Munsi  
**Student ID**: 241-15-730  
**Course**: Operating Systems / Computer Networks & Security  
**Project Title**: Local Mail Server Setup and Management Toolkit on Ubuntu Linux  
**Target Environment**: Ubuntu 22.04 LTS / 24.04 LTS  
**Primary Technologies**: Bash, Postfix (SMTP), Dovecot (IMAP & POP3), OpenSSL (TLS/SSL), SpamAssassin, Linux PAM  

---

## 1. Introduction & Executive Summary
- **1.1 Project Motivation**:
  - Educational necessity of understanding the client-server email stack in Unix/Linux.
  - Automating the deployment of an integrated, secure, multi-protocol mail ecosystem.
- **1.2 Course Learning Outcomes**:
  - Comprehensive coverage of:
    - **Email Protocols**: SMTP (RFC 5321), IMAP (RFC 3501), POP3 (RFC 1939).
    - **Server Configuration**: Multi-daemon coordination (Postfix, Dovecot, SpamAssassin).
    - **Network Security**: Closed relay policies, TLS/SSL transport encryption, LAN subnet boundary isolation.
    - **User Management**: Linux PAM authentication and user lifecycle administration.
    - **Spam Filtering**: Content inspection pipeline with SpamAssassin.
- **1.3 Scope and Boundary Design**:
  - Restricted to local Ubuntu host and authorized LAN subnets.
  - Strict exclusion of public internet delivery to guarantee safe laboratory isolation.

---

## 2. Theoretical Background & Protocol Architecture
- **2.1 The Unix Mail Architecture**:
  - **MUA (Mail User Agent)**: Client-side interaction (`mail`, `mutt`, Apple Mail, Thunderbird).
  - **MTA (Mail Transfer Agent)**: Postfix handling SMTP packet reception and local dispatch.
  - **MDA (Mail Delivery Agent)**: Local message routing into individual user mailboxes.
  - **Access Daemons (IMAP/POP3)**: Dovecot serving mailboxes over IMAP and POP3.
- **2.2 Protocol Comparison: SMTP, IMAP, and POP3**:
  - **SMTP (Port 25 / 587)**: Push transport protocol for message relaying.
  - **IMAP (Port 143 / 993)**: Stateful pull protocol supporting remote folder synchronization and message flags.
  - **POP3 (Port 110 / 995)**: Lightweight pull protocol designed for downloading messages to local client storage.
- **2.3 Concurrency & Filesystem Storage: mbox vs. Maildir**:
  - Disadvantages of `mbox`: Monolithic file lock contention (`flock`/`fcntl`), deadlock hazards.
  - Advantages of `Maildir`: Directory-based format (`~/Maildir/` with `tmp/`, `new/`, `cur/`), lockless atomic message writes via POSIX system calls.
- **2.4 Cryptographic Transport (TLS/SSL)**:
  - Symmetric vs. asymmetric encryption in mail transport.
  - Opportunistic STARTTLS vs. dedicated SSL/TLS wrappers (Ports 993 IMAPS, 995 POP3S).
  - Public-key infrastructure (PKI) and self-signed certificate generation.
- **2.5 Automated Content Filtering (SpamAssassin)**:
  - Architecture of `spamd` and `spamc`.
  - Rule-based heuristics, genetic algorithms, and Bayes classification.
  - Postfix content filter pipe integration and header injection (`X-Spam-Status`).

---

## 3. Toolkit System Design & Engineering
- **3.1 Architectural Principles**:
  - Modularity, idempotency, least privilege, and fail-safe automation in Bash.
- **3.2 Defensive Scripting**:
  - `set -euo pipefail`, strict parameter quoting, avoidance of `eval`.
  - Routing UI messages to `stderr` to preserve clean data pipelines on `stdout`.
- **3.3 Managed Configuration Blocks & Tag Delimiters**:
  - Unique tags (`# === BEGIN MANAGED BY MAIL-TOOLKIT ===` ... `# === END MANAGED BY MAIL-TOOLKIT ===`).
  - Suppression of duplicate directive warnings (`#[superseded]`) in Postfix and Dovecot.
- **3.4 Pre-Restart Validation & Automated Rollback**:
  - Atomic verification via `postfix check` and `doveconf -n`.
  - Automated recovery from timestamped backups (`/var/backups/mail-toolkit/`).

---

## 4. Implementation Details
- **4.1 Package Provisioning & Prerequisite Inspection**:
  - Automated non-interactive installation of `postfix`, `dovecot-imapd`, `dovecot-pop3d`, `mailutils`, `spamassassin`, `spamc`.
- **4.2 Dual Dovecot Architecture Support**:
  - Dynamic runtime version detection (`get_dovecot_version`).
  - Dovecot 2.4+ compatibility (`auth_allow_cleartext = yes`, `mail_driver = maildir`).
  - Dovecot 2.3 compatibility (`disable_plaintext_auth = no`, `mail_location = maildir:~/Maildir`).
- **4.3 TLS/SSL Encryption Pipeline**:
  - Generation of 2048-bit RSA self-signed certificates via OpenSSL.
  - Postfix configuration (`smtpd_tls_security_level = may`, `smtpd_tls_cert_file`).
  - Dovecot SSL listener activation for IMAPS (993) and POP3S (995).
- **4.4 SpamAssassin Filter Pipe**:
  - Integration in Postfix `master.cf` via `spamc` pipe filter.
  - Daemon enablement in `/etc/default/spamassassin`.
- **4.5 User Management & Account Administration**:
  - Interactive user creation, password modification, and Maildir status auditing.

---

## 5. Verification, Testing & Empirical Results
- **5.1 Test Environment Specification**:
  - Ubuntu 22.04 / 24.04 LTS test machine with test accounts (`alice`, `bob`).
- **5.2 Multi-Protocol Functional Verification**:
  - SMTP delivery verification via `sendmail bob@localhost`.
  - IMAP retrieval verification on port 143 and port 993 (IMAPS).
  - POP3 retrieval verification on port 110 and port 995 (POP3S).
- **5.3 Security & Spam Verification**:
  - Closed relay penetration test (external recipient rejection `554 5.7.1`).
  - SpamAssassin GTUBE test string verification (`X-Spam-Flag: YES`).
  - TLS/SSL handshake verification using `openssl s_client`.

---

## 6. Security Analysis & Course Limitations
- **6.1 Open Relay Prevention**:
  - Analysis of SMTP spambots and `smtpd_relay_restrictions`.
- **6.2 Local Educational Server vs. Production Internet Delivery**:
  - Detailed explanation of requirements for public internet email:
    - Public DNS A & MX records.
    - Reverse DNS (PTR) alignment.
    - SPF, DKIM, and DMARC cryptographic records.
    - Residential ISP Port 25 outbound blocks.

---

## 7. Educational Reflections & Conclusion
- Review of operating systems concepts reinforced: daemons, IPC sockets, file locking, permissions, and security.
- Summary of project achievements and grading rubric fulfillment.
