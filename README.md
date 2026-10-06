# ToggleMaster - Fase 2 (Tech Challenge Pós Tech FIAP)

## 📌 Dificuldades Encontradas e Decisões Técnicas de Engenharia

Este documento consolida o registro detalhado de todas as dificuldades técnicas, divergências de especificação, incompatibilidades de código e decisões de arquitetura encontradas durante a conteinerização e execução local dos microsserviços do **ToggleMaster**. 

Este registro serve como subsídio direto para o relatório de entrega e para o vídeo demonstrativo da Fase 2.

---

### 1. Restrição de 2 Instâncias de PostgreSQL para 3 Microsserviços Relacionais

* **Contexto:** O roteiro do projeto (página 4 e 9 do PDF) determinou que o ambiente local deve subir exatamente **9 contêineres** (5 microsserviços + 4 bancos de dados: 2 instâncias PostgreSQL, 1 Redis e 1 DynamoDB Local). No entanto, o ecossistema fornecido conta com **3 serviços relacionais distintos**:
  * `auth-service` $\rightarrow$ banco `auth_db`
  * `flag-service` $\rightarrow$ banco `flags_db`
  * `targeting-service` $\rightarrow$ banco `targeting_db`
* **Impasse Técnico:** A imagem oficial do Docker `postgres:15-alpine` suporta apenas um único banco de dados configurado via variável de ambiente (`POSTGRES_DB`). Ela não possui suporte nativo para provisionar múltiplos bancos de dados em uma única instância apenas através de variáveis do `docker-compose.yml`.
* **Decisão & Solução Adotada:** 
  * A primeira instância PostgreSQL (`auth-db`) ficou dedicada ao `auth-service`.
  * Para a segunda instância (`app-db`), criada para atender simultaneamente ao `flag-service` e ao `targeting-service`, criamos o script [`docker/init-app-db.sh`](file:///home/swerneck/Projetos/FIAP-ToggleMaster-Fase-2/docker/init-app-db.sh).
  * O script foi montado no diretório `/docker-entrypoint-initdb.d/` do contêiner. Durante o primeiro boot da instância, ele executa os comandos `CREATE DATABASE flags_db;` e `CREATE DATABASE targeting_db;` e em seguida aplica os scripts de schema (`init.sql`) de cada microsserviço nas suas respectivas bases.
  * Essa solução respeitou rigorosamente o teto de 9 contêineres do enunciado sem exigir nenhuma instância extra de banco relacional.

---

### 2. Incompatibilidade entre Versões de Dependências Python (Flask 2.2.2 vs. Werkzeug 3.x)

* **Contexto:** Os três microsserviços em Python (`flag-service`, `targeting-service` e `analytics-service`) utilizavam um arquivo `requirements.txt` fornecido com a biblioteca `Flask==2.2.2`.
* **Impasse Técnico:** Ao construir as imagens Docker e iniciar os serviços sob o Gunicorn, os contêineres entravam em reinicialização contínua (*CrashLoop*) com a seguinte exceção:
  ```text
  ImportError: cannot import name 'url_quote' from 'werkzeug.urls'
  ```
  Isso ocorreu porque o `requirements.txt` original não travava a versão da biblioteca transitiva `Werkzeug`. O gerenciador `pip` baixava a versão mais recente (`Werkzeug 3.1.x`), que removeu a função legada `url_quote`, essencial para a versão antiga do Flask 2.2.2.
* **Decisão & Solução Adotada:** 
  * Para preservar 100% do código da aplicação dos professores sem alterar nenhuma linha dos arquivos `app.py`, fixamos a compatibilidade de dependência nos `requirements.txt`:
    ```text
    Flask==2.2.2
    Werkzeug>=2.2.2,<3.0.0
    ```
  * Isso restabeleceu a compatibilidade binária imediata com o Flask 2.2.2 e permitiu que todos os workers Gunicorn iniciassem normalmente.

---

### 3. Falhas e Erros de Compilação Pré-existentes nos Microsserviços em Go

* **Contexto:** Os microsserviços `auth-service` e `evaluation-service` foram desenvolvidos em Go 1.21. No processo de conteinerização com compilação multi-stage (`go build`), nos deparamos com erros fatais de compilação em código fornecido.
* **Impasses Técnicos Encontrados:**
  1. **Sintaxe Inválida no `go.mod` do `auth-service`:** O arquivo trazia a diretiva `github.com/jackc/pgx/v4/stdlib v4.18.3` dentro do bloco `require`. Em Go, `stdlib` é um subpacote interno do driver `pgx/v4`, e não um módulo independente. O compilador abortava a compilação com `version invalid: should be v0 or v1, not v4`.
  2. **Imports Não Utilizados no Go:** O compilador do Go é estrito e proíbe imports não utilizados (*imported and not used* é considerado erro fatal pelo compilador, não mero warning):
     * Em `auth-service/key.go`: import `"fmt"` não utilizado.
     * Em `auth-service/handlers.go`: imports `"crypto/sha256"` e `"encoding/hex"` não utilizados.
     * Em `auth-service/main.go`: import `"fmt"` não utilizado, e o driver PostgreSQL estava importado como identificador nomeado em vez de *blank identifier* (`_ "github.com/jackc/pgx/v4/stdlib"`), que é o padrão da linguagem para registro estático de drivers de banco SQL.
     * Em `evaluation-service/evaluator.go`: import `"context"` não utilizado, enquanto faltava o import essencial `"os"` para chamar `os.Getenv("SERVICE_API_KEY")`.
* **Decisão & Solução Adotada:** 
  * Ajustamos cirurgicamente o `go.mod` removendo a entrada incorreta do subpacote.
  * Realizamos a limpeza dos imports não utilizados e adicionamos o import de `os` faltante.
  * Com isso, o build multi-stage estático compilou binários enxutos com sucesso e gerou imagens finais de apenas ~28 MB baseadas em Alpine Linux.

---

### 4. DynamoDB Local vs. AWS DynamoDB: Paridade de Ambientes e Idempotência

* **Contexto:** Houve uma aparente divergência de documentação no desafio:
  * O **PDF (página 4)** exige que o ambiente local execute um contêiner **DynamoDB Local** (`amazon/dynamodb-local`).
  * Já o **código-fonte e README do `analytics-service`** foram estruturados originalmente para conectar direto no DynamoDB da AWS via Boto3, sem aceitar parâmetro de endpoint customizado.
  * Além disso, a imagem oficial `amazon/dynamodb-local` inicia completamente limpa (sem nenhuma tabela provisionada).
* **Premissa Arquitetural:** O código da aplicação deveria seguir o princípio de **paridade de ambientes (*12-Factor App*)**: ter **uma única base de código** capaz de rodar tanto no ambiente de desenvolvimento local (Raspberry Pi / PC) quanto em produção na AWS (EKS), sem exigir alterações no código na hora da migração para a nuvem.
* **Decisão & Solução Adotada:**
  1. **Configuração via Variável de Ambiente:** Incluímos a leitura de `DYNAMODB_ENDPOINT_URL = os.getenv("DYNAMODB_ENDPOINT_URL")` no `analytics-service/app.py`. Se definida (local), o cliente Boto3 direciona as chamadas para `http://dynamodb-local:8000`; se ausente/vazia (nuvem), o Boto3 conecta automaticamente no endpoint nativo da AWS.
  2. **Criação Idempotente da Tabela (`ensure_dynamodb_table`):** Implementamos uma rotina no arranque do `analytics-service` que consulta a existência da tabela (`describe_table`). Se ela não existir (`ResourceNotFoundException`), a tabela `ToggleMasterAnalytics` é criada com a Partition Key `event_id`. Se a tabela já existir, a aplicação apenas segue a execução. Isso garantiu **idempotência total**: o Docker Compose pode ser iniciado e reiniciado infinitas vezes sem nunca falhar por conflito de tabela.

---

### 5. Cadeia de Autenticação Inter-serviços (M2M) e Resolução de Erros 401

* **Contexto:** Durante os testes ponta a ponta do hot path no `evaluation-service` (`/evaluate`), as requisições falhavam com `StatusBadGateway: flag-service retornou status 401`.
* **Impasse Técnico:** Os serviços `flag-service` e `targeting-service` possuem middlewares de autenticação estrita (`@require_auth`) que validam tokens contra o `auth-service`. Quando o `evaluation-service` consulta esses serviços internamente para resolver a decisão de uma flag, ele precisa se autenticar como um cliente válido.
* **Decisão & Solução Adotada:**
  * Compreendemos a dinâmica entre as duas chaves arquiteturais do sistema:
    * `MASTER_KEY`: chave administrativa usada exclusivamente para criar novas credenciais via `POST /admin/keys` no `auth-service`.
    * `SERVICE_API_KEY`: token de serviço gerado no `auth-service` e injetado via variável de ambiente no `evaluation-service`.
  * Configuramos a `SERVICE_API_KEY` gerada no arquivo `.env`. Com isso, as chamadas internas passaram a ser autorizadas com sucesso com retorno HTTP 200 e avaliação com cache no Redis.

---

### 6. Execução Multi-plataforma e Compatibilidade com ARM64 (Raspberry Pi 5)

* **Contexto:** Foi definida a meta de executar o projeto completo em um hardware de homelab dedicado: o **Raspberry Pi 5**.
* **Impasse Técnico:** O Raspberry Pi opera sobre arquitetura **ARM64 (aarch64)**, enquanto o ambiente comum de desenvolvimento utiliza **x86_64 (AMD64)**. Havia o risco de imagens oficiais ou dependências binárias em C (como `psycopg2` ou o binário do DynamoDB Local) não possuírem suporte nativo para ARM64, forçando emulação pesada.
* **Decisão & Solução Adotada:**
  * Analisamos os manifestos OCI de todas as imagens base utilizadas (`golang:1.21-alpine`, `alpine:3.19`, `python:3.10-slim`, `postgres:15-alpine`, `redis:7-alpine` e `amazon/dynamodb-local:latest`) e confirmamos suporte oficial multi-arquitetura nativo para `linux/arm64`.
  * A compilação em Go gera binários estáticos diretamente para a arquitetura alvo.
  * O consumo total de memória medido de todos os 9 contêineres somados ficou em torno de ~800 MB de RAM, garantindo que o Raspberry Pi 5 execute todo o ecossistema com folga de recursos.

---

### 7. Integração Híbrida Local com Fila AWS SQS Real

* **Contexto:** O projeto previa o uso de mensageria assíncrona entre o `evaluation-service` (produtor de eventos de telemetria) e o `analytics-service` (consumidor).
* **Impasse Técnico:** O roteiro do Tech Challenge não inclui um emulador de mensageria SQS local (como LocalStack) no escopo dos 4 bancos locais, exigindo o uso de uma fila real na AWS mesmo durante os testes locais.
* **Decisão & Solução Adotada:**
  * Provisionamos a fila Standard `togglemaster-events` no console da AWS na região `us-east-1`.
  * Mapeamos as credenciais temporárias do AWS Academy (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) e a `AWS_SQS_URL` no arquivo centralizado `.env`.
  * O teste funcional confirmou o ciclo completo: o `evaluation-service` publica eventos de avaliação na AWS SQS via internet, e o worker em background do `analytics-service` consome as mensagens da AWS em tempo real e persiste os dados no DynamoDB Local.
