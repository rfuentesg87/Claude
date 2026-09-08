# CRM Jomipsa

CRM propio para los comerciales de Jomipsa, conectado a Business Central.

- **Contexto y reglas del proyecto:** [`CLAUDE.md`](CLAUDE.md)
- **Cómo arrancar en Claude Code:** [`PROMPT-INICIAL.md`](PROMPT-INICIAL.md)
- **Arquitectura detallada:** [`docs/arquitectura.md`](docs/arquitectura.md)

## Orden de ejecución de la base de datos

```
db/01_esquemas_ddl.sql              esquemas core, crm, crm_v y tablas
db/00_vistas_base_erp.sql           capa base crm_v.Erp*: única frontera con el ERP
db/02_vistas_ficha360.sql           capa crm_v y vistas de la ficha
db/03_seguridad_rls.sql             usuario crm_app, permisos y RLS
db/04_propiedades_personalizadas.sql
db/05_autolog_m365.sql
db/06_presupuestos_pedidos.sql
```

El `00` va después del `01` (necesita el esquema `crm_v`) y antes del `02`.

Ninguno se ha ejecutado todavía. Revisar antes de aplicar: la base de datos es de
producción y la comparten los pipelines de datos y los paneles ya en marcha. La
revisión crítica de los scripts está en [`docs/revision-scripts-db.md`](docs/revision-scripts-db.md).
