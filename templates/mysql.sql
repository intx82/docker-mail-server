-- CREATE DATABASE IF NOT EXISTS mailserver CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE mailserver;

CREATE TABLE IF NOT EXISTS mail_domains (
  id   INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255) NOT NULL UNIQUE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS mail_users (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  domain_id  INT NOT NULL,
  email      VARCHAR(255) NOT NULL UNIQUE,  -- user@domain
  password   VARCHAR(255) NOT NULL,         -- {SHA256-CRYPT}...
  quota      INT NULL,
  FOREIGN KEY (domain_id) REFERENCES mail_domains(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS mail_aliases (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  domain_id   INT NOT NULL,
  source      VARCHAR(255) NOT NULL UNIQUE, -- alias@domain
  destination VARCHAR(255) NOT NULL,        -- target@domain
  FOREIGN KEY (domain_id) REFERENCES mail_domains(id) ON DELETE CASCADE
) ENGINE=InnoDB;

