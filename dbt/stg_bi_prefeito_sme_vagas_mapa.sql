with parametros as (
    select
        current_date as data_atual,
        cast(date_trunc('year', current_date) as date) as inicio_ano_atual
),

/* ============================================================
BASE DE ENDEREÇO DA CRIANÇA
============================================================ */

base_endereco as (
    select distinct
        c.id as criancaid,

        case
            when try_cast(
                regexp_replace(cast(e.cep as varchar), '[^0-9]', '')
                as bigint
            ) between 80000000 and 83999999
            then lpad(
                regexp_replace(cast(e.cep as varchar), '[^0-9]', ''),
                8,
                '0'
            )
            else null
        end as cep,

        try_cast(
            replace(cast(e.latitude as varchar), ',', '.')
            as double
        ) as latitude,

        try_cast(
            replace(cast(e.longitude as varchar), ',', '.')
            as double
        ) as longitude,

        e.bairro

    from {{ source('sme_silver', 'educacaoinfantil_public_crianca') }} c

    inner join {{ source('sme_silver', 'educacaoinfantil_public_responsavel') }} r
        on c.responsavelid = r.id

    inner join {{ source('sme_silver', 'educacaoinfantil_public_endereco') }} e
        on r.enderecoid = e.id
),

/* ============================================================
PRIMEIRA OPÇÃO DE NÚCLEO DA INTENÇÃO DE VAGA
============================================================ */

intencao_unidade_rank as (
    select
        iu.intencaovagaid,
        iu.nucleoid,
        iu.ordempreferencia,

        row_number() over (
            partition by iu.intencaovagaid
            order by iu.ordempreferencia asc, iu.id asc
        ) as rn

    from {{ source('sme_silver', 'educacaoinfantil_public_intencaovagaunidade') }} iu
),

/* ============================================================
NOME DOS NÚCLEOS
============================================================ */

nucleos as (
    select
        nucleoid,
        max(nucleo) as nucleo

    from {{ source('sme_silver', 'educacaoinfantil_public_vagaporunidade') }}

    where nucleoid is not null

    group by nucleoid
),

/* ============================================================
FILA ATUAL
============================================================ */

fila_atual_base as (
    select distinct
        iv.id as intencaovagaid,
        iv.criancaid,
        cast(iv.datacadastro as date) as data_referencia,
        cast(pc.datanascimento as date) as datanascimento,
        e.cep,
        e.latitude,
        e.longitude,
        e.bairro

    from {{ source('sme_silver', 'educacaoinfantil_public_intencaovaga') }} iv

    inner join {{ source('sme_silver', 'educacaoinfantil_public_crianca') }} c
        on c.id = iv.criancaid

    inner join {{ source('sme_silver', 'educacaoinfantil_public_pessoa') }} pc
        on pc.id = c.pessoaid

    inner join base_endereco e
        on e.criancaid = iv.criancaid

    cross join parametros p

    where iv.status = 1
      and iv.valecrechedeferido = false
      and cast(iv.datacadastro as date)
            between p.inicio_ano_atual and p.data_atual
      and date_add(
            'month',
            4,
            cast(pc.datanascimento as date)
          ) <= p.data_atual
),

fila_atual as (
    select distinct
        f.intencaovagaid,
        f.criancaid,
        f.data_referencia,
        f.cep,
        f.latitude,
        f.longitude,
        f.bairro,
        iu.nucleoid,
        n.nucleo,

        case
            when ce.turma in (1, 2, 7) then 7
            when ce.turma in (3, 4, 8) then 8
        end as grupo_turma,

        case
            when ce.turma in (1, 2, 7) then 'Berçário'
            when ce.turma in (3, 4, 8) then 'Maternal'
        end as turma,

        'fila_ativa' as situacao

    from fila_atual_base f

    inner join {{ source('sme_silver', 'educacaoinfantil_public_configuracaocorteetario') }} ce
        on f.datanascimento between cast(ce.datainicial as date)
                               and cast(ce.datafinal as date)

    left join intencao_unidade_rank iu
        on iu.intencaovagaid = f.intencaovagaid
       and iu.rn = 1

    left join nucleos n
        on n.nucleoid = iu.nucleoid

    where ce.turma in (1, 2, 3, 4, 7, 8)
),

/* ============================================================
CONTEMPLADOS AO VALE-CRECHE NO ANO ATUAL
ÚLTIMO REGISTRO POR CRIANÇA
============================================================ */

contemplados_base as (
    select
        intencaovagaid,
        criancaid,
        data_referencia,
        datanascimento,
        cep,
        latitude,
        longitude,
        bairro

    from (
        select
            vc.intencaovagaid,
            vc.criancaid,
            cast(vc.data as date) as data_referencia,
            cast(pc.datanascimento as date) as datanascimento,
            e.cep,
            e.latitude,
            e.longitude,
            e.bairro,

            row_number() over (
                partition by vc.criancaid
                order by vc.data desc
            ) as rn

        from {{ source('sme_silver', 'educacaoinfantil_public_valecrechehistorico') }} vc

        inner join {{ source('sme_silver', 'educacaoinfantil_public_crianca') }} c
            on c.id = vc.criancaid

        inner join {{ source('sme_silver', 'educacaoinfantil_public_pessoa') }} pc
            on pc.id = c.pessoaid

        inner join base_endereco e
            on e.criancaid = vc.criancaid

        cross join parametros p

        where vc.situacao in (
            'Contemplado',
            'ContemplacaoCanceladaViaAdm',
            'ContemplacaoCanceladaViaPortal'
        )

          and cast(vc.data as date)
                between p.inicio_ano_atual and p.data_atual
    ) t

    where rn = 1
),

contemplados_atual as (
    select distinct
        f.intencaovagaid,
        f.criancaid,
        f.data_referencia,
        f.cep,
        f.latitude,
        f.longitude,
        f.bairro,
        iu.nucleoid,
        n.nucleo,

        case
            when ce.turma in (1, 2, 7) then 7
            when ce.turma in (3, 4, 8) then 8
        end as grupo_turma,

        case
            when ce.turma in (1, 2, 7) then 'Berçário'
            when ce.turma in (3, 4, 8) then 'Maternal'
        end as turma,

        'contemplado' as situacao

    from contemplados_base f

    inner join {{ source('sme_silver', 'educacaoinfantil_public_configuracaocorteetario') }} ce
        on f.datanascimento between cast(ce.datainicial as date)
                               and cast(ce.datafinal as date)

    left join intencao_unidade_rank iu
        on iu.intencaovagaid = f.intencaovagaid
       and iu.rn = 1

    left join nucleos n
        on n.nucleoid = iu.nucleoid

    where ce.turma in (1, 2, 3, 4, 7, 8)
),

/* ============================================================
DEFERIDOS NO ANO ATUAL
============================================================ */

deferidos_base as (
    select distinct
        vc.intencaovagaid,
        vc.criancaid,
        cast(vc.data as date) as data_referencia,
        cast(pc.datanascimento as date) as datanascimento,
        e.cep,
        e.latitude,
        e.longitude,
        e.bairro

    from {{ source('sme_silver', 'educacaoinfantil_public_valecreche') }} vc

    inner join {{ source('sme_silver', 'educacaoinfantil_public_crianca') }} c
        on c.id = vc.criancaid

    inner join {{ source('sme_silver', 'educacaoinfantil_public_pessoa') }} pc
        on pc.id = c.pessoaid

    inner join base_endereco e
        on e.criancaid = vc.criancaid

    cross join parametros p

    where cast(vc.data as date)
            between p.inicio_ano_atual and p.data_atual

      and vc.situacao in (
          'Deferido',
          'DeferimentoCanceladoViaAdm',
          'DeferimentoCanceladoViaPortal'
      )
),

deferidos_atual as (
    select distinct
        f.intencaovagaid,
        f.criancaid,
        f.data_referencia,
        f.cep,
        f.latitude,
        f.longitude,
        f.bairro,
        iu.nucleoid,
        n.nucleo,

        case
            when ce.turma in (1, 2, 7) then 7
            when ce.turma in (3, 4, 8) then 8
        end as grupo_turma,

        case
            when ce.turma in (1, 2, 7) then 'Berçário'
            when ce.turma in (3, 4, 8) then 'Maternal'
        end as turma,

        'deferido' as situacao

    from deferidos_base f

    inner join {{ source('sme_silver', 'educacaoinfantil_public_configuracaocorteetario') }} ce
        on f.datanascimento between cast(ce.datainicial as date)
                               and cast(ce.datafinal as date)

    left join intencao_unidade_rank iu
        on iu.intencaovagaid = f.intencaovagaid
       and iu.rn = 1

    left join nucleos n
        on n.nucleoid = iu.nucleoid

    where ce.turma in (1, 2, 3, 4, 7, 8)
),

/* ============================================================
BASE FINAL
============================================================ */

base_final as (
    select
        intencaovagaid,
        criancaid,
        data_referencia,
        cep,
        latitude,
        longitude,
        bairro,
        nucleoid,
        nucleo,
        grupo_turma,
        turma,
        situacao
    from fila_atual

    union all

    select
        intencaovagaid,
        criancaid,
        data_referencia,
        cep,
        latitude,
        longitude,
        bairro,
        nucleoid,
        nucleo,
        grupo_turma,
        turma,
        situacao
    from contemplados_atual

    union all

    select
        intencaovagaid,
        criancaid,
        data_referencia,
        cep,
        latitude,
        longitude,
        bairro,
        nucleoid,
        nucleo,
        grupo_turma,
        turma,
        situacao
    from deferidos_atual
),

/* ============================================================
GEOMETRIA DOS BAIRROS
============================================================ */

bairros_geometria as (
    select
        concat(
            upper(substr(trim(nome), 1, 1)),
            lower(substr(trim(nome), 2))
        ) as bairro_coordenada,

        ST_GeometryFromText(geometry_wkt) as geometria_bairro

    from {{ source('sms', 'dim_bairros_geometria') }}

    where geometry_wkt is not null
),

/* ============================================================
GEOMETRIA DAS REGIONAIS
============================================================ */

regionais_geometria as (
    select
        concat(
            upper(substr(trim(nome), 1, 1)),
            lower(substr(trim(nome), 2))
        ) as nucleo_coordenada,

        ST_GeometryFromText(geometry_wkt) as geometria_regional

    from {{ source('sms', 'dim_regionais_geometria') }}

    where geometry_wkt is not null
),

/* ============================================================
IDENTIFICA O BAIRRO PELA COORDENADA
============================================================ */

validacao_bairro as (
    select
        b.intencaovagaid,
        b.criancaid,
        b.data_referencia,
        b.cep,
        b.latitude,
        b.longitude,

        concat(
            upper(substr(trim(b.bairro), 1, 1)),
            lower(substr(trim(b.bairro), 2))
        ) as bairro_original,

        bg.bairro_coordenada,

        b.nucleoid,
        b.nucleo,
        b.grupo_turma,
        b.turma,
        b.situacao

    from base_final b

    left join bairros_geometria bg
        on b.latitude is not null
       and b.longitude is not null
       and ST_Contains(
            bg.geometria_bairro,
            ST_Point(
                b.longitude,
                b.latitude
            )
       )
),

/* ============================================================
IDENTIFICA A REGIONAL PELA COORDENADA
============================================================ */

validacao_geografica as (
    select
        b.intencaovagaid,
        b.criancaid,
        b.data_referencia,
        b.cep,
        b.latitude,
        b.longitude,

        b.bairro_original,
        b.bairro_coordenada,

        b.nucleoid,

        concat(
            upper(substr(trim(b.nucleo), 1, 1)),
            lower(substr(trim(b.nucleo), 2))
        ) as nucleo_original,

        rg.nucleo_coordenada,

        b.grupo_turma,
        b.turma,
        b.situacao

    from validacao_bairro b

    left join regionais_geometria rg
        on b.latitude is not null
       and b.longitude is not null
       and ST_Contains(
            rg.geometria_regional,
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
        intencaovagaid,
        criancaid,
        data_referencia,
        cep,
        latitude,
        longitude,

        /* BAIRRO */

        bairro_original,
        bairro_coordenada,

        case
            when latitude is null
              or longitude is null
                then 'SEM COORDENADA'

            when bairro_coordenada is null
                then 'FORA DE CURITIBA'

            when lower(trim(coalesce(bairro_original, ''))) =
                 lower(trim(coalesce(bairro_coordenada, '')))
                then 'OK'

            else 'BAIRRO DIVERGENTE'
        end as validacao_bairro,

        coalesce(
            bairro_coordenada,
            bairro_original
        ) as bairro,

        /* NÚCLEO / REGIONAL */

        nucleoid,
        nucleo_original,
        nucleo_coordenada,

        case
            when latitude is null
              or longitude is null
                then 'SEM COORDENADA'

            when nucleo_coordenada is null
                then 'FORA DE CURITIBA'

            when lower(trim(coalesce(nucleo_original, ''))) =
                 lower(trim(coalesce(nucleo_coordenada, '')))
                then 'OK'

            else 'NÚCLEO DIVERGENTE'
        end as validacao_nucleo,

        coalesce(
            nucleo_coordenada,
            nucleo_original
        ) as nucleo,

        grupo_turma,
        turma,
        situacao

    from validacao_geografica
)

/* ============================================================
RESULTADO FINAL
============================================================ */

select
    intencaovagaid,
    criancaid,
    data_referencia,
    cep,
    latitude,
    longitude,
    bairro,
    nucleoid,
    nucleo,
    grupo_turma,
    turma,
    situacao
from tratado