\getenv database DB_NAME
\getenv username DB_USER
\getenv password DB_PASSWORD
SELECT format('CREATE ROLE %I LOGIN', :'username')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'username') \gexec
ALTER ROLE :"username" WITH LOGIN PASSWORD :'password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
SELECT format('CREATE DATABASE %I OWNER %I', :'database', :'username')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'database') \gexec
ALTER DATABASE :"database" OWNER TO :"username";
REVOKE ALL ON DATABASE :"database" FROM PUBLIC;
