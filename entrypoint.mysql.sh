#!/usr/bin/env bash
set -euo pipefail

# --- Core env (as before) ---
: "${DOMAIN:?Set DOMAIN=yourdomain.com}"
: "${HOSTNAME_FQDN:=mail.${DOMAIN}}"
: "${DKIM_SELECTOR:=mail}"
: "${ENABLE_OPENDMARC:=true}"
: "${ENABLE_SPAMASSASSIN:=false}"
: "${ENABLE_POP3:=false}"
: "${SSL_CERT:=/etc/mail.fullchain.pem}"
: "${SSL_KEY:=/etc/mail.privkey.pem}"
: "${INIT_SQL:=/etc/init.mysql.sql}"

# --- MySQL env ---
: "${MYSQL_HOST:=db}"                 # service name from docker-compose
: "${MYSQL_PORT:=3306}"
: "${MYSQL_DB:=mailserver}"
: "${MYSQL_USER:=mailuser}"
: "${MYSQL_PASSWORD:=mailpass}"
: "${MYSQL_SSL:=false}"               # set true if you enable TLS to DB

# Optional seed user
: "${DEFAULT_VUSER:=}"               # e.g. alice@yourdomain.com
: "${DEFAULT_VPASS:=}"

echo "[entrypoint] DOMAIN=${DOMAIN} HOSTNAME_FQDN=${HOSTNAME_FQDN}"

echo "${HOSTNAME_FQDN}" > /etc/mailname

# --- TLS presence check (same as before) ---
if [[ ! -s "${SSL_CERT}" || ! -s "${SSL_KEY}" ]]; then
  echo "WARNING: TLS cert/key not found at ${SSL_CERT} - ${SSL_KEY} "
fi


mkdir -p /var/mail/vhosts
mkdir -p /var/log/supervisor

# --- DKIM key generation (same as before) ---
DKIM_DIR="/etc/opendkim/keys/${DOMAIN}"
DKIM_PRIV="${DKIM_DIR}/${DKIM_SELECTOR}.private"
if [[ ! -s "${DKIM_PRIV}" ]]; then
  mkdir -p "${DKIM_DIR}"
  opendkim-genkey -b 2048 -s "${DKIM_SELECTOR}" -d "${DOMAIN}" -D "${DKIM_DIR}"
  chown opendkim:opendkim "${DKIM_PRIV}"
  chmod 600 "${DKIM_PRIV}"
  echo "DKIM DNS TXT (selector ${DKIM_SELECTOR}):"
  cat "${DKIM_DIR}/${DKIM_SELECTOR}.txt" || true
fi
cat >/etc/opendkim/key.table <<EOF
${DKIM_SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${DKIM_SELECTOR}:${DKIM_PRIV}
EOF
cat >/etc/opendkim/signing.table <<EOF
*@${DOMAIN} ${DKIM_SELECTOR}._domainkey.${DOMAIN}
EOF

# --- Postfix config render (same as before) ---
sed -e "s/__HOSTNAME_FQDN__/${HOSTNAME_FQDN}/g" \
    -e "s/__DOMAIN__/${DOMAIN}/g" \
    -e "s#__SSL_CERT__#${SSL_CERT}#g" \
    -e "s#__SSL_KEY__#${SSL_KEY}#g" \
    /etc/postfix/templates/main.cf > /etc/postfix/main.cf
cp /etc/postfix/templates/master.cf /etc/postfix/master.cf

# --- Render Postfix MySQL maps ---
for f in virtual-domains.cf virtual-users.cf virtual-aliases.cf; do
  sed -e "s/__MYSQL_HOST__/${MYSQL_HOST}/g" \
      -e "s/__MYSQL_PORT__/${MYSQL_PORT}/g" \
      -e "s/__MYSQL_DB__/${MYSQL_DB}/g" \
      -e "s/__MYSQL_USER__/${MYSQL_USER}/g" \
      -e "s/__MYSQL_PASSWORD__/${MYSQL_PASSWORD}/g" \
      /etc/postfix/mysql/$f > /etc/postfix/mysql/$f.r
  mv /etc/postfix/mysql/$f.r /etc/postfix/mysql/$f
done
chmod 640 /etc/postfix/mysql/*.cf
chown root:postfix /etc/postfix/mysql/*.cf

# --- Dovecot configs ---
MAIL_ROOT="/var/mail/vhosts"
chown -R vmail:vmail "${MAIL_ROOT}"

sed -e "s#__MAIL_LOCATION__#maildir:${MAIL_ROOT}/%d/%n/Maildir#g" \
    /etc/dovecot/templates/10-mail.conf > /etc/dovecot/conf.d/10-mail.conf
sed -e "s/__DISABLE_PLAINTEXT__/yes/g" \
    /etc/dovecot/templates/10-auth.conf > /etc/dovecot/conf.d/10-auth.conf
sed -e "s#__ENABLE_POP3__#${ENABLE_POP3}#g" \
    /etc/dovecot/templates/10-master.conf > /etc/dovecot/conf.d/10-master.conf
sed -e "s#__SSL_CERT__#${SSL_CERT}#g" \
    -e "s#__SSL_KEY__#${SSL_KEY}#g" \
    /etc/dovecot/templates/10-ssl.conf > /etc/dovecot/conf.d/10-ssl.conf

# Dovecot SQL (MySQL) render
sed -e "s/__MYSQL_HOST__/${MYSQL_HOST}/g" \
    -e "s/__MYSQL_PORT__/${MYSQL_PORT}/g" \
    -e "s/__MYSQL_DB__/${MYSQL_DB}/g" \
    -e "s/__MYSQL_USER__/${MYSQL_USER}/g" \
    -e "s/__MYSQL_PASSWORD__/${MYSQL_PASSWORD}/g" \
    -e "s/__MYSQL_SSL__/${MYSQL_SSL}/g" \
    /etc/dovecot/templates/dovecot-sql.conf.ext > /etc/dovecot/dovecot-sql.conf.ext
chmod 640 /etc/dovecot/dovecot-sql.conf.ext
chown root:dovecot /etc/dovecot/dovecot-sql.conf.ext

# --- OpenDMARC toggle (same as before) ---
if [[ "${ENABLE_OPENDMARC}" == "true" ]]; then
  sed -e "s/__HOSTNAME_FQDN__/${HOSTNAME_FQDN}/g" /etc/opendmarc/templates/opendmarc.conf > /etc/opendmarc/opendmarc.conf
  ln -s /etc/opendmarc.conf /etc/opendmarc/opendmarc.conf
else
  sed -i 's#, unix:/opendmarc/opendmarc.sock##g' /etc/postfix/main.cf || true
fi


wait_for_mysql() {
  echo "[entrypoint] Waiting for MySQL at ${MYSQL_HOST}:${MYSQL_PORT}..."
  local i=0
  while ! mysqladmin ping \
           -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" \
           -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
           --silent >/dev/null 2>&1; do
    i=$((i+1))
    if [ "$i" -ge 60 ]; then
      echo "ERROR: MySQL not reachable after 60s"
      exit 1
    fi
    sleep 1
  done
}

init_mysql_schema() {
  [ -s "${INIT_SQL}" ] || { echo "[entrypoint] No INIT_SQL at ${INIT_SQL}, skipping DB init"; return; }

  wait_for_mysql

  # Count known tables. If fewer than 3 exist, apply the schema.
  local count
  count=$(mysql -N -s \
    -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" \
    -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" --skip-ssl \
    -e "SELECT COUNT(*) FROM information_schema.tables
        WHERE table_schema='${MYSQL_DB}'
          AND table_name IN ('mail_domains','mail_users','mail_aliases');" 2>/dev/null || echo 0)

  echo "[entrypoint] Found: ${count} tables"
  if [ "${count}" -lt 3 ]; then
    echo "[entrypoint] Applying schema from ${INIT_SQL}"
    mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" --skip-ssl < "${INIT_SQL}"
  else
    echo "[entrypoint] Schema already present (tables found: ${count}), skipping."
  fi
}


init_mysql_schema

# --- Optional: seed a default virtual user into MySQL ---
if [[ -n "${DEFAULT_VUSER}" && -n "${DEFAULT_VPASS}" ]]; then
  if [[ "${DEFAULT_VUSER}" != *"@"* ]]; then
    echo "ERROR: DEFAULT_VUSER must be full email like user@${DOMAIN}"
    exit 1
  fi
  DEF_DOMAIN="${DEFAULT_VUSER##*@}"
  DEF_LOCAL="${DEFAULT_VUSER%@*}"
  HASH=$(doveadm pw -s SHA256-CRYPT -p "${DEFAULT_VPASS}")
  mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" "${MYSQL_DB}" <<SQL
INSERT IGNORE INTO mail_domains(name) VALUES ('${DEF_DOMAIN}');
INSERT INTO mail_users(domain_id, email, password)
  SELECT id, '${DEFAULT_VUSER}', '${HASH}'
  FROM mail_domains WHERE name='${DEF_DOMAIN}'
ON DUPLICATE KEY UPDATE password=VALUES(password);
SQL
  mkdir -p "${MAIL_ROOT}/${DEF_DOMAIN}/${DEF_LOCAL}/Maildir"/{cur,new,tmp}
  chown -R vmail:vmail "${MAIL_ROOT}/${DEF_DOMAIN}/${DEF_LOCAL}"
fi

# --- Permissions & start ---
chown -R opendkim:opendkim /etc/opendkim
chmod 640 /etc/opendkim/key.table /etc/opendkim/signing.table /etc/opendkim/trusted.hosts

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
