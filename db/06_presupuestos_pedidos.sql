/* =====================================================================
   CRM JOMIPSA — Script 06: presupuestos y pedidos contra Business Central
   Objetivo: que el comercial no abra BC.

   PRINCIPIO: BC es el motor de precios y el sistema de registro del
   documento valorado. El CRM manda cliente, artículos y cantidades; BC
   aplica tarifa, divisa y unidad de medida y devuelve las líneas
   valoradas. El CRM NUNCA calcula un precio de venta por su cuenta: el
   día que el CRM y BC den cifras distintas, el comercial deja de fiarse
   de los dos.

   Lo que sí calcula el CRM y BC no le da fácil al comercial: el MARGEN
   estimado de lo que está presupuestando, cruzando el precio que
   devuelve BC con el coste de gold.vw_ProductUnitCost.

   Flujo: borrador local -> POST salesQuote + salesQuoteLines -> BC valora
   -> GET devuelve totales -> envío -> aceptado -> Microsoft.NAV.makeOrder
   -> seguimiento del pedido desde gold.FactSalesOrderLine.
   ===================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =====================================================================
   1. COLA DE ESCRITURA HACIA BC
   Toda escritura al ERP pasa por aquí. n8n la consume. Nunca se llama a
   BC de forma síncrona desde la API: si BC está caído o lento, el
   comercial no se queda con la pantalla colgada, y un fallo no pierde
   el trabajo.
   ===================================================================== */
IF OBJECT_ID('core.ColaEscrituraBC') IS NULL
CREATE TABLE core.ColaEscrituraBC (
    ColaId              BIGINT IDENTITY(1,1) NOT NULL,
    Entidad             NVARCHAR(30)   NOT NULL,   -- 'presupuesto' | 'presupuesto_linea' | 'pedido' | 'cliente'
    EntidadId           BIGINT         NOT NULL,
    Operacion           NVARCHAR(30)   NOT NULL,   -- 'crear' | 'actualizar' | 'borrar' | 'enviar' | 'convertir_pedido'
    Metodo              NVARCHAR(10)   NOT NULL,   -- POST | PATCH | DELETE | ACTION
    Recurso             NVARCHAR(300)  NULL,       -- ruta relativa del API v2.0
    PayloadJson         NVARCHAR(MAX)  NULL,
    /* Clave de idempotencia: si n8n reintenta tras un timeout que en
       realidad sí llegó a BC, esta clave evita crear el documento dos
       veces. Se comprueba contra BC por externalDocumentNumber. */
    ClaveIdempotencia   NVARCHAR(80)   NOT NULL,
    Estado              NVARCHAR(20)   NOT NULL CONSTRAINT DF_Cola_Estado DEFAULT N'pendiente',
    Prioridad           TINYINT        NOT NULL CONSTRAINT DF_Cola_Prio DEFAULT 5,
    Intentos            INT            NOT NULL CONSTRAINT DF_Cola_Intentos DEFAULT 0,
    ProximoIntento      DATETIME2(3)   NOT NULL CONSTRAINT DF_Cola_Proximo DEFAULT SYSUTCDATETIME(),
    HttpStatus          INT            NULL,
    RespuestaJson       NVARCHAR(MAX)  NULL,
    Error               NVARCHAR(2000) NULL,
    UsuarioId           INT            NULL,
    FechaCreacion       DATETIME2(3)   NOT NULL CONSTRAINT DF_Cola_FC DEFAULT SYSUTCDATETIME(),
    FechaProceso        DATETIME2(3)   NULL,
    CONSTRAINT PK_ColaEscrituraBC PRIMARY KEY CLUSTERED (ColaId),
    CONSTRAINT UQ_Cola_Idem UNIQUE (ClaveIdempotencia),
    CONSTRAINT CK_Cola_Estado CHECK (Estado IN (N'pendiente', N'en_curso', N'completada',
                                                N'error', N'error_permanente', N'cancelada')),
    CONSTRAINT FK_Cola_Usuario FOREIGN KEY (UsuarioId) REFERENCES core.Usuario (UsuarioId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Cola_Pendiente' AND object_id=OBJECT_ID('core.ColaEscrituraBC'))
CREATE INDEX IX_Cola_Pendiente ON core.ColaEscrituraBC (Estado, ProximoIntento, Prioridad)
    INCLUDE (Entidad, EntidadId, Operacion);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Cola_Entidad' AND object_id=OBJECT_ID('core.ColaEscrituraBC'))
CREATE INDEX IX_Cola_Entidad ON core.ColaEscrituraBC (Entidad, EntidadId, FechaCreacion DESC);
GO

/* =====================================================================
   2. PRESUPUESTO
   Espejo local del salesQuote de BC. Los campos de precio los escribe
   la sincronización, no el usuario: por eso van marcados.
   ===================================================================== */
IF OBJECT_ID('crm.Presupuesto') IS NULL
CREATE TABLE crm.Presupuesto (
    PresupuestoId       BIGINT IDENTITY(1,1) NOT NULL,
    Codigo              AS (N'PRE-' + RIGHT(N'000000' + CAST(PresupuestoId AS NVARCHAR(10)), 6)) PERSISTED,
    OportunidadId       BIGINT         NULL,
    EmpresaId           INT            NOT NULL,
    ContactoId          INT            NULL,
    SalespersonCode     NVARCHAR(20)   NOT NULL,
    PropietarioId       INT            NOT NULL,

    Titulo              NVARCHAR(200)  NOT NULL,
    Estado              NVARCHAR(20)   NOT NULL CONSTRAINT DF_Pre_Estado DEFAULT N'borrador',
    Moneda              NCHAR(3)       NOT NULL CONSTRAINT DF_Pre_Moneda DEFAULT N'EUR',
    Incoterm            NVARCHAR(20)   NULL,
    CondicionPago       NVARCHAR(50)   NULL,
    ValidoHasta         DATE           NULL,
    FechaEntregaSolicitada DATE        NULL,
    DireccionEnvio      NVARCHAR(300)  NULL,
    Notas               NVARCHAR(MAX)  NULL,
    NotasInternas       NVARCHAR(MAX)  NULL,       -- no viajan a BC ni al PDF

    /* --- lo escribe BC, no el usuario --- */
    BcQuoteId           UNIQUEIDENTIFIER NULL,     -- id del salesQuote en el API v2.0
    BcQuoteNo           NVARCHAR(20)   NULL,       -- número de la serie de BC
    BcOrderNo           NVARCHAR(20)   NULL,       -- pedido resultante tras makeOrder
    TotalSinImpuestos   DECIMAL(18,2)  NULL,
    TotalImpuestos      DECIMAL(18,2)  NULL,
    TotalConImpuestos   DECIMAL(18,2)  NULL,
    DescuentoImporte    DECIMAL(18,2)  NULL,
    /* --- margen: lo calcula el CRM, BC no se lo da al comercial --- */
    CosteEstimado       DECIMAL(18,2)  NULL,
    MargenEstimado      DECIMAL(18,2)  NULL,
    MargenEstimadoPct   DECIMAL(9,2)   NULL,

    EstadoSync          NVARCHAR(20)   NOT NULL CONSTRAINT DF_Pre_Sync DEFAULT N'sin_sincronizar',
    SincronizadoEn      DATETIME2(3)   NULL,
    ErrorSync           NVARCHAR(1000) NULL,

    PdfUrl              NVARCHAR(1000) NULL,
    FechaEnvio          DATETIME2(3)   NULL,
    FechaAceptacion     DATETIME2(3)   NULL,
    MotivoRechazo       NVARCHAR(300)  NULL,

    CreadoPor           INT            NULL,
    FechaCreacion       DATETIME2(3)   NOT NULL CONSTRAINT DF_Pre_FC DEFAULT SYSUTCDATETIME(),
    ModificadoPor       INT            NULL,
    FechaModificacion   DATETIME2(3)   NOT NULL CONSTRAINT DF_Pre_FM DEFAULT SYSUTCDATETIME(),
    Version             ROWVERSION     NOT NULL,
    CONSTRAINT PK_Presupuesto PRIMARY KEY CLUSTERED (PresupuestoId),
    CONSTRAINT CK_Pre_Estado CHECK (Estado IN (N'borrador', N'valorado', N'enviado',
                                               N'aceptado', N'rechazado', N'caducado', N'convertido')),
    CONSTRAINT CK_Pre_Sync CHECK (EstadoSync IN (N'sin_sincronizar', N'en_cola', N'sincronizado', N'error')),
    CONSTRAINT FK_Pre_Oport    FOREIGN KEY (OportunidadId) REFERENCES crm.Oportunidad (OportunidadId),
    CONSTRAINT FK_Pre_Empresa  FOREIGN KEY (EmpresaId)     REFERENCES core.Empresa (EmpresaId),
    CONSTRAINT FK_Pre_Contacto FOREIGN KEY (ContactoId)    REFERENCES core.Contacto (ContactoId),
    CONSTRAINT FK_Pre_Propietario FOREIGN KEY (PropietarioId) REFERENCES core.Usuario (UsuarioId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Pre_Cartera' AND object_id=OBJECT_ID('crm.Presupuesto'))
CREATE INDEX IX_Pre_Cartera ON crm.Presupuesto (SalespersonCode, Estado)
    INCLUDE (EmpresaId, Titulo, TotalSinImpuestos, ValidoHasta);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_Pre_BcQuote' AND object_id=OBJECT_ID('crm.Presupuesto'))
CREATE UNIQUE INDEX UQ_Pre_BcQuote ON crm.Presupuesto (BcQuoteNo) WHERE BcQuoteNo IS NOT NULL;
GO

IF OBJECT_ID('crm.PresupuestoLinea') IS NULL
CREATE TABLE crm.PresupuestoLinea (
    LineaId             BIGINT IDENTITY(1,1) NOT NULL,
    PresupuestoId       BIGINT         NOT NULL,
    Orden               INT            NOT NULL CONSTRAINT DF_PreLin_Orden DEFAULT 1,
    BcLineId            UNIQUEIDENTIFIER NULL,
    BcItemNo            NVARCHAR(20)   NULL,       -- NULL en líneas de texto o comentario
    Descripcion         NVARCHAR(250)  NOT NULL,
    Cantidad            DECIMAL(18,4)  NOT NULL CONSTRAINT DF_PreLin_Cant DEFAULT 0,
    UnidadMedida        NVARCHAR(20)   NULL,
    FechaEntrega        DATE           NULL,

    /* --- lo devuelve BC --- */
    PrecioTarifa        DECIMAL(18,4)  NULL,       -- precio que aplica BC antes de descuento
    DescuentoPct        DECIMAL(9,4)   NULL,
    PrecioUnitario      DECIMAL(18,4)  NULL,       -- precio final de la línea en BC
    ImporteLinea        DECIMAL(18,2)  NULL,

    /* --- lo calcula el CRM --- */
    CosteUnitario       DECIMAL(18,4)  NULL,
    MargenPct           DECIMAL(9,2)   NULL,

    CONSTRAINT PK_PresupuestoLinea PRIMARY KEY CLUSTERED (LineaId),
    CONSTRAINT FK_PreLin_Pre FOREIGN KEY (PresupuestoId)
        REFERENCES crm.Presupuesto (PresupuestoId) ON DELETE CASCADE
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_PreLin_Pre' AND object_id=OBJECT_ID('crm.PresupuestoLinea'))
CREATE INDEX IX_PreLin_Pre ON crm.PresupuestoLinea (PresupuestoId, Orden);
GO

/* =====================================================================
   3. ENCOLAR LAS ESCRITURAS
   ===================================================================== */
CREATE OR ALTER PROCEDURE crm.usp_EnviarPresupuestoABC
    @PresupuestoId BIGINT,
    @UsuarioId     INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM crm.Presupuesto WHERE PresupuestoId = @PresupuestoId)
    BEGIN
        THROW 51001, 'El presupuesto no existe o no es visible para este usuario.', 1;
    END

    IF EXISTS (SELECT 1 FROM crm.PresupuestoLinea WHERE PresupuestoId = @PresupuestoId
               HAVING COUNT(*) = 0)
       OR NOT EXISTS (SELECT 1 FROM crm.PresupuestoLinea WHERE PresupuestoId = @PresupuestoId)
    BEGIN
        THROW 51002, 'El presupuesto no tiene líneas.', 1;
    END

    /* La clave de idempotencia incluye la versión del presupuesto: si el
       comercial cambia una línea y reenvía, es una escritura distinta;
       si n8n reintenta la misma, es la misma. */
    DECLARE @Clave NVARCHAR(80) =
        N'PRE-' + CAST(@PresupuestoId AS NVARCHAR(20)) + N'-' +
        CONVERT(NVARCHAR(40), (SELECT Version FROM crm.Presupuesto WHERE PresupuestoId = @PresupuestoId), 2);

    IF EXISTS (SELECT 1 FROM core.ColaEscrituraBC
               WHERE ClaveIdempotencia = @Clave AND Estado IN (N'pendiente', N'en_curso', N'completada'))
    BEGIN
        SELECT N'ya_encolado' AS Resultado; RETURN;
    END

    DECLARE @Payload NVARCHAR(MAX) = (
        SELECT
            e.BcCustomerNo                                  AS customerNumber,
            p.Codigo                                        AS externalDocumentNumber,
            CONVERT(CHAR(10), CAST(SYSUTCDATETIME() AS DATE), 23) AS documentDate,
            CONVERT(CHAR(10), p.ValidoHasta, 23)            AS validUntilDate,
            NULLIF(p.Moneda, N'EUR')                        AS currencyCode,
            p.SalespersonCode                               AS salesperson,
            c.Email                                         AS email,
            (
                SELECT l.BcItemNo   AS itemNumber,
                       l.Descripcion AS description,
                       l.Cantidad    AS quantity,
                       CONVERT(CHAR(10), l.FechaEntrega, 23) AS shipmentDate,
                       l.Orden       AS sequence
                FROM crm.PresupuestoLinea l
                WHERE l.PresupuestoId = p.PresupuestoId
                ORDER BY l.Orden
                FOR JSON PATH
            ) AS salesQuoteLines
        FROM crm.Presupuesto p
        JOIN core.Empresa e   ON e.EmpresaId = p.EmpresaId
        LEFT JOIN core.Contacto c ON c.ContactoId = p.ContactoId
        WHERE p.PresupuestoId = @PresupuestoId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    INSERT INTO core.ColaEscrituraBC
        (Entidad, EntidadId, Operacion, Metodo, Recurso, PayloadJson, ClaveIdempotencia, UsuarioId, Prioridad)
    VALUES
        (N'presupuesto', @PresupuestoId,
         CASE WHEN (SELECT BcQuoteId FROM crm.Presupuesto WHERE PresupuestoId=@PresupuestoId) IS NULL
              THEN N'crear' ELSE N'actualizar' END,
         CASE WHEN (SELECT BcQuoteId FROM crm.Presupuesto WHERE PresupuestoId=@PresupuestoId) IS NULL
              THEN N'POST' ELSE N'PATCH' END,
         N'salesQuotes', @Payload, @Clave, @UsuarioId, 3);

    UPDATE crm.Presupuesto SET EstadoSync = N'en_cola', ErrorSync = NULL
    WHERE PresupuestoId = @PresupuestoId;

    SELECT N'encolado' AS Resultado, @Clave AS ClaveIdempotencia;
END
GO

/* Convertir en pedido: Microsoft.NAV.makeOrder sobre el salesQuote. */
CREATE OR ALTER PROCEDURE crm.usp_ConvertirPresupuestoEnPedido
    @PresupuestoId BIGINT,
    @UsuarioId     INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @BcQuoteId UNIQUEIDENTIFIER, @Estado NVARCHAR(20);
    SELECT @BcQuoteId = BcQuoteId, @Estado = Estado
    FROM crm.Presupuesto WHERE PresupuestoId = @PresupuestoId;

    IF @BcQuoteId IS NULL
        THROW 51003, 'El presupuesto todavía no existe en Business Central.', 1;
    IF @Estado <> N'aceptado'
        THROW 51004, 'Solo se convierten en pedido los presupuestos aceptados.', 1;

    DECLARE @Clave NVARCHAR(80) = N'ORD-' + CAST(@PresupuestoId AS NVARCHAR(20));
    IF EXISTS (SELECT 1 FROM core.ColaEscrituraBC WHERE ClaveIdempotencia = @Clave
               AND Estado IN (N'pendiente', N'en_curso', N'completada'))
    BEGIN
        SELECT N'ya_encolado' AS Resultado; RETURN;
    END

    INSERT INTO core.ColaEscrituraBC
        (Entidad, EntidadId, Operacion, Metodo, Recurso, PayloadJson, ClaveIdempotencia, UsuarioId, Prioridad)
    VALUES
        (N'presupuesto', @PresupuestoId, N'convertir_pedido', N'ACTION',
         N'salesQuotes(' + CAST(@BcQuoteId AS NVARCHAR(50)) + N')/Microsoft.NAV.makeOrder',
         NULL, @Clave, @UsuarioId, 1);

    SELECT N'encolado' AS Resultado;
END
GO

/* Lo que n8n llama al terminar cada escritura. */
CREATE OR ALTER PROCEDURE core.usp_CerrarEscrituraBC
    @ColaId        BIGINT,
    @HttpStatus    INT,
    @RespuestaJson NVARCHAR(MAX) = NULL,
    @Error         NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Entidad NVARCHAR(30), @EntidadId BIGINT, @Operacion NVARCHAR(30), @Intentos INT;
    SELECT @Entidad=Entidad, @EntidadId=EntidadId, @Operacion=Operacion, @Intentos=Intentos
    FROM core.ColaEscrituraBC WHERE ColaId = @ColaId;

    IF @HttpStatus BETWEEN 200 AND 299
    BEGIN
        UPDATE core.ColaEscrituraBC
        SET Estado=N'completada', HttpStatus=@HttpStatus, RespuestaJson=@RespuestaJson,
            FechaProceso=SYSUTCDATETIME(), Error=NULL
        WHERE ColaId=@ColaId;

        IF @Entidad = N'presupuesto' AND @Operacion IN (N'crear', N'actualizar')
        BEGIN
            UPDATE p
            SET p.BcQuoteId        = TRY_CAST(JSON_VALUE(@RespuestaJson,'$.id') AS UNIQUEIDENTIFIER),
                p.BcQuoteNo        = JSON_VALUE(@RespuestaJson,'$.number'),
                p.TotalSinImpuestos= TRY_CAST(JSON_VALUE(@RespuestaJson,'$.totalAmountExcludingTax') AS DECIMAL(18,2)),
                p.TotalImpuestos   = TRY_CAST(JSON_VALUE(@RespuestaJson,'$.totalTaxAmount') AS DECIMAL(18,2)),
                p.TotalConImpuestos= TRY_CAST(JSON_VALUE(@RespuestaJson,'$.totalAmountIncludingTax') AS DECIMAL(18,2)),
                p.DescuentoImporte = TRY_CAST(JSON_VALUE(@RespuestaJson,'$.discountAmount') AS DECIMAL(18,2)),
                p.Estado           = CASE WHEN p.Estado = N'borrador' THEN N'valorado' ELSE p.Estado END,
                p.EstadoSync       = N'sincronizado',
                p.SincronizadoEn   = SYSUTCDATETIME(),
                p.ErrorSync        = NULL
            FROM crm.Presupuesto p WHERE p.PresupuestoId = @EntidadId;
        END

        IF @Entidad = N'presupuesto' AND @Operacion = N'convertir_pedido'
        BEGIN
            UPDATE crm.Presupuesto
            SET BcOrderNo = JSON_VALUE(@RespuestaJson,'$.number'),
                Estado    = N'convertido',
                FechaModificacion = SYSUTCDATETIME()
            WHERE PresupuestoId = @EntidadId;
        END
    END
    ELSE
    BEGIN
        /* 4xx que no sea 429 es error del payload: no tiene sentido
           reintentar, hay que enseñárselo a alguien. */
        DECLARE @Permanente BIT =
            CASE WHEN @HttpStatus BETWEEN 400 AND 499 AND @HttpStatus <> 429 THEN 1
                 WHEN @Intentos >= 5 THEN 1 ELSE 0 END;

        UPDATE core.ColaEscrituraBC
        SET Estado         = CASE WHEN @Permanente = 1 THEN N'error_permanente' ELSE N'error' END,
            HttpStatus     = @HttpStatus,
            RespuestaJson  = @RespuestaJson,
            Error          = @Error,
            Intentos       = Intentos + 1,
            /* espera exponencial: 1, 2, 4, 8, 16 minutos */
            ProximoIntento = DATEADD(MINUTE, POWER(2, LEAST(Intentos, 4)), SYSUTCDATETIME()),
            FechaProceso   = SYSUTCDATETIME()
        WHERE ColaId = @ColaId;

        IF @Entidad = N'presupuesto'
            UPDATE crm.Presupuesto
            SET EstadoSync = N'error', ErrorSync = LEFT(ISNULL(@Error, N'HTTP ' + CAST(@HttpStatus AS NVARCHAR(10))), 1000)
            WHERE PresupuestoId = @EntidadId;
    END
END
GO

/* =====================================================================
   4. VISTAS
   ===================================================================== */

/* Catálogo para construir el presupuesto: lo que el comercial necesita
   saber de un artículo antes de meterlo en una oferta. El precio de
   referencia es el último que se le vendió A ESE CLIENTE, no una tarifa
   teórica: es la cifra sobre la que negocia de verdad. El precio en
   firme lo pone BC al valorar. */
CREATE OR ALTER VIEW crm_v.CatalogoCliente
AS
WITH ult AS (
    SELECT vl.CustomerNo, vl.ItemNo,
           vl.PrecioUnitario, vl.Fecha, vl.MargenPct,
           ROW_NUMBER() OVER (PARTITION BY vl.CustomerNo, vl.ItemNo ORDER BY vl.Fecha DESC) AS rn
    FROM crm_v.VentaLinea vl
    WHERE vl.ItemNo IS NOT NULL AND vl.TipoDocumento = N'FACTURA'
), stock AS (
    SELECT ItemNo, SUM(QtyOnHand) AS QtyOnHand, MIN(ExpirationDate) AS CaducidadMasProxima
    FROM gold.InventorySnapshotCurrent
    WHERE BlockedFlag = 0
    GROUP BY ItemNo
)
SELECT
    mc.CustomerNo,
    dp.ItemNo,
    dp.Description                  AS Descripcion,
    dp.ItemCategoryCode             AS Categoria,
    dp.BaseUOM                      AS UnidadBase,
    dp.BlockedFlag                  AS Bloqueado,
    u.PrecioUnitario                AS UltimoPrecioCliente,
    u.Fecha                         AS UltimaVentaCliente,
    u.MargenPct                     AS UltimoMargenCliente,
    c.LastDirectCost                AS CosteUltimaCompra,
    c.UnitCost_Standard             AS CosteEstandar,
    ISNULL(s.QtyOnHand, 0)          AS StockDisponible,
    s.CaducidadMasProxima
FROM core.vw_MiCartera mc
CROSS JOIN gold.DimProduct dp
LEFT JOIN ult u   ON u.CustomerNo = mc.CustomerNo AND u.ItemNo = dp.ItemNo AND u.rn = 1
LEFT JOIN gold.vw_ProductUnitCost c ON c.ItemNo = dp.ItemNo
LEFT JOIN stock s ON s.ItemNo = dp.ItemNo
WHERE dp.IsCurrent = 1 AND dp.BlockedFlag = 0;
GO

CREATE OR ALTER VIEW crm_v.Presupuesto
AS
SELECT
    p.PresupuestoId, p.Codigo, p.Titulo, p.Estado, p.EstadoSync, p.ErrorSync,
    p.EmpresaId, e.Nombre AS Cliente, e.BcCustomerNo AS CustomerNo,
    p.ContactoId, c.Nombre + ISNULL(N' ' + c.Apellidos, N'') AS Contacto,
    p.OportunidadId, o.Titulo AS Oportunidad,
    p.SalespersonCode, u.Nombre AS Propietario,
    p.Moneda, p.Incoterm, p.CondicionPago, p.ValidoHasta,
    CASE WHEN p.ValidoHasta < CAST(GETDATE() AS DATE) AND p.Estado IN (N'enviado', N'valorado')
         THEN 1 ELSE 0 END               AS Caducado,
    DATEDIFF(DAY, CAST(GETDATE() AS DATE), p.ValidoHasta) AS DiasParaCaducar,
    p.TotalSinImpuestos, p.TotalConImpuestos, p.DescuentoImporte,
    p.CosteEstimado, p.MargenEstimado, p.MargenEstimadoPct,
    p.BcQuoteNo, p.BcOrderNo, p.PdfUrl,
    p.FechaEnvio, p.FechaAceptacion, p.MotivoRechazo,
    p.FechaCreacion, p.FechaModificacion,
    (SELECT COUNT(*) FROM crm.PresupuestoLinea l WHERE l.PresupuestoId = p.PresupuestoId) AS NumLineas
FROM crm.Presupuesto p
JOIN core.Empresa e   ON e.EmpresaId = p.EmpresaId
JOIN core.Usuario u   ON u.UsuarioId = p.PropietarioId
LEFT JOIN core.Contacto c   ON c.ContactoId = p.ContactoId
LEFT JOIN crm.Oportunidad o ON o.OportunidadId = p.OportunidadId;
GO

/* Seguimiento del pedido sin salir del CRM: el presupuesto convertido
   se enlaza con las líneas vivas de gold.FactSalesOrderLine. */
CREATE OR ALTER VIEW crm_v.PedidoSeguimiento
AS
SELECT
    p.PresupuestoId,
    p.Codigo                        AS PresupuestoCodigo,
    p.BcOrderNo                     AS PedidoNo,
    e.Nombre                        AS Cliente,
    e.BcCustomerNo                  AS CustomerNo,
    p.SalespersonCode,
    f.[LineNo]                      AS Linea,
    dp.ItemNo,
    dp.Description                  AS Articulo,
    f.Quantity                      AS Cantidad,
    f.QuantityShipped               AS Enviado,
    f.QuantityOutstanding           AS Pendiente,
    f.OutstandingAmount             AS ImportePendiente,
    de.[Date]                       AS FechaEntregaSolicitada,
    CASE WHEN f.IsCompletelyShipped = 1 THEN N'enviado'
         WHEN f.QuantityShipped > 0     THEN N'parcial'
         WHEN de.[Date] < CAST(GETDATE() AS DATE) THEN N'retrasado'
         ELSE N'pendiente' END      AS EstadoLinea,
    DATEDIFF(DAY, CAST(GETDATE() AS DATE), de.[Date]) AS DiasParaEntrega
FROM crm.Presupuesto p
JOIN core.Empresa e ON e.EmpresaId = p.EmpresaId
JOIN gold.FactSalesOrderLine f ON f.DocumentNo = p.BcOrderNo
LEFT JOIN gold.DimProduct dp ON dp.ProductSK = f.ProductSK
LEFT JOIN gold.DimDate de    ON de.DateSK = f.RequestedDeliveryDateSK
WHERE p.BcOrderNo IS NOT NULL;
GO

/* Bandeja de escrituras con problema: lo que administración tiene que mirar. */
CREATE OR ALTER VIEW crm_v.ColaEscrituraBC
AS
SELECT
    q.ColaId, q.Entidad, q.EntidadId, q.Operacion, q.Estado,
    q.Intentos, q.ProximoIntento, q.HttpStatus,
    LEFT(q.Error, 300)              AS Error,
    q.FechaCreacion, q.FechaProceso,
    p.Codigo                        AS PresupuestoCodigo,
    e.Nombre                        AS Cliente,
    u.Nombre                        AS Usuario
FROM core.ColaEscrituraBC q
LEFT JOIN crm.Presupuesto p ON q.Entidad = N'presupuesto' AND p.PresupuestoId = q.EntidadId
LEFT JOIN core.Empresa e    ON e.EmpresaId = p.EmpresaId
LEFT JOIN core.Usuario u    ON u.UsuarioId = q.UsuarioId;
GO

/* =====================================================================
   5. SEGURIDAD
   ===================================================================== */
GRANT SELECT ON crm_v.CatalogoCliente    TO [crm_app];
GRANT SELECT ON crm_v.Presupuesto        TO [crm_app];
GRANT SELECT ON crm_v.PedidoSeguimiento  TO [crm_app];
GRANT SELECT ON crm_v.ColaEscrituraBC    TO [crm_app];
GRANT EXECUTE ON crm.usp_EnviarPresupuestoABC        TO [crm_app];
GRANT EXECUTE ON crm.usp_ConvertirPresupuestoEnPedido TO [crm_app];
GO

/* RLS: el presupuesto entra en la misma política de cartera. */
IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = N'PoliticaCartera')
BEGIN
    ALTER SECURITY POLICY core.PoliticaCartera
        ADD FILTER PREDICATE core.fn_FiltroCartera(SalespersonCode)  ON crm.Presupuesto,
        ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON crm.Presupuesto AFTER INSERT,
        ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON crm.Presupuesto AFTER UPDATE,
        ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON crm.Presupuesto BEFORE UPDATE,
        ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON crm.Presupuesto BEFORE DELETE;
END
GO
