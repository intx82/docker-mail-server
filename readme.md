# Mail server template

How to:

## 1. Retrieve certificates

```sh
certbot certonly --standalone -d $MAIL_DOMAIN
```

Where $MAIL_DOMAIN - your mail domain (like mail.*)

Then, put fullchain.pem and private.key to the repo root folder.

Let's encrypt stores certificates in: `/etc/letsencrypt/live/$MAIL_DOMAIN/`

## 2. Build docker container

```sh
sudo docker compose up -d --build
```

## 3. Add DNS records

| name | type | value |
| --- | --- | --- |
| @   | MX  | $MAIL_DOMAIN prio: 10 |
| @   | TXT | v=spf1 ip4:$MAIL_DOMAIN_IP a:$MAIL_DOMAIN ~all |
| _dmarc | TXT | v=DMARC1; p=quarantine; rua=mailto:dmarc-reports@$DOMAIN; ruf=mailto:dmarc-reports@$DOMAIN; fo=1; adkim=s; aspf=s |
| mail2025._domainkey | TXT | { value from /etc/opendkim/keys/$DOMAIN/mail2025.txt } |

DKIM (mail2025._domainkey) value looks like:  `v=DKIM1; h=sha256; k=rsa; p=MIIB...`

> it can be read using `docker exec -it mail /bin/bash`

## 4. Test a sending mails

```sh
swaks --server $MAIL_DOMAIN --port 587 --tls --auth LOGIN --auth-user "$MAIL_NAME" --auth-password '$MAIL_PWD' --from "$MAIL_NAME" --to $RCPT_TEST_MAIL --header "Subject: Test via Postfix/Dovecot" --body "noreply test mail, again, dmarc test, dkim test"
``` 

Then open mail and show raw data, and found next:

```
ARC-Authentication-Results: i=1; mx.google.com;
       dkim=pass header.i=@$MAIL_DOMAIN header.s=mail2025 header.b=...;
       spf=pass (google.com: domain of noreply@$MAIL_DOMAIN designates $MAIL_IP as permitted sender) smtp.mailfrom=noreply@$MAIL_DOMAIN;
       dmarc=pass (p=QUARANTINE sp=QUARANTINE dis=NONE) header.from=$MAIL_DOMAIN
```

