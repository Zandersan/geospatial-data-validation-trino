# %%
import os
import pandas as pd
import geopandas as gpd
import trino
from trino.auth import BasicAuthentication
from trino.dbapi import connect

TRINO_HOST = os.environ.get("TRINO_HOST", "host")
TRINO_PORT = int(os.environ.get("TRINO_PORT", "port"))
TRINO_USER = os.environ.get("TRINO_USER", "login")
TRINO_PASSWORD = os.environ.get("TRINO_PASSWORD", "senha")

TRINO_CATALOG = os.environ.get("TRINO_CATALOG", "sms")
TRINO_SCHEMA = os.environ.get("TRINO_SCHEMA", "dev_gold")

CAMINHO_ZIP_BAIRROS = "DIVISA_DE_BAIRROS.zip"
CAMINHO_ZIP_REGIONAIS = "DIVISA_DE_REGIONAIS.zip"

TABELA_BAIRROS = "dim_bairros_geometria"
TABELA_REGIONAIS = "dim_regionais_geometria"

# %%
conn = connect(
    host=TRINO_HOST,
    port=TRINO_PORT,
    user=TRINO_USER,
    catalog=TRINO_CATALOG,
    schema=TRINO_SCHEMA,
    http_scheme="https",
    auth=BasicAuthentication(TRINO_USER, TRINO_PASSWORD),
    verify=False,
)

cur = conn.cursor()

# %%
def normalizar_colunas(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df.columns = [
        c.lower()
         .replace(" ", "_")
         .replace(".", "_")
         .replace("-", "_")
        for c in df.columns
    ]
    return df


def carregar_shapefile_zip(caminho_zip: str) -> gpd.GeoDataFrame:
    gdf = gpd.read_file(f"zip://{caminho_zip}")
    
    if gdf.crs is None:
        raise ValueError(f"O arquivo {caminho_zip} está sem CRS definido.")
    
    gdf = gdf.to_crs("EPSG:4326")
    gdf = normalizar_colunas(gdf)
    gdf["geometry_wkt"] = gdf.geometry.to_wkt()
    gdf = gdf.drop(columns=["geometry"], errors="ignore")
    
    return pd.DataFrame(gdf)

# %%
def sql_literal(valor):
    if pd.isna(valor):
        return "NULL"
    
    if isinstance(valor, (int, float)):
        return str(valor)
    
    valor = str(valor).replace("'", "''")
    return f"'{valor}'"


def criar_tabela_bairros():
    cur.execute(f"""
        drop table if exists {TRINO_CATALOG}.{TRINO_SCHEMA}.{TABELA_BAIRROS}
    """)
    
    cur.execute(f"""
        create table {TRINO_CATALOG}.{TRINO_SCHEMA}.{TABELA_BAIRROS} (
            objectid integer,
            codigo integer,
            tipo varchar,
            nome varchar,
            fonte varchar,
            cd_regiona integer,
            nm_regiona varchar,
            shape_area double,
            shape_len double,
            geometry_wkt varchar
        )
    """)


def criar_tabela_regionais():
    cur.execute(f"""
        drop table if exists {TRINO_CATALOG}.{TRINO_SCHEMA}.{TABELA_REGIONAIS}
    """)
    
    cur.execute(f"""
        create table {TRINO_CATALOG}.{TRINO_SCHEMA}.{TABELA_REGIONAIS} (
            objectid integer,
            codigo double,
            tipo varchar,
            nome varchar,
            nome_leg varchar,
            cod_leg varchar,
            fonte varchar,
            shape_area double,
            shape_len double,
            geometry_wkt varchar
        )
    """)

# %%
def inserir_dataframe(df: pd.DataFrame, tabela: str, colunas: list[str], batch_size: int = 50):
    df = df[colunas].copy()

    total = len(df)
    print(f"Inserindo {total} registros em {tabela}...")

    for inicio in range(0, total, batch_size):
        lote = df.iloc[inicio:inicio + batch_size]

        values_sql = []
        for _, row in lote.iterrows():
            valores = ", ".join(sql_literal(row[col]) for col in colunas)
            values_sql.append(f"({valores})")

        query = f"""
            insert into {TRINO_CATALOG}.{TRINO_SCHEMA}.{tabela}
            ({", ".join(colunas)})
            values
            {", ".join(values_sql)}
        """

        cur.execute(query)
        print(f"Lote {inicio + 1} até {min(inicio + batch_size, total)} inserido.")

    print("Carga finalizada.")

# %%
# Bairros

df_bairros = carregar_shapefile_zip(CAMINHO_ZIP_BAIRROS)

df_bairros = df_bairros.rename(columns={
    "objectid": "objectid",
    "codigo": "codigo",
    "tipo": "tipo",
    "nome": "nome",
    "fonte": "fonte",
    "cd_regiona": "cd_regiona",
    "nm_regiona": "nm_regiona",
    "shape_area": "shape_area",
    "shape_len": "shape_len",
})

colunas_bairros = [
    "objectid",
    "codigo",
    "tipo",
    "nome",
    "fonte",
    "cd_regiona",
    "nm_regiona",
    "shape_area",
    "shape_len",
    "geometry_wkt",
]

criar_tabela_bairros()
inserir_dataframe(df_bairros, TABELA_BAIRROS, colunas_bairros)

df_bairros.head()

# %%
# Regionais

df_regionais = carregar_shapefile_zip(CAMINHO_ZIP_REGIONAIS)

df_regionais = df_regionais.rename(columns={
    "objectid": "objectid",
    "codigo": "codigo",
    "tipo": "tipo",
    "nome": "nome",
    "nome_leg": "nome_leg",
    "cod_leg": "cod_leg",
    "fonte": "fonte",
    "shape_area": "shape_area",
    "shape_len": "shape_len",
})

colunas_regionais = [
    "objectid",
    "codigo",
    "tipo",
    "nome",
    "nome_leg",
    "cod_leg",
    "fonte",
    "shape_area",
    "shape_len",
    "geometry_wkt",
]

criar_tabela_regionais()
inserir_dataframe(df_regionais, TABELA_REGIONAIS, colunas_regionais)

df_regionais.head()


