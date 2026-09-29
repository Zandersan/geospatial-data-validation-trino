with base_atendimento as (
    select
        atd.id as atendimento_id,
        cast(date_trunc('month', atd.datacriacaoatendimento) as date) as mes_ano,
        ori.descricao as origem_descricao,
        atd.statusatendimento,
        cast(atd.datacriacaoatendimento as date) as data_ocorrencia,

        max(
            case
                when nat.flagrante = true
                 and nat.id <> 12
                then 1
                else 0
            end
        ) as flg_crime,

        max(
            case
                when lower(nat.nomenatureza) like '%maria da penha%'
                then 1
                else 0
            end
        ) as flg_maria_penha,

        max(
            case
                when nat.id = 1
                then 1
                else 0
            end
        ) as flg_defesa_civil,

        max(
            case
                when lower(nat.nomenatureza) like '%transito%'
                  or lower(nat.nomenatureza) like '%trânsito%'
                then 1
                else 0
            end
        ) as flg_transito,

        max(
            case
                when nat.id = 12
                then 1
                else 0
            end
        ) as flg_drogas,

        {{ smdt_bairro_chave('edr.bairro') }} as bairro_chave,

        case
            when try_cast(
                regexp_replace(
                    cast(edr.cep as varchar),
                    '[^0-9]',
                    ''
                ) as bigint
            ) between 80000000 and 83999999
            then lpad(
                regexp_replace(
                    cast(edr.cep as varchar),
                    '[^0-9]',
                    ''
                ),
                8,
                '0'
            )
            else null
        end as cep,

        try_cast(
            replace(
                cast(edr.latitude as varchar),
                ',',
                '.'
            ) as double
        ) as latitude,

        try_cast(
            replace(
                cast(edr.longitude as varchar),
                ',',
                '.'
            ) as double
        ) as longitude

    from {{ source('smartgov', 'guardamunicipal_public_atendimento') }} atd

    join {{ source('smartgov', 'guardamunicipal_public_atendimentonatureza') }} atn
        on atn.atendimentoid = atd.id

    join {{ source('smartgov', 'guardamunicipal_public_natureza') }} nat
        on nat.id = atn.naturezaid

    left join {{ source('smartgov', 'guardamunicipal_public_origem') }} ori
        on ori.id = atd.origemid

    left join {{ source('smartgov', 'guardamunicipal_public_endereco') }} edr
        on edr.id = atd.enderecoid

    where year(atd.datacriacaoatendimento) = 2026
      and cast(atd.datacriacaoatendimento as date) < current_date + interval '1' day

    group by
        atd.id,
        cast(date_trunc('month', atd.datacriacaoatendimento) as date),
        ori.descricao,
        atd.statusatendimento,
        cast(atd.datacriacaoatendimento as date),
        {{ smdt_bairro_chave('edr.bairro') }},
        edr.cep,
        edr.latitude,
        edr.longitude
),

base as (
    select
        atendimento_id,
        mes_ano,
        data_ocorrencia,

        case
            when origem_descricao = '156'
                then 'Central 156'
            when trim(coalesce(origem_descricao, '')) = ''
                then 'Sem Nº Ocorrência'
            else 'Sigesguarda'
        end as origem_registro,

        case
            when statusatendimento = 1 then 'Aberto'
            when statusatendimento = 2 then 'Em Atendimento'
            when statusatendimento = 3 then 'Encerrado'
            when statusatendimento = 4 then 'Atendido'
            else null
        end as status,

        case
            when flg_crime = 1 then 'Crime'
            when flg_maria_penha = 1 then 'Maria da Penha'
            when flg_defesa_civil = 1 then 'Defesa Civil'
            when flg_transito = 1 then 'Trânsito'
            when flg_drogas = 1 then 'Drogas'
            else 'Outros'
        end as tipo_ocorrencia,

        day_of_week(data_ocorrencia) as ordem_dia_semana,

        case day_of_week(data_ocorrencia)
            when 1 then 'Segunda-feira'
            when 2 then 'Terça-feira'
            when 3 then 'Quarta-feira'
            when 4 then 'Quinta-feira'
            when 5 then 'Sexta-feira'
            when 6 then 'Sábado'
            when 7 then 'Domingo'
        end as dia_semana,

        bairro_chave,
        cep,
        latitude,
        longitude

    from base_atendimento
),

bairros as (
    {{ smdt_bairros_mapa() }}
),

base_bairro as (
    select
        base.atendimento_id,
        base.data_ocorrencia,
        base.mes_ano,
        base.tipo_ocorrencia,

        case
            when {{ smdt_bairro_normalizado('base.bairro_chave') }} is not null
            then concat(
                upper(substr(trim({{ smdt_bairro_normalizado('base.bairro_chave') }}), 1, 1)),
                lower(substr(trim({{ smdt_bairro_normalizado('base.bairro_chave') }}), 2))
            )
        end as bairro_original,

        base.cep,
        base.latitude,
        base.longitude,
        base.status,
        base.origem_registro,
        base.ordem_dia_semana,
        base.dia_semana

    from base

    left join bairros b
        on b.bairro_chave = base.bairro_chave
),

/* ============================================================
POLÍGONOS DOS BAIRROS DE CURITIBA
============================================================ */

bairros_geometria as (
    select
        case
            when trim(nome) <> ''
            then concat(
                upper(substr(trim(nome), 1, 1)),
                lower(substr(trim(nome), 2))
            )
        end as bairro_coordenada,
        ST_GeometryFromText(geometry_wkt) as geometria

    from {{ source('sms', 'dim_bairros_geometria') }}

    where tipo = 'DIVISA DE BAIRROS'
      and geometry_wkt is not null
),

/* ============================================================
IDENTIFICA O BAIRRO REAL DA LATITUDE/LONGITUDE
============================================================ */

validacao_geografica as (
    select
        b.atendimento_id,
        b.data_ocorrencia,
        b.mes_ano,
        b.tipo_ocorrencia,
        b.bairro_original,
        g.bairro_coordenada,
        b.cep,
        b.latitude,
        b.longitude,
        b.status,
        b.origem_registro,
        b.ordem_dia_semana,
        b.dia_semana

    from base_bairro b

    left join bairros_geometria g
        on b.latitude is not null
       and b.longitude is not null
       and ST_Contains(
            g.geometria,
            ST_Point(
                b.longitude,
                b.latitude
            )
       )
),

/* ============================================================
TRATAMENTO FINAL
============================================================ */

tratado as (
    select
        atendimento_id,
        data_ocorrencia,
        mes_ano,
        tipo_ocorrencia,

        bairro_original,
        bairro_coordenada,

        case
            when latitude is null
              or longitude is null
                then 'SEM COORDENADA'

            when bairro_coordenada is null
                then 'FORA DE CURITIBA'

            when upper(trim(bairro_original)) =
                 upper(trim(bairro_coordenada))
                then 'OK'

            else 'BAIRRO DIVERGENTE'
        end as validacao_coordenada,

        /*
        A coordenada passa a ser a fonte principal do bairro.
        Caso não seja possível determinar pela coordenada,
        mantém o bairro informado originalmente.
        */
        coalesce(
            bairro_coordenada,
            bairro_original
        ) as bairro,

        cep,
        latitude,
        longitude,
        status,
        origem_registro,
        ordem_dia_semana,
        dia_semana

    from validacao_geografica
)

select
    atendimento_id,
    data_ocorrencia,
    mes_ano,
    tipo_ocorrencia,
    bairro,
    cep,
    latitude,
    longitude,
    status,
    origem_registro,
    dia_semana
from tratado
order by
    data_ocorrencia desc,
    atendimento_id