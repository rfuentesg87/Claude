/* =====================================================================
   CRM JOMIPSA — Script 00: capa base de lectura del ERP
   EJECUTAR ANTES DEL 02. Orden: 01 -> 00 -> 02 -> 03 -> 04 -> 05 -> 06.

   POR QUÉ EXISTE ESTE SCRIPT
   --------------------------
   En el esquema gold solo son fiables las VISTAS (gold.vw_*). Las tablas
   de gold (DimCustomer, DimSalesperson, DimProduct, DimDate, DimLocation,
   FactSalesOrderLine, InventorySnapshotCurrent) NO se actualizan, así que
   el CRM no puede leerlas: daría cifras viejas sin avisar, que es el peor
   fallo posible en una pantalla de comercial.

   Todo lo que el CRM necesita del ERP pasa por las vistas de este script.
   Ninguna otra vista del CRM vuelve a nombrar gold ni bc directamente:
   así, el día que cambie el origen de un dato (el PDE está en evaluación
   de sustitución), se cambia aquí y en ningún otro sitio.

       crm_v.Cliente*  (ficha, cartera, pipeline)
              |
              v
       crm_v.Erp*      <- esta capa, única frontera con el ERP
              |
              v
       gold.vw_*  (solo vistas)   bc.*  (réplica del PDE)

   NOMBRES DE COLUMNA
   ------------------
   Los nombres salen del SQL ya en producción en los workflows de n8n
   (informe mensual de ventas, panel de logística), no de suposiciones.
   En esta réplica las columnas conservan la notación de Business Central,
   con puntos y espacios: [No.], [Sell-to Customer No.], [Document Type].
   Lo marcado /* CONFIRMAR */ no aparece en ningún SQL en producción y hay
   que verificarlo con el bloque de comprobación del final antes de dar
   este script por bueno.

   MULTIEMPRESA
   ------------
   Las tablas de bc llevan [$company]. Todas las consultas de producción
   unen por esa columna, y ninguna filtra por una empresa concreta. Aquí se
   mantiene ese comportamiento (crm_v.ErpCompania devuelve todas), pero
   queda en UN solo sitio para poder restringirlo el día que haga falta.
   ===================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF SCHEMA_ID('crm_v') IS NULL EXEC('CREATE SCHEMA crm_v AUTHORIZATION dbo');
GO

/* =====================================================================
   0. EMPRESAS DE BC EN ALCANCE
   Un solo sitio donde se decide qué empresas de Business Central ve el
   CRM. Por defecto todas, igual que hacen hoy los informes. Para
   restringir, sustituir el cuerpo por la lista de literales:
       SELECT N'JOMIPSA' AS Compania;   -- nombre exacto de [$company]
   ===================================================================== */
CREATE OR ALTER VIEW crm_v.ErpCompania
AS
SELECT DISTINCT c.[$company] AS Compania
FROM bc.[Customer] c;
GO

/* =====================================================================
   1. CLIENTES — sustituye a gold.DimCustomer
   bc.[Customer] es el maestro vivo: lleva la asignación de comercial
   ACTUAL, así que aquí no hay dimensión de tipo 2 ni IsCurrent que
   filtrar. La regla de oro 4 sigue en pie en lo que importa: la cartera
   se resuelve por esta vista y NUNCA por ComercialAsignado de la vista
   de margen, que es la asignación histórica de cada línea.
   ===================================================================== */
CREATE OR ALTER VIEW crm_v.ErpCliente
AS
SELECT
    c.[No.]                     AS CustomerNo,
    c.[Name]                    AS CustomerName,
    c.[Salesperson Code]        AS SalespersonCode,      /* CONFIRMAR */
    c.[Country_Region Code]     AS PaisCodigo,           /* CONFIRMAR */
    c.[Blocked]                 AS Bloqueado,            /* CONFIRMAR */
    c.[$company]                AS Compania
FROM bc.[Customer] c
JOIN crm_v.ErpCompania ec ON ec.Compania = c.[$company];
GO

/* =====================================================================
   2. COMERCIALES — sustituye a gold.DimSalesperson
   ===================================================================== */
CREATE OR ALTER VIEW crm_v.ErpComercial
AS
SELECT
    s.[Code]                    AS SalespersonCode,      /* CONFIRMAR */
    s.[Name]                    AS SalespersonName,      /* CONFIRMAR */
    s.[$company]                AS Compania
FROM bc.[Salesperson_Purchaser] s                        /* CONFIRMAR nombre de tabla */
JOIN crm_v.ErpCompania ec ON ec.Compania = s.[$company];
GO

/* =====================================================================
   3. ARTÍCULOS — sustituye a gold.DimProduct
   ===================================================================== */
CREATE OR ALTER VIEW crm_v.ErpArticulo
AS
SELECT
    i.[No.]                     AS ItemNo,
    i.[Description]             AS Descripcion,
    i.[Item Category Code]      AS Categoria,            /* CONFIRMAR */
    i.[Base Unit of Measure]    AS UnidadBase,           /* CONFIRMAR */
    i.[Blocked]                 AS Bloqueado,            /* CONFIRMAR */
    i.[$company]                AS Compania
FROM bc.[Item] i
JOIN crm_v.ErpCompania ec ON ec.Compania = i.[$company];
GO

/* =====================================================================
   4. LÍNEAS DE PEDIDO — sustituye a gold.FactSalesOrderLine,
      gold.DimDate y gold.DimLocation de una vez
   El SQL de esta vista es el del nodo "SQL Cartera de Pedidos" del
   informe mensual de ventas, que lleva meses funcionando:
     [Document Type] = 1  -> pedido de venta
     [Outstanding Quantity] <> 0 -> línea viva
   Al leer las fechas directamente de bc desaparece el doble salto por
   DimDate con DateSK, que además era una tabla no actualizada.
   ===================================================================== */
CREATE OR ALTER VIEW crm_v.ErpPedidoLinea
AS
SELECT
    l.[Sell-to Customer No.]    AS CustomerNo,
    l.[Document No.]            AS PedidoNo,
    l.[Line No.]                AS Linea,                /* CONFIRMAR */
    CASE WHEN l.[Type] = 2 THEN l.[No.] END AS ItemNo,   /* CONFIRMAR: 2 = Artículo */
    l.[Description]             AS ArticuloDescripcion,
    h.[Order Date]              AS FechaPedido,
    l.[Shipment Date]           AS FechaEntregaSolicitada,
    l.[Quantity]                AS Cantidad,             /* CONFIRMAR */
    l.[Quantity Shipped]        AS CantidadEnviada,      /* CONFIRMAR */
    l.[Outstanding Quantity]    AS CantidadPendiente,
    l.[Unit Price]              AS PrecioUnitario,
    l.[Outstanding Amount]      AS ImportePendiente,
    l.[Location Code]           AS Almacen,              /* CONFIRMAR */
    CASE WHEN l.[Outstanding Quantity] <> 0 THEN 1 ELSE 0 END AS EsAbierta,
    l.[$company]                AS Compania
FROM bc.[Sales Line] l
JOIN bc.[Sales Header] h
       ON h.[No.]            = l.[Document No.]
      AND h.[Document Type]  = l.[Document Type]
      AND h.[$company]       = l.[$company]
JOIN crm_v.ErpCompania ec ON ec.Compania = l.[$company]
WHERE l.[Document Type] = 1;
GO

/* =====================================================================
   5. COSTE UNITARIO — gold.vw_ProductUnitCost es una VISTA, se puede
      usar. Se envuelve para que el CRM tenga un único nombre propio y
      para poder cambiar el origen sin tocar el presupuesto.
      Regla 5: esto es lo único que el CRM usa para calcular margen; el
      precio de venta lo pone siempre BC.
   ===================================================================== */
CREATE OR ALTER VIEW crm_v.ErpCoste
AS
SELECT
    c.ItemNo,
    c.LastDirectCost            AS CosteUltimaCompra,
    c.UnitCost_Standard         AS CosteEstandar
FROM gold.vw_ProductUnitCost c;
GO

/* =====================================================================
   6. STOCK Y CADUCIDADES — sustituye a gold.InventorySnapshotCurrent
   ATENCIÓN: esta es la vista menos verificada de todo el script. El
   panel de logística de n8n ya calcula stock, ocupación y caducidades
   con SQL contrastado contra bc; antes de dar esto por bueno hay que
   traer esa consulta y sustituir el cuerpo de aquí por ella, en vez de
   mantener dos formas distintas de contar el mismo stock.
   Solo la usa crm_v.CatalogoCliente, que es de la fase de presupuestos,
   así que no bloquea la Fase 1.
   ===================================================================== */
CREATE OR ALTER VIEW crm_v.ErpStock
AS
SELECT
    e.[Item No.]                                AS ItemNo,          /* CONFIRMAR */
    SUM(e.[Quantity])                           AS StockDisponible, /* CONFIRMAR */
    MIN(CASE WHEN e.[Remaining Quantity] > 0
             THEN e.[Expiration Date] END)      AS CaducidadMasProxima, /* CONFIRMAR */
    e.[$company]                                AS Compania
FROM bc.[Item Ledger Entry] e                                        /* CONFIRMAR */
JOIN crm_v.ErpCompania ec ON ec.Compania = e.[$company]
GROUP BY e.[Item No.], e.[$company];
GO

/* =====================================================================
   PERMISOS
   crm_app ya tiene SELECT sobre el esquema crm_v por el script 03. Estas
   líneas solo hacen falta si este script se ejecuta después.
   ===================================================================== */
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'crm_app')
BEGIN
    GRANT SELECT ON crm_v.ErpCompania    TO [crm_app];
    GRANT SELECT ON crm_v.ErpCliente     TO [crm_app];
    GRANT SELECT ON crm_v.ErpComercial   TO [crm_app];
    GRANT SELECT ON crm_v.ErpArticulo    TO [crm_app];
    GRANT SELECT ON crm_v.ErpPedidoLinea TO [crm_app];
    GRANT SELECT ON crm_v.ErpCoste       TO [crm_app];
    GRANT SELECT ON crm_v.ErpStock       TO [crm_app];
END
GO

/* =====================================================================
   COMPROBACIONES ANTES DE EJECUTAR
   Ejecutar como usuario de solo lectura. Nada de esto escribe.
   ===================================================================== */
/*
-- 1. ¿Qué objetos de gold son vistas y cuáles tablas? Si algo que
--    usamos sale como USER_TABLE, no se puede usar.
SELECT o.name, o.type_desc
FROM sys.objects o
WHERE o.schema_id = SCHEMA_ID('gold')
  AND o.name IN (N'vw_FactMargenLineaFactura', N'vw_ProductUnitCost',
                 N'DimCustomer', N'DimSalesperson', N'DimProduct', N'DimDate',
                 N'DimLocation', N'FactSalesOrderLine', N'InventorySnapshotCurrent')
ORDER BY o.type_desc, o.name;

-- 2. Nombres reales de las columnas que este script marca CONFIRMAR.
SELECT t.name AS Tabla, c.name AS Columna, ty.name AS Tipo, c.max_length
FROM sys.columns c
JOIN sys.objects t ON t.object_id = c.object_id
JOIN sys.types  ty ON ty.user_type_id = c.user_type_id
WHERE t.schema_id = SCHEMA_ID('bc')
  AND t.name IN (N'Customer', N'Item', N'Sales Line', N'Sales Header',
                 N'Salesperson_Purchaser', N'Salesperson/Purchaser',
                 N'Item Ledger Entry')
ORDER BY t.name, c.column_id;

-- 3. ¿Cuántas empresas hay en bc y hay códigos de cliente repetidos
--    entre ellas? Si el segundo SELECT devuelve filas, hay que filtrar
--    crm_v.ErpCompania o el CRM contará clientes dos veces.
SELECT [$company] AS Compania, COUNT(*) AS Clientes
FROM bc.[Customer] GROUP BY [$company] ORDER BY Clientes DESC;

SELECT [No.] AS CustomerNo, COUNT(DISTINCT [$company]) AS Empresas
FROM bc.[Customer] GROUP BY [No.] HAVING COUNT(DISTINCT [$company]) > 1;

-- 4. La cartera según bc frente a la que decía gold.DimCustomer.
--    Toda diferencia aquí es un cliente que el comercial equivocado
--    estaba viendo (o dejando de ver).
SELECT TOP 50 c.CustomerNo, c.CustomerName, c.SalespersonCode
FROM crm_v.ErpCliente c
WHERE c.SalespersonCode IS NULL OR c.SalespersonCode = N''
ORDER BY c.CustomerNo;

SELECT c.SalespersonCode, COUNT(*) AS Clientes
FROM crm_v.ErpCliente c
GROUP BY c.SalespersonCode
ORDER BY Clientes DESC;

-- 5. Cartera de pedidos por la capa base. Debe cuadrar con la hoja
--    "Cartera de Pedidos" del informe mensual de ventas.
SELECT COUNT(*) AS LineasVivas, SUM(ImportePendiente) AS Importe
FROM crm_v.ErpPedidoLinea WHERE EsAbierta = 1;
*/
GO
