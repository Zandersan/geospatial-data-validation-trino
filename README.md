## Validação Geoespacial de Bairros e Regionais

### Problema

Durante a análise de dados exibidos em mapas, foi identificado que alguns pontos apareciam fora do bairro esperado ao aplicar filtros.

A investigação mostrou que, em diversos registros, o problema não estava nas coordenadas geográficas: **latitude e longitude estavam corretas, porém o bairro informado na base de origem estava preenchido incorretamente**.

Isso gerava inconsistências entre a localização real do ponto no mapa e o bairro utilizado para classificação e filtragem dos dados.

### Solução

Para tornar a localização independente do bairro informado na origem, implementei uma validação baseada em **geometria espacial**.

Os arquivos geográficos oficiais de **Bairros e Regionais de Curitiba** foram obtidos através do portal de geodados do IPPUC. Em Python, utilizei **GeoPandas** para:

- realizar a leitura dos arquivos geográficos;
- converter o sistema de coordenadas para **EPSG:4326**;
- transformar as geometrias em **WKT (Well-Known Text)**;
- criar e carregar tabelas dimensionais de bairros e regionais no **Trino**.

A carga foi automatizada em Python, incluindo a criação das tabelas `dim_bairros_geometria` e `dim_regionais_geometria` e a inserção dos dados geográficos em lotes. 

### Validação no Trino

Nas consultas SQL/dbt, as geometrias armazenadas em WKT são convertidas novamente para objetos espaciais utilizando:

`ST_GeometryFromText(geometry_wkt)`

Em seguida, a função `ST_Contains` verifica em qual polígono cada coordenada está localizada, utilizando `ST_Point(longitude, latitude)`. Dessa forma, o **bairro real é determinado pelas coordenadas**, e não apenas pelo texto cadastrado no sistema de origem. 

A mesma abordagem também foi aplicada para determinar automaticamente a **Regional/Núcleo** correspondente à coordenada. 

### Resultado

A solução passou a identificar automaticamente registros como **OK**, **Bairro Divergente**, **Sem Coordenada** ou **Fora de Curitiba**, permitindo detectar problemas de qualidade cadastral.

Além da validação, a coordenada geográfica passou a ser utilizada como **fonte prioritária para definição do bairro**, mantendo o valor original apenas como fallback quando não é possível determinar a localização espacial.

Com isso, os mapas e filtros passaram a representar a **localização geográfica efetiva dos registros**, reduzindo inconsistências causadas por erros de preenchimento na base de origem.

**Tecnologias utilizadas:** Python • GeoPandas • Trino • SQL • dbt • WKT • Funções Geoespaciais • ETL/ELT • Qualidade de Dados
