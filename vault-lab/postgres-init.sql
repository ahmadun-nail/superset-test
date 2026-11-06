CREATE DATABASE vault_demo;

CREATE ROLE vault_admin WITH LOGIN CREATEROLE PASSWORD 'lab-only-vault-db-admin';
CREATE ROLE app_readonly_privileges NOLOGIN;
CREATE ROLE app_readwrite NOLOGIN;

\connect vault_demo

GRANT CONNECT ON DATABASE vault_demo TO app_readonly_privileges, app_readwrite;
GRANT USAGE ON SCHEMA public TO app_readonly_privileges, app_readwrite;

CREATE TABLE public.poc_orders (
    order_id INTEGER PRIMARY KEY,
    description TEXT NOT NULL
);

INSERT INTO public.poc_orders (order_id, description) VALUES
    (1, 'sample row one'),
    (2, 'sample row two'),
    (3, 'sample row three');

GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_readonly_privileges;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_readwrite;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO app_readwrite;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT SELECT ON TABLES TO app_readonly_privileges;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_readwrite;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO app_readwrite;

GRANT app_readonly_privileges, app_readwrite TO vault_admin WITH ADMIN OPTION;
