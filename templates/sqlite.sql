PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS mail_domains (
  id    INTEGER PRIMARY KEY AUTOINCREMENT,
  name  TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS mail_users (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  domain_id  INTEGER NOT NULL,
  email      TEXT NOT NULL UNIQUE,   -- full address (user@domain)
  password   TEXT NOT NULL,          -- Dovecot hash (e.g., {SHA256-CRYPT}...)
  quota      INTEGER NULL,
  FOREIGN KEY(domain_id) REFERENCES mail_domains(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS mail_aliases (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  domain_id   INTEGER NOT NULL,
  source      TEXT NOT NULL UNIQUE,  -- full address alias
  destination TEXT NOT NULL,         -- full address target
  FOREIGN KEY(domain_id) REFERENCES mail_domains(id) ON DELETE CASCADE
);
