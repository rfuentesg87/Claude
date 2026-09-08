/* =====================================================================
   CRM JOMIPSA — Comprobaciones previas a ejecutar cualquier script
   SOLO LECTURA. Ninguna consulta escribe, crea ni altera nada.

   Cómo usarlo: abrir en SSMS o Azure Data Studio contra
   sqldb-jomipsapde-prod-westeu-001, ejecutar todo y pegar la salida.
   Cada comprobación va separada por GO, así que si una falla las demás
   siguen dando resultado.

   OJO CON LA COLLATION: la base de datos usa Latin1_General_CI_AS_KS_WS
   y el catálogo SQL_Latin1_General_CP1_CI_AS. Cualquier comparación entre
   una columna de sys.* y un literal necesita COLLATE DATABASE_DEFAULT o
   el motor responde «Cannot resolve collation conflict». Ya está aplicado
   más abajo. Verificado contra el servidor el 8/9/2026.
   ===================================================================== */

/* --- 0. Collation, para dejarlo por escrito -------------------------- */
SELECT DB_NAME()                                          AS BaseDeDatos,
       DATABASEPROPERTYEX(DB_NAME(), 'Collation')         AS CollationBD,
       SERVERPROPERTY('Collation')                        AS CollationServidor;
GO

/* --- 1. ¿Qué objetos de gold son VISTAS y cuáles TABLAS? -------------
   Regla de oro 10: lo que salga como USER_TABLE no se puede usar.
   -------------------------------------------------------------------- */
SELECT o.name AS Objeto, o.type_desc AS Tipo, o.modify_date AS UltimaModificacion
FROM sys.objects o
WHERE o.schema_id = SCHEMA_ID('gold')
  AND o.name COLLATE DATABASE_DEFAULT IN
      ('vw_FactMargenLineaFactura','vw_ProductUnitCost','DimCustomer','DimSalesperson',
       'DimProduct','DimDate','DimLocation','FactSalesOrderLine','InventorySnapshotCurrent')
ORDER BY o.type_desc, o.name;
GO

/* --- 2. Todas las vistas de gold, para saber con qué contamos -------- */
SELECT o.name AS Vista
FROM sys.objects o
WHERE o.schema_id = SCHEMA_ID('gold') AND o.type_desc = 'VIEW'
ORDER BY o.name;
GO

/* --- 3. Tablas de bc que necesita la capa base ------------------------
   Confirma el nombre real de la tabla de comerciales, que puede ser
   [Salesperson_Purchaser] o [Salesperson/Purchaser].
   -------------------------------------------------------------------- */
SELECT o.name AS Tabla, o.type_desc AS Tipo
FROM sys.objects o
WHERE o.schema_id = SCHEMA_ID('bc')
  AND (o.name COLLATE DATABASE_DEFAULT LIKE '%Salesperson%'
    OR o.name COLLATE DATABASE_DEFAULT IN
       ('Customer','Item','Sales Line','Sales Header','Item Ledger Entry','Contact'))
ORDER BY o.name;
GO

/* --- 4. ¿Existe cada columna que usa el script 00? -------------------
   Devuelve el tipo si existe y 'NO EXISTE' si no. Todo lo que salga
   NO EXISTE hay que corregirlo en db/00_vistas_base_erp.sql.
   -------------------------------------------------------------------- */
SELECT v.tab AS Tabla, v.col AS Columna,
       ISNULL(ty.name COLLATE DATABASE_DEFAULT
              + CASE WHEN ty.name COLLATE DATABASE_DEFAULT LIKE '%char%'
                     THEN '(' + CAST(c.max_length AS NVARCHAR(10)) + ')' ELSE '' END,
              'NO EXISTE') AS Tipo
FROM (VALUES
  ('Customer','No.'),('Customer','Name'),('Customer','Salesperson Code'),
  ('Customer','Country_Region Code'),('Customer','Blocked'),('Customer','$company'),
  ('Item','No.'),('Item','Description'),('Item','Item Category Code'),
  ('Item','Base Unit of Measure'),('Item','Blocked'),
  ('Sales Line','Line No.'),('Sales Line','Type'),('Sales Line','No.'),
  ('Sales Line','Quantity'),('Sales Line','Quantity Shipped'),('Sales Line','Location Code'),
  ('Sales Line','Outstanding Quantity'),('Sales Line','Outstanding Amount'),
  ('Sales Line','Shipment Date'),('Sales Line','Unit Price'),
  ('Sales Header','No.'),('Sales Header','Order Date'),
  ('Item Ledger Entry','Item No.'),('Item Ledger Entry','Quantity'),
  ('Item Ledger Entry','Remaining Quantity'),('Item Ledger Entry','Expiration Date')
) v(tab,col)
LEFT JOIN sys.objects t ON t.schema_id = SCHEMA_ID('bc')
                       AND t.name COLLATE DATABASE_DEFAULT = v.tab
LEFT JOIN sys.columns c ON c.object_id = t.object_id
                       AND c.name COLLATE DATABASE_DEFAULT = v.col
LEFT JOIN sys.types  ty ON ty.user_type_id = c.user_type_id
ORDER BY v.tab, v.col;
GO

/* --- 5. Si algo de lo anterior no existe, aquí sale el nombre real --- */
SELECT t.name AS Tabla, c.name AS Columna, ty.name AS Tipo
FROM sys.objects t
JOIN sys.columns c ON c.object_id = t.object_id
JOIN sys.types  ty ON ty.user_type_id = c.user_type_id
WHERE t.schema_id = SCHEMA_ID('bc')
  AND t.name COLLATE DATABASE_DEFAULT IN ('Customer','Item','Item Ledger Entry','Sales Line')
  AND (c.name COLLATE DATABASE_DEFAULT LIKE '%Salesperson%'
    OR c.name COLLATE DATABASE_DEFAULT LIKE '%Country%'
    OR c.name COLLATE DATABASE_DEFAULT LIKE '%Region%'
    OR c.name COLLATE DATABASE_DEFAULT LIKE '%Blocked%'
    OR c.name COLLATE DATABASE_DEFAULT LIKE '%Categor%'
    OR c.name COLLATE DATABASE_DEFAULT LIKE '%Unit of Measure%'
    OR c.name COLLATE DATABASE_DEFAULT LIKE '%Expiration%'
    OR c.name COLLATE DATABASE_DEFAULT LIKE '%Remaining%'
    OR c.name COLLATE DATABASE_DEFAULT LIKE '%Line No%')
ORDER BY t.name, c.name;
GO

/* --- 6. Propietario de cada esquema ----------------------------------
   Los DENY del script 03 sobre bc y gold solo funcionan sin romper la
   ficha si crm_v, gold y bc comparten propietario. Si no, la ficha
   arranca vacía con «permiso denegado».
   -------------------------------------------------------------------- */
SELECT s.name AS Esquema, dp.name AS Propietario
FROM sys.schemas s
JOIN sys.database_principals dp ON dp.principal_id = s.principal_id
WHERE s.name COLLATE DATABASE_DEFAULT IN ('dbo','core','crm','crm_v','gold','bc')
ORDER BY s.name;
GO

/* --- 7. Multiempresa: ¿cuántas empresas y hay clientes repetidos? ----
   Si la segunda consulta devuelve filas, hay que filtrar
   crm_v.ErpCompania o el CRM contará clientes y facturación dos veces.
   -------------------------------------------------------------------- */
SELECT [$company] AS Compania, COUNT(*) AS Clientes
FROM bc.[Customer] GROUP BY [$company] ORDER BY Clientes DESC;
GO
SELECT [No.] AS CustomerNo, COUNT(DISTINCT [$company]) AS Empresas
FROM bc.[Customer] GROUP BY [No.] HAVING COUNT(DISTINCT [$company]) > 1
ORDER BY [No.];
GO

/* --- 8. La cartera real, según bc ------------------------------------
   Se compara con las cifras de CLAUDE.md: PMZ 452, CGA 187, DLL 112,
   JNA 100, AGH 50, DPB 36, MPB 16, LBP 9. Toda diferencia es un
   comercial que vería una cartera distinta de la esperada.
   Ojo: si el paso 4 dice que [Salesperson Code] no existe, esta
   consulta falla; usar el nombre real que devuelva el paso 5.
   -------------------------------------------------------------------- */
SELECT ISNULL(NULLIF([Salesperson Code], N''), N'(sin codigo)') AS SalespersonCode,
       COUNT(*) AS Clientes
FROM bc.[Customer]
GROUP BY [Salesperson Code]
ORDER BY Clientes DESC;
GO

/* --- 9. Cartera de pedidos por la capa base --------------------------
   Debe cuadrar con la hoja «Cartera de Pedidos» del informe mensual de
   ventas de n8n, que usa este mismo criterio.
   -------------------------------------------------------------------- */
SELECT COUNT(*) AS LineasVivas,
       CAST(SUM([Outstanding Amount]) AS DECIMAL(18,2)) AS ImportePendiente
FROM bc.[Sales Line]
WHERE [Document Type] = 1 AND [Outstanding Quantity] <> 0;
GO

/* --- 10. La fuente única de facturación está viva -------------------- */
SELECT COUNT(*) AS Lineas, MIN(PostingDate) AS Desde, MAX(PostingDate) AS Hasta
FROM gold.vw_FactMargenLineaFactura;
GO

/* --- 11. Sensibilidad a acentos, para decidir el buscador ------------
   Con Latin1_General_CI_AS_KS_WS la primera devuelve 0 y la segunda 1:
   el buscador global necesita COLLATE Latin1_General_CI_AI explícito.
   -------------------------------------------------------------------- */
SELECT CASE WHEN N'Belgica' = N'Bélgica' THEN 1 ELSE 0 END AS IgualPorDefecto,
       CASE WHEN N'Belgica' COLLATE Latin1_General_CI_AI
                 = N'Bélgica' COLLATE Latin1_General_CI_AI THEN 1 ELSE 0 END AS IgualSinAcentos;
GO
