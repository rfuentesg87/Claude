# Prompt inicial para Claude Code

Copia el bloque de abajo y pégalo en Claude Code, dentro de la carpeta del proyecto y
con el `CLAUDE.md` ya en la raíz.

---

```
Vamos a montar el CRM de Jomipsa. Lee CLAUDE.md antes de nada: tiene el contexto
completo, las nueve reglas de oro y las decisiones ya cerradas, que no hay que
volver a abrir.

Estado: los scripts db/01 a db/06 están escritos y verificados columna a columna
contra el esquema real, pero NINGUNO se ha ejecutado todavía contra la base de
datos. El prototipo de la ficha de empresa está en web/prototipos/ como referencia
visual, no como código.

Objetivo de esta primera sesión: dejar la Fase 1 funcionando de punta a punta para
un solo comercial. Es decir, que yo pueda abrir un navegador, autenticarme con mi
cuenta de Jomipsa y ver la ficha real de un cliente de mi cartera con datos vivos.

Empieza por aquí, en este orden:

1. Revisa los seis scripts de db/ con ojo crítico antes de que los ejecutemos.
   Busca errores de sintaxis, referencias a columnas que no existan, y sobre todo
   cualquier sitio donde se incumpla alguna de las reglas de oro de CLAUDE.md.
   Dime lo que encuentres antes de tocar nada.

2. Prepara el docker-compose de api/ con Data API Builder, con la cadena de
   conexión por variable de entorno. Todavía sin levantar.

3. Propón el plan de la aplicación web: React + Vite + TypeScript, móvil primero,
   estructura de carpetas por módulo para que compras e incidencias entren después
   sin tocar lo de comercial. Quiero verlo antes de que escribas componentes.

No ejecutes nada contra la base de datos ni contra Business Central sin
preguntarme. La base de datos es de producción y la comparten los pipelines de
datos y los paneles que ya están en marcha.

Trabajamos en español.
```

---

## Antes de pegar el prompt

1. Crea la carpeta y copia el paquete:

```bash
mkdir -p ~/proyectos/crm-jomipsa && cd ~/proyectos/crm-jomipsa
# copia aquí CLAUDE.md, db/, api/, web/, n8n/, docs/
git init && git add -A && git commit -m "Arranque del CRM: esquema, vistas, seguridad y presupuestos"
```

2. Crea el `.gitignore` **antes** del primer commit:

```
.env
.env.*
*.local
node_modules/
dist/
.mcp.json
```

3. Variables de entorno en `.env` (nunca en git):

```
CRM_SQL_CONNSTR=Server=tcp:<servidor>.database.windows.net,1433;Database=sqldb-jomipsapde-prod-westeu-001;User ID=crm_app;Password=<...>;Encrypt=True;
ENTRA_TENANT_ID=
ENTRA_CLIENT_ID=
ENTRA_CLIENT_SECRET=
BC_ENVIRONMENT=
BC_COMPANY_ID=
```

4. MCP de SQL en el proyecto (`.mcp.json`, también fuera de git). Apúntalo a un
   usuario de **solo lectura**, no al `crm_app` que escribe:

```json
{
  "mcpServers": {
    "mssql": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-mssql"],
      "env": { "MSSQL_CONNECTION_STRING": "${CRM_SQL_RO_CONNSTR}" }
    }
  }
}
```

---

## Prompts para las sesiones siguientes

**Formularios (script 07):**

```
Escribe db/07_formularios.sql siguiendo el diseño que está en CLAUDE.md, sección
"Pendiente de escribir". Lo importante es core.usp_ProcesarEnvioFormulario: la
deduplicación por email es el requisito explícito, no un extra. Antes de escribir,
comprueba contra la base de datos cuántos contactos de bc.Contact tienen email y
cuántos dominios distintos hay, para dimensionar el emparejamiento.
```

**Secuencias (script 08):**

```
Escribe db/08_secuencias.sql siguiendo el diseño de CLAUDE.md. La parada automática
al recibir respuesta se apoya en core.ActividadImportada, así que revisa primero el
script 05 para engancharlo bien. Sin píxel de apertura y con límite diario por buzón.
```

**Carga inicial de contactos:**

```
bc.Contact tiene 3.527 contactos, 2.235 con email, 746 personas y 2.781 empresas.
Escribe el script de carga inicial a core.Empresa y core.Contacto: enlaza por
bc.[Contact Business Relation] con el cliente de BC, evita duplicados, y deja en una
tabla de revisión lo que no case. No sobrescribas nada que ya exista en core.
```

**Frontend de la ficha:**

```
Implementa la ficha de empresa en web/ tomando web/prototipos/ficha-empresa.html
como referencia de estructura y diseño. Los datos vienen de los endpoints de DAB
sobre crm_v. Móvil primero. Los colores están en tokens CSS: déjalos preparados
para sustituirlos por el manual de marca de Jomipsa.
```

---

## Lo primero que hay que desbloquear fuera del código

1. **Registro de aplicación en Entra ID para la API de Business Central.** Sin esto
   no hay presupuestos ni pedidos, que es el corazón del proyecto. Ya estuvo
   bloqueado antes.
2. **Confirmar licencias de BC con Prodware.** El acceso indirecto cuenta igual que
   el directo, y crear presupuestos requiere licencia completa. No prometer ahorro
   de licencias hasta confirmarlo.
3. **Emails de Entra ID de los seis comerciales**, para el bloque de alta de
   `db/01_esquemas_ddl.sql`.
4. **Backup nocturno de `core` + `crm`**, antes de que entre el primer dato real.
