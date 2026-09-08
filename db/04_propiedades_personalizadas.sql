/* =====================================================================
   CRM JOMIPSA — Script 04: propiedades personalizables
   Equivalente a las "custom properties" de HubSpot.

   Modelo: definiciones en tabla + valores en una columna JSON de la
   entidad. Se descarta el patrón EAV clásico (una fila por valor)
   porque obliga a un PIVOT en cada lectura y destroza el rendimiento
   de las listas. SQL Server indexa JSON mediante columnas calculadas
   persistidas, que es lo que hacemos para las propiedades que de
   verdad se filtran.
   ===================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* --- Definición de propiedades ---------------------------------------
   Una fila por campo personalizado. La pantalla de administración
   escribe aquí y el frontend construye el formulario leyendo esta
   tabla: añadir un campo no requiere ni migración ni despliegue.
   -------------------------------------------------------------------- */
IF OBJECT_ID('core.PropiedadDefinicion') IS NULL
CREATE TABLE core.PropiedadDefinicion (
    PropiedadId         INT IDENTITY(1,1) NOT NULL,
    Entidad             NVARCHAR(30)   NOT NULL,   -- 'empresa' | 'contacto' | 'oportunidad'
    Clave               NVARCHAR(50)   NOT NULL,   -- identificador en el JSON, sin espacios
    Etiqueta            NVARCHAR(100)  NOT NULL,   -- lo que ve el usuario
    Descripcion         NVARCHAR(500)  NULL,       -- texto de ayuda bajo el campo
    Tipo                NVARCHAR(20)   NOT NULL,   -- texto, texto_largo, numero, decimal,
                                                   -- fecha, booleano, lista, lista_multiple,
                                                   -- url, email, telefono
    Grupo               NVARCHAR(50)   NULL,       -- sección de la ficha donde se agrupa
    Orden               INT            NOT NULL CONSTRAINT DF_PropDef_Orden DEFAULT 100,
    Obligatoria         BIT            NOT NULL CONSTRAINT DF_PropDef_Oblig DEFAULT 0,
    SoloLectura         BIT            NOT NULL CONSTRAINT DF_PropDef_SoloLec DEFAULT 0,
    ValorDefecto        NVARCHAR(500)  NULL,
    ReglaValidacion     NVARCHAR(500)  NULL,       -- expresión regular opcional
    VisibleEnLista      BIT            NOT NULL CONSTRAINT DF_PropDef_VisLista DEFAULT 0,
    Activa              BIT            NOT NULL CONSTRAINT DF_PropDef_Activa DEFAULT 1,
    CreadoPor           INT            NULL,
    FechaCreacion       DATETIME2(3)   NOT NULL CONSTRAINT DF_PropDef_FC DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_PropiedadDefinicion PRIMARY KEY CLUSTERED (PropiedadId),
    CONSTRAINT UQ_PropiedadDefinicion UNIQUE (Entidad, Clave),
    CONSTRAINT CK_PropDef_Entidad CHECK (Entidad IN (N'empresa', N'contacto', N'oportunidad', N'actividad')),
    CONSTRAINT CK_PropDef_Tipo CHECK (Tipo IN (N'texto', N'texto_largo', N'numero', N'decimal',
                                               N'fecha', N'booleano', N'lista', N'lista_multiple',
                                               N'url', N'email', N'telefono')),
    CONSTRAINT FK_PropDef_Usuario FOREIGN KEY (CreadoPor) REFERENCES core.Usuario (UsuarioId)
);
GO

/* --- Opciones de las propiedades de tipo lista ------------------------ */
IF OBJECT_ID('core.PropiedadOpcion') IS NULL
CREATE TABLE core.PropiedadOpcion (
    OpcionId            INT IDENTITY(1,1) NOT NULL,
    PropiedadId         INT            NOT NULL,
    Valor               NVARCHAR(100)  NOT NULL,   -- lo que se guarda en el JSON
    Etiqueta            NVARCHAR(100)  NOT NULL,   -- lo que se muestra
    Color               NVARCHAR(20)   NULL,       -- para pintar etiquetas de colores
    Orden               INT            NOT NULL CONSTRAINT DF_PropOpc_Orden DEFAULT 100,
    Activa              BIT            NOT NULL CONSTRAINT DF_PropOpc_Activa DEFAULT 1,
    CONSTRAINT PK_PropiedadOpcion PRIMARY KEY CLUSTERED (OpcionId),
    CONSTRAINT UQ_PropiedadOpcion UNIQUE (PropiedadId, Valor),
    CONSTRAINT FK_PropOpc_Def FOREIGN KEY (PropiedadId)
        REFERENCES core.PropiedadDefinicion (PropiedadId) ON DELETE CASCADE
);
GO

/* --- Columnas JSON en las entidades ---------------------------------- */
IF COL_LENGTH('core.Empresa', 'PropiedadesJson') IS NULL
    ALTER TABLE core.Empresa ADD PropiedadesJson NVARCHAR(MAX) NULL
        CONSTRAINT CK_Empresa_PropJson CHECK (PropiedadesJson IS NULL OR ISJSON(PropiedadesJson) = 1);
GO
IF COL_LENGTH('core.Contacto', 'PropiedadesJson') IS NULL
    ALTER TABLE core.Contacto ADD PropiedadesJson NVARCHAR(MAX) NULL
        CONSTRAINT CK_Contacto_PropJson CHECK (PropiedadesJson IS NULL OR ISJSON(PropiedadesJson) = 1);
GO
IF COL_LENGTH('crm.Oportunidad', 'PropiedadesJson') IS NULL
    ALTER TABLE crm.Oportunidad ADD PropiedadesJson NVARCHAR(MAX) NULL
        CONSTRAINT CK_Oport_PropJson CHECK (PropiedadesJson IS NULL OR ISJSON(PropiedadesJson) = 1);
GO

/* --- Historial de cambios de propiedades -----------------------------
   HubSpot guarda el histórico de cada propiedad. Aquí lo hacemos solo
   para las entidades del CRM y sin trigger: lo escribe la API cuando
   detecta un cambio, para no encarecer cada UPDATE.
   -------------------------------------------------------------------- */
IF OBJECT_ID('core.PropiedadHistorico') IS NULL
CREATE TABLE core.PropiedadHistorico (
    HistoricoId         BIGINT IDENTITY(1,1) NOT NULL,
    Entidad             NVARCHAR(30)   NOT NULL,
    EntidadId           BIGINT         NOT NULL,
    Clave               NVARCHAR(50)   NOT NULL,
    ValorAnterior       NVARCHAR(MAX)  NULL,
    ValorNuevo          NVARCHAR(MAX)  NULL,
    UsuarioId           INT            NOT NULL,
    Fecha               DATETIME2(3)   NOT NULL CONSTRAINT DF_PropHist_Fecha DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_PropiedadHistorico PRIMARY KEY CLUSTERED (HistoricoId),
    CONSTRAINT FK_PropHist_Usuario FOREIGN KEY (UsuarioId) REFERENCES core.Usuario (UsuarioId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_PropHist_Entidad' AND object_id=OBJECT_ID('core.PropiedadHistorico'))
CREATE INDEX IX_PropHist_Entidad ON core.PropiedadHistorico (Entidad, EntidadId, Fecha DESC);
GO

/* =====================================================================
   CÓMO SE INDEXA UNA PROPIEDAD QUE SE FILTRA MUCHO
   No se indexan todas: solo aquellas por las que se filtra o se ordena
   en las listas. El patrón es columna calculada persistida + índice.
   Ejemplo con una propiedad 'nivel_certificacion' de empresa:

   ALTER TABLE core.Empresa ADD NivelCertificacion
       AS CAST(JSON_VALUE(PropiedadesJson, '$.nivel_certificacion') AS NVARCHAR(50)) PERSISTED;
   CREATE INDEX IX_Empresa_NivelCert ON core.Empresa (NivelCertificacion);

   Esto sí es una migración, pero solo para las tres o cuatro
   propiedades que acaben siendo filtros habituales. El resto vive en
   el JSON y se lee sin coste añadido al abrir la ficha.
   ===================================================================== */

/* =====================================================================
   VISTAS PARA LA API
   ===================================================================== */

/* Definiciones que el frontend usa para pintar los formularios. */
CREATE OR ALTER VIEW crm_v.PropiedadDefinicion
AS
SELECT
    pd.PropiedadId,
    pd.Entidad,
    pd.Clave,
    pd.Etiqueta,
    pd.Descripcion,
    pd.Tipo,
    pd.Grupo,
    pd.Orden,
    pd.Obligatoria,
    pd.SoloLectura,
    pd.ValorDefecto,
    pd.ReglaValidacion,
    pd.VisibleEnLista,
    (
        SELECT po.Valor, po.Etiqueta, po.Color, po.Orden
        FROM core.PropiedadOpcion po
        WHERE po.PropiedadId = pd.PropiedadId AND po.Activa = 1
        ORDER BY po.Orden, po.Etiqueta
        FOR JSON PATH
    ) AS OpcionesJson
FROM core.PropiedadDefinicion pd
WHERE pd.Activa = 1;
GO

/* Valores de una entidad en formato fila, para pintar la ficha sin que
   el frontend tenga que conocer el esquema del JSON. */
CREATE OR ALTER VIEW crm_v.EmpresaPropiedad
AS
SELECT
    e.EmpresaId,
    pd.Clave,
    pd.Etiqueta,
    pd.Tipo,
    pd.Grupo,
    pd.Orden,
    JSON_VALUE(e.PropiedadesJson, '$.' + pd.Clave) AS Valor,
    po.Etiqueta                                    AS ValorEtiqueta,
    po.Color                                       AS ValorColor
FROM core.Empresa e
CROSS JOIN core.PropiedadDefinicion pd
LEFT JOIN core.PropiedadOpcion po
       ON po.PropiedadId = pd.PropiedadId
      AND po.Valor = JSON_VALUE(e.PropiedadesJson, '$.' + pd.Clave)
WHERE pd.Entidad = N'empresa' AND pd.Activa = 1;
GO

CREATE OR ALTER VIEW crm_v.OportunidadPropiedad
AS
SELECT
    o.OportunidadId,
    pd.Clave,
    pd.Etiqueta,
    pd.Tipo,
    pd.Grupo,
    pd.Orden,
    JSON_VALUE(o.PropiedadesJson, '$.' + pd.Clave) AS Valor,
    po.Etiqueta                                    AS ValorEtiqueta,
    po.Color                                       AS ValorColor
FROM crm.Oportunidad o
CROSS JOIN core.PropiedadDefinicion pd
LEFT JOIN core.PropiedadOpcion po
       ON po.PropiedadId = pd.PropiedadId
      AND po.Valor = JSON_VALUE(o.PropiedadesJson, '$.' + pd.Clave)
WHERE pd.Entidad = N'oportunidad' AND pd.Activa = 1;
GO

/* =====================================================================
   PROPIEDADES INICIALES
   Un punto de partida pensado para el negocio de Jomipsa. Todas se
   pueden borrar o cambiar desde la pantalla de administración.
   ===================================================================== */

IF NOT EXISTS (SELECT 1 FROM core.PropiedadDefinicion)
BEGIN
    INSERT INTO core.PropiedadDefinicion (Entidad, Clave, Etiqueta, Tipo, Grupo, Orden, VisibleEnLista, Descripcion) VALUES
        (N'empresa', N'tipo_organizacion',   N'Tipo de organización',      N'lista',       N'Clasificación', 10, 1, N'Ejército, organismo internacional, distribuidor, retail…'),
        (N'empresa', N'canal',               N'Canal',                     N'lista',       N'Clasificación', 20, 1, NULL),
        (N'empresa', N'idioma_preferido',    N'Idioma preferido',          N'lista',       N'Clasificación', 30, 0, N'Idioma para ofertas y fichas técnicas'),
        (N'empresa', N'requiere_halal',      N'Requiere halal',            N'booleano',    N'Requisitos',    40, 0, NULL),
        (N'empresa', N'certificaciones',     N'Certificaciones exigidas',  N'lista_multiple', N'Requisitos', 50, 0, N'Certificaciones que el cliente exige en sus pliegos'),
        (N'empresa', N'vida_util_minima',    N'Vida útil mínima (meses)',  N'numero',      N'Requisitos',    60, 0, NULL),
        (N'empresa', N'incoterm_habitual',   N'Incoterm habitual',         N'texto',       N'Comercial',     70, 0, NULL),
        (N'empresa', N'frecuencia_compra',   N'Frecuencia de compra',      N'lista',       N'Comercial',     80, 1, NULL),

        (N'contacto', N'rol_decision',       N'Rol en la decisión',        N'lista',       N'Perfil',        10, 1, N'Decisor, prescriptor, usuario, comprador…'),
        (N'contacto', N'linkedin',           N'LinkedIn',                  N'url',         N'Perfil',        20, 0, NULL),
        (N'contacto', N'canal_preferido',    N'Canal preferido',           N'lista',       N'Perfil',        30, 0, NULL),

        (N'oportunidad', N'modalidad',       N'Modalidad',                 N'lista',       N'Licitación',    10, 1, N'Contrato directo, licitación abierta, acuerdo marco…'),
        (N'oportunidad', N'organismo',       N'Organismo convocante',      N'texto',       N'Licitación',    20, 0, NULL),
        (N'oportunidad', N'lote',            N'Lote',                      N'texto',       N'Licitación',    30, 0, NULL),
        (N'oportunidad', N'exige_muestras',  N'Exige muestras',            N'booleano',    N'Licitación',    40, 0, NULL),
        (N'oportunidad', N'plazo_entrega',   N'Plazo de entrega (días)',   N'numero',      N'Condiciones',   50, 0, NULL);
END
GO

IF NOT EXISTS (SELECT 1 FROM core.PropiedadOpcion)
BEGIN
    INSERT INTO core.PropiedadOpcion (PropiedadId, Valor, Etiqueta, Color, Orden)
    SELECT pd.PropiedadId, v.Valor, v.Etiqueta, v.Color, v.Orden
    FROM core.PropiedadDefinicion pd
    JOIN (VALUES
        (N'empresa', N'tipo_organizacion', N'ejercito',      N'Ejército / Defensa',        N'azul',     10),
        (N'empresa', N'tipo_organizacion', N'organismo_int', N'Organismo internacional',   N'morado',   20),
        (N'empresa', N'tipo_organizacion', N'ong',           N'ONG',                       N'verde',    30),
        (N'empresa', N'tipo_organizacion', N'distribuidor',  N'Distribuidor',              N'naranja',  40),
        (N'empresa', N'tipo_organizacion', N'retail',        N'Retail',                    N'gris',     50),
        (N'empresa', N'tipo_organizacion', N'otro',          N'Otro',                      N'gris',     99),

        (N'empresa', N'canal', N'directo',       N'Venta directa',   N'azul',    10),
        (N'empresa', N'canal', N'distribucion',  N'Distribución',    N'naranja', 20),
        (N'empresa', N'canal', N'licitacion',    N'Licitación',      N'morado',  30),

        (N'empresa', N'idioma_preferido', N'es', N'Español', NULL, 10),
        (N'empresa', N'idioma_preferido', N'en', N'Inglés',  NULL, 20),
        (N'empresa', N'idioma_preferido', N'fr', N'Francés', NULL, 30),
        (N'empresa', N'idioma_preferido', N'de', N'Alemán',  NULL, 40),

        (N'empresa', N'frecuencia_compra', N'recurrente', N'Recurrente', N'verde',   10),
        (N'empresa', N'frecuencia_compra', N'estacional', N'Estacional', N'naranja', 20),
        (N'empresa', N'frecuencia_compra', N'puntual',    N'Puntual',    N'gris',    30),

        (N'contacto', N'rol_decision', N'decisor',     N'Decisor',     N'azul',    10),
        (N'contacto', N'rol_decision', N'prescriptor', N'Prescriptor', N'morado',  20),
        (N'contacto', N'rol_decision', N'comprador',   N'Comprador',   N'verde',   30),
        (N'contacto', N'rol_decision', N'usuario',     N'Usuario',     N'gris',    40),

        (N'contacto', N'canal_preferido', N'email',    N'Email',    NULL, 10),
        (N'contacto', N'canal_preferido', N'telefono', N'Teléfono', NULL, 20),
        (N'contacto', N'canal_preferido', N'whatsapp', N'WhatsApp', NULL, 30),

        (N'oportunidad', N'modalidad', N'directo',       N'Contrato directo',  N'verde',   10),
        (N'oportunidad', N'modalidad', N'abierta',       N'Licitación abierta',N'morado',  20),
        (N'oportunidad', N'modalidad', N'acuerdo_marco', N'Acuerdo marco',     N'azul',    30),
        (N'oportunidad', N'modalidad', N'consulta',      N'Consulta de mercado', N'gris',  40)
    ) v(Entidad, Clave, Valor, Etiqueta, Color, Orden)
      ON v.Entidad = pd.Entidad AND v.Clave = pd.Clave;
END
GO

/* Permisos para el usuario de la API. */
GRANT SELECT ON crm_v.PropiedadDefinicion  TO [crm_app];
GRANT SELECT ON crm_v.EmpresaPropiedad     TO [crm_app];
GRANT SELECT ON crm_v.OportunidadPropiedad TO [crm_app];
GO
