# data-index — página-índice de `https://data.sidneybissoli.com/`

O domínio `data.sidneybissoli.com` é ligado direto ao bucket R2 `healthbr-data`,
que só serve objetos pelo caminho exato; a raiz `/` não é objeto e devolvia o
404 padrão da Cloudflare. Este Worker responde **apenas na rota da raiz exata**
(`data.sidneybissoli.com/`), com uma página que lista os datasets, aponta os
manifestos e lê o `sih/cubos/manifest.json` no próprio bucket (binding
`BUCKET`) para mostrar quantos anos de cubos existem. Todo outro caminho
continua indo ao R2 sem passar por aqui, e a Cache Rule do domínio (objetos
pelo `Cache-Control` da origem; `.json` com 5 minutos) segue valendo.

- Fonte: `src/index.js` (módulo ES, sem build, sem dependências).
- Configuração: `wrangler.jsonc` (rota, binding R2, observabilidade).
- Cache: a resposta sai com `Cache-Control: public, max-age=300`.

## Deploy

```
cd workers/data-index
npx wrangler deploy
```

Exige `wrangler login` com escopo de edição de Workers. Sem ele, o mesmo
deploy sai pela API (foi assim em 07/09/2026, pelo MCP oficial da Cloudflare):
`PUT /accounts/{account}/workers/scripts/healthbr-data-index` em
`multipart/form-data` com `metadata` (`main_module: "index.js"`,
`compatibility_date`, `bindings: [{type: "r2_bucket", name: "BUCKET",
bucket_name: "healthbr-data"}]`, `observability`) e a parte `index.js`
(`application/javascript+module`), depois
`POST /zones/{zone}/workers/routes` com
`{pattern: "data.sidneybissoli.com/", script: "healthbr-data-index"}`.

## Conferência

```
curl -s -o /dev/null -w "%{http_code} %{content_type}\n" https://data.sidneybissoli.com/
curl -s -o /dev/null -w "%{http_code}\n" https://data.sidneybissoli.com/sih/cubos/manifest.json
```

A raiz responde `200 text/html`; o manifesto continua `200` vindo do R2.
