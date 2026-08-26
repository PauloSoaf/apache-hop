BEGIN;

CREATE SCHEMA IF NOT EXISTS online_retail;

COMMENT ON SCHEMA online_retail IS
  'Camadas de staging, qualidade, modelo dimensional e indicadores do projeto Online Retail.';

COMMIT;
