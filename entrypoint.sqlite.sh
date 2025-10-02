#!/usr/bin/env bash
set -euo pipefail

# -------- ENV defaults --------
: "${DOMAIN:?Set DOMAIN=yourdomain.com}"
: "${HOSTNAME_FQDN:=mail.${DOMAIN}}"
: "${DKIM_SELECTOR:=mail}"
: "${ENABLE_OPENDMARC:=true}"
: "${ENABLE_SPAMASSASSIN:=false}"
: "${ENABLE_POP3:=false}"
: "${SSL_CERT:=/etc/letsencrypt/live/${HOSTNAME_FQDN}/fullchain.pem}"
: "${SSL_KEY:=/etc/letsencrypt/live/${HOSTNAME_FQDN}/privkey.pem}"

# Seed a virtual user (optional)
: "${DEFAULT_VUSER:=}"      # full address, e.g. alice@yourdomain.com
: "${DEFAULT_VPASS:=}"      # plaintext; will be hashed

echo "[entrypoint] DOMAIN=${DOMAIN} HOSTNAME_FQDN=${HOSTNAME_FQDN}"

# Ensure /etc/mailname matches our FQDN
echo "${HOSTNAME_FQDN}" > /etc/mailname

# TLS presence (warn only)
if [[ ! -s "${SSL_CERT}" || ! -s "${SSL_KEY}" ]]; then
  echo "WARNING: TLS cert/key not found at ${SSL_CERT} / ${SSL_KEY}."
  echo "Mount Let's Encrypt live dir to /etc/letsencrypt."
fi

# -------- DKIM key (generate if missing) --------
DKIM_DIR="/etc/opendkim/keys/${DOMAIN}"
DKIM_PRIV="${DKIM_DIR}/${DKIM_SELECTOR}.private"
if [[ ! -s "${DKIM_PRIV}" ]]; then
  echo "[entrypoint] Generating DKIM key for ${DOMAIN} (selector ${DKIM_SELECTOR})"
  mkdir -p "${DKIM_DIR}"
  opendkim-genkey -b 2048 -s "${DKIM_SELECTOR}" -d "${DOMAIN}" -D "${DKIM_DIR}"
  chown opendkim:opendkim "${DKIM_PRIV}"
  chmod 600 "${DKIM_PRIV}"
  echo "DKIM DNS TXT to publish (selector ${DKIM_SELECTOR}):"
  cat "${DKIM_DIR}/${DKIM_SELECTOR}.txt" || true
fi

# Render OpenDKIM tables
cat >/etc/opendkim/key.table <<EOF
${DKIM_SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${DKIM_SELECTOR}:${DKIM_PRIV}
EOF
cat >/etc/opendkim/signing.table <<EOF
*@${DOMAIN} ${DKIM_SELECTOR}._domainkey.${DOMAIN}
EOF

# -------- Virtual mail root --------
MAIL_ROOT="/var/mail/vhosts"
chown -R vmail:vmail "${MAIL_ROOT}"

# -------- SQLite DB (create if missing) --------
SQL_DB="/etc/dovecot/sql/virtual-mail.db"
if [[ ! -s "${SQL_DB}" ]]; then
  echo "[entrypoint] Initializing SQLite DB at ${SQL_DB}"
  sqlite3 "${SQL_DB}" < /etc/dovecot/sql/virtual-mail.sql
fi

# Optionally seed default domain and user
if [[ -n "${DEFAULT_VUSER}" && -n "${DEFAULT_VPASS}" ]]; then
  if [[ "${DEFAULT_VUSER}" != *"@"* ]]; then
    echo "ERROR: DEFAULT_VUSER must be a full email like user@${DOMAIN}"
    exit 1
  fi
  DEF_DOMAIN="${DEFAULT_VUSER##*@}"
  DEF_LOCAL="${DEFAULT_VUSER%@*}"
  # Insert domain if missing
  sqlite3 "${SQL_DB}" "INSERT OR IGNORE INTO mail_domains(name) VALUES('${DEF_DOMAIN}');"
  # Hash password via Dovecot
  HASH=$(doveadm pw -s SHA256-CRYPT -p "${DEFAULT_VPASS}")
  # Insert/replace user
  sqlite3 "${SQL_DB}" "
    INSERT OR REPLACE INTO mail_users(domain_id, email, password, quota)
    SELECT id, '${DEFAULT_VUSER}', '${HASH}', NULL FROM mail_domains WHERE name='${DEF_DOMAIN}';
  "
  # Ensure Maildir exists
  mkdir -p "${MAIL_ROOT}/${DEF_DOMAIN}/${DEF_LOCAL}/Maildir"/{cur,new,tmp}
  chown -R vmail:vmail "${MAIL_ROOT}/${DEF_DOMAIN}/${DEF_LOCAL}"
fi

# -------- Render Postfix configs --------
POSTFIX_MAIN=/etc/postfix/main.cf
POSTFIX_MASTER=/etc/postfix/master.cf

sed -e "s/__HOSTNAME_FQDN__/${HOSTNAME_FQDN}/g" \
    -e "s/__DOMAIN__/${DOMAIN}/g" \
    -e "s#__SSL_CERT__#${SSL_CERT}#g" \
    -e "s#__SSL_KEY__#${SSL_KEY}#g" \
    /etc/postfix/templates/main.cf > "${POSTFIX_MAIN}"

cp /etc/postfix/templates/master.cf "${POSTFIX_MASTER}"

# -------- Render Dovecot configs (SQL auth) --------
DOVECOT_DIR=/etc/dovecot/conf.d
sed -e "s#__MAIL_LOCATION__#maildir:${MAIL_ROOT}/%d/%n/Maildir#g" \
    /etc/dovecot/templates/10-mail.conf > "${DOVECOT_DIR}/10-mail.conf"

sed -e "s/__DISABLE_PLAINTEXT__/yes/g" \
    /etc/dovecot/templates/10-auth.conf > "${DOVECOT_DIR}/10-auth.conf"

sed -e "s#__ENABLE_POP3__#${ENABLE_POP3}#g" \
    /etc/dovecot/templates/10-master.conf > "${DOVECOT_DIR}/10-master.conf"

sed -e "s#__SSL_CERT__#${SSL_CERT}#g" \
    -e "s#__SSL_KEY__#${SSL_KEY}#g" \
    /etc/dovecot/templates/10-ssl.conf > "${DOVECOT_DIR}/10-ssl.conf"

# Dovecot SQL config
sed -e "s#__SQLITE_PATH__#${SQL_DB}#g" \
    /etc/dovecot/templates/dovecot-sql.conf.ext > /etc/dovecot/dovecot-sql.conf.ext
chmod 640 /etc/dovecot/dovecot-sql.conf.ext
chown root:dovecot /etc/dovecot/dovecot-sql.conf.ext

# -------- OpenDMARC (optional) --------
if [[ "${ENABLE_OPENDMARC}" == "true" ]]; then
  sed -e "s/__HOSTNAME_FQDN__/${HOSTNAME_FQDN}/g" \
      /etc/opendmarc/templates/opendmarc.conf > /etc/opendmarc/opendmarc.conf
else
  # remove OpenDMARC from postfix milters
  sed -i 's#, unix:/opendmarc/opendmarc.sock##g' /etc/postfix/main.cf || true
fi

# SpamAssassin switch
if [[ "${ENABLE_SPAMASSASSIN}" == "true" ]]; then
  sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/spamassassin || true
else
  sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/spamassassin || true
fi

# Permissions sanity
chown -R opendkim:opendkim /etc/opendkim
chmod 640 /etc/opendkim/key.table /etc/opendkim/signing.table /etc/opendkim/trusted.hosts

# Start all services under supervisord
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
