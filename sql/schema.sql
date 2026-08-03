-- =============================================================================
-- Registro Horario de Producción (Cadena) — Azure SQL schema
-- =============================================================================
-- Reference DDL for the production database on:
--   Server:   sqlserver-jomipsapde-prod-westeu-001
--   Database: sqldb-jomipsapde-prod-westeu-001
--   Schemas:  gold (app data), bc (Business Central mirror tables)
--
-- The `gold.RegistroProduccion*` tables and the `gold.vw_PowerApp_*` /
-- `gold.vw_BC_DiarioSalida` views ALREADY EXIST in production. They are
-- reproduced here only as documentation and for standing up a fresh
-- environment. The only object this application *needs to create* that did not
-- exist in the n8n prototype is `gold.AppUsers` (see the bottom of this file):
-- the prototype had no real user table (it logged everything as 'n8n').
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 2.1  gold.RegistroProduccion_Temp  — pending (editable/deletable) lines
-- -----------------------------------------------------------------------------
IF OBJECT_ID('gold.RegistroProduccion_Temp', 'U') IS NULL
CREATE TABLE gold.RegistroProduccion_Temp (
    RegistroProduccionTempId   INT IDENTITY PRIMARY KEY,
    ProductionOrderNo          NVARCHAR(40)     NOT NULL,
    HoraInicio                 TIME(3)          NOT NULL,
    HoraFin                    TIME(3)          NOT NULL,
    NumPersonas                INT              NOT NULL,
    TotalUnidadesProducidas    DECIMAL(18,2)    NOT NULL,
    TipoTrabajo                NVARCHAR(100)    NULL,
    Comentarios                NVARCHAR(MAX)    NULL,
    FechaRegistro              DATE             NOT NULL,
    CreatedAt                  DATETIME2(6)     NOT NULL,
    CreatedBy                  NVARCHAR(200)    NULL,
    ModifiedAt                 DATETIME2(6)     NULL,
    ModifiedBy                 NVARCHAR(200)    NULL,
    -- snapshot of the OP at the moment the line was created (see spec §6)
    ItemNo                     NVARCHAR(50)     NULL,
    ItemDescription            NVARCHAR(250)    NULL,
    LocationCode               NVARCHAR(20)     NULL,
    RoutingNo                  NVARCHAR(50)     NULL,
    MachineCenterNo            NVARCHAR(50)     NULL,
    CantidadPlanificada        DECIMAL(18,2)    NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_RegistroProduccion_Temp_OP_Fecha')
CREATE NONCLUSTERED INDEX IX_RegistroProduccion_Temp_OP_Fecha
    ON gold.RegistroProduccion_Temp (ProductionOrderNo, FechaRegistro, CreatedAt);
GO


-- -----------------------------------------------------------------------------
-- 2.2  gold.RegistroProduccion  — validated / definitive lines
-- -----------------------------------------------------------------------------
-- TotalHoras is a PERSISTED computed column: never INSERT/UPDATE it directly.
IF OBJECT_ID('gold.RegistroProduccion', 'U') IS NULL
CREATE TABLE gold.RegistroProduccion (
    RegistroProduccionId       INT IDENTITY PRIMARY KEY,
    ProductionOrderNo          NVARCHAR(40)     NOT NULL,
    HoraInicio                 TIME(3)          NOT NULL,
    HoraFin                    TIME(3)          NOT NULL,
    NumPersonas                INT              NOT NULL,
    TotalUnidadesProducidas    DECIMAL(18,2)    NOT NULL,
    TipoTrabajo                NVARCHAR(100)    NULL,
    Comentarios                NVARCHAR(MAX)    NULL,
    TotalHoras                 AS (CONVERT(DECIMAL(10,2), DATEDIFF(MINUTE, HoraInicio, HoraFin) / 60.0)) PERSISTED,
    FechaRegistro              DATE             NOT NULL,
    CreatedAt                  DATETIME2(6)     NOT NULL,
    CreatedBy                  NVARCHAR(200)    NULL,
    ModifiedAt                 DATETIME2(6)     NULL,
    ModifiedBy                 NVARCHAR(200)    NULL,
    ItemNo                     NVARCHAR(50)     NULL,
    ItemDescription            NVARCHAR(250)    NULL,
    LocationCode               NVARCHAR(20)     NULL,
    RoutingNo                  NVARCHAR(50)     NULL,
    MachineCenterNo            NVARCHAR(50)     NULL,
    CantidadPlanificada        DECIMAL(18,2)    NULL,
    CONSTRAINT CK_RegistroProduccion_HoraFin CHECK (HoraFin > HoraInicio),
    CONSTRAINT CK_RegistroProduccion_NumPersonas CHECK (NumPersonas > 0),
    CONSTRAINT CK_RegistroProduccion_Unidades CHECK (TotalUnidadesProducidas >= 0),
    CONSTRAINT CK_RegistroProduccion_TipoTrabajo CHECK (
        TipoTrabajo IS NULL OR TipoTrabajo = '' OR
        TipoTrabajo = 'Etiquetado' OR TipoTrabajo = 'Reproceso' OR   -- legacy, do NOT use for new rows
        TipoTrabajo = N'005 Preparación' OR
        TipoTrabajo = N'010 Fabricación/Comida' OR
        TipoTrabajo = '006 Reproceso'
    )
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_RegistroProduccion_OP')
CREATE NONCLUSTERED INDEX IX_RegistroProduccion_OP
    ON gold.RegistroProduccion (FechaRegistro, TotalHoras, TotalUnidadesProducidas, ProductionOrderNo);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_RegistroProduccion_Fecha')
CREATE NONCLUSTERED INDEX IX_RegistroProduccion_Fecha
    ON gold.RegistroProduccion (ProductionOrderNo, FechaRegistro);
GO


-- -----------------------------------------------------------------------------
-- 2.3  Read views  (already exist in production — shown for reference)
-- -----------------------------------------------------------------------------
-- gold.vw_PowerApp_OPsAbiertas       -> open OPs for the picker
-- gold.vw_PowerApp_HistoricoCompleto -> pending + confirmed, joined to OP data
-- gold.vw_BC_DiarioSalida            -> future Business Central export
--
-- See CLAUDE.md / the technical spec for their full definitions. They are not
-- recreated here to avoid accidentally overwriting the production versions.


-- =============================================================================
-- APP USERS  — new object required by the standalone app (spec §5)
-- =============================================================================
-- Minimal local-auth store: hashed passwords (PBKDF2, stdlib) + real usernames
-- so CreatedBy/ModifiedBy stop being the literal 'n8n'. If/when the app moves
-- to Entra ID / LDAP this table can be dropped or kept as a fallback.
IF OBJECT_ID('gold.AppUsers', 'U') IS NULL
CREATE TABLE gold.AppUsers (
    AppUserId       INT IDENTITY PRIMARY KEY,
    Username        NVARCHAR(200)  NOT NULL UNIQUE,
    DisplayName     NVARCHAR(200)  NULL,
    -- Encoded as "pbkdf2_sha256$<iterations>$<salt_hex>$<hash_hex>"
    PasswordHash    NVARCHAR(400)  NOT NULL,
    Role            NVARCHAR(50)   NOT NULL DEFAULT 'cadena',   -- 'cadena' | 'planta'
    IsActive        BIT            NOT NULL DEFAULT 1,
    CreatedAt       DATETIME2(6)   NOT NULL DEFAULT SYSUTCDATETIME()
);
GO
