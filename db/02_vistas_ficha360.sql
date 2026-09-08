/* =====================================================================
   CRM JOMIPSA — Script 02: capa de vistas (crm_v) y ficha 360º
   Fase 1: SOLO LECTURA. Ninguna de estas vistas escribe en BC.

   Fuente única de facturación y margen: gold.vw_FactMargenLineaFactura
   (2018–2026, facturas y abonos, coste real de movimientos de valor).
   NO se usa gold.vw_FacturacionMensualCliente ni vw_ResumenComercialCliente
   porque solo cubren el año en curso (leen bc.[Sales Invoice Line], que
   únicamente contiene 2026); mezclarlas daría dos cifras distintas para
   el mismo cliente según la pantalla.

   Convenio de signos verificado en la vista de margen:
     LineAmount_Neto    -> ya viene en negativo para los ABONOS
     Profit_Definitivo  -> ya viene con el signo correcto
     Quantity           -> NO lleva signo, hay que invertirla en abonos
   ===================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =====================================================================
   IDENTIDAD Y ALCANCE
   ===================================================================== */

/* Usuario que ejecuta la petición. Data API Builder vuelca los claims del
   token de Entra ID en SESSION_CONTEXT antes de cada consulta.
   Si no hay contexto, la vista no devuelve filas: falla cerrada, que es
   como tiene que fallar una capa de seguridad.
   Para probar en SSMS:
     EXEC sp_set_session_context @key=N'preferred_username',
                                 @value=N'rfuentes@jomipsa.es';        */
CREATE OR ALTER VIEW core.vw_UsuarioActual
AS
SELECT u.UsuarioId, u.Email, u.Nombre, u.Rol, u.SalespersonCode
FROM core.Usuario u
WHERE u.Activo = 1
  AND ( u.EntraObjectId = TRY_CAST(CAST(SESSION_CONTEXT(N'oid') AS NVARCHAR(100)) AS UNIQUEIDENTIFIER)
     OR u.Email = CAST(SESSION_CONTEXT(N'preferred_username') AS NVARCHAR(200))
     OR u.Email = CAST(SESSION_CONTEXT(N'upn')                AS NVARCHAR(200))
     OR u.Email = CAST(SESSION_CONTEXT(N'email')              AS NVARCHAR(200)) );
GO

/* Clientes visibles para el usuario actual.
   La cartera se resuelve SIEMPRE contra gold.DimCustomer WHERE IsCurrent=1,
   nunca contra ComercialAsignado de la vista de margen: esa columna es la
   asignación histórica de cada línea. Ejemplo real: Economat Des Armées
   está asignado hoy a LBP, pero sus líneas de 2025 llevan CGA. Filtrando
   por la vista de margen, LBP no vería el histórico de su propio cliente
   y CGA seguiría viéndolo. */
CREATE OR ALTER VIEW core.vw_MiCartera
AS
SELECT dc.CustomerNo, dc.CustomerName, dc.SalespersonCode
FROM gold.DimCustomer dc
WHERE dc.IsCurrent = 1
  AND ( EXISTS (SELECT 1 FROM core.vw_UsuarioActual ua
                WHERE ua.Rol IN (N'direccion', N'admin', N'lectura'))
     OR EXISTS (SELECT 1 FROM core.vw_UsuarioActual ua
                JOIN core.UsuarioCartera uc ON uc.UsuarioId = ua.UsuarioId
                WHERE uc.SalespersonCode = dc.SalespersonCode) );
GO

/* =====================================================================
   BASE DE FACTURACIÓN NORMALIZADA
   Un solo sitio donde se decide qué es "una venta". Todo lo demás
   cuelga de aquí, así que si algún día cambia el criterio se cambia
   en una vista y no en once.
   ===================================================================== */
CREATE OR ALTER VIEW crm_v.VentaLinea
AS
SELECT
    m.CustomerNo,
    m.Cliente                       AS ClienteNombre,
    m.ComercialAsignado             AS ComercialEnFactura,
    m.TipoDocumento,
    m.DocumentNo,
    m.LineNumber                    AS LineaNo,
    m.PostingDate                   AS Fecha,
    m.AnioFactura                   AS Anio,
    MONTH(m.PostingDate)            AS Mes,
    m.OrderNo                       AS PedidoNo,
    m.ItemNo,
    m.Description                   AS ArticuloDescripcion,
    m.ItemCategoryCode,
    m.TipoProducto,
    m.UnidadVenta,
    m.CurrencyCode                  AS Moneda,
    m.Incoterm,
    CASE WHEN m.TipoDocumento = N'FACTURA' THEN m.Quantity ELSE -m.Quantity END AS Cantidad,
    m.PrecioUnitarioNeto_LCY        AS PrecioUnitario,
    m.LineAmount_Neto               AS Importe,
    m.Coste_Definitivo              AS Coste,
    m.Profit_Definitivo             AS Profit,
    m.Margen_Definitivo             AS MargenPct,
    m.Origen_Coste                  AS OrigenCoste
FROM gold.vw_FactMargenLineaFactura m;
GO

/* =====================================================================
   FICHA 360º — bloques de la pantalla del comercial
   ===================================================================== */

/* --- Cabecera: lo que ve el comercial nada más abrir el cliente ------ */
CREATE OR ALTER VIEW crm_v.ClienteCabecera
AS
WITH v AS (
    SELECT
        vl.CustomerNo,
        SUM(vl.Importe)                                                     AS FacturacionTotal,
        SUM(CASE WHEN vl.Fecha >= DATEADD(MONTH,-12, CAST(GETDATE() AS DATE)) THEN vl.Importe END) AS Facturacion12m,
        SUM(CASE WHEN vl.Fecha >= DATEADD(MONTH,-24, CAST(GETDATE() AS DATE))
                  AND vl.Fecha <  DATEADD(MONTH,-12, CAST(GETDATE() AS DATE)) THEN vl.Importe END) AS FacturacionPrev12m,
        SUM(CASE WHEN vl.Anio = YEAR(GETDATE()) THEN vl.Importe END)        AS FacturacionAnioActual,
        SUM(CASE WHEN vl.Anio = YEAR(GETDATE())-1 THEN vl.Importe END)      AS FacturacionAnioAnterior,
        SUM(CASE WHEN vl.Fecha >= DATEADD(MONTH,-12, CAST(GETDATE() AS DATE)) THEN vl.Profit END)  AS Profit12m,
        MIN(vl.Fecha)                                                       AS PrimeraFactura,
        MAX(vl.Fecha)                                                       AS UltimaFactura,
        COUNT(DISTINCT vl.DocumentNo)                                       AS NumDocumentos,
        COUNT(DISTINCT vl.ItemNo)                                           AS NumArticulosHistoricos
    FROM crm_v.VentaLinea vl
    GROUP BY vl.CustomerNo
)
SELECT
    mc.CustomerNo,
    mc.CustomerName                                     AS Cliente,
    mc.SalespersonCode                                  AS ComercialCodigo,
    ds.SalespersonName                                  AS ComercialNombre,
    dc.CountryCode                                      AS PaisCodigo,
    dc.BlockedFlag                                      AS Bloqueado,
    e.EmpresaId,
    e.Segmento,
    e.PotencialAnual,
    ISNULL(v.FacturacionTotal, 0)                       AS FacturacionTotal,
    ISNULL(v.Facturacion12m, 0)                         AS Facturacion12m,
    ISNULL(v.FacturacionPrev12m, 0)                     AS FacturacionPrev12m,
    CASE WHEN ISNULL(v.FacturacionPrev12m,0) = 0 THEN NULL
         ELSE CAST((v.Facturacion12m - v.FacturacionPrev12m) * 100.0
                   / NULLIF(v.FacturacionPrev12m,0) AS DECIMAL(9,2)) END    AS VariacionPct,
    ISNULL(v.FacturacionAnioActual, 0)                  AS FacturacionAnioActual,
    ISNULL(v.FacturacionAnioAnterior, 0)                AS FacturacionAnioAnterior,
    ISNULL(v.Profit12m, 0)                              AS Profit12m,
    CASE WHEN ISNULL(v.Facturacion12m,0) = 0 THEN NULL
         ELSE CAST(v.Profit12m * 100.0 / NULLIF(v.Facturacion12m,0) AS DECIMAL(9,2)) END AS MargenPct12m,
    v.PrimeraFactura,
    v.UltimaFactura,
    DATEDIFF(DAY, v.UltimaFactura, CAST(GETDATE() AS DATE))                 AS DiasDesdeUltimaFactura,
    ISNULL(v.NumDocumentos, 0)                          AS NumDocumentos,
    ISNULL(v.NumArticulosHistoricos, 0)                 AS NumArticulosHistoricos,
    ISNULL(ped.CarteraPedidos, 0)                       AS CarteraPedidos,
    ISNULL(op.OportunidadesAbiertas, 0)                 AS OportunidadesAbiertas,
    ISNULL(op.ImportePipeline, 0)                       AS ImportePipeline,
    act.UltimaActividad,
    DATEDIFF(DAY, act.UltimaActividad, CAST(GETDATE() AS DATE))             AS DiasDesdeUltimaActividad
FROM core.vw_MiCartera mc
LEFT JOIN gold.DimCustomer dc  ON dc.CustomerNo = mc.CustomerNo AND dc.IsCurrent = 1
LEFT JOIN gold.DimSalesperson ds ON ds.SalespersonCode = mc.SalespersonCode
LEFT JOIN v                    ON v.CustomerNo = mc.CustomerNo
LEFT JOIN core.Empresa e       ON e.BcCustomerNo = mc.CustomerNo
LEFT JOIN (
    SELECT dcp.CustomerNo, SUM(f.OutstandingAmount) AS CarteraPedidos
    FROM gold.FactSalesOrderLine f
    JOIN gold.DimCustomer dcp ON dcp.CustomerSK = f.CustomerSK
    WHERE f.IsOpen = 1
    GROUP BY dcp.CustomerNo
) ped ON ped.CustomerNo = mc.CustomerNo
LEFT JOIN (
    SELECT o.EmpresaId,
           COUNT(*)                  AS OportunidadesAbiertas,
           SUM(o.ImporteEstimado)    AS ImportePipeline
    FROM crm.Oportunidad o
    WHERE o.Estado = N'abierta'
    GROUP BY o.EmpresaId
) op ON op.EmpresaId = e.EmpresaId
LEFT JOIN (
    SELECT a.EmpresaId, MAX(a.FechaInicio) AS UltimaActividad
    FROM core.Actividad a
    WHERE a.Estado = N'realizada'
    GROUP BY a.EmpresaId
) act ON act.EmpresaId = e.EmpresaId;
GO

/* --- Evolución anual ------------------------------------------------- */
CREATE OR ALTER VIEW crm_v.ClienteVentasAnual
AS
SELECT
    vl.CustomerNo,
    vl.Anio,
    SUM(vl.Importe)                 AS Facturacion,
    SUM(vl.Profit)                  AS Profit,
    CASE WHEN SUM(vl.Importe) = 0 THEN NULL
         ELSE CAST(SUM(vl.Profit) * 100.0 / NULLIF(SUM(vl.Importe),0) AS DECIMAL(9,2)) END AS MargenPct,
    COUNT(DISTINCT vl.DocumentNo)   AS NumDocumentos,
    COUNT(DISTINCT vl.ItemNo)       AS NumArticulos
FROM crm_v.VentaLinea vl
WHERE EXISTS (SELECT 1 FROM core.vw_MiCartera mc WHERE mc.CustomerNo = vl.CustomerNo)
GROUP BY vl.CustomerNo, vl.Anio;
GO

/* --- Evolución mensual (para la gráfica de la ficha) ----------------- */
CREATE OR ALTER VIEW crm_v.ClienteVentasMensual
AS
SELECT
    vl.CustomerNo,
    vl.Anio,
    vl.Mes,
    DATEFROMPARTS(vl.Anio, vl.Mes, 1)   AS MesInicio,
    SUM(vl.Importe)                     AS Facturacion,
    SUM(vl.Profit)                      AS Profit
FROM crm_v.VentaLinea vl
WHERE EXISTS (SELECT 1 FROM core.vw_MiCartera mc WHERE mc.CustomerNo = vl.CustomerNo)
GROUP BY vl.CustomerNo, vl.Anio, vl.Mes;
GO

/* --- Artículos: qué compra, qué ha dejado de comprar -----------------
   Es la pantalla que justifica el proyecto. Compara los últimos 12 meses
   contra los 12 anteriores y clasifica cada referencia.
   -------------------------------------------------------------------- */
CREATE OR ALTER VIEW crm_v.ClienteArticulos
AS
WITH agg AS (
    SELECT
        vl.CustomerNo,
        vl.ItemNo,
        MAX(vl.ArticuloDescripcion) AS Descripcion,
        MAX(vl.ItemCategoryCode)    AS Categoria,
        MAX(vl.Fecha)               AS UltimaCompra,
        SUM(CASE WHEN vl.Fecha >= DATEADD(MONTH,-12, CAST(GETDATE() AS DATE)) THEN vl.Importe   ELSE 0 END) AS Importe12m,
        SUM(CASE WHEN vl.Fecha >= DATEADD(MONTH,-24, CAST(GETDATE() AS DATE))
                  AND vl.Fecha <  DATEADD(MONTH,-12, CAST(GETDATE() AS DATE)) THEN vl.Importe  ELSE 0 END) AS ImportePrev12m,
        SUM(CASE WHEN vl.Fecha >= DATEADD(MONTH,-12, CAST(GETDATE() AS DATE)) THEN vl.Cantidad  ELSE 0 END) AS Cantidad12m,
        SUM(CASE WHEN vl.Fecha >= DATEADD(MONTH,-12, CAST(GETDATE() AS DATE)) THEN vl.Profit    ELSE 0 END) AS Profit12m,
        SUM(vl.Importe)             AS ImporteHistorico
    FROM crm_v.VentaLinea vl
    WHERE vl.ItemNo IS NOT NULL
      AND vl.Fecha >= DATEADD(MONTH,-36, CAST(GETDATE() AS DATE))
      AND EXISTS (SELECT 1 FROM core.vw_MiCartera mc WHERE mc.CustomerNo = vl.CustomerNo)
    GROUP BY vl.CustomerNo, vl.ItemNo
)
SELECT
    a.CustomerNo,
    a.ItemNo,
    a.Descripcion,
    a.Categoria,
    a.UltimaCompra,
    DATEDIFF(DAY, a.UltimaCompra, CAST(GETDATE() AS DATE)) AS DiasSinComprar,
    a.Cantidad12m,
    a.Importe12m,
    a.ImportePrev12m,
    a.Profit12m,
    a.ImporteHistorico,
    CASE WHEN a.ImportePrev12m <= 0 THEN NULL
         ELSE CAST((a.Importe12m - a.ImportePrev12m) * 100.0
                   / NULLIF(a.ImportePrev12m,0) AS DECIMAL(9,2)) END AS VariacionPct,
    CASE WHEN a.Importe12m <= 0 AND a.ImportePrev12m > 0                              THEN N'abandonado'
         WHEN a.Importe12m > 0  AND a.ImportePrev12m > 0 AND a.Importe12m < a.ImportePrev12m * 0.6 THEN N'en_caida'
         WHEN a.Importe12m > 0  AND a.ImportePrev12m <= 0                             THEN N'nuevo'
         WHEN a.Importe12m > 0  AND a.ImportePrev12m > 0 AND a.Importe12m > a.ImportePrev12m * 1.4 THEN N'en_crecimiento'
         WHEN a.Importe12m > 0                                                        THEN N'estable'
         ELSE N'inactivo' END                                        AS EstadoArticulo
FROM agg a;
GO

/* --- Pedidos abiertos ------------------------------------------------ */
CREATE OR ALTER VIEW crm_v.ClientePedidosAbiertos
AS
SELECT
    dc.CustomerNo,
    f.DocumentNo                    AS PedidoNo,
    f.[LineNo]                      AS Linea,
    dp.ItemNo,
    dp.Description                  AS ArticuloDescripcion,
    dd.[Date]                       AS FechaPedido,
    de.[Date]                       AS FechaEntregaSolicitada,
    f.Quantity                      AS Cantidad,
    f.QuantityShipped               AS CantidadEnviada,
    f.QuantityOutstanding           AS CantidadPendiente,
    f.UnitPrice                     AS PrecioUnitario,
    f.OutstandingAmount             AS ImportePendiente,
    dl.LocationCode                 AS Almacen,
    f.IsStrategicOrder              AS EsEstrategico,
    f.IsFrameworkAgreement          AS EsAcuerdoMarco,
    f.IsExport                      AS EsExportacion,
    CASE WHEN de.[Date] < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END AS EnRetraso,
    DATEDIFF(DAY, CAST(GETDATE() AS DATE), de.[Date])            AS DiasParaEntrega
FROM gold.FactSalesOrderLine f
JOIN gold.DimCustomer dc ON dc.CustomerSK = f.CustomerSK
LEFT JOIN gold.DimProduct dp ON dp.ProductSK = f.ProductSK
LEFT JOIN gold.DimDate dd ON dd.DateSK = f.DateSK
LEFT JOIN gold.DimDate de ON de.DateSK = f.RequestedDeliveryDateSK
LEFT JOIN gold.DimLocation dl ON dl.LocationSK = f.LocationSK
WHERE f.IsOpen = 1
  AND EXISTS (SELECT 1 FROM core.vw_MiCartera mc WHERE mc.CustomerNo = dc.CustomerNo);
GO

/* --- Facturas (nivel documento) -------------------------------------- */
CREATE OR ALTER VIEW crm_v.ClienteFacturas
AS
SELECT
    vl.CustomerNo,
    vl.TipoDocumento,
    vl.DocumentNo,
    MIN(vl.Fecha)                   AS Fecha,
    MIN(vl.PedidoNo)                AS PedidoNo,
    MIN(vl.Moneda)                  AS Moneda,
    MIN(vl.Incoterm)                AS Incoterm,
    COUNT(*)                        AS NumLineas,
    SUM(vl.Importe)                 AS Importe,
    SUM(vl.Profit)                  AS Profit,
    CASE WHEN SUM(vl.Importe) = 0 THEN NULL
         ELSE CAST(SUM(vl.Profit) * 100.0 / NULLIF(SUM(vl.Importe),0) AS DECIMAL(9,2)) END AS MargenPct
FROM crm_v.VentaLinea vl
WHERE EXISTS (SELECT 1 FROM core.vw_MiCartera mc WHERE mc.CustomerNo = vl.CustomerNo)
GROUP BY vl.CustomerNo, vl.TipoDocumento, vl.DocumentNo;
GO

/* --- Cronología: actividades del CRM + hitos del ERP en una sola lista */
CREATE OR ALTER VIEW crm_v.ClienteCronologia
AS
SELECT
    e.BcCustomerNo                  AS CustomerNo,
    N'actividad'                    AS Origen,
    a.Tipo                          AS Tipo,
    a.Asunto                        AS Titulo,
    a.Descripcion                   AS Detalle,
    CAST(a.FechaInicio AS DATE)     AS Fecha,
    u.Nombre                        AS Usuario,
    NULL                            AS Importe,
    CAST(a.ActividadId AS NVARCHAR(30)) AS Referencia
FROM core.Actividad a
JOIN core.Empresa e ON e.EmpresaId = a.EmpresaId
JOIN core.Usuario u ON u.UsuarioId = a.UsuarioId
WHERE e.BcCustomerNo IS NOT NULL
  AND EXISTS (SELECT 1 FROM core.vw_MiCartera mc WHERE mc.CustomerNo = e.BcCustomerNo)
UNION ALL
SELECT
    vl.CustomerNo,
    N'erp',
    LOWER(vl.TipoDocumento),
    CASE WHEN vl.TipoDocumento = N'FACTURA' THEN N'Factura ' ELSE N'Abono ' END + vl.DocumentNo,
    NULL,
    MIN(vl.Fecha),
    NULL,
    SUM(vl.Importe),
    vl.DocumentNo
FROM crm_v.VentaLinea vl
WHERE EXISTS (SELECT 1 FROM core.vw_MiCartera mc WHERE mc.CustomerNo = vl.CustomerNo)
GROUP BY vl.CustomerNo, vl.TipoDocumento, vl.DocumentNo;
GO

/* =====================================================================
   PANTALLA DE INICIO DEL COMERCIAL
   Su cartera ordenable por riesgo: quién ha caído, quién lleva tiempo
   sin comprar, quién no recibe una visita desde hace meses.
   ===================================================================== */
CREATE OR ALTER VIEW crm_v.MiCartera
AS
SELECT
    c.CustomerNo,
    c.Cliente,
    c.ComercialCodigo,
    c.PaisCodigo,
    c.Bloqueado,
    c.EmpresaId,
    c.Segmento,
    c.Facturacion12m,
    c.FacturacionPrev12m,
    c.VariacionPct,
    c.MargenPct12m,
    c.CarteraPedidos,
    c.UltimaFactura,
    c.DiasDesdeUltimaFactura,
    c.UltimaActividad,
    c.DiasDesdeUltimaActividad,
    c.OportunidadesAbiertas,
    c.ImportePipeline,
    CASE
        WHEN c.Facturacion12m <= 0 AND c.FacturacionPrev12m > 0            THEN N'perdido'
        WHEN c.VariacionPct IS NOT NULL AND c.VariacionPct <= -40          THEN N'en_riesgo'
        WHEN c.DiasDesdeUltimaFactura > 365                                THEN N'inactivo'
        WHEN c.VariacionPct IS NOT NULL AND c.VariacionPct >= 40           THEN N'en_crecimiento'
        ELSE N'estable'
    END                                                                    AS EstadoCliente,
    CASE
        WHEN c.Facturacion12m <= 0 AND c.FacturacionPrev12m > 0 THEN 100
        WHEN c.VariacionPct IS NOT NULL AND c.VariacionPct <= -40 THEN 80
        WHEN c.DiasDesdeUltimaActividad > 180 AND c.Facturacion12m > 50000 THEN 60
        WHEN c.DiasDesdeUltimaFactura > 365 THEN 40
        ELSE 0
    END                                                                    AS PrioridadAtencion
FROM crm_v.ClienteCabecera c;
GO

/* --- Pipeline -------------------------------------------------------- */
CREATE OR ALTER VIEW crm_v.Pipeline
AS
SELECT
    o.OportunidadId,
    o.Codigo,
    o.Titulo,
    o.Estado,
    et.Codigo                       AS EtapaCodigo,
    et.Nombre                       AS EtapaNombre,
    et.Orden                        AS EtapaOrden,
    e.EmpresaId,
    e.Nombre                        AS Cliente,
    e.BcCustomerNo                  AS CustomerNo,
    o.SalespersonCode,
    u.Nombre                        AS Propietario,
    o.ImporteEstimado,
    o.Moneda,
    o.MargenEstimadoPct,
    COALESCE(o.ProbabilidadPct, et.ProbabilidadPct)                        AS ProbabilidadPct,
    CAST(ISNULL(o.ImporteEstimado,0)
         * COALESCE(o.ProbabilidadPct, et.ProbabilidadPct) / 100.0 AS DECIMAL(18,2)) AS ImportePonderado,
    o.FechaApertura,
    o.FechaCierrePrevista,
    o.FechaCierreReal,
    DATEDIFF(DAY, CAST(GETDATE() AS DATE), o.FechaCierrePrevista)          AS DiasParaCierre,
    DATEDIFF(DAY, o.FechaApertura, CAST(GETDATE() AS DATE))                AS DiasAbierta,
    o.Origen,
    o.TipoNegocio,
    o.ReferenciaLicitacion,
    o.FechaLimitePresentacion,
    mp.Nombre                       AS MotivoPerdida
FROM crm.Oportunidad o
JOIN core.Empresa e   ON e.EmpresaId = o.EmpresaId
JOIN crm.Etapa et     ON et.EtapaId = o.EtapaId
JOIN core.Usuario u   ON u.UsuarioId = o.PropietarioId
LEFT JOIN crm.MotivoPerdida mp ON mp.MotivoId = o.MotivoPerdidaId;
GO
